import AppKit
import SwiftUI

/// The small pill near the bottom of the screen. It never takes focus and clicks pass through
/// it, because the text has to land in the app you were already using.
@MainActor
final class Overlay {
    private final class Model: ObservableObject {
        enum Look {
            case listening
            case working
            case message
        }

        @Published var look = Look.listening
        @Published var message = ""
        @Published var level: Float = 0
    }

    private struct Pill: View {
        @ObservedObject var model: Model

        private var color: Color {
            switch model.look {
            case .listening: return Color(red: 1, green: 0.36, blue: 0.36)
            case .working: return Color(red: 1, green: 0.7, blue: 0.24)
            case .message: return Color.white.opacity(0.65)
            }
        }

        var body: some View {
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    ForEach(0..<5, id: \.self) { bar in
                        Capsule()
                            .fill(color)
                            .frame(width: 3.5, height: height(of: bar))
                    }
                }
                .frame(height: 26)

                Text(model.look == .listening ? "Hört zu …" : model.message)
                    .font(.system(size: 14.5))
                    .foregroundColor(model.look == .message ? .white : .white.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .frame(width: 440, height: 54)
            .background(Color(red: 0.12, green: 0.12, blue: 0.13))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .animation(.easeOut(duration: 0.12), value: model.level)
        }

        private func height(of bar: Int) -> CGFloat {
            let shape = 1 - abs(Double(bar) - 2) * 0.25
            switch model.look {
            case .listening:
                // A square root makes quiet speech visible without loud speech pinning the bars.
                return CGFloat(max(4, min(26, 26 * min(1, Double(model.level).squareRoot() * 3) * shape)))
            case .working:
                return 12
            case .message:
                return 4
            }
        }
    }

    private let model = Model()
    private let panel: NSPanel
    private var hide: Task<Void, Never>?

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 54), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: Pill(model: model))
    }

    func showListening() {
        present(.listening, "")
    }

    func showWorking(_ message: String) {
        present(.working, message)
    }

    func setLevel(_ level: Float) {
        model.level = level
    }

    func flash(_ message: String, isProblem: Bool) {
        present(.message, message)
        hide = Task { [weak self] in
            try? await Task.sleep(nanoseconds: isProblem ? 4_000_000_000 : 1_800_000_000)
            if !Task.isCancelled {
                self?.dismiss()
            }
        }
    }

    func dismiss() {
        hide?.cancel()
        panel.orderOut(nil)
    }

    private func present(_ look: Model.Look, _ message: String) {
        hide?.cancel()
        model.look = look
        model.message = message

        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - 220, y: frame.minY + 36))
        }

        panel.orderFrontRegardless()
    }
}
