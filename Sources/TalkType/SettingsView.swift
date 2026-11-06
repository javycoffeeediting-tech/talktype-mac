import AVFoundation
import AppKit
import Carbon
import SwiftUI
import TalkTypeCore

/// A box that records the next shortcut pressed while it has focus.
private final class ShortcutRecorder: NSView {
    var combo: KeyCombo?
    var isOptional = false
    var changed: ((KeyCombo?) -> Void)?
    var focusChanged: ((Bool) -> Void)?

    private let label = NSTextField(labelWithString: "")
    private var isRecording = false {
        didSet {
            updateLabel()
        }
    }

    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Only used from code.")
    }

    func updateLabel() {
        label.stringValue = isRecording ? "Kürzel drücken …" : combo?.display ?? "Keins"
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func becomeFirstResponder() -> Bool {
        isRecording = true
        focusChanged?(true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        focusChanged?(false)
        return true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else {
            return super.performKeyEquivalent(with: event)
        }

        keyDown(with: event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: UInt32 = 0
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }

        if isOptional, modifiers == 0, Int(event.keyCode) == kVK_Delete || Int(event.keyCode) == kVK_ForwardDelete {
            combo = nil
            changed?(nil)
        } else {
            let pressed = KeyCombo(keyCode: UInt32(event.keyCode), modifiers: modifiers)
            combo = pressed
            changed?(pressed)
        }

        window?.makeFirstResponder(nil)
    }
}

private struct ShortcutField: NSViewRepresentable {
    @Binding var combo: KeyCombo?
    var isOptional: Bool
    var hotkeys: HotkeyCenter

    func makeNSView(context: Context) -> ShortcutRecorder {
        let view = ShortcutRecorder()
        view.isOptional = isOptional
        view.focusChanged = { focused in
            if focused {
                hotkeys.suspend()
            } else {
                hotkeys.resume()
            }
        }
        return view
    }

    func updateNSView(_ view: ShortcutRecorder, context: Context) {
        view.combo = combo
        view.changed = { combo = $0 }
        view.updateLabel()
    }
}

/// A button that fetches a model, with a progress bar while it does.
private struct DownloadButton: View {
    let model: ModelFile
    let finished: () -> Void

    @State private var progress: Double?
    @State private var task: Task<Void, Never>?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let progress {
                ProgressView(value: progress)
                Button("Download stoppen") {
                    task?.cancel()
                }
            } else {
                Button("Laden (\(model.sizeText))") {
                    start()
                }
            }

            if failed {
                Text("Das Laden hat nicht geklappt. Prüfe die Verbindung und versuche es noch einmal.")
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
    }

    private func start() {
        failed = false
        progress = 0
        let model = model
        task = Task {
            do {
                try await ModelDownload.run(model) { share in
                    Task { @MainActor in
                        progress = share
                    }
                }
                progress = nil
                finished()
            } catch {
                progress = nil
                failed = !(error is CancellationError) && (error as? URLError)?.code != .cancelled
            }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    let hotkeys: HotkeyCenter

    @State private var microphones = Microphone.all()
    @State private var microphoneAllowed = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @State private var canPaste = Paster.canPaste
    @State private var startAtLogin = LoginItem.isEnabled
    @State private var systemTranslatorReady = false

    // Bumped after a download, so the view looks at the model files again.
    @State private var refresh = 0

    private let permissionCheck = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    private var speechModel: ModelFile {
        store.value.speechModel(for: store.value.language)
    }

    private var qualities: [SpeechQuality] {
        store.value.language == .german ? SpeechQuality.allCases : [.best, .medium, .ultraLight]
    }

    var body: some View {
        Form {
            if !microphoneAllowed || !canPaste {
                permissionsSection
            }

            Section("Diktieren") {
                LabeledContent("Kürzel") {
                    ShortcutField(combo: Binding(get: { store.value.hotkey }, set: { if let combo = $0, combo.problem == nil { store.value.hotkey = combo } }), isOptional: false, hotkeys: hotkeys)
                        .frame(width: 180, height: 26)
                }

                Text("Tippen startet und stoppt, oder halten, solange du sprichst. Esc bricht ab.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Picker("Mikrofon", selection: $store.value.microphone) {
                    Text("Systemstandard").tag(String?.none)
                    ForEach(microphones) { microphone in
                        Text(microphone.name).tag(String?.some(microphone.id))
                    }
                }
            }

            Section("Sprache und Modell") {
                Picker("Sprache", selection: $store.value.language) {
                    Text("Deutsch").tag(DictationLanguage.german)
                    Text("Englisch").tag(DictationLanguage.english)
                }

                Picker("Modell", selection: $store.value.speechQuality) {
                    ForEach(qualities, id: \.self) { quality in
                        Text("\(name(of: quality)) (\(ModelFile.speech(store.value.language, quality).sizeText))").tag(quality)
                    }
                }

                Text(explanation(of: store.value.speechQuality))
                    .font(.caption)
                    .foregroundColor(.secondary)

                if !speechModel.isInstalled {
                    DownloadButton(model: speechModel) {
                        refresh += 1
                    }
                    .id("\(speechModel.fileName)\(refresh)")
                }
            }

            Section("Ins Englische übersetzen") {
                Text("Sprich Deutsch und bekomme Englisch.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                LabeledContent("Kürzel") {
                    ShortcutField(combo: optionalHotkey(\.translateHotkey), isOptional: true, hotkeys: hotkeys)
                        .frame(width: 180, height: 26)
                }

                TextField("Stichwort", text: $store.value.translateKeywords, prompt: Text("Kein Stichwort"))

                if SystemTranslator.isSupported {
                    Picker("Übersetzen mit", selection: $store.value.translationEngine) {
                        Text("Sprachmodell").tag(TranslationEngine.languageModel)
                        Text("macOS (ultraleicht)").tag(TranslationEngine.system)
                    }

                    if store.value.translationEngine == .system, !systemTranslatorReady {
                        Text("Lade Deutsch und Englisch einmalig unter Systemeinstellungen > Allgemein > Sprache & Region > Übersetzungssprachen.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Section("Zusammenfassen") {
                Text("Macht aus dem Gesagten sauberen, klaren Text.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                LabeledContent("Kürzel") {
                    ShortcutField(combo: optionalHotkey(\.condenseHotkey), isOptional: true, hotkeys: hotkeys)
                        .frame(width: 180, height: 26)
                }

                TextField("Stichwort", text: $store.value.condenseKeywords, prompt: Text("Kein Stichwort"))

                Text("Sag ein Stichwort als allererstes oder allerletztes Wort, für sich allein. Die Rücktaste löscht ein Kürzel.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Sprachmodell zum Übersetzen und Zusammenfassen") {
                Picker("Größe", selection: $store.value.rewriteQuality) {
                    Text("Beste Qualität (\(ModelFile.rewriteBest.sizeText))").tag(RewriteQuality.best)
                    Text("Leicht (\(ModelFile.rewriteLight.sizeText))").tag(RewriteQuality.light)
                }

                Text(store.value.rewriteQuality == .light
                    ? "Halb so groß und doppelt so schnell. Übersetzt gut, fasst aber gröber zusammen."
                    : "Am zuverlässigsten bei Fakten und Zahlen.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if !store.value.rewriteModel.isInstalled {
                    DownloadButton(model: store.value.rewriteModel) {
                        refresh += 1
                    }
                    .id("\(store.value.rewriteModel.fileName)\(refresh)")
                }
            }

            Section("Deine Wörter") {
                TextField("Namen und Begriffe, durch Kommas getrennt", text: $store.value.vocabulary)
            }

            Section("Optionen") {
                Toggle("Nach dem Einfügen Eingabetaste drücken (sendet die Nachricht sofort)", isOn: $store.value.pressEnterAfterPaste)
                Toggle("Töne beim Starten und Stoppen", isOn: $store.value.playSounds)
                Toggle("Beim Anmelden starten", isOn: $startAtLogin)
                    .onChange(of: startAtLogin) { newValue in
                        LoginItem.isEnabled = newValue
                    }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 680)
        .onChange(of: store.value.language) { _ in
            if !qualities.contains(store.value.speechQuality) {
                store.value.speechQuality = .best
            }
        }
        .onReceive(permissionCheck) { _ in
            microphoneAllowed = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            canPaste = Paster.canPaste
        }
        .task {
            systemTranslatorReady = await SystemTranslator.isReady()
        }
    }

    private var permissionsSection: some View {
        Section("Noch zwei Dinge") {
            if !microphoneAllowed {
                LabeledContent("Mikrofon") {
                    Button("Erlauben") {
                        AVCaptureDevice.requestAccess(for: .audio) { _ in
                        }
                    }
                }
            }

            if !canPaste {
                LabeledContent("Bedienungshilfen (zum Einfügen)") {
                    Button("Erlauben") {
                        Paster.askForPermission()
                    }
                }
            }
        }
    }

    private func optionalHotkey(_ path: WritableKeyPath<AppSettings, KeyCombo?>) -> Binding<KeyCombo?> {
        Binding(
            get: { store.value[keyPath: path] },
            set: { combo in
                if combo?.problem == nil {
                    store.value[keyPath: path] = combo
                }
            }
        )
    }

    private func name(of quality: SpeechQuality) -> String {
        switch quality {
        case .best: return "Beste Qualität"
        case .medium: return "Mittel"
        case .ultraLight: return "Ultraleicht"
        case .tunedGerman: return "Deutsch-Feinabstimmung"
        }
    }

    private func explanation(of quality: SpeechQuality) -> String {
        switch quality {
        case .best: return "Am genauesten. Kostenlos und offline."
        case .medium: return "Schneller und leichter, mit etwas mehr Fehlern."
        case .ultraLight: return "Für einen ausgelasteten Mac. Rechne mit mehr Fehlern."
        case .tunedGerman: return "Auf Deutsch abgestimmt, schreibt aber ss statt ß."
        }
    }
}
