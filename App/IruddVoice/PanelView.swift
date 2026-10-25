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

            Section {
                if let last = model.lastThought {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(last.duration, format: .number.precision(.fractionLength(1))) s of audio, ended by \(last.endReason.description)")
                        Text("\(last.endedAt, style: .relative) ago · not saved yet (saving comes next)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Nothing dictated yet.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Last dictation").font(.subheadline.weight(.semibold))
            }

            Divider()

            HStack {
                Button("Settings…") {
                    NSApp.activate()
                    openSettings()
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 320)
    }

    private func open(_ id: String) {
        NSApp.activate()
        openWindow(id: id)
    }
}
