import Testing
@testable import IruddVoiceKit

struct PreferencesTests {
    @Test func defaults() {
        let prefs = Preferences(store: MemoryStore())
        #expect(prefs.isOn)
        #expect(prefs.previewMode == .off)
        #expect(!prefs.hasCompletedSetup)
    }

    @Test func valuesPersistInTheStore() {
        let store = MemoryStore()
        let prefs = Preferences(store: store)
        prefs.isOn = false
        prefs.previewMode = .transcript
        prefs.hasCompletedSetup = true

        let reopened = Preferences(store: store)
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
