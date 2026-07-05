import AVFoundation
import Foundation
import Speech
import os

/// One of the two protocol seams in the app (see DESIGN.md §2). The MVP
/// implementation is `SpeechAnalyzerEngine`; `ParakeetEngine` (FluidAudio) is the
/// planned second implementation that justifies the seam.
///
/// Lifecycle for one dictation:
///   prepare() once at launch → beginSession() → append(buffer)* → finishSession()
protocol TranscriptionEngine: AnyObject, Sendable {
    /// Ensure on-device model assets are installed. May download on first run;
    /// `status` receives human-readable progress for the menu-bar line.
    func prepare(status: @escaping @Sendable (String) -> Void) async throws

    /// Open a streaming transcription session. Returns once the analyzer is
    /// consuming input; call `append` with mic buffers afterwards.
    func beginSession() async throws

    /// Feed a raw microphone buffer. The engine converts to its own preferred
    /// format internally. Safe to call from the audio-tap thread.
    func append(_ buffer: AVAudioPCMBuffer)

    /// Finalize the session and return the full transcript.
    func finishSession() async throws -> String

    /// Abort the session, discarding any partial transcript.
    func cancelSession() async
}

enum TranscriptionError: Error, CustomStringConvertible {
    case unavailable
    case localeUnsupported

    var description: String {
        switch self {
        case .unavailable:
            return "SpeechTranscriber is unavailable on this device."
        case .localeUnsupported:
            return "No supported speech locale for this system."
        }
    }
}

/// MVP transcription engine backed by Apple's SpeechAnalyzer / SpeechTranscriber
/// (Speech framework, macOS 26). On-device, ANE-accelerated, zero model downloads
/// beyond the first-run asset install handled here via AssetInventory.
///
/// Threading: `append` runs on the AVAudioEngine tap thread. It only deep-copies
/// the buffer (tap buffers are valid solely within the callback) and hands it to a
/// dedicated serial queue; that queue owns the AVAudioConverter and does the
/// actual format conversion, keeping that work off the tap thread. All per-session
/// state lives in `Session` behind `lock`, so the serial queue's reads never race
/// the MainActor lifecycle methods (`beginSession` / `finishSession` /
/// `cancelSession`) that publish and tear it down. `@unchecked Sendable` is honest
/// because every shared field is immutable or accessed only under `lock`.
///
// ponytail: the tap callback still allocates (the buffer copy) and dispatches, so
// it is not hard-realtime-safe. AVAudioEngine taps are not the CoreAudio render
// thread, so this is acceptable here; a future AURenderCallback path would need a
// preallocated lock-free ring buffer instead of copy + dispatch.
final class SpeechAnalyzerEngine: TranscriptionEngine, @unchecked Sendable {
    /// Everything that lives for the duration of one dictation. Guarded by `lock`.
    private struct Session {
        var transcriber: SpeechTranscriber?
        var analyzer: SpeechAnalyzer?
        var format: AVAudioFormat?
        var continuation: AsyncStream<AnalyzerInput>.Continuation?
        var recognizerTask: Task<String, Error>?
    }

    private let lock = OSAllocatedUnfairLock(uncheckedState: Session())
    private let processingQueue = DispatchQueue(label: "com.chrismckenna.sotto.transcribe")
    private let converter = BufferConverter() // touched only on processingQueue
    private var resolvedLocale: Locale?        // touched only on the async lifecycle path

    // MARK: TranscriptionEngine

    func prepare(status: @escaping @Sendable (String) -> Void) async throws {
        guard SpeechTranscriber.isAvailable else { throw TranscriptionError.unavailable }
        let locale = try await resolveLocale()

        let installed = await SpeechTranscriber.installedLocales
        let bcp47 = locale.identifier(.bcp47)
        let alreadyInstalled = installed.contains { $0.identifier(.bcp47) == bcp47 }

        if !alreadyInstalled {
            status("Preparing speech model…")
            let module = SpeechTranscriber(
                locale: locale,
                transcriptionOptions: [],
                reportingOptions: [],
                attributeOptions: []
            )
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                let progress = request.progress
                let poller = Task {
                    while !Task.isCancelled {
                        let pct = Int((progress.fractionCompleted * 100).rounded())
                        status("Downloading speech model… \(pct)%")
                        try? await Task.sleep(nanoseconds: 300_000_000)
                    }
                }
                defer { poller.cancel() }
                try await request.downloadAndInstall()
            }
        }

        // Keep the model reserved so the OS doesn't evict it. Best-effort.
        _ = try? await AssetInventory.reserve(locale: locale)
        status("Ready")
    }

    func beginSession() async throws {
        let locale = try await resolveLocale()

        // No volatile results requested, so every result the stream delivers is
        // finalized text — we just accumulate them (guarded by `.isFinal` anyway).
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: []
        )
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()

        let task = Task {
            var transcript = AttributedString()
            for try await result in transcriber.results where result.isFinal {
                transcript.append(result.text)
            }
            return String(transcript.characters)
        }

        lock.withLockUnchecked {
            $0.transcriber = transcriber
            $0.analyzer = analyzer
            $0.format = format
            $0.continuation = continuation
            $0.recognizerTask = task
        }

        try await analyzer.start(inputSequence: stream)
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        // Tap buffers are only valid during this callback; copy before deferring
        // the (allocating) conversion work onto the serial queue.
        guard let copy = Self.copyBuffer(buffer) else { return }
        processingQueue.async { [weak self] in
            self?.process(copy)
        }
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        let (format, continuation) = lock.withLockUnchecked { ($0.format, $0.continuation) }
        guard let format, let continuation else { return }
        do {
            let converted = try converter.convert(buffer, to: format)
            continuation.yield(AnalyzerInput(buffer: converted))
        } catch {
            NSLog("Sotto: buffer conversion failed: \(error)")
        }
    }

    func finishSession() async throws -> String {
        defer { teardown() }
        // Drain buffers still queued for conversion so their audio reaches the
        // analyzer before we finalize.
        processingQueue.sync {}
        let (continuation, analyzer, task) = lock.withLockUnchecked {
            ($0.continuation, $0.analyzer, $0.recognizerTask)
        }
        continuation?.finish()
        try await analyzer?.finalizeAndFinishThroughEndOfInput()
        let text = try await task?.value ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cancelSession() async {
        defer { teardown() }
        let (continuation, analyzer, task) = lock.withLockUnchecked {
            ($0.continuation, $0.analyzer, $0.recognizerTask)
        }
        continuation?.finish()
        await analyzer?.cancelAndFinishNow()
        task?.cancel()
    }

    // MARK: Helpers

    private func teardown() {
        lock.withLockUnchecked { $0 = Session() }
    }

    private func resolveLocale() async throws -> Locale {
        if let resolvedLocale { return resolvedLocale }
        let candidates = [Locale.current, Locale(identifier: "en-US")]
        for candidate in candidates {
            if let supported = await SpeechTranscriber.supportedLocale(equivalentTo: candidate) {
                resolvedLocale = supported
                return supported
            }
        }
        throw TranscriptionError.localeUnsupported
    }

    /// Deep-copies a PCM buffer so it outlives the tap callback that produced it.
    private static func copyBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameCapacity) else {
            return nil
        }
        copy.frameLength = buffer.frameLength
        let channels = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)
        if let src = buffer.floatChannelData, let dst = copy.floatChannelData {
            for ch in 0..<channels { memcpy(dst[ch], src[ch], frames * MemoryLayout<Float>.size) }
        } else if let src = buffer.int16ChannelData, let dst = copy.int16ChannelData {
            for ch in 0..<channels { memcpy(dst[ch], src[ch], frames * MemoryLayout<Int16>.size) }
        } else if let src = buffer.int32ChannelData, let dst = copy.int32ChannelData {
            for ch in 0..<channels { memcpy(dst[ch], src[ch], frames * MemoryLayout<Int32>.size) }
        } else {
            return nil
        }
        return copy
    }
}

/// Converts microphone buffers to the format SpeechAnalyzer asks for, reusing one
/// AVAudioConverter across calls. Pattern from Apple's WWDC25 session 277 sample.
/// Not thread-safe by itself — SpeechAnalyzerEngine only touches it on its serial
/// processing queue.
final class BufferConverter {
    enum Error: Swift.Error {
        case failedToCreateConverter
        case failedToCreateBuffer
        case conversionFailed(NSError?)
    }

    private var converter: AVAudioConverter?

    func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let inputFormat = buffer.format
        guard inputFormat != format else { return buffer }

        if converter == nil || converter?.outputFormat != format || converter?.inputFormat != inputFormat {
            converter = AVAudioConverter(from: inputFormat, to: format)
            // Sacrifice first-sample quality to avoid timestamp drift on the stream.
            converter?.primeMethod = .none
        }
        guard let converter else { throw Error.failedToCreateConverter }

        let ratio = format.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up))
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw Error.failedToCreateBuffer
        }

        var error: NSError?
        var supplied = false
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            defer { supplied = true }
            inputStatus.pointee = supplied ? .noDataNow : .haveData
            return supplied ? nil : buffer
        }
        guard status != .error else { throw Error.conversionFailed(error) }
        return output
    }
}
