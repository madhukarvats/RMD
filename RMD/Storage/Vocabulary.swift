import Foundation

/// Names and words the user says often (people, places, products, jargon), one per line in vocabulary.txt
/// next to the transcript. The speech model gets them as a hint; Claude gets them to make sense of misheard ones.
enum Vocabulary {
    static func url() throws -> URL {
        try TranscriptStore.defaultURL().deletingLastPathComponent().appending(path: "vocabulary.txt")
    }

    /// Read fresh every time, so an edit counts from the next line RMD hears.
    /// Blank lines and lines starting with # are ignored.
    static func load() -> [String] {
        guard let url = try? url(), let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// Writes a file with instructions and no words, if there isn't one yet.
    static func createIfMissing() {
        guard let url = try? url(), !FileManager.default.fileExists(atPath: url.path) else { return }
        try? template.write(to: url, atomically: true, encoding: .utf8)
    }

    static let template = """
        # Names and words you say often: people, places, products, jargon. One per line.
        # RMD's speech model listens for them, and Claude uses them to fix misheard words.
        # The speech model takes about the first 20; Claude sees them all. Edits count from the next line RMD hears.

        """
}
