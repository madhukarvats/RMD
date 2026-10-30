import Foundation
import WhisperKit

/// Whisper running on the Neural Engine through WhisperKit (Core ML). Fully on-device;
/// models live in Application Support/RMD/models and are reused offline.
///
/// Prefers the Hinglish model (Oriserve Whisper-Hindi2Hinglish-Apex, converted locally with
/// Argmax's whisperkittools into `models/converted/`), which writes Hindi in Roman letters.
/// Without it, falls back to stock Whisper turbo, which writes Hindi in Devanagari.
actor WhisperKitTranscriber: Transcriber {
    static let stockModel = "openai_whisper-large-v3-v20240930_turbo_632MB"
    private static let stockRepo = "argmaxinc/whisperkit-coreml"

    private let whisper: WhisperKit
    private let language: String?
    private static let debug = ProcessInfo.processInfo.environment["RMD_DEBUG"] != nil

    private init(whisper: WhisperKit, language: String?) {
        self.whisper = whisper
        self.language = language
    }

    static func load(progress: @escaping @Sendable (Double) -> Void) async throws -> WhisperKitTranscriber {
        let base = try TranscriptStore.defaultURL().deletingLastPathComponent().appending(path: "models")
        let folder: URL
        var language: String?
        if let hinglish = hinglishModel(in: base) {
            folder = hinglish
            language = "en"  // Apex's model card: with "en" it writes Hindi as Roman Hinglish.
        } else {
            folder = try await stockModel(in: base, progress: progress)
        }
        if let forced = ProcessInfo.processInfo.environment["RMD_LANGUAGE"] {
            language = forced
        }
        if debug {
            print("model: \(folder.lastPathComponent), language: \(language ?? "auto")")
        }

        let config = WhisperKitConfig(
            modelFolder: folder.path,
            tokenizerFolder: base,
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true,
            download: false
        )
        return WhisperKitTranscriber(whisper: try await WhisperKit(config), language: language)
    }

    private static func hinglishModel(in base: URL) -> URL? {
        let converted = base.appending(path: "converted")
        guard let found = FileManager.default.enumerator(at: converted, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in found where url.lastPathComponent == "AudioEncoder.mlmodelc" {
            let folder = url.deletingLastPathComponent()
            if folder.lastPathComponent.localizedCaseInsensitiveContains("hinglish") { return folder }
        }
        return nil
    }

    private static func stockModel(in base: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        // Matches where WhisperKit's Hub client puts downloads: <base>/models/<repo>/<variant>.
        let folder = base.appending(path: "models/\(stockRepo)/\(stockModel)")
        if FileManager.default.fileExists(atPath: folder.appending(path: "AudioEncoder.mlmodelc").path) {
            return folder
        }
        return try await WhisperKit.download(variant: stockModel, downloadBase: base, from: stockRepo) {
            progress($0.fractionCompleted)
        }
    }

    func transcribe(_ samples: [Float]) async throws -> Transcript? {
        let options = DecodingOptions(
            task: .transcribe,
            language: language,
            temperatureFallbackCount: 2,
            detectLanguage: language == nil,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            // WhisperKit-only check (not in OpenAI's Whisper). It aborts on a hesitant first
            // token, which is common for Hindi and Hinglish, and returns empty text.
            firstTokenLogProbThreshold: nil
        )
        let results = try await whisper.transcribe(audioArray: samples, decodeOptions: options)
        if Self.debug {
            for segment in results.flatMap(\.segments) {
                print(String(format: "  [%@] noSpeech %.2f, logprob %.2f, compression %.2f: %@",
                             results.first?.language ?? "-", segment.noSpeechProb, segment.avgLogprob,
                             segment.compressionRatio, segment.text))
            }
        }
        let segments = results.flatMap(\.segments).filter { !Self.isSilence($0) }
        let text = segments.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !Self.isKnownHallucination(text) else { return nil }
        // A forced language says nothing about what was actually spoken, so only keep detected ones.
        return Transcript(text: text, language: language == nil ? results.first?.language : nil)
    }

    private static func isSilence(_ segment: TranscriptionSegment) -> Bool {
        segment.noSpeechProb > 0.6 && segment.avgLogprob < -1
    }

    /// Phrases Whisper is known to invent from background noise.
    private static func isKnownHallucination(_ text: String) -> Bool {
        let normalized = text.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        return hallucinations.contains(normalized)
    }

    private static let hallucinations: Set<String> = [
        "thank you", "thanks for watching", "thank you for watching", "please subscribe",
        "subtitles by the amara.org community", "you",
        "धन्यवाद", "शुक्रिया",
    ]
}
