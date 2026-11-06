import AppKit
import ApplicationServices
import Carbon

/// Puts text into whichever app has focus, then gives the clipboard back.
@MainActor
enum Paster {
    // Chat apps read the clipboard a moment after ⌘V, so it can't be restored right away.
    private static let restoreDelay: UInt64 = 700_000_000
    private static let keyReleaseLimit: TimeInterval = 2

    // Clipboard managers leave anything marked like this alone.
    private static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    private static var saved: [NSPasteboardItem]?
    private static var pasteNumber = 0

    static var canPaste: Bool {
        AXIsProcessTrusted()
    }

    static func askForPermission() {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
    }

    /// Without the Accessibility permission all that's left is to leave the text on the clipboard.
    static func copy(_ text: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
    }

    static func paste(_ text: String, pressEnter: Bool) async {
        await waitForKeysUp()

        let board = NSPasteboard.general

        // A paste right after another must not save our own text as the "original" clipboard.
        if saved == nil {
            saved = snapshot(board)
        }

        pasteNumber += 1
        let thisPaste = pasteNumber

        board.clearContents()
        board.setString(text, forType: .string)
        board.setData(Data(), forType: transient)
        let ours = board.changeCount

        press(key: UInt16(kVK_ANSI_V), flags: .maskCommand)
        if pressEnter {
            try? await Task.sleep(nanoseconds: 120_000_000)
            press(key: UInt16(kVK_Return), flags: [])
        }

        try? await Task.sleep(nanoseconds: restoreDelay)

        // Anything newer than our text is the person's own copy, and that wins.
        if thisPaste == pasteNumber {
            if board.changeCount == ours, let items = saved {
                board.clearContents()
                if !items.isEmpty {
                    board.writeObjects(items)
                }
            }

            saved = nil
        }
    }

    private static func snapshot(_ board: NSPasteboard) -> [NSPasteboardItem] {
        (board.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }

            return copy
        }
    }

    private static func press(key: UInt16, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for isDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: isDown)
            event?.flags = flags
            event?.post(tap: .cgSessionEventTap)
        }
    }

    // A key still held from the shortcut would turn ⌘V into something else.
    private static func waitForKeysUp() async {
        let deadline = Date().addingTimeInterval(keyReleaseLimit)
        let held: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]
        while !CGEventSource.flagsState(.combinedSessionState).intersection(held).isEmpty, Date() < deadline {
            try? await Task.sleep(nanoseconds: 15_000_000)
        }
    }
}
