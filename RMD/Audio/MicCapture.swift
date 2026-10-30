import AVFoundation

/// A slice of 16 kHz mono audio and the wall-clock time its first sample was heard.
struct AudioChunk: Sendable {
    let samples: [Float]
    let start: Date
}

/// Streams the default microphone as 16 kHz mono chunks. Nothing is written to disk.
final class MicCapture {
    static let sampleRate = 16_000.0

    private let engine = AVAudioEngine()
    private var continuation: AsyncStream<AudioChunk>.Continuation?

    func start() throws -> AsyncStream<AudioChunk> {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        let resampler = try Resampler(from: inputFormat, toRate: Self.sampleRate)
        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
        self.continuation = continuation

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { @Sendable buffer, _ in
            let heardAt = Date.now.addingTimeInterval(-Double(buffer.frameLength) / inputFormat.sampleRate)
            guard let samples = resampler.convert(buffer), !samples.isEmpty else { return }
            continuation.yield(AudioChunk(samples: samples, start: heardAt))
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            continuation.finish()
            throw error
        }
        return stream
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation?.finish()
        continuation = nil
    }
}

/// Converts device-format buffers to mono Float32 at a fixed rate.
/// Not thread-safe: use one instance per stream, one buffer at a time.
final class Resampler: @unchecked Sendable {
    struct UnsupportedFormat: Error {}

    private let converter: AVAudioConverter
    private let target: AVAudioFormat

    init(from source: AVAudioFormat, toRate rate: Double) throws {
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: source, to: target)
        else { throw UnsupportedFormat() }
        self.target = target
        self.converter = converter
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }

        var delivered = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if delivered {
                status.pointee = .noDataNow
                return nil
            }
            delivered = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = output.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}
