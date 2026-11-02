import Foundation

/// On laptop speakers the mic also hears the other people on a call, so what they say is saved twice:
/// cleanly from the Mac's audio ("Others") and, a little garbled, from the mic ("Me"). This finds the
/// sentences of a "Me" line that repeat what "Others" said at the same time. The two transcriptions of the
/// same speech rarely match word for word ("screencast" / "skin cast"), so a sentence counts as echo when
/// most of its words line up with a stretch of the other side's words.
enum EchoFilter {
    /// `mine` without the sentences that echo `others` (the "Others" lines heard at about the same time),
    /// or nil when all of it is echo. Sentences are judged one by one, so "Theirs echoed. My reply." keeps
    /// the reply, and running it again on the result changes nothing.
    static func removingEcho(from mine: String, heard others: [String]) -> String? {
        let heard = others.flatMap(words)
        guard !heard.isEmpty else { return mine }
        let all = sentences(mine)
        let kept = all.filter { !isEcho(words($0), of: heard) }
        if kept.count == all.count { return mine }
        return kept.isEmpty ? nil : kept.joined(separator: " ")
    }

    /// Short sentences ("Ok.", "Yeah, perfect.") must match in full; longer ones need half their words.
    private static func isEcho(_ sentence: [String], of heard: [String]) -> Bool {
        guard !sentence.isEmpty else { return true }
        let matched = matchedWords(sentence, in: heard)
        return sentence.count <= 3 ? matched == sentence.count : Double(matched) >= Double(sentence.count) * 0.5
    }

    /// How many of the sentence's words line up with the best-matching stretch of `heard`
    /// (Smith–Waterman alignment: a word either side may be missing or misheard).
    private static func matchedWords(_ sentence: [String], in heard: [String]) -> Int {
        struct Cell: Comparable {
            var score = 0
            var matches = 0
            static func < (a: Cell, b: Cell) -> Bool { (a.score, a.matches) < (b.score, b.matches) }
        }
        var best = Cell()
        var previous = Array(repeating: Cell(), count: heard.count + 1)
        for word in sentence {
            var row = [Cell()]
            row.reserveCapacity(heard.count + 1)
            for j in 1...heard.count {
                let same = sounds(word, like: heard[j - 1])
                let cell = max(
                    Cell(),
                    Cell(score: previous[j - 1].score + (same ? 2 : -1), matches: previous[j - 1].matches + (same ? 1 : 0)),
                    Cell(score: previous[j].score - 1, matches: previous[j].matches),  // a word only I said
                    Cell(score: row[j - 1].score - 1, matches: row[j - 1].matches)  // a word only they said
                )
                row.append(cell)
                if (cell.matches, cell.score) > (best.matches, best.score) { best = cell }
            }
            previous = row
        }
        return best.matches
    }

    /// Same word, or a near miss of a longer one ("tour" / "tool", "deploy" / "deployed").
    private static func sounds(_ a: String, like b: String) -> Bool {
        if a == b { return true }
        guard min(a.count, b.count) >= 4 else { return false }
        return editDistance(Array(a), Array(b)) <= max(a.count, b.count) / 3
    }

    private static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
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

    /// Whisper ends sentences with . ? ! (or ।), sometimes with no space after ("all.That's"); "4.5" stays whole.
    private static func sentences(_ text: String) -> [String] {
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

    private static func words(_ text: String) -> [String] {
        text.lowercased()
            .folding(options: .diacriticInsensitive, locale: nil)
            .replacing("'", with: "").replacing("’", with: "")
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }
}
