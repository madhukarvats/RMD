import Foundation

/// Checks on the text a speech model returns. Kept apart from the model so they can be tested on their own.
enum TranscriptCleanup {
    /// Whisper can get stuck repeating a few words when the audio is unclear ("30 6. 30 6. 30 6…").
    /// A word or phrase (up to 6 words) said 4 or more times in a row is cut back to once.
    /// People do repeat themselves ("haan haan", "no no no"), so 2 or 3 in a row are left alone.
    static func collapsingRepeats(_ text: String) -> String {
        let words = text.split(whereSeparator: \.isWhitespace)
        let keys = words.map(key)
        var kept: [Substring] = []
        var i = 0
        while i < words.count {
            var skipped = false
            for size in 1...6 where i + size * 4 <= words.count && !keys[i..<i + size].allSatisfy(\.isEmpty) {
                var repeats = 1
                while i + (repeats + 1) * size <= words.count,
                      keys[i + repeats * size..<i + (repeats + 1) * size].elementsEqual(keys[i..<i + size]) {
                    repeats += 1
                }
                if repeats >= 4 {
                    kept += words[i..<i + size]
                    i += repeats * size
                    skipped = true
                    break
                }
            }
            if !skipped {
                kept.append(words[i])
                i += 1
            }
        }
        return kept.joined(separator: " ")
    }

    /// Phrases models invent from background noise. Apex writes a bare "nan" for audio it can't make out,
    /// or a line of just dots ("........").
    static func isKnownHallucination(_ text: String) -> Bool {
        !text.contains { $0.isLetter || $0.isNumber }
            || hallucinations.contains(text.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)))
    }

    /// With names given as a hint, Whisper sometimes "hears" just the list in background noise.
    /// A line made only of two or more of those names is treated as that, not speech.
    static func isOnlyVocabulary(_ text: String, _ vocabulary: [String]) -> Bool {
        let known = Set(vocabulary.flatMap { $0.split(whereSeparator: \.isWhitespace).map(key) })
        let heard = text.split(whereSeparator: \.isWhitespace).map(key).filter { !$0.isEmpty }
        return Set(heard).count >= 2 && heard.allSatisfy(known.contains)
    }

    private static func key(_ word: Substring) -> String {
        word.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }

    private static let hallucinations: Set<String> = [
        "thank you", "thanks for watching", "thank you for watching", "please subscribe",
        "subtitles by the amara.org community", "you", "nan",
        "धन्यवाद", "शुक्रिया",
    ]
}
