import Foundation
import TalkTypeCore
import whisper

enum WhisperError: Error {
    case modelFailed
    case transcriptionFailed
}

/// Whisper running on this Mac. The model only sits in memory while it's being used.
actor LocalWhisper {
    private static let unloadAfter: UInt64 = 5 * 60 * 1_000_000_000
    private static let silenceRms: Float = 0.0008

    // Whisper refuses clips under a second, so short ones get padded with silence.
    private static let minimumSamples = SpeechAudio.sampleRate * 11 / 10

    private var context: OpaquePointer?
    private var loaded: ModelFile?
    private var voiceDetector: OpaquePointer?
    private var unload: Task<Void, Never>?

    /// Gets the model into memory ahead of time, while someone is still talking.
    func warmUp(_ model: ModelFile) {
        guard model.isInstalled else {
            return
        }

        _ = try? load(model)
        scheduleUnload()
    }

    /// The whole path from audio to text: only the talking gets to Whisper, then invented lines go.
    func transcribe(_ samples: [Float], language: DictationLanguage, model: ModelFile, terms: [String], earlierText: String?) throws -> String {
        defer { scheduleUnload() }

        guard rms(samples) >= LocalWhisper.silenceRms else {
            return ""
        }

        let spans = detect(samples, threshold: 0.5)
        if spans?.isEmpty == true {
            return ""
        }

        // If voice detection itself fails, a dictation still beats an error.
        let speech = spans.map { SpeechAudio.compose(samples, spans: $0) } ?? SpeechAudio(samples: samples, spans: [])
        let heard = try run(speech.samples, language: language, model: model, prompt: makePrompt(terms: terms, earlierText: earlierText))

        let text = InventedPhrases.strip(heard, language: language) { from, to in
            secondsOfSpeech(speech.samples, from: from, to: to)
        }

        return clean(text)
    }

    /// Where to cut off what's been said so far, in samples, if there's a good pause yet.
    func pause(in samples: [Float], atLeast seconds: Double) -> Int? {
        guard let spans = detect(samples, threshold: 0.5) else {
            return nil
        }

        return SpeechAudio.lastPause(in: spans, atLeast: seconds)
    }

    private func makePrompt(terms: [String], earlierText: String?) -> String? {
        let parts = [terms.isEmpty ? nil : terms.joined(separator: ", "), earlierText.map { String($0.suffix(200)) }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private func load(_ model: ModelFile) throws -> OpaquePointer {
        if let context, loaded == model {
            return context
        }

        freeModel()
        let started = Date()
        var parameters = whisper_context_default_params()
        parameters.use_gpu = true
        guard let context = whisper_init_from_file_with_params(model.path.path, parameters) else {
            throw WhisperError.modelFailed
        }

        self.context = context
        loaded = model
        Log.write("Whisper \(model.fileName) loaded in \(Int(Date().timeIntervalSince(started) * 1000)) ms.")
        return context
    }

    private func run(_ samples: [Float], language: DictationLanguage, model: ModelFile, prompt: String?) throws -> [TimedText] {
        let context = try load(model)

        var padded = samples
        if padded.count < LocalWhisper.minimumSamples {
            padded.append(contentsOf: [Float](repeating: 0, count: LocalWhisper.minimumSamples - padded.count))
        }

        var parameters = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        parameters.print_progress = false
        parameters.print_realtime = false
        parameters.print_special = false
        parameters.print_timestamps = false

        // The fast cores of an M1. The slow ones only hold everything else up.
        parameters.n_threads = Int32(max(2, min(4, ProcessInfo.processInfo.activeProcessorCount - 2)))

        let code = strdup(language.code)
        let promptText = prompt.flatMap { strdup($0) }
        defer {
            free(code)
            free(promptText)
        }

        parameters.language = UnsafePointer(code)
        parameters.initial_prompt = promptText.map { UnsafePointer($0) }

        let status = padded.withUnsafeBufferPointer { whisper_full(context, parameters, $0.baseAddress, Int32($0.count)) }
        guard status == 0 else {
            throw WhisperError.transcriptionFailed
        }

        return (0..<whisper_full_n_segments(context)).map { index in
            TimedText(
                text: String(cString: whisper_full_get_segment_text(context, index)),
                start: Double(whisper_full_get_segment_t0(context, index)) / 100,
                end: Double(whisper_full_get_segment_t1(context, index)) / 100
            )
        }
    }

    // Nil means voice detection isn't available, which isn't the same as nobody talking.
    private func detect(_ samples: [Float], threshold: Float) -> [SpeechSpan]? {
        guard let detector = loadVoiceDetector() else {
            return nil
        }

        var parameters = whisper_vad_default_params()
        parameters.threshold = threshold
        parameters.min_speech_duration_ms = 120
        parameters.min_silence_duration_ms = 250
        parameters.speech_pad_ms = 0

        let found = samples.withUnsafeBufferPointer { whisper_vad_segments_from_samples(detector, parameters, $0.baseAddress, Int32($0.count)) }
        guard let found else {
            return nil
        }

        defer { whisper_vad_free_segments(found) }

        // These come in hundredths of a second.
        return (0..<whisper_vad_segments_n_segments(found)).map { index in
            SpeechSpan(
                start: Double(whisper_vad_segments_get_segment_t0(found, index)) / 100,
                end: Double(whisper_vad_segments_get_segment_t1(found, index)) / 100
            )
        }
    }

    private func loadVoiceDetector() -> OpaquePointer? {
        if let voiceDetector {
            return voiceDetector
        }

        guard let path = Bundle.main.path(forResource: "silero-vad", ofType: "bin") else {
            Log.write("The voice detection model is missing.")
            return nil
        }

        // It's tiny, and the GPU is busy with Whisper.
        var parameters = whisper_vad_default_context_params()
        parameters.use_gpu = false
        parameters.n_threads = 2
        voiceDetector = whisper_vad_init_from_file_with_params(path, parameters)
        return voiceDetector
    }

    // How many seconds in this part of the audio are clearly someone talking. How sure it must be
    // is set high, because this decides whether a closing line counts as really said.
    private func secondsOfSpeech(_ samples: [Float], from: Double, to: Double) -> Double {
        let rate = Double(SpeechAudio.sampleRate)
        let first = max(0, min(samples.count, Int(from * rate)))
        let last = max(first, min(samples.count, Int(to * rate)))

        // Detection needs some sound around a word to settle, so it gets a little either side.
        let margin = SpeechAudio.sampleRate / 2
        let start = max(0, first - margin)
        let end = min(samples.count, last + margin)
        let offset = Double(start) / rate

        guard let spans = detect(Array(samples[start..<end]), threshold: 0.75) else {
            return Double.greatestFiniteMagnitude
        }

        return spans.reduce(0) { total, span in
            total + max(0, min(span.end + offset, to) - max(span.start + offset, from))
        }
    }

    private func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else {
            return 0
        }

        return (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
    }

    // Whisper labels non-speech like [BLANK_AUDIO] or (music) instead of staying quiet.
    private func clean(_ text: String) -> String {
        let spoken = text
            .replacingOccurrences(of: #"\[[^\]]*\]|\([^)]*\)|\*[^*]*\*|♪+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return spoken.contains(where: { $0.isLetter || $0.isNumber }) ? spoken : ""
    }

    private func scheduleUnload() {
        unload?.cancel()
        unload = Task { [weak self] in
            try? await Task.sleep(nanoseconds: LocalWhisper.unloadAfter)
            if !Task.isCancelled {
                await self?.freeModel()
            }
        }
    }

    private func freeModel() {
        if let context {
            whisper_free(context)
        }

        context = nil
        loaded = nil
    }
}
