import AVFoundation
import AppKit
import SwiftUI
import TalkTypeCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = SettingsStore()
    private let overlay = Overlay()
    private let hotkeys = HotkeyCenter()
    private let whisper = LocalWhisper()
    private let rewriter = Rewriter()
    private lazy var dictation = DictationController(settings: settings, overlay: overlay, whisper: whisper, rewriter: rewriter)

    private let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let copyLast = NSMenuItem(title: "Letztes Diktat kopieren", action: #selector(AppDelegate.copyLastTranscript), keyEquivalent: "")
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        copyLast.target = self
        copyLast.isEnabled = false
        menu.addItem(copyLast)
        let openSettings = NSMenuItem(title: "Einstellungen …", action: #selector(showSettings), keyEquivalent: ",")
        openSettings.target = self
        menu.addItem(openSettings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "TalkType beenden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        status.menu = menu
        setIcon(.idle)

        dictation.stateChanged = { [weak self] state in
            self?.stateChanged(state)
        }
        dictation.setupNeeded = { [weak self] in
            self?.showSettings()
        }

        hotkeys.pressed = { [weak self] action in
            Task { @MainActor in
                self?.hotkeyPressed(action)
            }
        }
        hotkeys.released = { [weak self] held in
            Task { @MainActor in
                self?.dictation.hotkeyReleased(held: held)
            }
        }

        settings.changed = { [weak self] old in
            guard let self else {
                return
            }

            let new = self.settings.value
            if old.hotkey != new.hotkey || old.translateHotkey != new.translateHotkey || old.condenseHotkey != new.condenseHotkey {
                self.applyHotkeys()
            }
        }
        applyHotkeys()

        let rewriter = rewriter
        Task {
            await rewriter.cleanUpAfterCrash()
        }

        Log.write("Started.")
        if !dictation.isReady || !Paster.canPaste || AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            showSettings()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        let rewriter = rewriter
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await rewriter.stop()
            done.signal()
        }
        _ = done.wait(timeout: .now() + 1)
    }

    @objc func showSettings() {
        if let settingsWindow {
            NSApp.activate(ignoringOtherApps: true)
            settingsWindow.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 680), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "TalkType Einstellungen"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView(store: settings, hotkeys: hotkeys))
        window.center()
        window.delegate = self
        settingsWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func hotkeyPressed(_ action: HotkeyAction) {
        switch action {
        case .dictate: dictation.hotkeyPressed([])
        case .translate: dictation.hotkeyPressed(.translate)
        case .condense: dictation.hotkeyPressed(.condense)
        case .cancel: dictation.cancel()
        }
    }

    private func applyHotkeys() {
        let value = settings.value
        if !hotkeys.set(.dictate, to: value.hotkey) {
            Log.write("The main shortcut is taken.")
        }

        hotkeys.set(.translate, to: value.translateHotkey)
        hotkeys.set(.condense, to: value.condenseHotkey)
    }

    private func stateChanged(_ state: DictationController.State) {
        hotkeys.set(.cancel, to: state == .idle ? nil : KeyCombo.escape)
        setIcon(state)
        copyLast.isEnabled = dictation.lastTranscript != nil
    }

    private func setIcon(_ state: DictationController.State) {
        let symbol: String
        switch state {
        case .idle: symbol = "mic"
        case .recording: symbol = "mic.fill"
        case .finishing: symbol = "ellipsis.circle"
        }

        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "TalkType")
        image?.isTemplate = true
        status.button?.image = image
    }

    @objc private func copyLastTranscript() {
        if let text = dictation.lastTranscript {
            Paster.copy(text)
        }
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        settingsWindow = nil
        hotkeys.resume()
    }
}
