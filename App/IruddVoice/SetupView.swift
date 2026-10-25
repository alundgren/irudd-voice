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
                Text("Picking a mic arrives with mic capture.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
            }

            HStack {
                if !checklist.canFinish {
                    Text("Allow \(checklist.missingRequired.map(\.title).formatted(.list(type: .and))) to finish.")
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
                model.permissions.refresh()
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
