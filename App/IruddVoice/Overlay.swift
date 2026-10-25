import AppKit
import IruddVoiceKit
import SwiftUI

/// The small floating preview near the bottom of the screen: a dot while
/// hearing you, or the live transcript. It never takes focus or clicks.
@MainActor
final class OverlayController {
    private let panel: NSPanel
    private weak var model: AppModel?

    init(model: AppModel) {
        self.model = model
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 120),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: OverlayView().environment(model))
    }

    func update() {
        guard let model else { return }
        let visible: Bool = switch model.previewMode {
        case .off: false
        case .dot: model.activity == .hearing
        case .transcript: model.activity == .hearing || model.justFinishedText != nil
        }
        if visible {
            position()
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }

    private func position() {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 28))
    }
}

private struct OverlayView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            switch model.previewMode {
            case .off:
                EmptyView()
            case .dot:
                HearingDot()
                    .padding(10)
                    .background(.regularMaterial, in: Capsule())
            case .transcript:
                TranscriptBubble(text: model.activity == .hearing ? model.liveText : (model.justFinishedText ?? ""),
                                 hearing: model.activity == .hearing)
            }
        }
        .frame(width: 560, height: 120)
    }
}

private struct HearingDot: View {
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(.red)
            .frame(width: 12, height: 12)
            .scaleEffect(pulse ? 1 : 0.7)
            .opacity(pulse ? 1 : 0.6)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
            .onAppear { pulse = true }
            .accessibilityLabel("Hearing you")
    }
}

private struct TranscriptBubble: View {
    let text: String
    let hearing: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if hearing {
                HearingDot().padding(.top, 4)
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            Text(text.isEmpty ? "Listening…" : text)
                .foregroundStyle(text.isEmpty ? .secondary : .primary)
                .lineLimit(4)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 540)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
