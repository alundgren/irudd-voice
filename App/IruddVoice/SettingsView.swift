import IruddVoiceKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Hotkeys", systemImage: "keyboard") {
                LaterPane(text: "No hotkey is set. A start/stop hotkey arrives with mic capture.")
            }
            Tab("Model", systemImage: "cpu") {
                LaterPane(text: "The cleanup model arrives in a later version. Until then you get Apple's raw text.")
            }
            Tab("Data", systemImage: "internaldrive") {
                LaterPane(text: "The database size and Delete all arrive with recording.")
            }
            Tab("Updates", systemImage: "arrow.down.circle") {
                LaterPane(text: "Update now arrives with self-update. For now, run install.sh again.")
            }
        }
        .frame(width: 460, height: 260)
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        Form {
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
