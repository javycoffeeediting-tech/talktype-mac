import XCTest
@testable import TalkTypeCore

final class KeywordTests: XCTestCase {
    private func said(_ text: String) -> (text: String, said: Rewrite) {
        Keywords.extract(text, translate: ["übersetzen"], condense: ["condense", "zusammenfassen"])
    }

    func testCommandsOnTheirOwn() {
        XCTAssertEqual(said("Übersetzen. Ich bin gleich da.").text, "Ich bin gleich da.")
        XCTAssertEqual(said("Übersetzen. Ich bin gleich da.").said, .translate)
        XCTAssertEqual(said("Ich bin gleich da. Übersetzen.").text, "Ich bin gleich da.")
        XCTAssertEqual(said("Ich bin gleich da, übersetzen.").text, "Ich bin gleich da.")
        XCTAssertEqual(said("Condense: we need to talk about the budget.").text, "We need to talk about the budget.")
        XCTAssertEqual(said("Zusammen fassen. Das Meeting ist am Montag.").said, .condense)
        XCTAssertEqual(said("CONDENSE! ok then").text, "Ok then.")
        XCTAssertEqual(said("Übersetzen.").text, "")
    }

    func testTwoCommands() {
        XCTAssertEqual(said("Zusammenfassen. Übersetzen. Hallo zusammen.").said, [.condense, .translate])
        XCTAssertEqual(said("Hallo zusammen. Zusammenfassen, übersetzen.").text, "Hallo zusammen.")
        XCTAssertEqual(said("Übersetzen. Hallo. Zusammenfassen.").said, [.condense, .translate])
    }

    func testOrdinarySentencesStayOrdinary() {
        for sentence in ["Wir müssen das noch übersetzen.", "Übersetzen wir das doch einfach.", "Bitte übersetzen, und dann schicken wir es raus.", "Hello there."] {
            XCTAssertEqual(said(sentence).text, sentence)
            XCTAssertEqual(said(sentence).said, [])
        }
    }

    func testParsing() {
        XCTAssertEqual(Keywords.parse(" condense, zusammenfassen ,, "), ["condense", "zusammenfassen"])
        XCTAssertEqual(Keywords.parse("  "), [])
    }
}

final class InventedPhraseTests: XCTestCase {
    private func nobody(_ from: Double, _ to: Double) -> Double { 0 }
    private func somebody(_ from: Double, _ to: Double) -> Double { to - from }

    func testClosingLines() {
        let closing = [TimedText(text: " Wir reden morgen.", start: 0, end: 3), TimedText(text: " Vielen Dank fürs Zuschauen!", start: 3, end: 5)]
        XCTAssertEqual(InventedPhrases.strip(closing, language: .german, secondsOfSpeech: nobody), " Wir reden morgen.")
        XCTAssertTrue(InventedPhrases.strip(closing, language: .german, secondsOfSpeech: somebody).contains("Vielen Dank"))
        XCTAssertTrue(InventedPhrases.strip(closing, language: .english, secondsOfSpeech: nobody).contains("Vielen Dank"))
    }

    func testInsideALongerSegment() {
        let text = [TimedText(text: " We'll talk tomorrow. Thank you.", start: 0, end: 4)]
        XCTAssertEqual(InventedPhrases.strip(text, language: .english, secondsOfSpeech: nobody), " We'll talk tomorrow.")
        XCTAssertEqual(InventedPhrases.strip(text, language: .english, secondsOfSpeech: somebody), text[0].text)
    }

    func testCreditsGoAnywhere() {
        let text = [
            TimedText(text: " Das Meeting ist am Montag.", start: 0, end: 3),
            TimedText(text: " Untertitel im Auftrag des ZDF für funk, 2017", start: 3, end: 6),
            TimedText(text: " Danach reden wir.", start: 6, end: 8),
        ]
        let result = InventedPhrases.strip(text, language: .german, secondsOfSpeech: somebody)
        XCTAssertFalse(result.contains("ZDF"))
        XCTAssertTrue(result.contains("Danach reden wir."))
    }

    func testARealSentenceStays() {
        XCTAssertFalse(InventedPhrases.isClosingLine("Thank you for the invoice", language: .english))
    }
}

final class SpeechAudioTests: XCTestCase {
    func testComposeKeepsPaddingAndMovesPositions() {
        let audio = SpeechAudio.compose([Float](repeating: 0, count: 32000), spans: [SpeechSpan(start: 0.5, end: 1.0)])
        XCTAssertEqual(audio.samples.count, 16000)
        XCTAssertEqual(audio.spans[0].start, 0.25, accuracy: 0.001)
    }

    func testComposeClosesLongPauses() {
        let audio = SpeechAudio.compose([Float](repeating: 0, count: 16000 * 12), spans: [SpeechSpan(start: 1, end: 2), SpeechSpan(start: 10, end: 11)])
        XCTAssertLessThan(Double(audio.samples.count) / 16000, 3.1)
    }

    func testLastPause() {
        let spans = [SpeechSpan(start: 0, end: 10), SpeechSpan(start: 10.1, end: 16), SpeechSpan(start: 17, end: 22), SpeechSpan(start: 22.5, end: 24)]
        XCTAssertEqual(SpeechAudio.lastPause(in: spans, atLeast: 15), Int(22.25 * 16000))
        XCTAssertNil(SpeechAudio.lastPause(in: spans, atLeast: 23))
    }
}

final class ModelTests: XCTestCase {
    func testBestIsSharedAndSizesShrink() {
        XCTAssertEqual(ModelFile.speech(.english, .best), ModelFile.speech(.german, .best))
        XCTAssertLessThan(ModelFile.speech(.german, .ultraLight).bytes, ModelFile.speech(.german, .medium).bytes)
        XCTAssertLessThan(ModelFile.speech(.german, .medium).bytes, ModelFile.turbo.bytes)
        XCTAssertTrue(ModelFile.speech(.english, .medium).fileName.contains(".en"))
        XCTAssertFalse(ModelFile.speech(.german, .medium).fileName.contains(".en"))
    }

    func testSizesReadTheGermanWay() {
        XCTAssertEqual(ModelFile.rewriteLight.sizeText, "1,3 GB")
        XCTAssertEqual(ModelFile.turbo.sizeText, "574 MB")
    }
}

final class PromptTests: XCTestCase {
    func testPromptLanguages() {
        XCTAssertTrue(Prompts.forRewrite(.condense, language: .english, terms: []).contains("rambling dictation"))
        XCTAssertTrue(Prompts.forRewrite(.condense, language: .german, terms: []).contains("gesprochenem Diktat"))
        XCTAssertTrue(Prompts.forRewrite(.translate, language: .german, terms: []).contains("into natural English"))
        XCTAssertTrue(Prompts.forRewrite([.translate, .condense], language: .german, terms: []).contains("clean written English"))
        XCTAssertTrue(Prompts.forRewrite(.condense, language: .german, terms: ["Luvanty"]).contains("Luvanty"))
    }

    func testTidying() {
        XCTAssertEqual(Prompts.tidy("\"Hello there.\""), "Hello there.")
        XCTAssertEqual(Prompts.tidy("„Hallo zusammen.“"), "Hallo zusammen.")
        XCTAssertEqual(Prompts.tidy("\"One\" and \"two\""), "\"One\" and \"two\"")
        XCTAssertEqual(Prompts.tidy("Move it to **Friday** at 9."), "Move it to Friday at 9.")
        XCTAssertEqual(Prompts.tidy("<think>hmm\nok</think>\nDone."), "Done.")
    }

    func testAccepting() {
        XCTAssertEqual(Prompts.accept("Fine.", ranOut: false, original: "Fine, I guess."), "Fine.")
        XCTAssertNil(Prompts.accept("  ", ranOut: false, original: "Hello"))
        XCTAssertNil(Prompts.accept("It went on and on", ranOut: true, original: "Hello"))
        XCTAssertNil(Prompts.accept(String(repeating: "x", count: 2000), ranOut: false, original: "Short text."))
    }
}
