import AVFoundation
import CoreAudio

/// Streams what the Mac plays (on a call: the other people) as 16 kHz mono chunks, through a Core Audio
/// tap on all output, taken before it reaches the speaker or AirPods; what the user hears is unchanged.
/// Nothing is written to disk. macOS asks once to allow "System Audio Recording". When the speaker changes
/// (AirPods connect) the tap starts over on the new one and the stream carries on.
@MainActor
final class SystemAudioCapture {
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    private var stopWatchingDevice: (() -> Void)?

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
        return stream
    }

    func stop() {
        stopWatchingDevice?()
        stopWatchingDevice = nil
        stopTap()
        continuation?.finish()
        continuation = nil
    }

    private func restart() {
        guard continuation != nil else { return }
        stopTap()
        do {
            try startTap()
        } catch {
            print("RMD: couldn't follow the new speaker: \(error)")
        }
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

            try AudioDevices.check(AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggregate, nil) { @Sendable _, input, _, _, _ in
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil) else { return }
                let heardAt = Date.now.addingTimeInterval(-Double(buffer.frameLength) / format.sampleRate)
                guard let samples = resampler.convert(buffer), !samples.isEmpty else { return }
                continuation.yield(AudioChunk(samples: samples, start: heardAt))
            }, "read the Mac's audio")
            try AudioDevices.check(AudioDeviceStart(aggregate, ioProc), "start reading the Mac's audio")
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
