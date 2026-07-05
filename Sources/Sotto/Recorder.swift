import AVFoundation
import Foundation

/// Microphone capture via AVAudioEngine. Installs a tap on the input node and
/// hands each raw buffer to `onBuffer`; format conversion is the engine's job
/// (the transcriber picks its own preferred format), so the recorder stays
/// decoupled from any particular TranscriptionEngine.
final class Recorder {
    /// Called on the audio-tap thread for every captured buffer.
    var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?

    private let engine = AVAudioEngine()
    private var running = false

    func start() throws {
        guard !running else { return }
        let input = engine.inputNode
        // Tap in the input node's native hardware format; the engine converts.
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.onBuffer?(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            // Don't leave the tap installed — a later start() would stack a second
            // tap on the same bus and crash.
            input.removeTap(onBus: 0)
            throw error
        }
        running = true
    }

    func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
    }

    var isRunning: Bool { running }
}
