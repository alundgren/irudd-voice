import AppKit

/// The SwiftUI Settings window's identifier.
let settingsWindowID = "com_apple_SwiftUI_Settings_window"

/// A menu-bar app isn't the frontmost app, and macOS may refuse
/// `NSApp.activate()`, so a window it opens can land behind other apps'
/// windows. Once SwiftUI has made the window, raise it anyway. Tries for
/// about half a second, since the window appears a moment after it's opened.
@MainActor
func bringForward(where matches: @escaping @MainActor (NSWindow) -> Bool) {
    NSApp.activate()
    Task { @MainActor in
        for _ in 0..<10 {
            if let window = NSApp.windows.first(where: { $0.isVisible && matches($0) }) {
                NSApp.activate()
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
                return
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}
