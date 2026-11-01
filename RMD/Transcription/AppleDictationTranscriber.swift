import AVFoundation
import Speech

/// Apple's on-device dictation engine (the one behind macOS keyboard dictation), through SpeechAnalyzer.
/// Indian English (`en_IN`) writes Hindi words in Roman letters; Hindi (`hi_IN`) writes Devanagari.
/// macOS owns and updates the model, so there is nothing to convert or bundle.
struct AppleDictationTranscriber: Transcriber {
    struct UnsupportedLocale: Error, CustomStringConvertible {
        let identifier: String
        var description: String { "Apple dictation doesn't support \(identifier) on this Mac" }
    }

    let locale: Locale

    /// Checks the language is supported and installs Apple's model for it if it isn't on this Mac yet.
    static func load(locale identifier: String) async throws -> AppleDictationTranscriber {
        let supported = await DictationTranscriber.supportedLocales
        guard let locale = supported.first(where: { $0.identifier(.bcp47) == Locale(identifier: identifier).identifier(.bcp47) }) else {
            throw UnsupportedLocale(identifier: identifier)
        }
        if let install = try await AssetInventory.assetInstallationRequest(supporting: [module(for: locale)]) {
            try await install.downloadAndInstall()
        }
        return AppleDictationTranscriber(locale: locale)
    }

    func transcribe(_ samples: [Float]) async throws -> Transcript? {
        let module = Self.module(for: locale)
        let analyzer = SpeechAnalyzer(modules: [module])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else { return nil }
        let collecting = Task {
            var text = ""
            for try await result in module.results { text += String(result.text.characters) }
            return text
        }

        let (input, feed) = AsyncStream.makeStream(of: AnalyzerInput.self)
        feed.yield(AnalyzerInput(buffer: try Self.buffer(samples, as: format)))
        feed.finish()
        if let end = try await analyzer.analyzeSequence(input) {
            try await analyzer.finalizeAndFinish(through: end)
        } else {
            await analyzer.cancelAndFinishNow()
        }

        let text = try await collecting.value.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : Transcript(text: text, language: nil)
    }

    private static func module(for locale: Locale) -> DictationTranscriber {
        DictationTranscriber(locale: locale, preset: .longDictation)
    }

    /// 16 kHz mono Float32 samples in the format the analyzer asks for.
    private static func buffer(_ samples: [Float], as format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: MicCapture.sampleRate, channels: 1, interleaved: false),
              let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(samples.count))
        else { throw Resampler.UnsupportedFormat() }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        if format == source { return input }

        let capacity = AVAudioFrameCount(Double(samples.count) * format.sampleRate / source.sampleRate) + 32
        guard let converter = AVAudioConverter(from: source, to: format),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity)
        else { throw Resampler.UnsupportedFormat() }
        var delivered = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if delivered {
                status.pointee = .endOfStream
                return nil
            }
            delivered = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }
        return output
    }
}
