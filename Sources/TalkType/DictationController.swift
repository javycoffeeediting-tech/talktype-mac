import AVFoundation
import AppKit
import Foundation
import TalkTypeCore

/// Runs one dictation at a time: record, transcribe, rewrite if asked, paste.
@MainActor
final class DictationController {
    enum State {
        case idle
        case recording
        case finishing
    }

    // Held longer than this means push-to-talk, so letting go stops. Shorter is a tap.
    private static let holdThreshold: TimeInterval = 0.45

    // Limits that stop a forgotten recording from running on with an open microphone.
    private static let maxLength: TimeInterval = 600
    private static let maxSilence: TimeInterval = 60

    private static let minimumSeconds = 0.25
    private static let speechLevel: Float = 0.002

    // An M1 takes a while over long audio, so Whisper starts while someone is still talking, at a
    // pause once this much has been said. Stopping then only leaves the last stretch to do.
    private static let aheadAfterSeconds = 20.0
    private static let aheadEvery: UInt64 = 5_000_000_000

    var stateChanged: ((State) -> Void)?
    var setupNeeded: (() -> Void)?

    private(set) var state = State.idle {
        didSet {
            if state != oldValue {
                stateChanged?(state)
            }
        }
    }

    /// What was said, before any rewriting.
    private(set) var lastTranscript: String?

    private let settings: SettingsStore
    private let overlay: Overlay
    private let whisper: LocalWhisper
    private let rewriter: Rewriter

    private var recorder: MicRecorder?
    private var samples: [Float] = []
    private var transcribedUpTo = 0
    private var finishedParts: [String] = []
    private var ahead: Task<Void, Never>?
    private var job: Task<Void, Never>?
    private var limits: Timer?
    private var rewrite: Rewrite = []
    private var language = DictationLanguage.german
    private var startedAt = Date()
    private var lastSpeechAt = Date()

    init(settings: SettingsStore, overlay: Overlay, whisper: LocalWhisper, rewriter: Rewriter) {
        self.settings = settings
        self.overlay = overlay
        self.whisper = whisper
        self.rewriter = rewriter
    }

    var isReady: Bool {
        settings.value.speechModel(for: settings.value.language).isInstalled
    }

    /// Starts or stops a dictation. Stopping with the translate or condense shortcut counts too,
    /// so someone can decide once they've finished talking.
    func hotkeyPressed(_ asked: Rewrite) {
        switch state {
        case .idle:
            rewrite = asked
            start()
        case .recording:
            rewrite.formUnion(asked)
            stop()
        case .finishing:
            break
        }
    }

    func hotkeyReleased(held: TimeInterval) {
        if state == .recording, held >= DictationController.holdThreshold {
            stop()
        }
    }

    func cancel() {
        guard state != .idle else {
            return
        }

        job?.cancel()
        if state == .recording {
            let recorder = recorder
            Task {
                await recorder?.stop()
            }

            reset()
            overlay.dismiss()
        }
    }

    private func start() {
        // Translating means talking German, whichever language is normally used.
        language = rewrite.contains(.translate) ? .german : settings.value.language

        let model = settings.value.speechModel(for: language)
        guard model.isInstalled else {
            report("Lade zuerst das Sprachmodell in den Einstellungen.")
            setupNeeded?()
            return
        }

        samples = []
        transcribedUpTo = 0
        finishedParts = []

        let recorder = MicRecorder()
        do {
            try recorder.start(microphone: settings.value.microphone) { [weak self] chunk in
                Task { @MainActor in
                    self?.received(chunk)
                }
            }
        } catch {
            Log.write("Recording could not start: \(error.localizedDescription)")
            report("Das Mikrofon ließ sich nicht öffnen. Prüfe es in den Einstellungen.")
            return
        }

        self.recorder = recorder
        startedAt = Date()
        lastSpeechAt = startedAt
        state = .recording
        play("Tink")
        overlay.showListening()

        let whisper = whisper
        Task {
            await whisper.warmUp(model)
        }

        // Asked for up front, so the model can load while they're still talking.
        if !rewrite.isEmpty {
            warmUpRewriter()
        }

        limits = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkLimits()
            }
        }

        ahead = Task { [weak self] in
            await self?.transcribeAhead()
        }
    }

    private func warmUpRewriter() {
        let usesSystem = settings.value.translationEngine == .system && rewrite == [.translate]
        if !usesSystem {
            let model = settings.value.rewriteModel
            let rewriter = rewriter
            Task {
                await rewriter.warmUp(model)
            }
        }
    }

    private func received(_ chunk: [Float]) {
        guard state == .recording else {
            if state == .finishing {
                samples.append(contentsOf: chunk)
            }

            return
        }

        samples.append(contentsOf: chunk)
        let level = (chunk.reduce(0) { $0 + $1 * $1 } / Float(chunk.count)).squareRoot()
        overlay.setLevel(level)
        if level > DictationController.speechLevel {
            lastSpeechAt = Date()
        }
    }

    private func checkLimits() {
        let now = Date()
        let tooLong = now.timeIntervalSince(startedAt) > DictationController.maxLength
        let tooQuiet = now.timeIntervalSince(lastSpeechAt) > DictationController.maxSilence
        if state == .recording, tooLong || tooQuiet {
            Log.write(tooLong ? "Stopped at the length limit." : "Stopped after a long silence.")
            stop()
        }
    }

    private func transcribeAhead() async {
        let rate = Double(SpeechAudio.sampleRate)
        while state == .recording {
            try? await Task.sleep(nanoseconds: DictationController.aheadEvery)
            guard state == .recording, Double(samples.count - transcribedUpTo) / rate >= DictationController.aheadAfterSeconds else {
                continue
            }

            let start = transcribedUpTo
            let waiting = Array(samples[start...])
            guard let cut = await whisper.pause(in: waiting, atLeast: DictationController.aheadAfterSeconds - 5) else {
                continue
            }

            do {
                let text = try await whisper.transcribe(
                    Array(waiting[..<cut]),
                    language: language,
                    model: settings.value.speechModel(for: language),
                    terms: settings.value.terms,
                    earlierText: finishedParts.last
                )
                finishedParts.append(text)
                transcribedUpTo = start + cut
            } catch {
                Log.write("Transcribing ahead failed: \(error)")
                return
            }
        }
    }

    private func stop() {
        guard state == .recording, let recorder else {
            return
        }

        state = .finishing
        limits?.invalidate()
        overlay.showWorking("Schreibe auf …")
        job = Task { [weak self] in
            await recorder.stop()
            await self?.finish()
        }
    }

    private func finish() async {
        defer { reset() }

        // Only now, or the microphone would hear the tone from the speakers as a last sound.
        play("Pop")

        let stoppedAt = Date()
        await ahead?.value

        guard Double(samples.count) / Double(SpeechAudio.sampleRate) >= DictationController.minimumSeconds else {
            overlay.dismiss()
            return
        }

        do {
            let last = try await whisper.transcribe(
                Array(samples[transcribedUpTo...]),
                language: language,
                model: settings.value.speechModel(for: language),
                terms: settings.value.terms,
                earlierText: finishedParts.last
            )

            guard !Task.isCancelled else {
                overlay.dismiss()
                return
            }

            let text = (finishedParts + [last]).filter { !$0.isEmpty }.joined(separator: " ")
            Log.write("Transcribed \(samples.count / SpeechAudio.sampleRate) s of audio, \(Int(Date().timeIntervalSince(stoppedAt) * 1000)) ms after stopping.")

            let (spoken, said) = Keywords.extract(
                text,
                translate: language == .german ? Keywords.parse(settings.value.translateKeywords) : [],
                condense: Keywords.parse(settings.value.condenseKeywords)
            )

            guard !spoken.isEmpty else {
                report("Nichts verstanden.")
                return
            }

            lastTranscript = spoken
            var wanted = rewrite.union(said)
            if language != .german {
                wanted.remove(.translate)
            }

            var output = spoken
            var note: String?
            if !wanted.isEmpty {
                (output, note) = await rewritten(spoken, wanted)
            }

            guard !Task.isCancelled else {
                overlay.dismiss()
                return
            }

            overlay.dismiss()
            let pressEnter = settings.value.pressEnterAfterPaste

            // The space keeps the next dictation from running into this one.
            let pasted = pressEnter ? output : output + " "
            if Paster.canPaste {
                await Paster.paste(pasted, pressEnter: pressEnter)
            } else {
                Paster.copy(pasted)
                report("Text liegt in der Zwischenablage. Erlaube TalkType die Bedienungshilfen, damit es selbst einfügt.")
            }

            if let note {
                overlay.flash(note, isProblem: true)
            }
        } catch {
            Log.write("Dictation failed: \(error)")
            report("Das hat nicht geklappt. Details stehen in talktype.log.")
        }
    }

    // The plain text always survives: whatever goes wrong here, what was said still gets pasted.
    private func rewritten(_ text: String, _ wanted: Rewrite) async -> (String, String?) {
        overlay.showWorking(wanted == [.translate] ? "Übersetze …" : wanted == [.condense] ? "Fasse zusammen …" : "Fasse zusammen und übersetze …")

        do {
            var current = text
            var left = wanted

            // The translator in macOS can only translate, so it goes last, after any condensing.
            let useSystem = wanted.contains(.translate) && settings.value.translationEngine == .system && SystemTranslator.isSupported
            if useSystem {
                left.remove(.translate)
            }

            if !left.isEmpty {
                let model = settings.value.rewriteModel
                guard model.isInstalled else {
                    return (text, "Lade das Sprachmodell in den Einstellungen, um zu übersetzen oder zusammenzufassen.")
                }

                current = try await rewriter.rewrite(current, rewrite: left, language: language, terms: settings.value.terms, model: model)
            }

            return (useSystem ? try await SystemTranslator.translate(current) : current, nil)
        } catch let error as RewriteError {
            Log.write("Rewrite failed: \(error.message)")
            return (text, error.message)
        } catch is CancellationError {
            return (text, nil)
        } catch {
            Log.write("Translation failed: \(error.localizedDescription)")
            return (text, "Das Übersetzen ging nicht, hier ist der normale Text.")
        }
    }

    private func reset() {
        limits?.invalidate()
        limits = nil
        ahead?.cancel()
        ahead = nil
        job = nil
        recorder = nil
        samples = []
        state = .idle
    }

    private func report(_ message: String) {
        play("Basso")
        overlay.flash(message, isProblem: true)
    }

    private func play(_ sound: String) {
        if settings.value.playSounds {
            NSSound(named: NSSound.Name(sound))?.play()
        }
    }
}
