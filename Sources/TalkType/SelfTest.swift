import Foundation
import TalkTypeCore

/// Runs the speech and language models on a clip and prints what happened and how long it took.
/// This is how a build gets checked on GitHub's Macs, which have no microphone or person.
enum SelfTest {
    static func run(wav: String?) -> Never {
        let clip = wav ?? Bundle.main.path(forResource: "selftest-german", ofType: "wav") ?? ""
        Task.detached {
            var failed = false
            do {
                failed = try await check(clip)
            } catch {
                print("FAILED: \(error)")
                failed = true
            }

            exit(failed ? 1 : 0)
        }

        dispatchMain()
    }

    private static func check(_ clip: String) async throws -> Bool {
        let samples = try Convert.samples(ofFile: clip)
        print("Clip: \(Double(samples.count) / 16000) s")

        var failed = false
        let whisper = LocalWhisper()
        var german = ""
        for quality in [SpeechQuality.best, .medium, .ultraLight] {
            let model = ModelFile.speech(.german, quality)
            guard model.isInstalled else {
                print("\(quality): not installed, skipped")
                continue
            }

            for round in 1...2 {
                let started = Date()
                let text = try await whisper.transcribe(samples, language: .german, model: model, terms: [], earlierText: nil)
                print("\(quality) round \(round): \(Int(Date().timeIntervalSince(started) * 1000)) ms: \(text)")
                if quality == .best {
                    german = text
                }
            }
        }

        if german.isEmpty || !german.contains("Sediment") {
            print("FAILED: Whisper didn't hear the clip.")
            failed = true
        }

        let rewriter = Rewriter()
        for quality in RewriteQuality.allCases {
            let model = ModelFile.rewrite(quality)
            guard model.isInstalled else {
                print("\(quality) language model: not installed, skipped")
                continue
            }

            let started = Date()
            await rewriter.warmUp(model)
            print("\(quality) language model ready in \(Int(Date().timeIntervalSince(started) * 1000)) ms")

            let text = "Also ich wollte nur kurz sagen, dass wir das Meeting am Donnerstag, also nicht am Mittwoch, sondern am Donnerstag machen sollten, weil der Thomas am Mittwoch nicht da ist und er ja die ganzen Zahlen hat. Die Rechnung über 4.200 Euro müssen wir auch noch bezahlen."
            for rewrite in [Rewrite.translate, .condense] {
                let began = Date()
                let result = try await rewriter.rewrite(text, rewrite: rewrite, language: .german, terms: [], model: model)
                print("\(quality) \(rewrite == .translate ? "translate" : "condense"): \(Int(Date().timeIntervalSince(began) * 1000)) ms: \(result)")
                if !result.contains("4") {
                    print("FAILED: the number went missing.")
                    failed = true
                }
            }
        }

        await rewriter.stop()
        return failed
    }
}
