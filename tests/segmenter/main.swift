// Speech segmenter on synthetic audio where we know exactly when someone talks. Run with `make test`.
import Foundation

let rate = 16_000.0
var failures = 0

@MainActor func noise(_ seconds: Double, db: Float, wobble: Bool = false) -> [Float] {
    let amplitude = powf(10, db / 20) * sqrtf(3)
    return (0..<Int(seconds * rate)).map { i in
        // "wobble" swings the level like syllables (4 per second), as background voices do
        let envelope: Float = wobble ? Float(0.55 + 0.45 * sin(2 * .pi * 4 * Double(i) / rate)) : 1
        return Float.random(in: -amplitude...amplitude) * envelope
    }
}
/// `jump` moves the clock forward by `by` seconds once `after` seconds of audio have been fed, as when the
/// Mac sleeps or a capture stalls and comes back. `drift` makes the chunk times run fast by that fraction,
/// as a device clock does against the Mac's.
@MainActor func run(_ name: String, _ audio: [Float], jump: (after: Double, by: Double)? = nil, drift: Double = 0, expect: (([Utterance], Double) -> String?)) {
    var segmenter = SpeechSegmenter()
    let origin = Date(timeIntervalSince1970: 0)
    var out: [Utterance] = []
    for offset in stride(from: 0, to: audio.count, by: 1600) {
        let chunk = Array(audio[offset..<min(offset + 1600, audio.count)])
        var time = Double(offset) / rate
        if let jump, time >= jump.after { time += jump.by }
        time *= 1 + drift
        out += segmenter.append(AudioChunk(samples: chunk, start: origin.addingTimeInterval(time)))
    }
    out += [segmenter.flush()].compactMap { $0 }
    let lengths = out.map { String(format: "%.1f", Double($0.samples.count) / rate) }
    let cuts = out.map { String(format: "%.1f", $0.start.timeIntervalSince(origin)) }
    let problem = expect(out, Double(audio.count) / rate)
    if problem != nil { failures += 1 }
    print("\(problem == nil ? "  ok  " : "  FAIL") \(name)\n         starts \(cuts.joined(separator: ", ")) s · lengths \(lengths.joined(separator: ", ")) s\(problem.map { "\n         " + $0 } ?? "")")
}

print("Segmenter")
// 1. Speech with clear pauses: one line per burst.
run("3 bursts with 1 s pauses → 3 lines", noise(1, db: -65) + noise(2, db: -20) + noise(1, db: -65) + noise(2, db: -20) + noise(1, db: -65) + noise(2, db: -20) + noise(1, db: -65)) { out, _ in
    out.count == 3 ? nil : "expected 3 lines, got \(out.count)"
}
// 2. 40 s of talking with one tiny 200 ms dip at 17 s: the forced cut should land in the dip, not at 25 s,
//    and every bit of the speech should end up in exactly one line.
let talk = noise(0.5, db: -65) + noise(17, db: -20) + noise(0.2, db: -65) + noise(23, db: -20) + noise(0.5, db: -65)
run("40 s non-stop, tiny dip at 17.5 s → cut in the dip, no audio lost", talk) { out, total in
    guard let first = out.first else { return "no lines" }
    let firstEnd = first.start.timeIntervalSince1970 + Double(first.samples.count) / rate
    let kept = Double(out.reduce(0) { $0 + $1.samples.count }) / rate
    if abs(firstEnd - 17.6) > 0.4 { return String(format: "first cut at %.1f s, expected ~17.6 s", firstEnd) }
    if kept < 40.2 - 0.5 { return String(format: "only %.1f s of the 40.2 s of speech kept", kept) }
    return nil
}
// 3. Steady background voices (−38 dB) the whole time, the user (−18 dB) talking 3 s at a time with 1.2 s pauses.
var room = noise(2, db: -38)
for _ in 0..<12 { room += noise(3, db: -18) + noise(1.2, db: -38) }
run("steady background voices, user talks in 3 s bursts → every cut lands in a pause", room) { out, _ in
    // The user talks 3 s, then pauses 1.2 s, starting at 2 s. A cut inside the 3 s cuts them off mid-word.
    let midWord = out.dropFirst().map { $0.start.timeIntervalSince1970 }.filter { start in
        let phase = (start - 2).truncatingRemainder(dividingBy: 4.2)
        return start > 2 && phase > 0.15 && phase < 2.85
    }
    return midWord.isEmpty ? nil : "\(midWord.count) lines start in the middle of the user talking"
}
// 4. Same, but the background swings like real speech.
var lively = noise(2, db: -38, wobble: true)
for _ in 0..<12 { lively += noise(3, db: -18) + noise(1.2, db: -38, wobble: true) }
run("swinging background voices, user in 3 s bursts → every cut lands in a pause", lively) { out, _ in
    // The user talks 3 s, then pauses 1.2 s, starting at 2 s. A cut inside the 3 s cuts them off mid-word.
    let midWord = out.dropFirst().map { $0.start.timeIntervalSince1970 }.filter { start in
        let phase = (start - 2).truncatingRemainder(dividingBy: 4.2)
        return start > 2 && phase > 0.15 && phase < 2.85
    }
    return midWord.isEmpty ? nil : "\(midWord.count) lines start in the middle of the user talking"
}

// 5. The Mac sleeps for 22 minutes in the middle of a sentence. The line before the gap and the one after
//    it must come out separately, each with its own time (this used to crash RMD).
run("22 min gap mid-sentence → two lines with their own times, no crash",
    noise(1, db: -65) + noise(4, db: -20) + noise(4, db: -20) + noise(1, db: -65), jump: (after: 5, by: 22 * 60)) { out, _ in
    guard out.count == 2 else { return "expected 2 lines, got \(out.count)" }
    let secondStart = out[1].start.timeIntervalSince1970
    if out[0].end.timeIntervalSince1970 > 6 { return "the first line runs past the gap" }
    if secondStart < 22 * 60 { return String(format: "the second line starts at %.0f s, before the gap ended", secondStart) }
    return nil
}
// 6. Quiet, then a 30 s gap, then someone speaks at once: the pre-roll from before the gap must not be used.
run("quiet, 30 s gap, then speech → one line that starts after the gap",
    noise(5, db: -65) + noise(3, db: -20) + noise(1, db: -65), jump: (after: 5, by: 30)) { out, _ in
    guard out.count == 1 else { return "expected 1 line, got \(out.count)" }
    return out[0].start.timeIntervalSince1970 >= 35 ? nil : "the line starts before the gap ended"
}
// 7. The device clock drifts 1.5% against the wall clock (1.2 s over this clip): every 3 s burst is still one
//    line. Drift is absorbed in the pauses; it must never add up to a "jump" that cuts a sentence.
var drifting = noise(1, db: -65)
for _ in 0..<19 { drifting += noise(3, db: -20) + noise(1.2, db: -65) }
run("1.5% clock drift → 19 bursts give 19 lines, none cut", drifting, drift: 0.015) { out, _ in
    out.count == 19 ? nil : "expected 19 lines, got \(out.count)"
}
// 8. A quick "Haan" (0.33 s) is a line; a click (0.12 s) is not.
run("0.33 s reply kept, 0.12 s click skipped",
    noise(2, db: -65) + noise(0.33, db: -20) + noise(2, db: -65) + noise(0.12, db: -20) + noise(2, db: -65)) { out, _ in
    out.count == 1 ? nil : "expected 1 line, got \(out.count)"
}

print(failures == 0 ? "\nall passed" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
