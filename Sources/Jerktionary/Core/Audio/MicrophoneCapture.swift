import AVFoundation
import Foundation

/// Microphone capture via AVAudioEngine: taps the input node, averages to mono,
/// chunks by 4096 source frames, and emits 16 kHz int16 PCM + an RMS level.
final class MicrophoneCapture {
    private let engine = AVAudioEngine()
    private var accumulator: ChunkAccumulator?

    /// - Parameter deviceUID: CoreAudio UID of the preferred input; empty = default.
    func start(
        deviceUID: String,
        onChunk: @escaping @Sendable (Data) -> Void,
        onLevel: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard await Self.requestMicAccess() else {
            throw BackendError(
                message: "Нет доступа к микрофону. Разрешите в System Settings → Privacy & Security → Microphone.",
                status: 0
            )
        }

        let inputNode = engine.inputNode
        if let deviceID = AudioDevices.deviceID(forUID: deviceUID) {
            try setInputDevice(deviceID)
        }

        let format = inputNode.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw BackendError(message: "Микрофон не найден или недоступен.", status: 0)
        }
        let sourceRate = format.sampleRate

        let accumulator = ChunkAccumulator { chunk in
            onLevel(PCM.rmsLevel(chunk))
            onChunk(PCM.int16LEData(from: chunk, sourceSampleRate: sourceRate))
        }
        self.accumulator = accumulator

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            accumulator.append(Self.monoSamples(from: buffer))
        }

        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        accumulator = nil
    }

    /// Averages all channels into mono, matching Web Audio's default mixdown.
    static func monoSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channels = buffer.floatChannelData else { return [] }
        let frames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frames > 0, channelCount > 0 else { return [] }

        if channelCount == 1 {
            return Array(UnsafeBufferPointer(start: channels[0], count: frames))
        }
        var mono = [Float](repeating: 0, count: frames)
        for channel in 0..<channelCount {
            let pointer = channels[channel]
            for frame in 0..<frames {
                mono[frame] += pointer[frame]
            }
        }
        let scale = 1 / Float(channelCount)
        for frame in 0..<frames {
            mono[frame] *= scale
        }
        return mono
    }

    private func setInputDevice(_ deviceID: AudioDeviceID) throws {
        guard let audioUnit = engine.inputNode.audioUnit else {
            throw BackendError(message: "Не удалось получить аудиоюнит входа.", status: 0)
        }
        var device = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &device,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        // A stale saved device must not break capture — fall back to the default.
        if status != noErr {
            NSLog("Jerktionary: falling back to default input, AudioUnitSetProperty=\(status)")
        }
    }

    static func requestMicAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }
}
