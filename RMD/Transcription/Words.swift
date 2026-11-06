import Foundation

/// How RMD compares pieces of transcript: word by word, forgiving the small spelling differences two
/// transcriptions of the same speech always have ("screencast" / "skin cast", "pahle" / "pehle").
enum Words {
    /// Lowercased words without punctuation or accents.
    static func of(_ text: String) -> [String] {
        text.lowercased()
            .folding(options: .diacriticInsensitive, locale: nil)
            .replacing("'", with: "").replacing("’", with: "")
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    /// Whisper ends sentences with . ? ! (or ।), sometimes with no space after ("all.That's"); "4.5" stays whole.
    static func sentences(_ text: String) -> [String] {
        var sentences: [String] = []
        var start = text.startIndex
        var i = text.startIndex
        while i < text.endIndex {
            let next = text.index(after: i)
            if ".?!।".contains(text[i]), next == text.endIndex || text[next].isWhitespace || text[next].isUppercase {
                sentences.append(text[start..<next].trimmingCharacters(in: .whitespaces))
                start = next
            }
            i = next
        }
        sentences.append(text[start...].trimmingCharacters(in: .whitespaces))
        return sentences.filter { !$0.isEmpty }
    }

    /// Same word, or a near miss of a longer one ("tour" / "tool", "deploy" / "deployed").
    static func soundAlike(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        guard min(a.count, b.count) >= 4 else { return false }
        return editDistance(Array(a), Array(b)) <= max(a.count, b.count) / 3
    }

    static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return max(a.count, b.count) }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var row = [i]
            for j in 1...b.count {
                row.append(min(previous[j] + 1, row[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)))
            }
            previous = row
        }
        return previous[b.count]
    }

    /// How many of `words` line up with the best-matching stretch of `others`
    /// (Smith–Waterman alignment: a word either side may be missing or misheard).
    static func matched(_ words: [String], in others: [String]) -> Int {
        guard !words.isEmpty, !others.isEmpty else { return 0 }
        struct Cell: Comparable {
            var score = 0
            var matches = 0
            static func < (a: Cell, b: Cell) -> Bool { (a.score, a.matches) < (b.score, b.matches) }
        }
        var best = Cell()
        var previous = Array(repeating: Cell(), count: others.count + 1)
        for word in words {
            var row = [Cell()]
            row.reserveCapacity(others.count + 1)
            for j in 1...others.count {
                let same = soundAlike(word, others[j - 1])
                let cell = max(
                    Cell(),
                    Cell(score: previous[j - 1].score + (same ? 2 : -1), matches: previous[j - 1].matches + (same ? 1 : 0)),
                    Cell(score: previous[j].score - 1, matches: previous[j].matches),  // a word only in `words`
                    Cell(score: row[j - 1].score - 1, matches: row[j - 1].matches)  // a word only in `others`
                )
                row.append(cell)
                if (cell.matches, cell.score) > (best.matches, best.score) { best = cell }
            }
            previous = row
        }
        return best.matches
    }
}
