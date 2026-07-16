import AVFoundation
import Foundation
import ScreenCaptureKit

/// System-audio capture via ScreenCaptureKit — the native replacement for the
/// BlackHole virtual-device chain. Captures the audio of the whole display
/// (excluding this app's own output) without any audio routing setup.
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private var accumulator: ChunkAccumulator?
    private var sourceRate: Double = 48_000
    private let sampleQueue = DispatchQueue(label: "jerktionary.system-audio")
    private var onStopError: (@Sendable (String) -> Void)?

    func start(
        onChunk: @escaping @Sendable (Data) -> Void,
        onLevel: @escaping @Sendable (Double) -> Void,
        onStopError: @escaping @Sendable (String) -> Void
    ) async throws {
        self.onStopError = onStopError

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            throw BackendError(
                message: "Нет доступа к записи экрана (нужен для системного звука). " +
                    "Разрешите в System Settings → Privacy & Security → Screen & System Audio Recording и перезапустите приложение.",
                status: 0
            )
        }
        guard let display = content.displays.first else {
            throw BackendError(message: "Не найден дисплей для захвата системного звука.", status: 0)
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        // Video is mandatory for SCStream; keep it as cheap as possible.
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        sourceRate = 48_000
        let accumulator = ChunkAccumulator { chunk in
            onLevel(PCM.rmsLevel(chunk))
            onChunk(PCM.int16LEData(from: chunk, sourceSampleRate: 48_000))
        }
        self.accumulator = accumulator

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        accumulator = nil
        onStopError = nil
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        guard let samples = Self.monoSamples(from: sampleBuffer) else { return }
        accumulator?.append(samples)
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStopError?("Захват системного звука остановлен: \(error.localizedDescription)")
    }

    /// Deinterleaves/averages the CMSampleBuffer audio into mono floats.
    static func monoSamples(from sampleBuffer: CMSampleBuffer) -> [Float]? {
        guard let formatDescription = sampleBuffer.formatDescription,
              let asbd = formatDescription.audioStreamBasicDescription
        else { return nil }

        var bufferListSizeNeeded = 0
        var blockBuffer: CMBlockBuffer?
        // First query the needed AudioBufferList size (non-interleaved = one buffer per channel).
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &bufferListSizeNeeded,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: nil
        ) == noErr else { return nil }

        let bufferListPointer = UnsafeMutableRawPointer.allocate(
            byteCount: bufferListSizeNeeded,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { bufferListPointer.deallocate() }
        let audioBufferList = bufferListPointer.assumingMemoryBound(to: AudioBufferList.self)

        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: audioBufferList,
            bufferListSize: bufferListSizeNeeded,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        ) == noErr else { return nil }

        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        guard !buffers.isEmpty else { return nil }

        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        guard isFloat else { return nil } // SCK delivers float32; anything else is unexpected.

        let isInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
        if isInterleaved {
            let buffer = buffers[0]
            guard let rawData = buffer.mData else { return nil }
            let channelCount = max(1, Int(buffer.mNumberChannels))
            let totalFloats = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let frames = totalFloats / channelCount
            let floats = rawData.assumingMemoryBound(to: Float.self)
            if channelCount == 1 {
                return Array(UnsafeBufferPointer(start: floats, count: frames))
            }
            var mono = [Float](repeating: 0, count: frames)
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channelCount {
                    sum += floats[frame * channelCount + channel]
                }
                mono[frame] = sum / Float(channelCount)
            }
            return mono
        }

        // Non-interleaved: one AudioBuffer per channel.
        let channelBuffers = buffers.compactMap { buffer -> UnsafeBufferPointer<Float>? in
            guard let rawData = buffer.mData else { return nil }
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            return UnsafeBufferPointer(start: rawData.assumingMemoryBound(to: Float.self), count: count)
        }
        guard let first = channelBuffers.first else { return nil }
        if channelBuffers.count == 1 {
            return Array(first)
        }
        let frames = channelBuffers.map(\.count).min() ?? 0
        var mono = [Float](repeating: 0, count: frames)
        for buffer in channelBuffers {
            for frame in 0..<frames {
                mono[frame] += buffer[frame]
            }
        }
        let scale = 1 / Float(channelBuffers.count)
        for frame in 0..<frames {
            mono[frame] *= scale
        }
        return mono
    }
}
