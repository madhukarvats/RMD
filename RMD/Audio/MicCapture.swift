import AVFoundation
import CoreAudio

/// A slice of 16 kHz mono audio and the wall-clock time its first sample was heard.
struct AudioChunk: Sendable {
    let samples: [Float]
    let start: Date
}

/// Streams the default microphone as 16 kHz mono chunks. Nothing is written to disk.
/// When the microphone changes (AirPods connect, a call app switches devices) macOS stops the audio
/// engine, so a fresh one is started on the new microphone and the stream carries on.
@MainActor
final class MicCapture {
    struct NoMicrophone: Error {}

    nonisolated static let sampleRate = 16_000.0

    private var engine: AVAudioEngine?
    private var engineChanged: NSObjectProtocol?
    private var stopWatchingDevice: (() -> Void)?
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    private var restartAttempts = 0

    func start() throws -> AsyncStream<AudioChunk> {
        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
        self.continuation = continuation
        do {
            try startEngine()
        } catch {
            continuation.finish()
            self.continuation = nil
            throw error
        }
        stopWatchingDevice = AudioDevices.onDefaultDeviceChange(kAudioHardwarePropertyDefaultInputDevice) { [weak self] in
            self?.restart()
        }
        return stream
    }

    func stop() {
        stopWatchingDevice?()
        stopWatchingDevice = nil
        stopEngine()
        continuation?.finish()
        continuation = nil
    }

    private func restart() {
        guard continuation != nil else { return }
        stopEngine()
        do {
            try startEngine()
            restartAttempts = 0
        } catch {
            // A device that just connected can take a moment to be ready.
            restartAttempts += 1
            guard restartAttempts <= 5 else {
                print("RMD: the microphone didn't come back: \(error)")
                return
            }
            Task {
                try? await Task.sleep(for: .seconds(1))
                restart()
            }
        }
    }

    private func startEngine() throws {
        guard let continuation else { return }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else { throw NoMicrophone() }
        let resampler = try Resampler(from: inputFormat, toRate: Self.sampleRate)

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
            throw error
        }
        engineChanged = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restart() }
        }
        self.engine = engine
    }

    private func stopEngine() {
        if let engineChanged { NotificationCenter.default.removeObserver(engineChanged) }
        engineChanged = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
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
