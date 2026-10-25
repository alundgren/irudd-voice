import IruddVoiceKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Hotkeys", systemImage: "keyboard") { HotkeySettings() }
            Tab("Model", systemImage: "cpu") { ModelSettings() }
            Tab("Data", systemImage: "internaldrive") { DataSettings() }
            Tab("Updates", systemImage: "arrow.down.circle") { UpdateSettings() }
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

/// The cleanup model: which one is active, what it was trained on, how its
/// last eval went, and what the helper is doing.
private struct ModelSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                if let overview = model.modelOverview {
                    LabeledContent("Active model") {
                        Text(overview.activeID).font(.body.monospaced()).textSelection(.enabled)
                    }
                    LabeledContent("Kind") {
                        if let training = overview.training {
                            Text("Trained\(Self.trainedDetail(training))")
                        } else {
                            Text(overview.isDefault ? "Base model (the default)" : "Base model")
                        }
                    }
                    if let previous = overview.previousID {
                        LabeledContent("Previous") {
                            Text(previous).font(.body.monospaced()).textSelection(.enabled)
                        }
                    }
                }
                LabeledContent("Status") { CleanupStatusLine() }
            } footer: {
                Text("Each thought is cleaned on this Mac before it's pasted. If cleanup fails, times out or changes the meaning, your text is pasted as it was heard.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let eval = model.modelOverview?.eval {
                Section("Last eval") {
                    LabeledContent("Against") {
                        Text(eval.incumbentID ?? "the previous model").font(.body.monospaced())
                    }
                    LabeledContent("Votes won") {
                        if let percent = eval.winPercent {
                            Text("\(eval.wins) of \(eval.decided) (\(percent.formatted(.number.precision(.fractionLength(0))))%)")
                        } else {
                            Text("No decided votes").foregroundStyle(.secondary)
                        }
                    }
                    if let failed = eval.thoughtsFailed, let before = eval.incumbentThoughtsFailed {
                        LabeledContent("Failed a hard check") {
                            Text("\(failed) of \(eval.thoughts) test thoughts (previous: \(before))")
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task {
            // Follows promote, rollback and the training lease while open.
            while !Task.isCancelled {
                await model.refreshModelInfo()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private static func trainedDetail(_ training: ModelManifest.Training) -> String {
        var parts: [String] = []
        if let at = training.trainedAt.flatMap(CleanupCoordinator.parseTime) {
            parts.append(at.formatted(date: .abbreviated, time: .shortened))
        }
        if let chunks = training.chunks { parts.append("on \(chunks) thoughts") }
        return parts.isEmpty ? "" : " " + parts.joined(separator: ", ")
    }
}

/// What the cleanup helper is doing, in plain words.
private struct CleanupStatusLine: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let snapshot = model.cleanupSnapshot {
            VStack(alignment: .trailing, spacing: 2) {
                switch snapshot.state {
                case .loaded(let id):
                    Label("Loaded \(id)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .loading(let id):
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Loading \(id)…")
                    }
                case .unloaded:
                    Text("Not loaded").foregroundStyle(.secondary)
                case .unloadedForTraining:
                    Text("Unloaded while training runs. Text is pasted as heard until it's done.")
                        .foregroundStyle(.secondary)
                case .failed(let reason):
                    Text("Failed: \(reason)").foregroundStyle(.red).textSelection(.enabled)
                }
                if let problem = snapshot.activeProblem, let loaded = snapshot.loadedModel {
                    Text("Using the default (\(loaded)); \(problem.id) couldn't be loaded: \(problem.reason)")
                        .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                }
                if let bytes = snapshot.helperBytes, bytes > 0 {
                    Text("Helper memory: \(Int64(bytes).formatted(.byteCount(style: .memory)))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .multilineTextAlignment(.trailing)
        } else if let problem = model.cleanupProblem {
            Text(problem).foregroundStyle(.red)
        } else {
            Text("Starting…").foregroundStyle(.secondary)
        }
    }
}

private struct HotkeySettings: View {
    var body: some View {
        Form {
            ForEach(HotkeyAction.allCases, id: \.self) { action in
                Section {
                    LabeledContent(action.title) {
                        HotkeyRecorder(action: action)
                    }
                } footer: {
                    Text(action.help).font(.caption).foregroundStyle(.secondary)
                }
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

private struct UpdateSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                if let info = model.installInfo {
                    LabeledContent("Installed") {
                        Text("\(info.shortCommit) on \(info.branch)\(info.dirty ? " (with local changes)" : "")")
                            .font(.body.monospaced())
                    }
                } else {
                    Text("This app wasn't installed with install.sh, so it can't update itself.")
                        .foregroundStyle(.secondary)
                }
                UpdateStatus()
            } footer: {
                Text("Updates are built on this Mac from the source on GitHub, signed with your certificate, and swapped in whole when you restart. If a build fails, the installed app stays as it is.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Update status and the button for the next step. Used in Settings and the panel.
struct UpdateStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.updateState {
        case .unknown, .upToDate, .notOnBranch, .failed:
            VStack(alignment: .leading, spacing: 6) {
                switch model.updateState {
                case .upToDate:
                    Label("Up to date", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .notOnBranch(let reason):
                    Text(reason).font(.callout).foregroundStyle(.secondary)
                case .failed(let message, let log):
                    Text(message).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    if let log {
                        Button("Show Build Log") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: log)])
                        }
                    }
                default:
                    EmptyView()
                }
                Button("Check for Updates") { Task { await model.checkForUpdates() } }
                    .disabled(model.installInfo == nil)
            }
        case .checking:
            HStack {
                ProgressView().controlSize(.small)
                Text("Checking…").foregroundStyle(.secondary)
            }
        case .available(_, let changes, let summaries):
            VStack(alignment: .leading, spacing: 6) {
                Text("\(changes) new change\(changes == 1 ? "" : "s")").font(.headline)
                ForEach(summaries, id: \.self) { Text("• \($0)").font(.callout).lineLimit(1) }
                Button("Update Now") { model.updateNow() }
                    .buttonStyle(.borderedProminent)
            }
        case .building(let commit):
            HStack {
                ProgressView().controlSize(.small)
                Text("Building \(commit.prefix(7))… This takes a few minutes. You can keep dictating.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        case .ready:
            VStack(alignment: .leading, spacing: 6) {
                Text("The update is built and ready.").font(.headline)
                Button("Restart to Update") { model.restartToUpdate() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}
