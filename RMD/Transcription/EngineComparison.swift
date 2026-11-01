import Foundation

/// Runs the same speech through several engines, to find out which one hears the user best.
/// The first engine is the main one: its text is what goes into the transcript.
struct EngineComparison: Sendable {
    struct Engine: Sendable {
        let name: String
        let transcriber: any Transcriber
    }

    struct Attempt: Sendable {
        let engine: String
        let outcome: Result<Transcript?, any Error>
        let seconds: Double
    }

    let engines: [Engine]
    /// Where live comparisons are written, side by side. Text only, never audio.
    let log: ComparisonLog?

    /// The main engine plus Apple's dictation in Indian English and in Hindi.
    /// An engine that can't load is left out, with a note, rather than stopping the others.
    static func load(main: any Transcriber, log: ComparisonLog? = nil) async -> EngineComparison {
        var engines = [Engine(name: "apex", transcriber: main)]
        for locale in ["en_IN", "hi_IN"] {
            do {
                engines.append(Engine(name: "apple \(locale)", transcriber: try await AppleDictationTranscriber.load(locale: locale)))
            } catch {
                print("RMD: leaving out Apple dictation \(locale): \(error)")
            }
        }
        return EngineComparison(engines: engines, log: log)
    }

    /// One engine at a time, so each one's speed is measured on its own.
    func run(_ samples: [Float]) async -> [Attempt] {
        var attempts: [Attempt] = []
        for engine in engines {
            let started = ContinuousClock.now
            let outcome: Result<Transcript?, any Error>
            do {
                outcome = .success(try await engine.transcriber.transcribe(samples))
            } catch {
                outcome = .failure(error)
            }
            let elapsed = ContinuousClock.now - started
            attempts.append(Attempt(engine: engine.name, outcome: outcome, seconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18))
        }
        return attempts
    }

    /// Runs every engine, logs them side by side, and returns the main engine's result.
    func transcribeAndLog(_ utterance: Utterance) async throws -> Transcript? {
        let attempts = await run(utterance.samples)
        do {
            try await log?.append(utterance, attempts)
        } catch {
            print("RMD: couldn't log a comparison: \(error)")
        }
        return try attempts[0].outcome.get()
    }
}

/// `engine-comparison.jsonl` next to the transcript: one line per utterance with every engine's text.
actor ComparisonLog {
    private struct Entry: Encodable {
        let start: String
        let speechSeconds: Double
        let engines: [EngineText]
    }

    private struct EngineText: Encodable {
        let engine: String
        let text: String?
        let error: String?
        let seconds: Double
    }

    let url: URL

    init() throws {
        url = try TranscriptStore.defaultURL().deletingLastPathComponent().appending(path: "engine-comparison.jsonl")
    }

    func append(_ utterance: Utterance, _ attempts: [EngineComparison.Attempt]) throws {
        let entry = Entry(
            start: utterance.start.formatted(Date.ISO8601FormatStyle(timeZone: .current)),
            speechSeconds: (utterance.end.timeIntervalSince(utterance.start) * 10).rounded() / 10,
            engines: attempts.map { attempt in
                switch attempt.outcome {
                case .success(let transcript):
                    EngineText(engine: attempt.engine, text: transcript?.text, error: nil, seconds: attempt.seconds)
                case .failure(let error):
                    EngineText(engine: attempt.engine, text: nil, error: "\(error)", seconds: attempt.seconds)
                }
            }
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let line = try encoder.encode(entry) + Data("\n".utf8)
        guard let handle = try? FileHandle(forWritingTo: url) else {
            try line.write(to: url)
            return
        }
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }
}
