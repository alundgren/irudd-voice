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
            Image(systemName: model.status.symbolName)
                .accessibilityLabel("irudd-voice: \(model.status.title)")
        }
        .menuBarExtraStyle(.window)

        Window("Set Up irudd-voice", id: SetupView.windowID) {
            SetupView()
                .environment(model)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(model.hasCompletedSetup ? .suppressed : .presented)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
