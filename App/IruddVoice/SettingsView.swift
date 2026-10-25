import IruddVoiceKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Hotkeys", systemImage: "keyboard") { HotkeySettings() }
            Tab("Model", systemImage: "cpu") {
                LaterPane(text: "The cleanup model arrives in a later version. Until then you get Apple's raw text.")
            }
            Tab("Data", systemImage: "internaldrive") { DataSettings() }
            Tab("Updates", systemImage: "arrow.down.circle") {
                LaterPane(text: "Update now arrives with self-update. For now, run install.sh again.")
            }
        }
        .frame(width: 480, height: 380)
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        Form {
            Section("Microphone") {
                MicPicker().labelsHidden()
            }
            Toggle("Listening", isOn: $model.isOn)
            Toggle("Start at login", isOn: Binding(
                get: { model.startAtLogin == .enabled || model.startAtLogin == .requiresApproval },
                set: { model.setStartAtLogin($0) }
            ))
            if model.startAtLogin == .requiresApproval {
                Text("Turn irudd-voice on in System Settings → General → Login Items.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = model.loginItemError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            Picker("Preview while talking", selection: $model.previewMode) {
                ForEach(PreviewMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refreshLoginItem() }
    }
}

private struct LaterPane: View {
    let text: String

    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct HotkeySettings: View {
    var body: some View {
        Form {
            Section {
                LabeledContent("Start/stop thought") {
                    HotkeyRecorder()
                }
            } footer: {
                Text("Starts a thought, or ends the one in progress. Useful for mics without a mute button, like AirPods. A thought started with the hotkey also ends after 5 seconds of silence.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct DataSettings: View {
    @Environment(AppModel.self) private var model
    @State private var confirmingDelete = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Database") {
                    Text(model.databaseSize.formatted(.byteCount(style: .file)))
                }
                LabeledContent("Added in the last 7 days") {
                    GrowthBars(days: model.dailyBytes)
                }
                LabeledContent("Location") {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: model.databasePath)])
                    }
                }
            } footer: {
                Text("Every thought's audio and text is kept in this one file. Nothing is deleted automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Delete All Recordings…", role: .destructive) { confirmingDelete = true }
            }
        }
        .formStyle(.grouped)
        .task { await model.refreshDatabaseInfo() }
        .confirmationDialog("Delete every recording?", isPresented: $confirmingDelete) {
            Button("Delete All Recordings", role: .destructive) {
                Task { await model.deleteAllRecordings() }
            }
        } message: {
            Text("This deletes all audio, transcripts and labels. Trained models are kept. It can't be undone.")
        }
    }
}

/// Seven small bars, one per day, oldest on the left.
private struct GrowthBars: View {
    let days: [(day: String, bytes: Int64)]

    var body: some View {
        let peak = max(days.map(\.bytes).max() ?? 0, 1)
        let total = days.reduce(0) { $0 + $1.bytes }
        HStack(alignment: .bottom, spacing: 8) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(days, id: \.day) { day in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(day.bytes > 0 ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: max(2, 22 * CGFloat(day.bytes) / CGFloat(peak)))
                        .help("\(day.day): \(day.bytes.formatted(.byteCount(style: .file)))")
                }
            }
            .frame(height: 22, alignment: .bottom)
            Text(total.formatted(.byteCount(style: .file)))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(total.formatted(.byteCount(style: .file))) added in the last 7 days")
    }
}
