import Foundation

/// What install.sh records about the installed build
/// (`~/Library/Application Support/irudd-voice/install.json`).
public struct InstallInfo: Codable, Equatable, Sendable {
    public var commit: String
    public var branch: String
    public var remote: String
    public var dirty: Bool
    public var signingSHA1: String
    public var appsDir: String?
    public var installedAt: String?

    public var shortCommit: String { String(commit.prefix(7)) }
}

/// Runs a command and returns its exit status and combined output. Faked in tests.
public protocol CommandRunner: Sendable {
    func run(_ executable: String, _ arguments: [String], in directory: String?,
             environment: [String: String], logTo log: String?) async -> (status: Int32, output: String)
}

public enum UpdateState: Equatable, Sendable {
    case unknown
    case checking
    case upToDate(commit: String)
    /// The installed build isn't on the update branch (e.g. a development build).
    case notOnBranch(String)
    case available(commit: String, changes: Int, summaries: [String])
    case building(commit: String)
    case ready(commit: String, stageDir: String)
    case failed(String, log: String?)
}

/// Update now: fetch the branch into the app's own checkout, build it into a
/// staging folder with install.sh, then swap the whole app in on restart.
/// The installed app is never touched until the restart.
public actor Updater {
    public let stateDir: String
    public let cachesDir: String
    private let runner: CommandRunner
    private var target: String?
    /// The branch `target` came from: the installed branch, or main if that branch is gone.
    private var targetBranch: String?

    /// The app's own git checkout. In Application Support, so it's never
    /// in Documents, Desktop or Downloads (macOS asks before apps read those).
    public nonisolated var sourceDir: String { (stateDir as NSString).appendingPathComponent("source") }
    public nonisolated var logPath: String { (cachesDir as NSString).appendingPathComponent("update.log") }

    public init(stateDir: String, cachesDir: String, runner: CommandRunner) {
        self.stateDir = stateDir
        self.cachesDir = cachesDir
        self.runner = runner
    }

    public nonisolated func installInfo() -> InstallInfo? {
        let path = (stateDir as NSString).appendingPathComponent("install.json")
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(InstallInfo.self, from: data)
    }

    public func check() async -> UpdateState {
        guard let info = installInfo() else {
            return .failed("This install has no install.json. Run ./install.sh once from a clone.", log: nil)
        }
        guard !info.remote.isEmpty else {
            return .notOnBranch("This build wasn't made from a clone with a GitHub remote, so there's nowhere to update from.")
        }
        let url = Self.fetchURL(info.remote)

        if FileManager.default.fileExists(atPath: (sourceDir as NSString).appendingPathComponent(".git")) {
            _ = await git(["remote", "set-url", "origin", url])
        } else {
            try? FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
            let clone = await runner.run("/usr/bin/git", ["clone", "--quiet", "--no-checkout", url, sourceDir],
                                         in: stateDir, environment: Self.environment, logTo: nil)
            guard clone.status == 0 else { return .failed("Couldn't download the source: \(clone.output)", log: nil) }
        }

        var branch = info.branch
        var fetch = await git(["fetch", "--quiet", "origin", branch])
        // A branch merged on GitHub is usually deleted, and its commits are
        // on main by then, so follow main. `ls-remote` exits 2 only when the
        // branch is really gone, not when the network is down.
        if fetch.status != 0, branch != "main",
           await git(["ls-remote", "--exit-code", "--heads", "origin", branch]).status == 2 {
            branch = "main"
            fetch = await git(["fetch", "--quiet", "origin", branch])
        }
        guard fetch.status == 0 else { return .failed("Couldn't check for updates: \(fetch.output)", log: nil) }
        let remoteCommit = await git(["rev-parse", "FETCH_HEAD"]).output.trimmed
        guard remoteCommit.count == 40 else { return .failed("Couldn't read the latest \(branch).", log: nil) }

        if remoteCommit == info.commit {
            target = nil
            return .upToDate(commit: info.commit)
        }
        let known = await git(["cat-file", "-e", "\(info.commit)^{commit}"]).status == 0
        let behind = known ? await git(["merge-base", "--is-ancestor", info.commit, remoteCommit]).status == 0 : false
        guard behind else {
            target = nil
            if branch != info.branch {
                return .notOnBranch("\(info.branch) is gone from GitHub and this build (\(info.shortCommit)) isn't on main, so updates are off. Run ./install.sh once from main.")
            }
            return .notOnBranch("This build (\(info.shortCommit)) isn't on \(info.branch) yet, so updates are off until \(info.branch) has it.")
        }
        let count = Int(await git(["rev-list", "--count", "\(info.commit)..\(remoteCommit)"]).output.trimmed) ?? 0
        let summaries = await git(["log", "--format=%s", "-5", "\(info.commit)..\(remoteCommit)"]).output
            .split(separator: "\n").map(String.init)
        target = remoteCommit
        targetBranch = branch
        return .available(commit: remoteCommit, changes: count, summaries: summaries)
    }

    /// Builds the commit found by `check()` into a staging folder. A failed
    /// build leaves the installed app as it is.
    public func build() async -> UpdateState {
        guard let commit = target, let info = installInfo() else {
            return .failed("Check for updates first.", log: nil)
        }
        let checkout = await git(["checkout", "--quiet", "--force", "--detach", commit])
        guard checkout.status == 0 else { return .failed("Couldn't check out \(commit.prefix(7)): \(checkout.output)", log: nil) }

        let stageDir = (cachesDir as NSString).appendingPathComponent("staged/\(commit)")
        try? FileManager.default.createDirectory(atPath: cachesDir, withIntermediateDirectories: true)
        var environment = Self.environment
        environment["IRUDD_VOICE_SIGNING_IDENTITY"] = info.signingSHA1
        environment["IRUDD_VOICE_BRANCH"] = targetBranch ?? info.branch
        if let apps = info.appsDir { environment["IRUDD_VOICE_APPS_DIR"] = apps }
        let result = await runner.run("/bin/bash", [installScript, "--stage", stageDir], in: sourceDir,
                                      environment: environment, logTo: logPath)
        guard result.status == 0 else {
            let reason = result.output.split(separator: "\n").suffix(6).joined(separator: "\n")
            return .failed("The update didn't build, so nothing changed.\n\(reason)", log: logPath)
        }
        return .ready(commit: commit, stageDir: stageDir)
    }

    /// The command that swaps the staged build in once the app (`pid`) has
    /// quit, then reopens it. Run it detached, then quit.
    public nonisolated func restartCommand(stageDir: String, pid: Int32) -> (executable: String, arguments: [String], environment: [String: String]) {
        var environment = Self.environment
        if let apps = installInfo()?.appsDir { environment["IRUDD_VOICE_APPS_DIR"] = apps }
        return ("/bin/bash", [installScript, "--activate", stageDir, "--wait-pid", String(pid)], environment)
    }

    private nonisolated var installScript: String { (sourceDir as NSString).appendingPathComponent("install.sh") }

    private func git(_ arguments: [String]) async -> (status: Int32, output: String) {
        await runner.run("/usr/bin/git", ["-C", sourceDir] + arguments, in: nil, environment: Self.environment, logTo: nil)
    }

    /// GitHub over HTTPS for reading, so updates don't need SSH keys.
    static func fetchURL(_ remote: String) -> String {
        if remote.hasPrefix("git@github.com:") {
            return "https://github.com/" + remote.dropFirst("git@github.com:".count)
        }
        if remote.hasPrefix("ssh://git@github.com/") {
            return "https://github.com/" + remote.dropFirst("ssh://git@github.com/".count)
        }
        return remote
    }

    /// Apps started from Finder get a bare PATH; give tools the usual one.
    static let environment: [String: String] = [
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "HOME": NSHomeDirectory(),
        "GIT_TERMINAL_PROMPT": "0",
    ]
}

/// Runs commands with Foundation's Process.
public struct ProcessRunner: CommandRunner {
    public init() {}

    public func run(_ executable: String, _ arguments: [String], in directory: String?,
                    environment: [String: String], logTo log: String?) async -> (status: Int32, output: String) {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.environment = environment
            if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
            let output = FileManager.default.temporaryDirectory.appendingPathComponent("irudd-voice-\(UUID().uuidString).log")
            FileManager.default.createFile(atPath: output.path, contents: nil)
            let handle = try? FileHandle(forWritingTo: output)
            process.standardOutput = handle
            process.standardError = handle
            process.terminationHandler = { finished in
                try? handle?.close()
                let text = (try? String(contentsOf: output, encoding: .utf8)) ?? ""
                if let log { try? text.write(toFile: log, atomically: true, encoding: .utf8) }
                try? FileManager.default.removeItem(at: output)
                continuation.resume(returning: (finished.terminationStatus, text))
            }
            do {
                try process.run()
            } catch {
                try? handle?.close()
                continuation.resume(returning: (-1, "\(error)"))
            }
        }
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
