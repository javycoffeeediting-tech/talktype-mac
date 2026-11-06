import Carbon
import Foundation
import ServiceManagement
import TalkTypeCore

/// A small diagnostics log. Transcripts never go in here.
enum Log {
    private static let queue = DispatchQueue(label: "talktype.log")
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    static func write(_ message: String) {
        queue.async {
            let manager = FileManager.default
            try? manager.createDirectory(at: AppPaths.support, withIntermediateDirectories: true)
            let path = AppPaths.log.path
            if let size = (try? manager.attributesOfItem(atPath: path))?[.size] as? Int, size > 256 * 1024 {
                try? manager.removeItem(atPath: path)
            }

            let line = Data("\(formatter.string(from: Date())) \(message)\n".utf8)
            if let handle = FileHandle(forWritingAtPath: path) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: line)
                try? handle.close()
            } else {
                manager.createFile(atPath: path, contents: line)
            }
        }
    }
}

/// A keyboard shortcut, with Carbon's key code and modifier flags.
struct KeyCombo: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let controlOption = UInt32(controlKey | optionKey)
    static let dictate = KeyCombo(keyCode: UInt32(kVK_ANSI_T), modifiers: controlOption)
    static let translate = KeyCombo(keyCode: UInt32(kVK_ANSI_G), modifiers: controlOption)
    static let condense = KeyCombo(keyCode: UInt32(kVK_ANSI_C), modifiers: controlOption)
    static let escape = KeyCombo(keyCode: UInt32(kVK_Escape), modifiers: 0)

    /// The way Mac menus write it, like ⌃⌥T.
    var display: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + KeyCombo.name(of: keyCode)
    }

    /// Why this shortcut can't be used, or nil when it's fine.
    var problem: String? {
        if keyCode == UInt32(kVK_Escape) {
            return "Esc ist zum Abbrechen reserviert."
        }

        let hasCommandKey = modifiers & UInt32(controlKey | optionKey | cmdKey) != 0
        let isFunctionKey = KeyCombo.functionKeys[Int(keyCode)] != nil
        return hasCommandKey || isFunctionKey ? nil : "Nimm ⌃, ⌥ oder ⌘ dazu, sonst geht diese Taste beim Tippen nicht mehr."
    }

    private static let functionKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
        kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15",
        kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]

    private static let namedKeys: [Int: String] = [
        kVK_Space: "Leertaste", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
    ]

    // Asks the keyboard layout, because the same key is Z on a German Mac and Y on an American one.
    private static func name(of keyCode: UInt32) -> String {
        if let name = functionKeys[Int(keyCode)] ?? namedKeys[Int(keyCode)] {
            return name
        }

        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return "Taste \(keyCode)"
        }

        let layoutData = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = layoutData.withUnsafeBytes { bytes -> OSStatus in
            guard let layout = bytes.bindMemory(to: UCKeyboardLayout.self).baseAddress else {
                return OSStatus(paramErr)
            }

            return UCKeyTranslate(
                layout,
                UInt16(keyCode),
                UInt16(kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeys,
                characters.count,
                &length,
                &characters
            )
        }

        return status == noErr && length > 0 ? String(utf16CodeUnits: characters, count: length).uppercased() : "Taste \(keyCode)"
    }
}

struct AppSettings: Codable, Equatable {
    var hotkey = KeyCombo.dictate
    var translateHotkey: KeyCombo? = .translate
    var condenseHotkey: KeyCombo? = .condense
    var translateKeywords = "übersetzen"
    var condenseKeywords = "zusammenfassen"
    var microphone: String?
    var language = DictationLanguage.german
    var speechQuality = SpeechQuality.best
    var rewriteQuality = RewriteQuality.best
    var translationEngine = TranslationEngine.languageModel
    var vocabulary = ""
    var pressEnterAfterPaste = false
    var playSounds = true

    init() {
    }

    // Written out so a settings file from an older version keeps working.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        hotkey = try values.decodeIfPresent(KeyCombo.self, forKey: .hotkey) ?? defaults.hotkey
        translateHotkey = values.contains(.translateHotkey) ? try values.decodeIfPresent(KeyCombo.self, forKey: .translateHotkey) : defaults.translateHotkey
        condenseHotkey = values.contains(.condenseHotkey) ? try values.decodeIfPresent(KeyCombo.self, forKey: .condenseHotkey) : defaults.condenseHotkey
        translateKeywords = try values.decodeIfPresent(String.self, forKey: .translateKeywords) ?? defaults.translateKeywords
        condenseKeywords = try values.decodeIfPresent(String.self, forKey: .condenseKeywords) ?? defaults.condenseKeywords
        microphone = try values.decodeIfPresent(String.self, forKey: .microphone)
        language = try values.decodeIfPresent(DictationLanguage.self, forKey: .language) ?? defaults.language
        speechQuality = try values.decodeIfPresent(SpeechQuality.self, forKey: .speechQuality) ?? defaults.speechQuality
        rewriteQuality = try values.decodeIfPresent(RewriteQuality.self, forKey: .rewriteQuality) ?? defaults.rewriteQuality
        translationEngine = try values.decodeIfPresent(TranslationEngine.self, forKey: .translationEngine) ?? defaults.translationEngine
        vocabulary = try values.decodeIfPresent(String.self, forKey: .vocabulary) ?? defaults.vocabulary
        pressEnterAfterPaste = try values.decodeIfPresent(Bool.self, forKey: .pressEnterAfterPaste) ?? defaults.pressEnterAfterPaste
        playSounds = try values.decodeIfPresent(Bool.self, forKey: .playSounds) ?? defaults.playSounds
    }

    /// Names and terms to favour, as a list.
    var terms: [String] {
        var seen = Set<String>()
        return vocabulary
            .split(whereSeparator: { ",;\n".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
            .prefix(50)
            .map { $0 }
    }

    func speechModel(for language: DictationLanguage) -> ModelFile {
        ModelFile.speech(language, speechQuality)
    }

    var rewriteModel: ModelFile {
        ModelFile.rewrite(rewriteQuality)
    }
}

/// The settings, saved whenever they change.
@MainActor
final class SettingsStore: ObservableObject {
    @Published var value: AppSettings {
        didSet {
            if value != oldValue {
                save()
                changed?(oldValue)
            }
        }
    }

    var changed: ((AppSettings) -> Void)?

    init() {
        if let data = try? Data(contentsOf: AppPaths.settings), let saved = try? JSONDecoder().decode(AppSettings.self, from: data) {
            value = saved
        } else {
            value = AppSettings()
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: AppPaths.support, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            try encoder.encode(value).write(to: AppPaths.settings, options: .atomic)
        } catch {
            Log.write("Settings could not be saved: \(error.localizedDescription)")
        }
    }
}

/// Starting with the Mac, through the system's login items.
enum LoginItem {
    static var isEnabled: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                Log.write("Login item could not be changed: \(error.localizedDescription)")
            }
        }
    }
}
