import Foundation

/// A piece of Whisper's output and when it says it happened, in seconds.
public struct TimedText: Equatable, Sendable {
    public var text: String
    public var start: Double
    public var end: Double

    public init(text: String, start: Double, end: Double) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// Lines Whisper picked up from the end of subtitled videos. A closing line is only dropped when
/// voice detection finds nobody saying it, so a "Danke" someone really said stays in.
public enum InventedPhrases {
    // A real "Thank you" takes at least this long to say.
    private static let shortestRealPhrase = 0.25

    private static let english: Set<String> = [
        "thank you", "thank you very much", "thank you so much", "thanks", "thanks a lot",
        "thank you for watching", "thank you so much for watching", "thanks for watching",
        "thank you for listening", "thanks for listening",
        "please subscribe", "subscribe to my channel", "like and subscribe",
        "see you next time", "see you in the next video", "ill see you next time", "ill see you in the next video",
        "bye", "bye bye", "goodbye", "you",
    ]

    private static let german: Set<String> = [
        "danke", "danke schön", "dankeschön", "vielen dank", "vielen lieben dank",
        "danke fürs zuschauen", "vielen dank fürs zuschauen", "vielen dank für das zuschauen",
        "danke fürs zuhören", "vielen dank fürs zuhören", "vielen dank für ihre aufmerksamkeit",
        "bis zum nächsten mal", "bis zum nächsten video", "bis bald", "tschüss", "auf wiedersehen",
    ]

    // Subtitle credits, which nobody dictates, so these go wherever they turn up.
    private static let credits = try! NSRegularExpression(
        pattern: #"(?i)\b(Untertitel(ung)?\b[^.!?]*\b(ZDF|ARD|WDR|NDR|SWR|BR|funk|Amara(\.org)?|Geiges)\b[^.!?\n]*[.!?]?|(Copyright|©)\s*(WDR|SWR|NDR|BR|ZDF|ARD)\s*\d{0,4}[.!?]?|Subtitles by the Amara\.org community[.!?]?)"#
    )

    public static func strip(_ segments: [TimedText], language: DictationLanguage, secondsOfSpeech: (Double, Double) -> Double) -> String {
        var kept = segments.compactMap { segment -> TimedText? in
            var cleaned = segment
            let range = NSRange(segment.text.startIndex..., in: segment.text)
            cleaned.text = credits.stringByReplacingMatches(in: segment.text, range: range, withTemplate: " ")
            return cleaned.text.contains(where: { $0.isLetter || $0.isNumber }) ? cleaned : nil
        }

        while let last = kept.last {
            let split = lastSentenceStart(last.text)
            let closing = String(last.text[split...])
            guard isClosingLine(closing, language: language) else {
                break
            }

            let whole = last.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let share = Double(closing.trimmingCharacters(in: .whitespacesAndNewlines).count) / Double(max(whole.count, 1))
            let from = last.end - (last.end - last.start) * share
            if secondsOfSpeech(from, last.end) >= shortestRealPhrase {
                break
            }

            if split == last.text.startIndex {
                kept.removeLast()
            } else {
                kept[kept.count - 1].text = String(last.text[..<split])
                kept[kept.count - 1].end = from
            }
        }

        return kept.map(\.text).joined()
    }

    public static func isClosingLine(_ text: String, language: DictationLanguage) -> Bool {
        let noApostrophes = text.replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "’", with: "")
        let plain = noApostrophes
            .split(whereSeparator: { !($0.isLetter || $0.isNumber) })
            .joined(separator: " ")
            .lowercased()
        return (language == .german ? german : english).contains(plain)
    }

    // Where the last sentence of this text begins. Only full stops and the like end a sentence.
    private static func lastSentenceStart(_ text: String) -> String.Index {
        var end = text.endIndex
        while end > text.startIndex, text[text.index(before: end)].isWhitespace {
            end = text.index(before: end)
        }

        guard end > text.startIndex else {
            return text.startIndex
        }

        var index = text.index(before: end)
        while index > text.startIndex {
            index = text.index(before: index)
            let next = text.index(after: index)
            if ".!?".contains(text[index]), text[next].isWhitespace {
                return next
            }
        }

        return text.startIndex
    }
}
