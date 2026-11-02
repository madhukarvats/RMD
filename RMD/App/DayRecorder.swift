import AVFoundation
import Observation

/// Owns "recording my day": mic (and, on calls, the Mac's audio) → silence skipping → local speech-to-text
/// → transcript store. Audio only ever lives in memory; just the text is saved.
///
/// Calls: while a call app uses the microphone, RMD also records the other side of the call from the
/// Mac's audio, as "Others". If RMD was off when the call started, it records the call anyway and goes
/// off again when the call ends, unless the user switches it off during the call.
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

    private struct Heard: Sendable {
        let utterance: Utterance
        let source: TranscriptLine.Source
    }

    private(set) var state: State = .off

    private var store: TranscriptStore?
    private var transcriber: Transcriber?
    private var loadingModel: Task<Transcriber, any Error>?
    private var mic: MicCapture?
    private var computerAudio: SystemAudioCapture?
    private var heard: AsyncStream<Heard>.Continuation?
    private var segmenting: [Task<Void, Never>] = []
    private var pipeline: Task<Void, Never>?
    /// Bumped by every switch on or off, so a start that was waiting (for mic access or the
    /// model) can tell it has been overtaken and must not start the mic.
    private var generation = 0

    private var inCall = false
    private var startedForCall = false
    private var switchedOffDuringCall = false

    var isOn: Bool {
        switch state {
        case .on, .preparing: true
        default: false
        }
    }

    /// The user's switch (menu or `rmd://` link). It wins over automatic call recording.
    func setOn(_ on: Bool) async {
        startedForCall = false
        if on {
            await start()
        } else {
            if inCall { switchedOffDuringCall = true }
            stop()
        }
    }

    /// From CallWatcher: `app` is the call app's bundle ID while a call is on, nil once it ends.
    func callChanged(to app: String?) async {
        inCall = app != nil
        if inCall {
            if isOn {
                startComputerAudio()
            } else if !switchedOffDuringCall {
                startedForCall = true
                await start()
            }
        } else {
            stopComputerAudio()
            if startedForCall { stop() }
            startedForCall = false
            switchedOffDuringCall = false
        }
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
            let (heardStream, heard) = AsyncStream.makeStream(of: Heard.self)
            self.mic = mic
            self.heard = heard
            segmenting = [Self.segment(audio, as: .me, into: heard)]
            pipeline = Task.detached {
                await Self.transcribe(heardStream, transcriber: transcriber, comparison: comparison, store: store)
            }
            state = .on(since: .now)
            if inCall { startComputerAudio() }
        } catch {
            if attempt == generation { state = .failed(error.localizedDescription) }
        }
    }

    private func stop() {
        generation += 1
        mic?.stop()
        mic = nil
        computerAudio?.stop()
        computerAudio = nil
        // Each source still transcribes what it already heard; then the queue ends and so does the pipeline.
        let sources = segmenting
        let heard = heard
        Task {
            for source in sources { await source.value }
            heard?.finish()
        }
        segmenting = []
        self.heard = nil
        pipeline = nil
        state = .off
    }

    private func startComputerAudio() {
        guard computerAudio == nil, let heard, case .on = state else { return }
        let capture = SystemAudioCapture()
        do {
            let audio = try capture.start()
            computerAudio = capture
            segmenting.append(Self.segment(audio, as: .others, into: heard))
        } catch {
            print("RMD: can't record the call's audio: \(error)")
        }
    }

    private func stopComputerAudio() {
        computerAudio?.stop()
        computerAudio = nil
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

    /// Cuts one source's audio into utterances. Segmenting never waits on the model, so a slow
    /// transcription can't drop audio.
    private nonisolated static func segment(
        _ audio: AsyncStream<AudioChunk>,
        as source: TranscriptLine.Source,
        into heard: AsyncStream<Heard>.Continuation
    ) -> Task<Void, Never> {
        Task.detached {
            var segmenter = SpeechSegmenter()
            for await chunk in audio {
                for utterance in segmenter.append(chunk) { heard.yield(Heard(utterance: utterance, source: source)) }
            }
            if let last = segmenter.flush() { heard.yield(Heard(utterance: last, source: source)) }
        }
    }

    private nonisolated static func transcribe(
        _ heard: AsyncStream<Heard>,
        transcriber: Transcriber,
        comparison: EngineComparison?,
        store: TranscriptStore
    ) async {
        for await item in heard {
            do {
                let text = if let comparison {
                    try await comparison.transcribeAndLog(item.utterance)
                } else {
                    try await transcriber.transcribe(item.utterance.samples)
                }
                guard let transcript = text else { continue }
                _ = try await store.insert(TranscriptLine(
                    start: item.utterance.start,
                    end: item.utterance.end,
                    source: item.source,
                    text: transcript.text,
                    language: transcript.language
                ))
            } catch {
                print("RMD: dropped an utterance: \(error)")
            }
        }
    }

    private static func micAccessGranted() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }
}
