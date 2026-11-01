import Foundation

/// One stretch of speech, cut out of the stream at natural pauses.
struct Utterance: Sendable {
    let samples: [Float]
    let start: Date
    let end: Date
}

/// Energy-based voice activity detection. Skips silence and cuts speech at pauses
/// so only stretches with someone talking reach the (expensive) speech model.
struct SpeechSegmenter {
    private struct Frame {
        let level: Float
        let loud: Bool
    }

    private let sampleRate: Double
    private let frameSize: Int
    private let preRollFrames = 10          // 300 ms kept from before speech starts
    private let framesToStart = 3           // 90 ms of loud audio starts an utterance
    private let framesToEnd = 23            // 700 ms of quiet ends it
    private let longUtterance: TimeInterval = 12   // after this, a 300 ms pause is enough to end it
    private let framesToEndLong = 10
    private let maxDuration: TimeInterval = 25  // Whisper reads 30 s windows
    private let minCutPoint: TimeInterval = 10  // at the limit, cut somewhere after this
    private let minSpeech: TimeInterval = 0.4

    private var leftover: [Float] = []
    private var nextFrameTime = Date.distantPast
    private var noiseFloor: Float = -60
    private var preRoll: [(samples: [Float], time: Date, frame: Frame)] = []
    private var loudRun = 0

    private var inSpeech = false
    private var speech: [Float] = []
    private var frames: [Frame] = []        // one per frame of `speech`
    private var speechStart = Date.distantPast
    private var lastLoudEnd = Date.distantPast
    private var quietRun = 0

    init(sampleRate: Double = MicCapture.sampleRate) {
        self.sampleRate = sampleRate
        self.frameSize = Int(sampleRate * 0.03)
    }

    private var frameDuration: TimeInterval { Double(frameSize) / sampleRate }

    mutating func append(_ chunk: AudioChunk) -> [Utterance] {
        let chunkStart = chunk.start.addingTimeInterval(-Double(leftover.count) / sampleRate)
        if abs(chunkStart.timeIntervalSince(nextFrameTime)) > 1 {
            // First chunk, or the stream jumped (device change, wake from sleep): re-anchor the clock.
            nextFrameTime = chunkStart
        }
        leftover.append(contentsOf: chunk.samples)

        var finished: [Utterance] = []
        var offset = 0
        while leftover.count - offset >= frameSize {
            let frame = leftover[offset..<offset + frameSize]
            if let utterance = process(frame, at: nextFrameTime) {
                finished.append(utterance)
            }
            offset += frameSize
            nextFrameTime = nextFrameTime.addingTimeInterval(frameDuration)
        }
        leftover.removeFirst(offset)
        return finished
    }

    /// Ends any utterance in progress (call when listening stops).
    mutating func flush() -> Utterance? {
        defer { reset() }
        return inSpeech ? finish() : nil
    }

    private mutating func process(_ samples: ArraySlice<Float>, at time: Date) -> Utterance? {
        let level = Self.decibels(samples)
        let frame = Frame(level: level, loud: level > max(noiseFloor + 12, -50))
        let frameEnd = time.addingTimeInterval(frameDuration)
        // Keep following the room while people talk too, so steady voices in the background
        // become the new "quiet" and the user's own pauses still show up. Slowly, though:
        // someone talking non-stop must not turn into "background" within one utterance.
        trackNoiseFloor(level, rising: inSpeech ? 0.001 : 0.005)

        guard inSpeech else {
            preRoll.append((Array(samples), time, frame))
            if preRoll.count > preRollFrames { preRoll.removeFirst() }
            loudRun = frame.loud ? loudRun + 1 : 0
            if loudRun >= framesToStart {
                inSpeech = true
                speechStart = preRoll.first?.time ?? time
                speech = preRoll.flatMap(\.samples)
                frames = preRoll.map(\.frame)
                lastLoudEnd = frameEnd
                quietRun = 0
                preRoll.removeAll()
            }
            return nil
        }

        speech.append(contentsOf: samples)
        frames.append(frame)
        if frame.loud {
            quietRun = 0
            lastLoudEnd = frameEnd
        } else {
            quietRun += 1
        }

        let length = frameEnd.timeIntervalSince(speechStart)
        if quietRun >= (length >= longUtterance ? framesToEndLong : framesToEnd) {
            defer { reset() }
            return finish()
        }
        if length >= maxDuration {
            return cutAtQuietestPoint()
        }
        return nil
    }

    /// Long speech with no real pause, often because other people are talking nearby. Rather than cutting
    /// mid-word at the limit, cut in the quietest 300 ms after the first 10 s and carry the rest into the
    /// next utterance, so no audio is lost between them.
    private mutating func cutAtQuietestPoint() -> Utterance? {
        let window = 10
        let first = min(Int(minCutPoint / frameDuration), frames.count - window)
        var best = frames.count - window
        var bestLevel = Float.infinity
        for start in first...(frames.count - window) {
            let level = frames[start..<start + window].reduce(0) { $0 + $1.level }
            if level < bestLevel {
                bestLevel = level
                best = start
            }
        }
        let cut = best + window / 2
        let cutTime = speechStart.addingTimeInterval(Double(cut) * frameDuration)
        let utterance = finish(frameCount: cut, end: cutTime)

        speech.removeFirst(cut * frameSize)
        frames.removeFirst(cut)
        speechStart = cutTime
        quietRun = frames.reversed().prefix { !$0.loud }.count
        return utterance
    }

    private func finish(frameCount: Int? = nil, end: Date? = nil) -> Utterance? {
        let count = frameCount ?? frames.count
        let loudFrames = frames.prefix(count).filter(\.loud).count
        guard Double(loudFrames) * frameDuration >= minSpeech else { return nil }
        return Utterance(samples: Array(speech.prefix(count * frameSize)), start: speechStart, end: end ?? lastLoudEnd)
    }

    private mutating func reset() {
        inSpeech = false
        speech = []
        frames = []
        loudRun = 0
        quietRun = 0
    }

    private mutating func trackNoiseFloor(_ level: Float, rising: Float) {
        // Follow the room quickly when it gets quieter, slowly when it gets louder.
        let rate: Float = level < noiseFloor ? 0.1 : rising
        noiseFloor = min(max(noiseFloor + (level - noiseFloor) * rate, -80), -30)
    }

    private static func decibels(_ frame: ArraySlice<Float>) -> Float {
        let meanSquare = frame.reduce(0) { $0 + $1 * $1 } / Float(frame.count)
        return 10 * log10(meanSquare + 1e-10)
    }
}
