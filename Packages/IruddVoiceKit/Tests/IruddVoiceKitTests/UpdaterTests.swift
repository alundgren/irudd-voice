import Foundation
import Testing
@testable import IruddVoiceKit

/// Real git against a local "GitHub" repo in a temporary folder, with a
/// stand-in install.sh so nothing real is built, signed or installed.
struct UpdaterTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("irudd-voice-updater-\(UUID().uuidString)").path
    var remote: String { root + "/remote" }
    var work: String { root + "/work" }
    var state: String { root + "/state" }
    var caches: String { root + "/caches" }

    @discardableResult
    func sh(_ command: String, in directory: String? = nil) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]
        if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try! process.run()
        process.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmed
    }

    /// A repo with one commit, pushed to a bare "remote". Returns that commit.
    func makeRepo() -> String {
        try! FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        sh("git init --quiet --bare -b main remote && git init --quiet -b main work", in: root)
        let script = """
            #!/bin/bash
            # Stand-in install.sh: --stage DIR makes a fake app unless BROKEN exists.
            [[ -e BROKEN ]] && { echo "main.swift:1: error: it broke"; exit 1; }
            mkdir -p "$2/irudd-voice.app" && echo staged > "$2/irudd-voice.app/marker"
            echo "Staged $2/irudd-voice.app"
            """
        try! script.write(toFile: work + "/install.sh", atomically: true, encoding: .utf8)
        sh("git add . && git -c user.name=t -c user.email=t@t commit --quiet -m 'First' && git remote add origin ../remote && git push --quiet origin main", in: work)
        return sh("git rev-parse HEAD", in: work)
    }

    func commit(_ message: String, file: String = "change.txt") -> String {
        sh("echo '\(message)' >> \(file) && git add . && git -c user.name=t -c user.email=t@t commit --quiet -m '\(message)' && git push --quiet origin main", in: work)
        return sh("git rev-parse HEAD", in: work)
    }

    func install(commit: String) {
        try! FileManager.default.createDirectory(atPath: state, withIntermediateDirectories: true)
        let info = InstallInfo(commit: commit, branch: "main", remote: remote, dirty: false,
                               signingSHA1: String(repeating: "1", count: 40), appsDir: root + "/Applications")
        try! JSONEncoder().encode(info).write(to: URL(fileURLWithPath: state + "/install.json"))
    }

    func updater() -> Updater {
        Updater(stateDir: state, cachesDir: caches, runner: ProcessRunner())
    }

    @Test func upToDate() async {
        let first = makeRepo()
        install(commit: first)
        #expect(await updater().check() == .upToDate(commit: first))
    }

    @Test func findsNewerCommits() async {
        let first = makeRepo()
        install(commit: first)
        _ = commit("Fix the mic")
        let latest = commit("Add pasting")
        let state = await updater().check()
        #expect(state == .available(commit: latest, changes: 2, summaries: ["Add pasting", "Fix the mic"]))
    }

    @Test func aDevelopmentBuildIsNotUpdated() async {
        _ = makeRepo()
        install(commit: String(repeating: "a", count: 40)) // a commit main doesn't have
        _ = commit("Something on main")
        guard case .notOnBranch = await updater().check() else {
            Issue.record("expected notOnBranch")
            return
        }
    }

    @Test func aFailedBuildChangesNothing() async {
        let first = makeRepo()
        install(commit: first)
        _ = commit("Broken change", file: "BROKEN")
        let updater = updater()
        guard case .available = await updater.check() else {
            Issue.record("expected an update")
            return
        }
        guard case .failed(let message, let log) = await updater.build() else {
            Issue.record("expected the build to fail")
            return
        }
        #expect(message.contains("nothing changed"))
        #expect(message.contains("it broke"))
        #expect(log != nil)
        #expect(!FileManager.default.fileExists(atPath: root + "/Applications"))
        let staged = (try? FileManager.default.contentsOfDirectory(atPath: caches + "/staged")) ?? []
        #expect(staged.allSatisfy { !FileManager.default.fileExists(atPath: caches + "/staged/\($0)/irudd-voice.app") })
    }

    @Test func aGoodBuildIsStagedThenSwappedOnRestart() async {
        let first = makeRepo()
        install(commit: first)
        let latest = commit("Add pasting")
        let updater = updater()
        _ = await updater.check()
        guard case .ready(let commit, let stageDir) = await updater.build() else {
            Issue.record("expected a staged build")
            return
        }
        #expect(commit == latest)
        #expect(FileManager.default.fileExists(atPath: stageDir + "/irudd-voice.app/marker"))
        // The installed app isn't touched until the restart.
        #expect(!FileManager.default.fileExists(atPath: root + "/Applications"))
        let restart = updater.restartCommand(stageDir: stageDir, pid: 4242)
        #expect(restart.arguments.suffix(4) == ["--activate", stageDir, "--wait-pid", "4242"])
        #expect(restart.environment["IRUDD_VOICE_APPS_DIR"] == root + "/Applications")
    }

    @Test func checkoutStaysOutOfProtectedFolders() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].path
        let updater = Updater(stateDir: support + "/irudd-voice", cachesDir: "/tmp", runner: ProcessRunner())
        for folder in ["Documents", "Desktop", "Downloads"] {
            #expect(!updater.sourceDir.hasPrefix(NSHomeDirectory() + "/" + folder))
        }
    }

    @Test func githubSSHRemotesAreFetchedOverHTTPS() {
        #expect(Updater.fetchURL("git@github.com:alundgren/irudd-voice.git") == "https://github.com/alundgren/irudd-voice.git")
        #expect(Updater.fetchURL("https://github.com/alundgren/irudd-voice.git") == "https://github.com/alundgren/irudd-voice.git")
    }
}
