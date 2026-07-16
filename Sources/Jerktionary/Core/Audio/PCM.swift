import Foundation

/// PCM conversion helpers — a port of the web pcm-converter: linear resampling
/// to 16 kHz mono and little-endian int16 packing, so the backend receives the
/// exact same byte format as from the Electron client.
enum PCM {
    static let targetSampleRate = 16_000.0
    /// Same chunking as the Electron audio worklet: 4096 source frames per send.
    static let chunkFrames = 4096

    static func int16LEData(from samples: [Float], sourceSampleRate: Double) -> Data {
        let resampled = resampleLinear(samples, from: sourceSampleRate, to: targetSampleRate)
        var data = Data(capacity: resampled.count * 2)
        for sample in resampled {
            let clamped = max(-1, min(1, sample))
            let value = Int16(clamped < 0 ? clamped * 0x8000 : clamped * 0x7FFF)
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    static func rmsLevel(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        var sum = 0.0
        for sample in samples {
            sum += Double(sample) * Double(sample)
        }
        return min(1, (sum / Double(samples.count)).squareRoot() * 4)
    }

    static func resampleLinear(_ input: [Float], from source: Double, to target: Double) -> [Float] {
        guard source != target, !input.isEmpty else { return input }
        let ratio = source / target
        let outputLength = max(1, Int((Double(input.count) / ratio).rounded()))
        var output = [Float](repeating: 0, count: outputLength)
        for index in 0..<outputLength {
            let sourceIndex = Double(index) * ratio
            let left = Int(sourceIndex)
            let right = min(left + 1, input.count - 1)
            let fraction = Float(sourceIndex - Double(left))
            output[index] = input[left] + (input[right] - input[left]) * fraction
        }
        return output
    }
}

/// Accumulates incoming mono float samples and emits fixed-size chunks —
/// the counterpart of the Electron AudioWorklet processor.
final class ChunkAccumulator {
    private var buffer: [Float] = []
    private let chunkSize: Int
    private let onChunk: ([Float]) -> Void

    init(chunkSize: Int = PCM.chunkFrames, onChunk: @escaping ([Float]) -> Void) {
        self.chunkSize = chunkSize
        self.onChunk = onChunk
    }

    func append(_ samples: [Float]) {
        buffer.append(contentsOf: samples)
        while buffer.count >= chunkSize {
            let chunk = Array(buffer.prefix(chunkSize))
            buffer.removeFirst(chunkSize)
            onChunk(chunk)
        }
    }
}
