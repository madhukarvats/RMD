import AVFoundation
import Observation

/// Owns "recording my day": mic → silence skipping → local speech-to-text → transcript store.
/// Audio only ever lives in memory; just the text is saved.
@MainActor
@Observable
final class DayRecorder {
    enum State: Equatable {
        case off
        case preparing(String)
        case on(since: Date)
        case micDenied
        case failed(String)
    }

    private(set) var state: State = .off

    private var store: TranscriptStore?
    private var transcriber: Transcriber?
    private var loadingModel: Task<Transcriber, any Error>?
    private var mic: MicCapture?
    private var pipeline: Task<Void, Never>?
    /// Bumped by every switch on or off, so a start that was waiting (for mic access or the
    /// model) can tell it has been overtaken and must not start the mic.
    private var generation = 0

    var isOn: Bool {
        switch state {
        case .on, .preparing: true
        default: false
        }
    }

    func setOn(_ on: Bool) async {
        on ? await start() : stop()
    }

    private func start() async {
        guard !isOn else { return }
        generation += 1
        let attempt = generation
        state = .preparing("Starting…")

        guard await Self.micAccessGranted() else {
            if attempt == generation { state = .micDenied }
            return
        }
        guard attempt == generation else { return }  // switched off while asking for the mic
        do {
            let store = try openStore()
            Vocabulary.createIfMissing()
            let transcriber = try await loadTranscriber()
            guard attempt == generation else { return }  // switched off while the model was loading
            let comparison = try await loadComparison(main: transcriber)
            guard attempt == generation else { return }

            let mic = MicCapture()
            let audio = try mic.start()
            self.mic = mic
            state = .on(since: .now)
            pipeline = Task.detached {
                await Self.run(audio: audio, transcriber: transcriber, comparison: comparison, store: store)
            }
        } catch {
            if attempt == generation { state = .failed(error.localizedDescription) }
        }
    }

    private func stop() {
        generation += 1
        // Finishing the audio stream lets the pipeline transcribe what it already heard, then end.
        mic?.stop()
        mic = nil
        pipeline = nil
        state = .off
    }

    private func openStore() throws -> TranscriptStore {
        if let store { return store }
        let store = try TranscriptStore(url: TranscriptStore.defaultURL())
        self.store = store
        return store
    }

    /// Loads the model once. A switch off → on while it loads waits for the same load.
    private func loadTranscriber() async throws -> Transcriber {
        if let transcriber { return transcriber }
        state = .preparing("Loading speech model…")
        let progress: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in
                guard let self, case .preparing = self.state else { return }
                self.state = .preparing("Downloading speech model… \(Int(fraction * 100))%")
            }
        }
        let loading = loadingModel ?? Task { try await WhisperKitTranscriber.load(progress: progress) as Transcriber }
        loadingModel = loading
        defer { loadingModel = nil }  // after a failure, the next switch-on tries again

        let transcriber = try await loading.value
        self.transcriber = transcriber
        return transcriber
    }

    /// Compare mode, for choosing a speech engine: `defaults write com.madhukarsharma.RMD compareEngines -bool YES`,
    /// then switch RMD off and on. Every line is also run through Apple's dictation and all versions are logged
    /// side by side in engine-comparison.jsonl (text only). The transcript itself still comes from the main engine.
    private func loadComparison(main: Transcriber) async throws -> EngineComparison? {
        guard UserDefaults.standard.bool(forKey: "compareEngines") else { return nil }
        state = .preparing("Loading engines to compare…")
        return await EngineComparison.load(main: main, log: try ComparisonLog())
    }

    private nonisolated static func run(
        audio: AsyncStream<AudioChunk>,
        transcriber: Transcriber,
        comparison: EngineComparison?,
        store: TranscriptStore
    ) async {
        // Segmenting never waits on the model, so a slow transcription can't drop audio.
        let (utterances, queue) = AsyncStream.makeStream(of: Utterance.self)
        let segmenting = Task {
            var segmenter = SpeechSegmenter()
            for await chunk in audio {
                for utterance in segmenter.append(chunk) { queue.yield(utterance) }
            }
            if let last = segmenter.flush() { queue.yield(last) }
            queue.finish()
        }

        for await utterance in utterances {
            do {
                let heard = if let comparison {
                    try await comparison.transcribeAndLog(utterance)
                } else {
                    try await transcriber.transcribe(utterance.samples)
                }
                guard let transcript = heard else { continue }
                _ = try await store.insert(TranscriptLine(
                    start: utterance.start,
                    end: utterance.end,
                    source: .me,
                    text: transcript.text,
                    language: transcript.language
                ))
            } catch {
                print("RMD: dropped an utterance: \(error)")
            }
        }
        await segmenting.value
    }

    private static func micAccessGranted() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }
}
