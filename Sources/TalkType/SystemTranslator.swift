import AppKit
import Foundation
import SwiftUI
import TalkTypeCore

#if canImport(Translation)
import Translation
#endif

/// The translator built into macOS 15 and later: nothing to download from us, and it needs almost
/// no memory, so it's the ultra-light option. It's text only, so condensing still needs a model.
@MainActor
enum SystemTranslator {
    static var isSupported: Bool {
        if #available(macOS 15.0, *) {
            return true
        }

        return false
    }

    /// Whether the German and English language packs are on this Mac.
    static func isReady() async -> Bool {
        #if canImport(Translation)
        if #available(macOS 15.0, *) {
            let status = await Host.availability()
            return status == .installed
        }
        #endif
        return false
    }

    static func translate(_ text: String) async throws -> String {
        #if canImport(Translation)
        if #available(macOS 15.0, *) {
            return try await Host.shared.translate(text)
        }
        #endif
        throw RewriteError(message: "Die Übersetzung von macOS braucht macOS 15 oder neuer.")
    }

    #if canImport(Translation)
    /// Apple's API hands out sessions through a SwiftUI view, so a tiny hidden one has to exist.
    @available(macOS 15.0, *)
    @MainActor
    private final class Host: ObservableObject {
        static let shared = Host()

        private static let german = Locale.Language(identifier: "de")
        private static let english = Locale.Language(identifier: "en")

        @Published var configuration: TranslationSession.Configuration?

        private var window: NSWindow?
        private var pending: (text: String, finish: CheckedContinuation<String, Error>)?

        static func availability() async -> LanguageAvailability.Status {
            await LanguageAvailability().status(from: german, to: english)
        }

        func translate(_ text: String) async throws -> String {
            showHiddenView()
            return try await withCheckedThrowingContinuation { continuation in
                pending = (text, continuation)
                if configuration == nil {
                    configuration = TranslationSession.Configuration(source: Host.german, target: Host.english)
                } else {
                    configuration?.invalidate()
                }
            }
        }

        func run(_ session: TranslationSession) async {
            guard let job = pending else {
                return
            }

            pending = nil
            do {
                job.finish.resume(returning: try await session.translate(job.text).targetText)
            } catch {
                job.finish.resume(throwing: error)
            }
        }

        private func showHiddenView() {
            guard window == nil else {
                return
            }

            let hidden = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 1, height: 1), styleMask: .borderless, backing: .buffered, defer: false)
            hidden.contentView = NSHostingView(rootView: HostView(host: self))
            hidden.alphaValue = 0
            hidden.orderFrontRegardless()
            window = hidden
        }
    }

    @available(macOS 15.0, *)
    private struct HostView: View {
        @ObservedObject var host: Host

        var body: some View {
            Color.clear
                .frame(width: 1, height: 1)
                .translationTask(host.configuration) { session in
                    await host.run(session)
                }
        }
    }
    #endif
}
