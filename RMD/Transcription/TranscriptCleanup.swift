import Foundation

/// Checks on the text a speech model returns. Kept apart from the model so they can be tested on their own.
///
/// Whisper's usual failure on unclear audio is a loop: it writes the same words round and round, often with
/// small changes each time, at 10 to 20 words a second. `cleaned` cuts those back to what was said once.
enum TranscriptCleanup {
    /// The line to save for what the model wrote from `seconds` of audio, or nil when nothing real is left.
    static func cleaned(_ text: String, seconds: Double, vocabulary: [String]) -> String? {
        let squeezed = squeezingCharacterRuns(text)
        var cleaned = separatingGluedSentences(squeezed)
        cleaned = collapsingRepeats(cleaned)
        cleaned = collapsingNearRepeats(cleaned)
        cleaned = trimmedToSpeakable(cleaned, seconds: seconds).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, !isKnownHallucination(cleaned), !isRunaway(cleaned),
              !isOnlyVocabulary(cleaned, vocabulary)
        else { return nil }
        // "'s'shhhhhhhhhhhhh…" leaves a scrap behind ("'s'sh"): a line that was mostly one character is all noise.
        if text.count - squeezed.count >= 20, Words.of(cleaned).count < 3 { return nil }
        return cleaned
    }

    /// One character over and over ("hhhhhhhh…", "''''''''…"): runs of 4 or more are cut to one.
    /// Digits are left alone (10000).
    static func squeezingCharacterRuns(_ text: String) -> String {
        var result = ""
        var run: [Character] = []
        func flush() {
            guard let character = run.first else { return }
            if run.count >= 4, !character.isNumber { result.append(character) } else { result.append(contentsOf: run) }
        }
        for character in text {
            if character != run.first {
                flush()
                run = []
            }
            run.append(character)
        }
        flush()
        return result
    }

    /// "aaunga.Chalo" → "aaunga. Chalo". Whisper sometimes leaves out the space between sentences.
    static func separatingGluedSentences(_ text: String) -> String {
        var result = ""
        var before: Character?
        var previous: Character?
        for character in text {
            if let before, let previous, ".?!,".contains(previous), before.isLowercase || before.isNumber, character.isUppercase {
                result.append(" ")
            }
            result.append(character)
            before = previous
            previous = character
        }
        return result
    }

    /// Whisper can get stuck repeating a few words when the audio is unclear ("30 6. 30 6. 30 6…").
    /// A word or phrase (up to 6 words) said 4 or more times in a row is cut back to once; small spelling
    /// changes between the repeats ("theek, theekh, theeke") still count.
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
                      keys[i + repeats * size..<i + (repeats + 1) * size].elementsEqual(keys[i..<i + size], by: isSameOrOneLetterOff) {
                    repeats += 1
                }
                if repeats >= 4 {
                    kept += words[i..<i + size]
                    // "Sure sure sure sure. Yeah" keeps its full stop: "Sure. Yeah"; "Yes, yes, yes, yes. Then"
                    // swaps the comma for it: "Yes. Then".
                    if let mark = words[i + repeats * size - 1].last, ".?!,".contains(mark), let last = kept.last {
                        if let end = last.last, ".?!,".contains(end) {
                            if end == ",", mark != "," { kept[kept.count - 1] = Substring(String(last.dropLast()) + String(mark)) }
                        } else {
                            kept[kept.count - 1] = Substring(String(last) + String(mark))
                        }
                    }
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

    /// A loop that changes a little each time round ("Main kal aa raha hoon. Mein kal aa rahaa hoon. Main kal
    /// aa raha hun."): three or more sentences in a row that are near copies of the one before are cut to
    /// the first. One- and two-word sentences ("Ok. Ok. Ok.") need four.
    static func collapsingNearRepeats(_ text: String) -> String {
        let all = Words.sentences(text)
        guard all.count >= 3 else { return text }
        let words = all.map(Words.of)
        var kept: [String] = []
        var i = 0
        while i < all.count {
            var j = i + 1
            while j < all.count, isNearCopy(words[j], of: words[j - 1]) { j += 1 }
            kept.append(all[i])
            // A list ("Send it to design. Send it to sales. Send it to support.") also chains near copies;
            // a loop mostly says the same sentence, so at most half of the run may be distinct.
            var distinct: [[String]] = []
            for sentence in words[i..<j] where !distinct.contains(where: { isSameRound($0, sentence) }) {
                distinct.append(sentence)
            }
            i = j - i >= (words[i].count < 3 ? 4 : 3) && distinct.count * 2 <= j - i ? j : i + 1
        }
        return kept.count == all.count ? text : kept.joined(separator: " ")
    }

    /// Two rounds of a loop: the same words bar one short or misheard one ("bhi" / "bhej", "hoon" / "hun").
    /// A list changes a content word ("design" / "sales"), which makes the sentences distinct.
    private static func isSameRound(_ a: [String], _ b: [String]) -> Bool {
        guard abs(a.count - b.count) <= 1 else { return false }
        if Words.matched(a, in: b) == min(a.count, b.count) { return true }
        guard a.count == b.count else { return false }
        let odd = zip(a, b).filter { !Words.soundAlike($0, $1) }
        return odd.count == 1 && min(odd[0].0.count, odd[0].1.count) < 4
    }

    private static func isNearCopy(_ a: [String], of b: [String]) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a.count < 3 || b.count < 3 { return a.count == b.count && zip(a, b).allSatisfy(Words.soundAlike) }
        return Double(Words.matched(a, in: b)) >= Double(max(a.count, b.count)) * 0.6
    }

    /// More words than anyone can say in the time means the model looped. Real lines top out near 8 words
    /// a second in short bursts; loops run at 10 to 20. What fits at a normal pace is kept from the start
    /// (whole sentences, or up to the last comma), since the first time round is the part that was heard.
    static func trimmedToSpeakable(_ text: String, seconds: Double) -> String {
        let words = text.split(whereSeparator: \.isWhitespace)
        let tooMany = max(12, Int(seconds * 8.5))
        guard words.count > tooMany else { return text }
        let budget = max(8, Int(seconds * 4))
        var kept: [String] = []
        var count = 0
        for sentence in Words.sentences(text) {
            let length = sentence.split(whereSeparator: \.isWhitespace).count
            // The first sentence stays whole if it could have been said in the time.
            guard count + length <= (kept.isEmpty ? tooMany : budget) else { break }
            kept.append(sentence)
            count += length
        }
        if !kept.isEmpty { return kept.joined(separator: " ") }
        let fits = words.prefix(budget)
        if let comma = fits.lastIndex(where: { $0.hasSuffix(",") }), comma >= 3 {
            return fits[...comma].joined(separator: " ")
        }
        return fits.joined(separator: " ")
    }

    /// What is still not speech after the trims: mostly punctuation, one endless "word", or a few words
    /// going round ("Pani, paani. Pani, pani, FM, pani…").
    static func isRunaway(_ text: String) -> Bool {
        let words = Words.of(text)
        let letters = words.reduce(0) { $0 + $1.count }
        let visible = text.count { !$0.isWhitespace }
        if visible >= 20, letters * 2 < visible { return true }
        if words.contains(where: { $0.count > 30 }) { return true }
        return words.count >= 12 && Set(words).count * 10 <= words.count * 3
    }

    /// Phrases models invent from background noise. Apex writes a bare "nan" for audio it can't make out,
    /// or a line of just dots ("........").
    static func isKnownHallucination(_ text: String) -> Bool {
        !text.contains { $0.isLetter || $0.isNumber }
            || hallucinations.contains(text.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)))
    }

    /// With names given as a hint, Whisper sometimes "hears" just the list in background noise.
    /// A line made only of two or more of those names is treated as that, not speech. So is a longer line
    /// (5 words or more) that is nearly all names or near misses of them ("RMD, RMB, RMD, RMS, RMD").
    static func isOnlyVocabulary(_ text: String, _ vocabulary: [String]) -> Bool {
        let known = Set(vocabulary.flatMap { $0.split(whereSeparator: \.isWhitespace).map(key) })
        let heard = text.split(whereSeparator: \.isWhitespace).map(key).filter { !$0.isEmpty }
        guard Set(heard).count >= 2 else { return false }
        if heard.allSatisfy(known.contains) { return true }
        // Needs a near miss: "Asha, Ravi, Meera and Kabir." is a real answer.
        let exact = heard.count(where: known.contains)
        let close = heard.count { word in known.contains { $0 == word || isOneLetterOff(word, $0) } }
        return heard.count >= 5 && close > exact && close * 5 >= heard.count * 4
    }

    private static func isOneLetterOff(_ a: String, _ b: String) -> Bool {
        a.count >= 3 && b.count >= 3 && abs(a.count - b.count) <= 1 && Words.editDistance(Array(a), Array(b)) == 1
    }

    /// Stricter than `Words.soundAlike`, which would take "interior, exterior, exterior, exterior" for a loop.
    /// Only words of letters with the same first letter: "2021, 2022, 2023" and "idhar udhar" are not loops.
    private static func isSameOrOneLetterOff(_ a: String, _ b: String) -> Bool {
        a == b || (min(a.count, b.count) >= 4 && a.first == b.first
                   && a.allSatisfy(\.isLetter) && b.allSatisfy(\.isLetter) && isOneLetterOff(a, b))
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
