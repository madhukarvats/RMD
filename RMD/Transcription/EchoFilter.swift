import Foundation

/// On laptop speakers the mic also hears the other people on a call, so what they say is saved twice:
/// cleanly from the Mac's audio ("Others") and, a little garbled, from the mic ("Me"). This finds the
/// sentences of a "Me" line that repeat what "Others" said at the same time. The two transcriptions of the
/// same speech rarely match word for word ("screencast" / "skin cast"), so a sentence counts as echo when
/// most of its words line up with a stretch of the other side's words.
enum EchoFilter {
    /// Echo arrives with what it copies. A sentence is only compared with words "Others" said within this
    /// long of it, so a real "Ok." isn't dropped because the other person said "ok" 20 s earlier in a long line.
    private static let nearby: TimeInterval = 3

    /// `mine` without the sentences that echo `others` (the "Others" lines heard at about the same time),
    /// or nil when all of it is echo. Sentences are judged one by one, so "Theirs echoed. My reply." keeps
    /// the reply. Lines only carry a start and an end, so each word's moment is estimated by spreading the
    /// words evenly over the line.
    static func removingEcho(from mine: TranscriptLine, heard others: [TranscriptLine]) -> String? {
        let heard = others.flatMap(timedWords)
        guard !heard.isEmpty else { return mine.text }
        let all = Words.sentences(mine.text)
        let wordsOf = all.map(Words.of)
        let total = Double(max(wordsOf.reduce(0) { $0 + $1.count }, 1))
        let length = mine.end.timeIntervalSince(mine.start)

        var said = 0
        var kept: [String] = []
        for (sentence, words) in zip(all, wordsOf) {
            let from = mine.start.addingTimeInterval(length * Double(said) / total - nearby)
            let to = mine.start.addingTimeInterval(length * Double(said + words.count) / total + nearby)
            said += words.count
            let near = heard.filter { $0.at >= from && $0.at <= to }.map(\.word)
            if near.isEmpty || !isEcho(words, of: near) { kept.append(sentence) }
        }
        if kept.count == all.count { return mine.text }
        return kept.isEmpty ? nil : kept.joined(separator: " ")
    }

    /// The same check on plain text, with everything in `others` counted as said at the same time.
    static func removingEcho(from mine: String, heard others: [String]) -> String? {
        let heard = others.flatMap(Words.of)
        guard !heard.isEmpty else { return mine }
        let all = Words.sentences(mine)
        let kept = all.filter { !isEcho(Words.of($0), of: heard) }
        if kept.count == all.count { return mine }
        return kept.isEmpty ? nil : kept.joined(separator: " ")
    }

    private static func timedWords(_ line: TranscriptLine) -> [(word: String, at: Date)] {
        let all = Words.of(line.text)
        let step = line.end.timeIntervalSince(line.start) / Double(max(all.count, 1))
        return all.enumerated().map { ($1, line.start.addingTimeInterval((Double($0) + 0.5) * step)) }
    }

    /// Short sentences ("Ok.", "Yeah, perfect.") must match in full; longer ones need half their words.
    private static func isEcho(_ sentence: [String], of heard: [String]) -> Bool {
        guard !sentence.isEmpty else { return true }
        let matched = Words.matched(sentence, in: heard)
        return sentence.count <= 3 ? matched == sentence.count : Double(matched) >= Double(sentence.count) * 0.5
    }
}
