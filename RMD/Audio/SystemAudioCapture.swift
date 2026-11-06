import AVFoundation
import CoreAudio
import os

/// Streams what the Mac plays (on a call: the other people) as 16 kHz mono chunks, through a Core Audio
/// tap on all output, taken before it reaches the speaker or AirPods; what the user hears is unchanged.
/// Nothing is written to disk. macOS asks once to allow "System Audio Recording".
///
/// When the speaker changes (AirPods connect) the tap starts over on the new one and the stream carries on.
/// A tap built while the speaker is still switching can come up dead, with no error and no audio (once
/// the other side of a call was missing for 26 minutes). A healthy tap delivers buffers whenever any app
/// has the speaker running, silence included, so one that delivers nothing for 10 s while the speaker
/// is running is rebuilt.
@MainActor
final class SystemAudioCapture {
    /// Called with true when the Mac's audio can't be read (RMD keeps trying), and with false once it can.
    var onTrouble: ((Bool) -> Void)?

    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    private var stopWatchingDevice: (() -> Void)?
    private var restarting: Task<Void, Never>?
    private var watching: Task<Void, Never>?
    private let lastBuffer = OSAllocatedUnfairLock(initialState: Date.now)
    private var inTrouble = false

    func start() throws -> AsyncStream<AudioChunk> {
        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
        self.continuation = continuation
        do {
            try startTap()
        } catch {
            continuation.finish()
            self.continuation = nil
            throw error
        }
        stopWatchingDevice = AudioDevices.onDefaultDeviceChange(kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in
            self?.restart()
        }
        watching = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled, self.continuation != nil else { return }
                // Silence is fine while nothing plays. Counting only from when playback starts also keeps
                // the check out of the moment a speaker starts up, when the first buffer is still on its way.
                guard AudioDevices.speakerIsRunning() else {
                    self.lastBuffer.withLock { $0 = .now }
                    continue
                }
                if Date.now.timeIntervalSince(self.lastBuffer.withLock { $0 }) > 10 {
                    Log.audio.error("the tap on the Mac's audio went quiet while the speaker is running; rebuilding it")
                    self.restart()
                }
            }
        }
        return stream
    }

    func stop() {
        stopWatchingDevice?()
        stopWatchingDevice = nil
        restarting?.cancel()
        restarting = nil
        watching?.cancel()
        watching = nil
        stopTap()
        continuation?.finish()
        continuation = nil
    }

    /// Builds a new tap, after a moment for a speaker that just connected to settle. If that fails, the
    /// 10 s check brings it back here once something plays, for as long as the call lasts.
    private func restart() {
        guard continuation != nil else { return }
        restarting?.cancel()
        stopTap()
        lastBuffer.withLock { $0 = .now }  // the new tap gets its 10 s before the check looks again
        restarting = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, continuation != nil else { return }
            do {
                try startTap()
                report(trouble: false)
            } catch {
                Log.audio.error("couldn't read the Mac's audio after a change: \(String(describing: error), privacy: .public)")
                report(trouble: true)
            }
        }
    }

    private func report(trouble: Bool) {
        guard trouble != inTrouble else { return }
        inTrouble = trouble
        onTrouble?(trouble)
    }

    private func startTap() throws {
        guard let continuation else { return }
        do {
            let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
            description.uuid = UUID()
            description.isPrivate = true
            description.muteBehavior = .unmuted
            try AudioDevices.check(AudioHardwareCreateProcessTap(description, &tap), "tap the Mac's audio")

            // A tap is read through a private "aggregate" device built around the current speaker.
            let speaker = try AudioDevices.defaultOutputUID()
            let settings: [String: Any] = [
                kAudioAggregateDeviceNameKey: "RMD computer audio",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: speaker,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: speaker]],
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]],
            ]
            try AudioDevices.check(AudioHardwareCreateAggregateDevice(settings as CFDictionary, &aggregate), "set up reading the Mac's audio")

            var streamFormat = AudioStreamBasicDescription()
            try AudioDevices.read(tap, kAudioTapPropertyFormat, into: &streamFormat)
            guard let format = AVAudioFormat(streamDescription: &streamFormat) else { throw Resampler.UnsupportedFormat() }
            let resampler = try Resampler(from: format, toRate: MicCapture.sampleRate)

            let lastBuffer = lastBuffer
            try AudioDevices.check(AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggregate, nil) { @Sendable _, input, _, _, _ in
                lastBuffer.withLock { $0 = .now }
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil) else { return }
                let heardAt = Date.now.addingTimeInterval(-Double(buffer.frameLength) / format.sampleRate)
                guard let samples = resampler.convert(buffer), !samples.isEmpty else { return }
                continuation.yield(AudioChunk(samples: samples, start: heardAt))
            }, "read the Mac's audio")
            try AudioDevices.check(AudioDeviceStart(aggregate, ioProc), "start reading the Mac's audio")
            lastBuffer.withLock { $0 = .now }
        } catch {
            stopTap()
            throw error
        }
    }

    private func stopTap() {
        if aggregate != kAudioObjectUnknown {
            if let ioProc {
                AudioDeviceStop(aggregate, ioProc)
                AudioDeviceDestroyIOProcID(aggregate, ioProc)
            }
            AudioHardwareDestroyAggregateDevice(aggregate)
        }
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
        ioProc = nil
        aggregate = kAudioObjectUnknown
        tap = kAudioObjectUnknown
    }
}
