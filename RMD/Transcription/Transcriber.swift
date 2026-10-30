import Foundation

struct Transcript: Sendable {
    let text: String
    let language: String?
}

/// A local speech-to-text engine. Engines are swappable so the model can change
/// (Whisper, a Hinglish fine-tune, Shruti…) without touching the pipeline.
protocol Transcriber: Sendable {
    /// Returns nil when the audio held no real speech.
    func transcribe(_ samples: [Float]) async throws -> Transcript?
}
