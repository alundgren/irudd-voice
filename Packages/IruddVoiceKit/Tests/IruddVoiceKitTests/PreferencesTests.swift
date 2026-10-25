import Testing
@testable import IruddVoiceKit

struct PreferencesTests {
    @Test func defaults() {
        let prefs = Preferences(store: MemoryStore())
        #expect(prefs.isOn)
        #expect(prefs.previewMode == .off)
        #expect(!prefs.hasCompletedSetup)
        #expect(prefs.pinnedMicUID == nil)
        #expect(prefs.hotkey == nil)
    }

    @Test func valuesPersistInTheStore() {
        let store = MemoryStore()
        let prefs = Preferences(store: store)
        prefs.isOn = false
        prefs.previewMode = .transcript
        prefs.hasCompletedSetup = true
        prefs.pinnedMicUID = "AppleUSBAudioEngine:JIAYZ:BY-GM18CU:serial:1"
        prefs.hotkey = Hotkey(keyCode: 2, carbonModifiers: Hotkey.control | Hotkey.option, display: "⌃⌥D")

        let reopened = Preferences(store: store)
        #expect(reopened.pinnedMicUID == "AppleUSBAudioEngine:JIAYZ:BY-GM18CU:serial:1")
        #expect(reopened.hotkey == Hotkey(keyCode: 2, carbonModifiers: Hotkey.control | Hotkey.option, display: "⌃⌥D"))
        #expect(!reopened.isOn)
        #expect(reopened.previewMode == .transcript)
        #expect(reopened.hasCompletedSetup)
    }

    @Test func unknownPreviewModeFallsBackToOff() {
        let store = MemoryStore()
        store.set("hologram", forKey: Preferences.Key.previewMode)
        #expect(Preferences(store: store).previewMode == .off)
    }
}
