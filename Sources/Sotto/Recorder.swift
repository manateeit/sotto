import AVFoundation
import Foundation
import os

/// Microphone capture via AVAudioEngine. Installs a tap on the input node and
/// hands each raw buffer to `onBuffer`; format conversion is the engine's job
/// (the transcriber picks its own preferred format), so the recorder stays
/// decoupled from any particular TranscriptionEngine.
final class Recorder {
    /// Called on the audio-tap thread for every captured buffer.
    var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    /// Called on the audio-tap thread with a normalized 0...1 level for the HUD.
    var onLevel: (@Sendable (Float) -> Void)?

    private let engine = AVAudioEngine()
    private var running = false
    /// The WAV writer, guarded by a lock: the tap thread writes to it while
    /// start/stop (main) open and close it (same shape as the M0 engine's state).
    private let audioFile = OSAllocatedUnfairLock<AVAudioFile?>(uncheckedState: nil)

    /// Start capture. If `writingWAVTo` is given, the raw mic audio is also written
    /// to that WAV (for open history/audio); a write failure never fails recording.
    func start(writingWAVTo url: URL? = nil) throws {
        guard !running else { return }
        let input = engine.inputNode
        // Tap in the input node's native hardware format; the engine converts.
        let format = input.outputFormat(forBus: 0)

        if let url {
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let file = try AVAudioFile(forWriting: url, settings: format.settings)
                audioFile.withLockUnchecked { $0 = file }
            } catch {
                NSLog("Sotto: couldn't open WAV for writing: \(error)")
                audioFile.withLockUnchecked { $0 = nil }
            }
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.onBuffer?(buffer)
            if let onLevel = self.onLevel {
                onLevel(Recorder.level(of: buffer))
            }
            // ponytail: writes on the tap thread (not the hard-realtime render
            // thread); move to a writer queue if disk I/O ever hitches capture.
            self.audioFile.withLockUnchecked { file in
                try? file?.write(from: buffer)
            }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            // Don't leave the tap installed — a later start() would stack a second
            // tap on the same bus and crash.
            input.removeTap(onBus: 0)
            audioFile.withLockUnchecked { $0 = nil }
            throw error
        }
        running = true
    }

    func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0) // synchronous: no more tap callbacks after this
        engine.stop()
        audioFile.withLockUnchecked { $0 = nil }
        running = false
    }

    var isRunning: Bool { running }

    /// RMS loudness of a buffer, mapped to a perceptual 0...1 for the waveform.
    /// Non-float buffers report 0 (the mic path is float32).
    static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }

        var sum: Float = 0
        for i in 0..<frames {
            let sample = channel[i]
            sum += sample * sample
        }
        let rms = (sum / Float(frames)).squareRoot()

        // Compress a wide dynamic range into something legible: floor quiet rooms,
        // scale speech into the upper part of the bar.
        let clamped = min(max(rms, 0), 1)
        return min(1, clamped * 6)
    }
}
