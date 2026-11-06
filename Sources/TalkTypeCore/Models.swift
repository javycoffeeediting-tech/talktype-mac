import Foundation

public enum DictationLanguage: String, Codable, CaseIterable, Sendable {
    case english
    case german

    public var code: String { self == .german ? "de" : "en" }
}

/// How much model to run. Lighter ones leave room for whatever else the computer is doing.
public enum SpeechQuality: String, Codable, CaseIterable, Sendable {
    case best
    case medium
    case ultraLight
    case tunedGerman
}

public enum RewriteQuality: String, Codable, CaseIterable, Sendable {
    case best
    case light
}

/// What does the translating: the language model, or the translator built into macOS.
public enum TranslationEngine: String, Codable, CaseIterable, Sendable {
    case languageModel
    case system
}

/// What to do with a dictation besides pasting it as spoken.
public struct Rewrite: OptionSet, Sendable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let condense = Rewrite(rawValue: 1)
    public static let translate = Rewrite(rawValue: 2)
}

public enum AppPaths {
    public static var support: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("TalkType", isDirectory: true)
    }

    // TALKTYPE_MODELS lets the self-test use models from another folder.
    public static var models: URL {
        if let folder = ProcessInfo.processInfo.environment["TALKTYPE_MODELS"] {
            return URL(fileURLWithPath: folder, isDirectory: true)
        }

        return support.appendingPathComponent("models", isDirectory: true)
    }

    public static var settings: URL { support.appendingPathComponent("settings.json") }

    public static var log: URL { support.appendingPathComponent("talktype.log") }

    /// Remembers the helper's process, so one left behind by a crash can be cleaned up.
    public static var helperPid: URL { support.appendingPathComponent("helper.pid") }
}

/// A model file and where it comes from.
public struct ModelFile: Equatable, Sendable {
    public let fileName: String
    public let source: URL
    public let sha256: String
    public let bytes: Int64

    public var path: URL { AppPaths.models.appendingPathComponent(fileName) }

    public var isInstalled: Bool { FileManager.default.fileExists(atPath: path.path) }

    /// Written the way German speakers expect, like "1,3 GB" or "574 MB".
    public var sizeText: String {
        if bytes >= 1_000_000_000 {
            return String(format: "%.1f GB", Double(bytes) / 1e9).replacingOccurrences(of: ".", with: ",")
        }

        return "\(bytes / 1_000_000) MB"
    }

    private static func whisperCpp(_ fileName: String, _ sha256: String, _ bytes: Int64) -> ModelFile {
        ModelFile(
            fileName: fileName,
            source: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(fileName)")!,
            sha256: sha256,
            bytes: bytes
        )
    }

    // Turbo set to a language does as well as anything else its size, so both languages share it:
    // on real German clips it made 6 errors in 227 words, and the German fine-tune below made 8.
    public static let turbo = whisperCpp("ggml-large-v3-turbo-q5_0.bin", "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2", 574_041_195)

    // primeline's fine-tune. It writes ss for ß, as in "grosser", so it's an option, not the default.
    public static let tunedGerman = ModelFile(
        fileName: "ggml-large-v3-turbo-german-q5_0.bin",
        source: URL(string: "https://huggingface.co/cstr/whisper-large-v3-turbo-german-ggml/resolve/main/ggml-model-q5_0.bin")!,
        sha256: "15e92e3db0993c52fffa781513eec9253475331c1be808f8fb409285c9d9d030",
        bytes: 574_041_195
    )

    private static let smallEnglish = whisperCpp("ggml-small.en-q5_1.bin", "bfdff4894dcb76bbf647d56263ea2a96645423f1669176f4844a1bf8e478ad30", 190_098_681)
    private static let baseEnglish = whisperCpp("ggml-base.en-q5_1.bin", "4baf70dd0d7c4247ba2b81fafd9c01005ac77c2f9ef064e00dcf195d0e2fdd2f", 59_721_011)
    private static let small = whisperCpp("ggml-small-q5_1.bin", "ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb", 190_085_487)
    private static let base = whisperCpp("ggml-base-q5_1.bin", "422f1ae452ade6f30a004d7e5c6a43195e4433bc370bf23fac9cc591f01a8898", 59_707_625)

    public static func speech(_ language: DictationLanguage, _ quality: SpeechQuality) -> ModelFile {
        switch (language, quality) {
        case (.english, .medium): return smallEnglish
        case (.english, .ultraLight): return baseEnglish
        case (.german, .medium): return small
        case (.german, .ultraLight): return base
        case (.german, .tunedGerman): return tunedGerman
        default: return turbo
        }
    }

    // Picked by running real dictations through it: Qwen3.5 4B kept the facts, where models this
    // size or smaller from others changed numbers, looped, or turned statements around.
    public static let rewriteBest = ModelFile(
        fileName: "Qwen3.5-4B-Q4_K_M.gguf",
        source: URL(string: "https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/main/Qwen3.5-4B-Q4_K_M.gguf")!,
        sha256: "00fe7986ff5f6b463e62455821146049db6f9313603938a70800d1fb69ef11a4",
        bytes: 2_740_937_888
    )

    // Half the size and twice the speed. Translates well, but its condensing is rougher.
    public static let rewriteLight = ModelFile(
        fileName: "Qwen3.5-2B-Q4_K_M.gguf",
        source: URL(string: "https://huggingface.co/unsloth/Qwen3.5-2B-GGUF/resolve/main/Qwen3.5-2B-Q4_K_M.gguf")!,
        sha256: "aaf42c8b7c3cab2bf3d69c355048d4a0ee9973d48f16c731c0520ee914699223",
        bytes: 1_280_835_840
    )

    public static func rewrite(_ quality: RewriteQuality) -> ModelFile {
        quality == .light ? rewriteLight : rewriteBest
    }

    public static let all: [ModelFile] = [turbo, tunedGerman, smallEnglish, baseEnglish, small, base, rewriteBest, rewriteLight]
}
