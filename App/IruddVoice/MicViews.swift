import IruddVoiceKit
import SwiftUI

/// The mic list in the panel: one row per mic, a checkmark on the pinned one.
struct PanelMicList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if model.micChoices.isEmpty {
                Text("No microphones found.").foregroundStyle(.secondary)
            }
            ForEach(model.micChoices) { choice in
                Button {
                    model.pickMic(choice.uid)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark")
                            .opacity(choice.uid == model.pinnedUID ? 1 : 0)
                            .frame(width: 14)
                        Text(choice.name)
                            .foregroundStyle(choice.connected ? .primary : .secondary)
                        if !choice.connected {
                            Text("not connected").font(.caption).foregroundStyle(.orange)
                        }
                        Spacer()
                        if choice.uid == model.pinnedUID, model.micState.isListening {
                            LevelMeter(level: model.level)
                        }
                    }
                    .contentShape(Rectangle())
                    .padding(.vertical, 3)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(choice.uid == model.pinnedUID ? .isSelected : [])
            }
        }
    }
}

/// Mic picker for Settings and setup.
struct MicPicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.micChoices.isEmpty {
            Text("No microphones found. Plug one in.").foregroundStyle(.secondary)
        } else {
            Picker("Microphone", selection: Binding(
                get: { model.pinnedUID ?? "" },
                set: { model.pickMic($0) }
            )) {
                ForEach(model.micChoices) { choice in
                    Text(choice.connected ? choice.name : "\(choice.name) (not connected)").tag(choice.uid)
                }
            }
            .pickerStyle(.radioGroup)
        }
    }
}

/// A small bar that shows the mic is hearing something.
struct LevelMeter: View {
    let level: Float

    var body: some View {
        // Map roughly -60…0 dBFS onto the bar.
        let db = level > 0 ? 20 * log10(Double(level)) : -60
        let fraction = min(1, max(0, (db + 60) / 60))
        Capsule()
            .fill(.quaternary)
            .frame(width: 44, height: 5)
            .overlay(alignment: .leading) {
                Capsule().fill(.green).frame(width: 44 * fraction, height: 5)
            }
            .animation(.linear(duration: 0.1), value: fraction)
            .accessibilityHidden(true)
    }
}

/// Records a global hotkey: press Record, then the keys.
struct HotkeyRecorder: View {
    @Environment(AppModel.self) private var model
    @State private var recording = false
    @State private var monitor: Any?
    @State private var hint: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(recording ? "Press the keys…" : (model.hotkey?.display ?? "None"))
                    .font(.body.monospaced())
                    .frame(minWidth: 120, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                Button(recording ? "Cancel" : "Record…") {
                    recording ? stop() : start()
                }
                if model.hotkey != nil, !recording {
                    Button("Clear") { model.setHotkey(nil) }
                }
            }
            if let message = hint ?? model.hotkeyError {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        hint = "Use ⌘, ⌥ or ⌃ with a key, or an F-key alone. Esc cancels."
        recording = true
        model.pauseHotkey()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Esc
                stop()
                return nil
            }
            let modifiers = carbonModifiers(event.modifierFlags)
            let keyCode = UInt32(event.keyCode)
            guard Hotkey.isAllowed(keyCode: keyCode, carbonModifiers: modifiers) else {
                hint = "Add ⌘, ⌥ or ⌃, so normal typing never starts a thought."
                return nil
            }
            let key = Hotkey.keyName(keyCode: keyCode)
                ?? event.charactersIgnoringModifiers?.uppercased()
                ?? "Key \(keyCode)"
            stop()
            model.setHotkey(Hotkey(keyCode: keyCode, carbonModifiers: modifiers,
                                   display: Hotkey.modifierSymbols(modifiers) + key))
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording { model.resumeHotkey() }
        recording = false
        hint = nil
    }

    private func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= Hotkey.command }
        if flags.contains(.shift) { result |= Hotkey.shift }
        if flags.contains(.option) { result |= Hotkey.option }
        if flags.contains(.control) { result |= Hotkey.control }
        return result
    }
}
