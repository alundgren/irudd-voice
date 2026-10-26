import IruddVoiceKit
import SwiftUI

/// The window that opens from the menu-bar icon.
struct PanelView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        @Bindable var model = model

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: model.status.symbolName)
                    .font(.title2)
                    .foregroundStyle(model.status == .off ? .secondary : Color.accentColor)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.status.title).font(.headline)
                    Text(model.status.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if model.hasCompletedSetup {
                    Toggle("On", isOn: $model.isOn)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .accessibilityLabel("Listening")
                }
            }

            if !model.hasCompletedSetup {
                Button {
                    open(SetupView.windowID)
                } label: {
                    Text("Set Up irudd-voice…").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            Divider()

            Section {
                PanelMicList()
                if case .failed(let message) = model.micState {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("Microphone").font(.subheadline.weight(.semibold))
            }

            Section {
                Picker("Preview", selection: $model.previewMode) {
                    ForEach(PreviewMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            } header: {
                Text("Preview while talking").font(.subheadline.weight(.semibold))
            }

            // Newest first; each one stays until it's pasted, copied or thrown away.
            ForEach(model.waitingTexts.reversed(), id: \.id) { waiting in
                WaitingTextRow(waiting: waiting)
            }

            if model.hasCompletedSetup, model.speechFiles != .installed {
                SpeechFilesRow()
            }

            Section {
                if let last = model.lastChunk {
                    LastDictation(chunk: last)
                } else {
                    Text("Nothing dictated yet.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Last dictation").font(.subheadline.weight(.semibold))
            }

            switch model.updateState {
            case .available, .building, .ready:
                UpdateStatus()
                    .padding(10)
                    .background(.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            default:
                EmptyView()
            }

            if let error = model.databaseError {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            Divider()

            HStack {
                Text("Database \(model.databaseSize.formatted(.byteCount(style: .file)))")
                    .font(.caption).foregroundStyle(.secondary)
                    .help(model.databasePath)
                Spacer()
                Button("Settings…") {
                    leavePanel {
                        openSettings()
                        bringForward { $0.identifier?.rawValue == settingsWindowID }
                    }
                }
                Button("Quit") { NSApp.terminate(nil) }
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 320)
        .task { await model.refreshDatabaseInfo() }
    }

    private func open(_ id: String) {
        leavePanel {
            openWindow(id: id)
            bringForward { $0.identifier?.rawValue.hasPrefix(id) == true }
        }
    }

    /// This panel floats above normal windows, so a window opened from it
    /// lands underneath while the panel stays open. Raising that window can't
    /// fix it; close the panel instead. The panel is the window that got the
    /// click, so grab it before the new window can become key.
    private func leavePanel(after open: () -> Void) {
        let panel = NSApp.currentEvent?.window ?? NSApp.keyWindow
        open()
        panel?.close()
    }
}

private struct LastDictation: View {
    let chunk: ChunkSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            switch chunk.status {
            case "transcribed":
                Text(chunk.rawText?.isEmpty == false ? chunk.rawText! : "(nothing recognised)")
                    .lineLimit(3)
                    .textSelection(.enabled)
            case "pending":
                Text("Recognising…").foregroundStyle(.secondary)
            case "discarded":
                Text("Thrown away, not pasted.").foregroundStyle(.secondary)
            default:
                Text(chunk.error ?? "Something went wrong.").foregroundStyle(.red).lineLimit(3)
            }
            Text("\(Double(chunk.durationMs) / 1000, format: .number.precision(.fractionLength(1))) s · \(chunk.endedAt, style: .relative) ago · audio saved")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Shown when Apple's speech files are missing after setup.
struct SpeechFilesRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            switch model.speechFiles {
            case .checking:
                ProgressView().controlSize(.small)
                Text("Checking speech files…").foregroundStyle(.secondary)
            case .downloading(let fraction):
                ProgressView(value: fraction).frame(maxWidth: .infinity)
                Text(fraction, format: .percent.precision(.fractionLength(0)))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            case .installed:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("English speech files installed")
            case .missing:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Apple's English speech files are needed to turn speech into text.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Download") { model.installSpeechFiles() }
            case .failed(let message):
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Try Again") { model.installSpeechFiles() }
            }
        }
    }
}

/// Text that wasn't pasted, with what to do about it.
private struct WaitingTextRow: View {
    let waiting: WaitingText
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Text waiting", systemImage: "text.badge.plus").font(.subheadline.weight(.semibold))
            Text(waiting.text).lineLimit(3).textSelection(.enabled)
            Text(waiting.reason.description).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Paste Here") {
                    dismiss()
                    model.pasteHere(waiting)
                }
                .help("Closes this panel and pastes where your cursor is")
                Button("Copy") { model.copyWaiting(waiting) }
                Spacer()
                Button("Throw Away", role: .destructive) { model.throwAwayWaiting(waiting) }
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}
