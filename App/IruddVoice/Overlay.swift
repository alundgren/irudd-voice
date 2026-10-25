import AppKit
import IruddVoiceKit
import SwiftUI

/// The small floating preview near the bottom of the screen: a dot while
/// hearing you, or the live transcript and then what was heard next to what
/// was pasted. It never takes focus or clicks.
@MainActor
final class OverlayController {
    private let panel: NSPanel
    private weak var model: AppModel?

    init(model: AppModel) {
        self.model = model
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 200),
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
        case .transcript: model.activity == .hearing || model.finished != nil
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
                if model.activity == .hearing {
                    TranscriptBubble(text: model.liveText, state: .hearing)
                } else if let result = model.finished?.result {
                    ThoughtOutcome(result: result)
                } else {
                    TranscriptBubble(text: model.finished?.heard ?? "", state: .cleaning)
                }
            }
        }
        .frame(width: 560, height: 200)
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
    enum State { case hearing, cleaning }

    let text: String
    let state: State

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            switch state {
            case .hearing:
                HearingDot().padding(.top, 4)
            case .cleaning:
                Image(systemName: "sparkles").foregroundStyle(.secondary)
                    .accessibilityLabel("Cleaning up")
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

/// After a paste: what was heard, with the words cleanup removed struck
/// out, above what was pasted. When the heard text itself was used, it's
/// shown once with the reason in plain words.
private struct ThoughtOutcome: View {
    let result: FinishedThought.Result

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let reason = result.rawReason {
                Text("\(result.waiting ? "Waiting" : "Pasted") as heard: \(reason)")
                    .font(.caption).foregroundStyle(.secondary)
                Text(result.text).lineLimit(4).truncationMode(.head)
            } else {
                row("Heard", Self.text(result.heardWords) {
                    $0.strikethroughStyle = .single
                    $0.foregroundColor = .secondary
                })
                row(result.waiting ? "Waiting" : "Pasted", Self.text(result.textWords) {
                    $0.foregroundColor = .accentColor
                })
            }
            if result.waiting {
                Text("Not pasted: the text box changed. It's waiting in the menu.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 540, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func row(_ label: String, _ text: AttributedString) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 50, alignment: .leading)
            Text(text)
                .lineLimit(3)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The words joined by spaces, with `changed` applied to the ones that
    /// aren't on both sides.
    private static func text(_ words: [WordDiff.Word], changed: (inout AttributedString) -> Void) -> AttributedString {
        var out = AttributedString()
        for (index, word) in words.enumerated() {
            if index > 0 { out += AttributedString(" ") }
            var part = AttributedString(word.text)
            if !word.kept { changed(&part) }
            out += part
        }
        return out
    }
}
