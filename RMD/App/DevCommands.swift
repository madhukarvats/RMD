import AVFoundation

/// `RMD --transcribe <audio file>` runs a file through the same path as the mic
/// (silence skipping → speech model) and prints timestamped lines. Nothing is saved.
enum DevCommands {
    static func runIfRequested() {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--transcribe"), flag + 1 < arguments.count else { return }
        let url = URL(filePath: arguments[flag + 1])
        Task {
            do {
                try await transcribe(url)
            } catch {
                print("error: \(error)")
            }
            exit(0)
        }
    }

    private static func transcribe(_ url: URL) async throws {
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { return }
        try file.read(into: buffer)
        let samples = try Resampler(from: file.processingFormat, toRate: MicCapture.sampleRate).convert(buffer) ?? []

        let loadStart = Date.now
        let transcriber = try await WhisperKitTranscriber.load { print(String(format: "downloading model %.0f%%", $0 * 100)) }
        print(String(format: "model ready in %.1fs", Date.now.timeIntervalSince(loadStart)))

        // Feed the file in 100 ms chunks, as the mic would, with clock times starting now.
        let origin = Date.now
        let chunkSize = Int(MicCapture.sampleRate / 10)
        var segmenter = SpeechSegmenter()
        var utterances: [Utterance] = []
        for offset in stride(from: 0, to: samples.count, by: chunkSize) {
            let chunk = Array(samples[offset..<min(offset + chunkSize, samples.count)])
            let start = origin.addingTimeInterval(Double(offset) / MicCapture.sampleRate)
            utterances += segmenter.append(AudioChunk(samples: chunk, start: start))
        }
        utterances += [segmenter.flush()].compactMap { $0 }

        for utterance in utterances {
            let began = Date.now
            let transcript = try await transcriber.transcribe(utterance.samples)
            let offset = utterance.start.timeIntervalSince(origin)
            let length = utterance.end.timeIntervalSince(utterance.start)
            print(String(format: "+%05.1fs (%4.1fs speech, %.1fs to transcribe) [%@] %@",
                         offset, length, Date.now.timeIntervalSince(began),
                         transcript?.language ?? "-", transcript?.text ?? "(no speech)"))
        }
    }
}
