import Foundation

/// Spoken commands. One only counts at the very start or end of a dictation, standing on its own,
/// so that "übersetz das mal" or "wir müssen das übersetzen" stay ordinary sentences.
public enum Keywords {
    private static let word = try! NSRegularExpression(pattern: #"[\p{L}\p{N}]+(?:['’-][\p{L}\p{N}]+)*"#)
    private static let pause = try! NSRegularExpression(pattern: #"^\s*[.,;:!?…–—-]"#)

    /// Takes any commands off the ends of the text and says which were found.
    public static func extract(_ text: String, translate: [String], condense: [String]) -> (text: String, said: Rewrite) {
        var remaining = text
        var said: Rewrite = []
        var found: Bool

        repeat {
            found = false
            for (keywords, rewrite) in [(translate, Rewrite.translate), (condense, Rewrite.condense)] {
                for keyword in keywords where tryRemove(&remaining, keyword) {
                    said.insert(rewrite)
                    found = true
                }
            }
        } while found

        return (said.isEmpty ? text : tidy(remaining), said)
    }

    /// Keywords as typed in Settings: several can be given, separated by commas.
    public static func parse(_ keywords: String) -> [String] {
        keywords
            .split(whereSeparator: { $0 == "," || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !plain($0).isEmpty }
    }

    private static func words(in text: String) -> [NSRange] {
        word.matches(in: text, range: NSRange(text.startIndex..., in: text)).map(\.range)
    }

    private static func tryRemove(_ text: inout String, _ keyword: String) -> Bool {
        let wanted = plain(keyword)
        let found = words(in: text)
        let source = text as NSString
        let mostWords = words(in: keyword).count + 1

        // Whisper sometimes splits a long word, so "zusammen fassen" still counts.
        for count in stride(from: 1, through: min(mostWords, found.count), by: 1) {
            let opening = found[..<count].map { plain(source.substring(with: $0)) }.joined()
            let afterOpening = found[count - 1].upperBound
            let rest = source.substring(from: afterOpening)
            if opening == wanted, found.count == count || startsWithPause(rest) {
                text = rest
                return true
            }

            let closing = found[(found.count - count)...].map { plain(source.substring(with: $0)) }.joined()
            let before = source.substring(to: found[found.count - count].lowerBound)
            if closing == wanted, endsSentence(before) {
                text = before
                return true
            }
        }

        return false
    }

    private static func startsWithPause(_ text: String) -> Bool {
        pause.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    // A command at the end needs a pause before it too, or nothing at all.
    private static func endsSentence(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else {
            return true
        }

        return ".!?,;:-–—".contains(last)
    }

    private static func tidy(_ text: String) -> String {
        var tidy = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = tidy.first, ".,;:!?-–— ".contains(first) {
            tidy.removeFirst()
        }

        while let last = tidy.last, ",;:-–— ".contains(last) {
            tidy.removeLast()
        }

        guard let first = tidy.first, let last = tidy.last else {
            return ""
        }

        if last.isLetter || last.isNumber {
            tidy += "."
        }

        return first.uppercased() + tidy.dropFirst()
    }

    private static func plain(_ text: String) -> String {
        let lower = text.lowercased()
        let source = lower as NSString
        return words(in: lower).map { source.substring(with: $0) }.joined()
    }
}
