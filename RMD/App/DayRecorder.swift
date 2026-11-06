import AVFoundation
import Observation
import Synchronization

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
        /// macOS's audio engine stopped answering while starting the microphone (see MicCapture). Only a
        /// restart of RMD gets it back; `resume` says whether to record again afterwards.
        case micStuck(resume: Bool)
    }

    private struct Heard: Sendable {
        let utterance: Utterance
        let source: TranscriptLine.Source
        let app: String?
    }

    /// The call app's name, read by the tasks that cut audio into lines so each line knows its call.
    private final class CallName: Sendable {
        private let name = Mutex<String?>(nil)
        var current: String? {
            get { name.withLock { $0 } }
            set { name.withLock { $0 = newValue } }
        }
    }

    private(set) var state: State = .off
    private(set) var inCall = false
    /// True while RMD is on only because a call switched it on; it goes off again when the call ends.
    private(set) var startedForCall = false

    /// True once the microphone is open, which is before the speech model has loaded.
    var isListening: Bool { mic != nil }

    /// Something that isn't being recorded although RMD is on. The menu shows it and the icon turns yellow.
    var trouble: String? { micTrouble ?? callTrouble ?? modelTrouble }
    private var micTrouble: String?
    private var callTrouble: String?
    private var modelTrouble: String?

    private var store: TranscriptStore?
    private var model: Task<Transcriber, any Error>?
    private var modelIsReady = false
    private var mic: MicCapture?
    private var computerAudio: SystemAudioCapture?
    private var retryingComputerAudio: Task<Void, Never>?
    private var heard: AsyncStream<Heard>.Continuation?
    private var segmenting: [Task<Void, Never>] = []
    private var pipeline: Task<Void, Never>?
    /// Lines still being transcribed and saved after a switch-off.
    private var saving: Task<Void, Never>?
    private let callName = CallName()
    /// Bumped by every switch on or off, so a start that was waiting (for mic access or the
    /// model) can tell it has been overtaken and must not carry on.
    private var generation = 0
    private var switchedOffDuringCall = false

    var isOn: Bool {
        switch state {
        case .on, .preparing: true
        default: false
        }
    }

    /// The user's switch (menu, double-tap Fn or `rmd://` link). It wins over automatic call recording.
    func setOn(_ on: Bool) async {
        startedForCall = false
        if on {
            await start()
        } else {
            if inCall { switchedOffDuringCall = true }
            stop()
        }
    }

    /// From CallWatcher: `app` is the call app while a call is on, nil once it ends.
    func callChanged(to app: AudioDevices.CallApp?) async {
        inCall = app != nil
        callName.current = app?.name
        if inCall {
            if isOn {
                startComputerAudio()
            } else if !switchedOffDuringCall {
                if case .micStuck = state { return }  // only a fresh copy of RMD gets the microphone back
                startedForCall = true
                await start()
            }
        } else {
            stopComputerAudio()
            if startedForCall, isOn { stop() }  // a start that failed keeps its notice
            startedForCall = false
            switchedOffDuringCall = false
        }
    }

    /// For quitting: switches off and waits until every line already heard is saved.
    func finish() async {
        if isOn { stop() }
        await saving?.value
    }

    /// Called when the menu opens: access given in System Settings meanwhile clears the notice.
    func recheckMicAccess() {
        if state == .micDenied, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized { state = .off }
    }

    private func start() async {
        guard !isOn else { return }
        if case .micStuck = state { return }  // another try would only park one more thread in the stuck engine
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

            // Listen first. Cutting speech into lines doesn't need the model, so what is said while it
            // loads (2 s, or minutes after a macOS update) waits in the queue and is transcribed after.
            let mic = MicCapture()
            mic.onStuck = { [weak self, weak mic] in
                guard let self, let mic, self.mic === mic else { return }  // a microphone already switched off
                self.micStuck()
            }
            mic.onLost = { [weak self] lost in
                if lost { Log.audio.error("the microphone didn't come back after a change; still trying") }
                self?.micTrouble = lost ? "The microphone didn't come back. RMD keeps trying." : nil
            }
            let audio = try await mic.start()
            guard attempt == generation else {  // switched off while the mic started
                mic.stop()
                return
            }
            let (heardStream, heard) = AsyncStream.makeStream(of: Heard.self)
            self.mic = mic
            self.heard = heard
            segmenting = [Self.segment(audio, as: .me, during: callName, into: heard)]

            let model = loadModel()
            let compare = UserDefaults.standard.bool(forKey: "compareEngines")
            pipeline = Task.detached {
                guard let transcriber = try? await model.value else { return }
                await Self.transcribe(heardStream, transcriber: transcriber, compare: compare, store: store)
            }
            if inCall { startComputerAudio() }

            let transcriber: Transcriber
            do {
                transcriber = try await model.value
            } catch {
                self.model = nil  // the next switch-on tries the load again
                throw error
            }
            modelIsReady = true
            guard attempt == generation else { return }  // switched off while the model was loading
            if let whisper = transcriber as? WhisperKitTranscriber, !whisper.writesRomanHindi {
                modelTrouble = "Hinglish speech model not found: Hindi is written in Devanagari."
            }
            state = .on(since: .now)
        } catch is MicCapture.Stuck {
            if attempt == generation { micStuck() }
        } catch {
            Log.app.error("couldn't start recording: \(String(describing: error), privacy: .public)")
            if attempt == generation {
                stop()
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// Stops recording and turns the icon yellow; AppDelegate then starts a fresh copy of RMD, or the
    /// user does from the menu. A call ending doesn't switch this off, so it can't go unnoticed.
    private func micStuck() {
        Log.audio.error("the microphone is stuck in macOS's audio engine")
        // "On for the day" survives a second stuck start, for example a call arriving meanwhile.
        let resume = if case .micStuck(let earlier) = state { earlier || !startedForCall } else { !startedForCall }
        stop()
        startedForCall = false
        state = .micStuck(resume: resume)
    }

    private func stop() {
        generation += 1
        mic?.stop()
        mic = nil
        stopComputerAudio()
        // Each source still cuts what it already heard into lines, then the queue ends, and the pipeline
        // ends once it has transcribed and saved them all.
        let sources = segmenting
        let heard = heard
        let pipeline = pipeline
        let earlier = saving
        saving = Task {
            for source in sources { await source.value }
            heard?.finish()
            await pipeline?.value
            await earlier?.value
        }
        segmenting = []
        self.heard = nil
        self.pipeline = nil
        micTrouble = nil
        state = .off
    }

    private func startComputerAudio() {
        guard computerAudio == nil, let heard, isOn, inCall else { return }
        let capture = SystemAudioCapture()
        capture.onTrouble = { [weak self] trouble in
            self?.callTrouble = trouble ? "Can't hear the other side of this call. RMD keeps trying." : nil
        }
        do {
            let audio = try capture.start()
            computerAudio = capture
            callTrouble = nil
            segmenting.append(Self.segment(audio, as: .others, during: callName, into: heard))
        } catch {
            Log.audio.error("can't record the call's audio: \(String(describing: error), privacy: .public)")
            callTrouble = "Can't hear the other side of this call. Check System Audio Recording in Privacy & Security."
            retryingComputerAudio?.cancel()
            retryingComputerAudio = Task {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                startComputerAudio()
            }
        }
    }

    private func stopComputerAudio() {
        retryingComputerAudio?.cancel()
        retryingComputerAudio = nil
        computerAudio?.stop()
        computerAudio = nil
        callTrouble = nil
    }

    private func openStore() throws -> TranscriptStore {
        if let store { return store }
        let store = try TranscriptStore(url: TranscriptStore.defaultURL())
        self.store = store
        return store
    }

    /// Loads the model once; every later switch-on gets the same loaded model.
    private func loadModel() -> Task<Transcriber, any Error> {
        if let model { return model }
        if !modelIsReady { state = .preparing("Loading speech model…") }
        let progress: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in
                guard let self, case .preparing = self.state else { return }
                self.state = .preparing("Downloading speech model… \(Int(fraction * 100))%")
            }
        }
        let loading = Task { try await WhisperKitTranscriber.load(progress: progress) as Transcriber }
        model = loading
        return loading
    }

    /// Cuts one source's audio into utterances. Segmenting never waits on the model, so a slow
    /// transcription can't drop audio.
    private nonisolated static func segment(
        _ audio: AsyncStream<AudioChunk>,
        as source: TranscriptLine.Source,
        during call: CallName,
        into heard: AsyncStream<Heard>.Continuation
    ) -> Task<Void, Never> {
        Task.detached {
            var segmenter = SpeechSegmenter()
            for await chunk in audio {
                for utterance in segmenter.append(chunk) {
                    heard.yield(Heard(utterance: utterance, source: source, app: call.current))
                }
            }
            if let last = segmenter.flush() { heard.yield(Heard(utterance: last, source: source, app: call.current)) }
        }
    }

    /// Compare mode, for choosing a speech engine: `defaults write com.madhukarsharma.RMD compareEngines -bool YES`,
    /// then switch RMD off and on. Every line is also run through Apple's dictation and all versions are logged
    /// side by side in engine-comparison.jsonl (text only). The transcript itself still comes from the main engine.
    private nonisolated static func transcribe(
        _ heard: AsyncStream<Heard>,
        transcriber: Transcriber,
        compare: Bool,
        store: TranscriptStore
    ) async {
        let comparison = compare ? await EngineComparison.load(main: transcriber, log: try? ComparisonLog()) : nil
        for await item in heard {
            do {
                let text = if let comparison {
                    try await comparison.transcribeAndLog(item.utterance)
                } else {
                    try await transcriber.transcribe(item.utterance.samples)
                }
                guard let transcript = text else { continue }
                try await save(TranscriptLine(
                    start: item.utterance.start,
                    end: item.utterance.end,
                    source: item.source,
                    text: transcript.text,
                    language: transcript.language,
                    app: item.app
                ), in: store)
            } catch {
                Log.app.error("dropped a line: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// How far apart a "Me" and an "Others" line can be and still hold the same speech: the two sources
    /// cut their lines at slightly different moments.
    private nonisolated static let echoWindow: TimeInterval = 2

    /// Saves a line without the call audio the mic picked up from the speakers (see EchoFilter).
    /// Either side's line can be ready first, so a "Me" line is checked against the "Others" lines already
    /// saved, and each new "Others" line checks the "Me" lines saved before it again.
    private nonisolated static func save(_ line: TranscriptLine, in store: TranscriptStore) async throws {
        // On headphones the mic can't hear the call, so nothing is echo and nothing should be removed.
        guard AudioDevices.microphoneCanHearSpeaker() else {
            _ = try await store.insert(line)
            return
        }
        switch line.source {
        case .me:
            guard let text = try await withoutEcho(line, store) else { return }
            _ = try await store.insert(TranscriptLine(
                start: line.start, end: line.end, source: .me, text: text, language: line.language, app: line.app
            ))
        case .others:
            _ = try await store.insert(line)
            let mineAround = try await store.lines(
                from: .me,
                overlapping: line.start.addingTimeInterval(-echoWindow),
                to: line.end.addingTimeInterval(echoWindow)
            )
            // Only against the line that just arrived: the earlier ones were checked when `mine` was saved,
            // and a line shortened then still carries its old start and end, which would misplace its words.
            for mine in mineAround {
                switch EchoFilter.removingEcho(from: mine, heard: [line]) {
                case nil: try await store.delete(mine.id)
                case let text? where text != mine.text: try await store.setText(text, of: mine.id)
                default: break
                }
            }
        }
    }

    private nonisolated static func withoutEcho(_ mine: TranscriptLine, _ store: TranscriptStore) async throws -> String? {
        let heard = try await store.lines(
            from: .others,
            overlapping: mine.start.addingTimeInterval(-echoWindow),
            to: mine.end.addingTimeInterval(echoWindow)
        )
        return EchoFilter.removingEcho(from: mine, heard: heard)
    }

    private static func micAccessGranted() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }
}
