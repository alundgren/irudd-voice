import IruddVoiceKit
import SwiftUI

@main
struct IruddVoiceApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            PanelView()
                .environment(model)
        } label: {
            MenuBarIcon()
                .environment(model)
        }
        .menuBarExtraStyle(.window)

        Window("Set Up irudd-voice", id: SetupView.windowID) {
            SetupView()
                .environment(model)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

/// The menu-bar icon. It's the only view that exists from launch, so it also
/// opens setup in front of other apps until setup is finished.
private struct MenuBarIcon: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: model.status.symbolName)
            .accessibilityLabel("irudd-voice: \(model.status.title)")
            .task {
                guard !model.hasCompletedSetup else { return }
                NSApp.activate()
                openWindow(id: SetupView.windowID)
            }
    }
}
