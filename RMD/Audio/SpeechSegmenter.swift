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
    private let sampleRate: Double
    private let frameSize: Int
    private let preRollFrames = 10          // 300 ms kept from before speech starts
    private let framesToStart = 3           // 90 ms of loud audio starts an utterance
    private let framesToEnd = 23            // 700 ms of quiet ends it
    private let maxDuration: TimeInterval = 25  // Whisper reads 30 s windows
    private let minSpeech: TimeInterval = 0.4

    private var leftover: [Float] = []
    private var nextFrameTime = Date.distantPast
    private var noiseFloor: Float = -60
    private var preRoll: [(samples: [Float], time: Date)] = []
    private var loudRun = 0

    private var inSpeech = false
    private var speech: [Float] = []
    private var speechStart = Date.distantPast
    private var lastLoudEnd = Date.distantPast
    private var quietRun = 0
    private var loudFrames = 0

    init(sampleRate: Double = MicCapture.sampleRate) {
        self.sampleRate = sampleRate
        self.frameSize = Int(sampleRate * 0.03)
    }

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
            nextFrameTime = nextFrameTime.addingTimeInterval(Double(frameSize) / sampleRate)
        }
        leftover.removeFirst(offset)
        return finished
    }

    /// Ends any utterance in progress (call when listening stops).
    mutating func flush() -> Utterance? {
        defer { reset() }
        return inSpeech ? finish() : nil
    }

    private mutating func process(_ frame: ArraySlice<Float>, at time: Date) -> Utterance? {
        let level = Self.decibels(frame)
        let loud = level > max(noiseFloor + 12, -50)
        let frameEnd = time.addingTimeInterval(Double(frame.count) / sampleRate)

        guard inSpeech else {
            trackNoiseFloor(level)
            preRoll.append((Array(frame), time))
            if preRoll.count > preRollFrames { preRoll.removeFirst() }
            loudRun = loud ? loudRun + 1 : 0
            if loudRun >= framesToStart {
                inSpeech = true
                speechStart = preRoll.first?.time ?? time
                speech = preRoll.flatMap(\.samples)
                loudFrames = loudRun
                lastLoudEnd = frameEnd
                quietRun = 0
                preRoll.removeAll()
            }
            return nil
        }

        speech.append(contentsOf: frame)
        if loud {
            quietRun = 0
            loudFrames += 1
            lastLoudEnd = frameEnd
        } else {
            quietRun += 1
        }

        if quietRun >= framesToEnd {
            defer { reset() }
            return finish()
        }
        if frameEnd.timeIntervalSince(speechStart) >= maxDuration {
            // Still talking: hand off what we have and carry on with a fresh utterance.
            let utterance = finish()
            speech = []
            speechStart = frameEnd
            loudFrames = 0
            return utterance
        }
        return nil
    }

    private func finish() -> Utterance? {
        guard Double(loudFrames * frameSize) / sampleRate >= minSpeech else { return nil }
        return Utterance(samples: speech, start: speechStart, end: lastLoudEnd)
    }

    private mutating func reset() {
        inSpeech = false
        speech = []
        loudRun = 0
        loudFrames = 0
        quietRun = 0
    }

    private mutating func trackNoiseFloor(_ level: Float) {
        // Follow the room quickly when it gets quieter, slowly when it gets louder.
        let rate: Float = level < noiseFloor ? 0.1 : 0.005
        noiseFloor = min(max(noiseFloor + (level - noiseFloor) * rate, -80), -30)
    }

    private static func decibels(_ frame: ArraySlice<Float>) -> Float {
        let meanSquare = frame.reduce(0) { $0 + $1 * $1 } / Float(frame.count)
        return 10 * log10(meanSquare + 1e-10)
    }
}
