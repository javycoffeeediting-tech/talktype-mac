import Foundation

/// A stretch of talking, in seconds from the start of the audio.
public struct SpeechSpan: Equatable, Sendable {
    public var start: Double
    public var end: Double

    public init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }
}

/// Audio cut down to the talking, and where the talking sits in it.
public struct SpeechAudio: Sendable {
    public static let sampleRate = 16000

    // Kept around the talking, so soft word endings and the first breath of a word survive.
    private static let padding = 0.25

    public var samples: [Float]
    public var spans: [SpeechSpan]

    public init(samples: [Float], spans: [SpeechSpan]) {
        self.samples = samples
        self.spans = spans
    }

    /// Keeps the talking and a little around it, and closes up long pauses.
    public static func compose(_ samples: [Float], spans: [SpeechSpan]) -> SpeechAudio {
        let rate = Double(sampleRate)
        let total = Double(samples.count) / rate
        var kept: [Float] = []
        kept.reserveCapacity(samples.count)
        var placed: [SpeechSpan] = []
        var keptUntil = 0.0

        for span in spans {
            let from = max(keptUntil, max(0, span.start - padding))
            let to = min(total, span.end + padding)
            guard to > from else {
                continue
            }

            let shift = Double(kept.count) / rate - from
            let first = Int(from * rate)
            let last = min(samples.count, Int(to * rate))
            kept.append(contentsOf: samples[first..<last])
            placed.append(SpeechSpan(start: span.start + shift, end: span.end + shift))
            keptUntil = to
        }

        return SpeechAudio(samples: kept, spans: placed)
    }

    /// The best place to cut off what's been said so far: in a pause, as late as possible, and at
    /// least `atLeast` seconds in. Returns a sample position, or nil if there's no such pause yet.
    public static func lastPause(in spans: [SpeechSpan], atLeast: Double) -> Int? {
        for (span, next) in zip(spans, spans.dropFirst()).reversed() where next.start - span.end >= 0.3 {
            let middle = (span.end + next.start) / 2
            if middle >= atLeast {
                return Int(middle * Double(sampleRate))
            }
        }

        return nil
    }
}
