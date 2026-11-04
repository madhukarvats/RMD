import AVFoundation
import CoreAudio
import Synchronization

/// A slice of 16 kHz mono audio and the wall-clock time its first sample was heard.
struct AudioChunk: Sendable {
    let samples: [Float]
    let start: Date
}

/// Streams the default microphone as 16 kHz mono chunks. Nothing is written to disk.
/// When the microphone changes (AirPods connect, a call app switches devices) macOS stops the audio
/// engine, so a fresh one is started on the new microphone and the stream carries on.
///
/// The engine is only used on its own queue, never the main thread: macOS's audio engine can get stuck
/// for good while starting on a microphone that is still connecting or going away (once it spun for
/// 15 hours in `inputNode`, freezing the menu and the call watcher). A start that hasn't finished in 10 s
/// is reported through `onStuck`; only a fresh copy of RMD gets the microphone back after that.
@MainActor
final class MicCapture {
    struct NoMicrophone: Error {}
    struct Stuck: Error {}

    nonisolated static let sampleRate = 16_000.0

    /// Called when the audio engine stops answering while the microphone restarts.
    var onStuck: (() -> Void)?

    private let engine = MicEngine()
    private var stopWatchingDevice: (() -> Void)?
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    private var restarting: Task<Void, Never>?

    func start() async throws -> AsyncStream<AudioChunk> {
        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
        self.continuation = continuation
        do {
            try await startEngine()
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
        restarting?.cancel()
        restarting = nil
        engine.stop()
        continuation?.finish()
        continuation = nil
    }

    /// A microphone that just connected can take a moment to be ready, so the new engine starts after a
    /// short wait, with a few more tries if needed. Changes in quick succession lead to one restart.
    private func restart() {
        guard continuation != nil else { return }
        restarting?.cancel()
        restarting = Task {
            for _ in 1...5 {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                do {
                    try await startEngine()
                    return
                } catch is Stuck {
                    onStuck?()
                    return
                } catch {
                    print("RMD: the microphone isn't ready yet: \(error)")
                }
            }
            print("RMD: the microphone didn't come back")
        }
    }

    private func startEngine() async throws {
        guard let continuation else { return }
        let engine = engine
        try await engine.run {
            try engine.start(into: continuation) { [weak self] in
                Task { @MainActor in self?.restart() }
            }
        }
    }
}

/// The audio engine itself, only ever used on `queue`.
private final class MicEngine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "RMD.microphone")
    private var engine: AVAudioEngine?
    private var changed: NSObjectProtocol?

    /// Runs `work` on the queue. Throws `MicCapture.Stuck` if it hasn't returned 10 s after it began.
    func run(_ work: @escaping @Sendable () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, any Error>) in
            let once = ResumeOnce(done)
            queue.async {
                DispatchQueue.global().asyncAfter(deadline: .now() + 10) { once.resume(throwing: MicCapture.Stuck()) }
                do {
                    try work()
                    once.resume()
                } catch {
                    once.resume(throwing: error)
                }
            }
        }
    }

    /// Replaces any running engine with a new one on the current default microphone.
    /// `onChange` is called (on any thread) when macOS stops the engine because the device changed.
    func start(into continuation: AsyncStream<AudioChunk>.Continuation, onChange: @escaping @Sendable () -> Void) throws {
        stopNow()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else { throw MicCapture.NoMicrophone() }
        let resampler = try Resampler(from: inputFormat, toRate: MicCapture.sampleRate)

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
        changed = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { _ in
            onChange()
        }
        self.engine = engine
    }

    func stop() {
        queue.async { self.stopNow() }
    }

    private func stopNow() {
        if let changed { NotificationCenter.default.removeObserver(changed) }
        changed = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }
}

/// Resumes a continuation once: whichever comes first, the work finishing or its time limit.
private final class ResumeOnce: Sendable {
    private let continuation: Mutex<CheckedContinuation<Void, any Error>?>

    init(_ continuation: CheckedContinuation<Void, any Error>) {
        self.continuation = Mutex(continuation)
    }

    func resume(throwing error: (any Error)? = nil) {
        guard let continuation = continuation.withLock({ waiting in
            defer { waiting = nil }
            return waiting
        }) else { return }
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
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
