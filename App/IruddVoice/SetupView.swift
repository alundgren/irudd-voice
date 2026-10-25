import IruddVoiceKit
import SwiftUI

/// First-run setup: permissions, then the mic, then done.
struct SetupView: View {
    static let windowID = "setup"

    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        let checklist = model.permissions.checklist

        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Set up irudd-voice").font(.title2.weight(.semibold))
                Text("irudd-voice turns what you say into clean text and pastes it where your cursor is. Everything stays on this Mac.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            GroupBox("1. Permissions") {
                VStack(spacing: 10) {
                    ForEach(Permission.allCases, id: \.self) { permission in
                        PermissionRow(permission: permission, state: checklist.state(of: permission)) {
                            model.permissions.request(permission)
                        }
                    }
                }
                .padding(6)
            }

            GroupBox("2. Microphone") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Pick the mic to listen to. The app only ever uses this one. If it's unplugged, the app waits for it.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    MicPicker().labelsHidden()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }

            GroupBox("3. English speech") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Apple's speech recognition runs on this Mac. It needs its English files once.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    SpeechFilesRow()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }

            HStack {
                if !checklist.missingRequired.isEmpty {
                    Text("Allow \(checklist.missingRequired.map(\.title).formatted(.list(type: .and))) to finish.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if !checklist.micPicked {
                    Text("Pick a mic to finish.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if !checklist.speechReady {
                    Text("Download the speech files to finish.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") {
                    model.finishSetup()
                    dismissWindow(id: Self.windowID)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!checklist.canFinish)
            }
        }
        .padding(20)
        .frame(width: 480)
        .task {
            // Accessibility and clipboard are changed in System Settings, which
            // sends no notification, so the list re-reads them while it's open.
            while !Task.isCancelled {
                model.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

private struct PermissionRow: View {
    let permission: Permission
    let state: PermissionState
    let request: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(permission.title + (permission.isRequired ? "" : " (optional)"))
                Text(permission.reason).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            switch state {
            case .granted:
                Text("Allowed").foregroundStyle(.secondary)
            case .denied:
                Button("Open Settings", action: request)
            case .notAsked:
                Button("Allow…", action: request)
            }
        }
    }

    private var icon: String {
        switch state {
        case .granted: "checkmark.circle.fill"
        case .denied: "xmark.circle.fill"
        case .notAsked: "circle"
        }
    }

    private var color: Color {
        switch state {
        case .granted: .green
        case .denied: .red
        case .notAsked: .secondary
        }
    }
}
