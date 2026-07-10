import Foundation

/// Launches and owns the Python browser subagent sidecar process.
///
/// The sidecar is a child `Process` running `run.sh --socket <path>`. The Swift
/// app is the sole owner: it starts the process on first use, waits for the unix
/// socket file to appear, and terminates the process on quit. The sidecar path
/// and socket path are read from Info.plist (with sensible defaults) so the demo
/// machine and CI can point at different checkouts without code changes.
final class BrowserSubagentProcessSupervisor {

    enum SupervisorError: Error, LocalizedError {
        case sidecarPathMissing
        case runScriptMissing(String)
        case socketNeverAppeared
        case launchFailed(String)

        var errorDescription: String? {
            switch self {
            case .sidecarPathMissing:
                return "The browser subagent directory could not be found."
            case let .runScriptMissing(path):
                return "run.sh was not found at \(path)."
            case .socketNeverAppeared:
                return "The browser subagent started but never bound its socket."
            case let .launchFailed(reason):
                return "The browser subagent failed to launch: \(reason)"
            }
        }
    }

    /// Info.plist key holding the absolute path to the `browser-subagent/` directory.
    private static let sidecarPathInfoKey = "BrowserSubagentPath"
    /// Info.plist key holding the unix socket path the sidecar should bind.
    private static let socketPathInfoKey = "BrowserSubagentSocketPath"

    // The IPC socket lives under <repo>/support/ipc — Perch keeps all on-disk
    // state in the repo, never in ~/Library/Application Support. The repo path is
    // short enough that the socket path stays well under the macOS sun_path limit.
    private static let defaultSocketPath = PerchSupportPaths.directory("ipc")
        .appendingPathComponent("subagent.sock").path

    private static let socketAppearanceTimeoutSeconds = 8.0
    private static let socketPollIntervalSeconds = 0.1

    /// File the sidecar's stdout + stderr are redirected to. Without this the
    /// child process' output is discarded, so a launch failure (e.g. macOS
    /// denying exec of `run.sh` under a protected folder, or a Python traceback)
    /// is invisible to the app — it only ever observes `socketNeverAppeared`.
    /// Capturing here makes those failures diagnosable after the fact.
    private static let sidecarLogPath = PerchSupportPaths.file("sidecar.log").path

    /// The Worker gateway base URL (same one the app's ClaudeAPI uses). The
    /// sidecar's LLM calls are routed through `<base>/agent` so the real provider
    /// key never ships in the sidecar binary.
    private static let workerBaseURL = AppBundleConfiguration.stringValue(forKey: "WorkerBaseURL")
        ?? "https://your-worker-name.your-subdomain.workers.dev"

    /// Whether this build opted into the DEV-ONLY on-computer browser lane, via the
    /// Info.plist `PerchLocalBrowserEnabled` flag. Dev builds set it; the signed release
    /// strips it, so it is false (the safe default) for beta users — the sidecar then
    /// never registers the browser tool and no local Chrome is launched.
    private static var isLocalBrowserEnabled: Bool {
        guard let raw = AppBundleConfiguration.stringValue(forKey: "PerchLocalBrowserEnabled") else {
            return false
        }
        return ["1", "true", "yes", "on"].contains(raw.lowercased())
    }

    /// Whether this build reaches Composio DIRECTLY instead of through the Worker
    /// proxy, via the Info.plist `PerchComposioDirect` flag. DEV-ONLY: dev builds
    /// (`build-perch-dev.sh`) set it so the app injects NO Composio env and the
    /// sidecar uses its own isolated dev key from `browser-subagent/.env` — dev's
    /// Composio project never touches beta's. The signed release never sets it
    /// (and `verify-release-config.sh` asserts its absence), so beta keeps routing
    /// every Composio call through the Worker (real project key stays server-side,
    /// tenants stay siloed).
    private static var isComposioDirect: Bool {
        AppBundleConfiguration.isFlagEnabled(forKey: "PerchComposioDirect")
    }

    private var sidecarProcess: Process?

    /// The unix socket path the sidecar binds (read once from Info.plist).
    let socketPath: String

    init() {
        let configuredSocketPath = AppBundleConfiguration.stringValue(forKey: Self.socketPathInfoKey)
            .map { NSString(string: $0).expandingTildeInPath }
        // Honor an explicit Info.plist override ONLY when it does not point into
        // ~/Library/Application Support — Perch keeps all state in <repo>/support,
        // so a stale Application-Support socket path falls through to the default.
        if let configuredSocketPath,
           !configuredSocketPath.contains("Library/Application Support") {
            self.socketPath = configuredSocketPath
        } else {
            self.socketPath = Self.defaultSocketPath
        }
    }

    /// Whether the sidecar process is currently running.
    var isRunning: Bool {
        sidecarProcess?.isRunning ?? false
    }

    /// Ensures the sidecar is running and its socket exists, then returns the
    /// socket path. Idempotent — calling again while running is a no-op.
    @discardableResult
    func ensureRunning() async throws -> String {
        if isRunning, FileManager.default.fileExists(atPath: socketPath) {
            return socketPath
        }

        // Resolve the sidecar directory from an ordered list of candidates, using
        // the first that actually contains run.sh. This makes every build flavor
        // work without code changes — important now that the sidecar lives in the
        // *closed backend* repo, not beside the app:
        //   1. an explicit Info.plist BrowserSubagentPath — dev builds point this at
        //      the in-repo (monorepo) or sibling-worktree (post-split) browser-subagent/,
        //   2. <repoRoot>/browser-subagent — a plain source/monorepo checkout,
        //   3. the copy bundled read-only in Contents/Resources — the signed release
        //      binary, into which package-release.sh copies the sidecar from the backend.
        // Trying candidates by run.sh presence (rather than committing to the first
        // non-nil path) means a stale/empty override — e.g. the public app repo, which
        // ships no sidecar — cleanly falls through instead of hard-failing.
        var candidateSidecarDirectories: [String] = []
        if let configuredSidecarDirectory = AppBundleConfiguration.stringValue(forKey: Self.sidecarPathInfoKey) {
            candidateSidecarDirectories.append(configuredSidecarDirectory)
        }
        if let repoRootURL = PerchSupportPaths.repoRootURL {
            candidateSidecarDirectories.append(
                repoRootURL.appendingPathComponent("browser-subagent", isDirectory: true).path)
        }
        if let bundledResourceURL = Bundle.main.resourceURL {
            candidateSidecarDirectories.append(
                bundledResourceURL.appendingPathComponent("browser-subagent", isDirectory: true).path)
        }

        func directoryContainsRunScript(_ directory: String) -> Bool {
            FileManager.default.fileExists(
                atPath: (directory as NSString).appendingPathComponent("run.sh"))
        }
        guard let sidecarDirectory = candidateSidecarDirectories.first(where: directoryContainsRunScript) else {
            throw SupervisorError.sidecarPathMissing
        }

        // A leftover socket file from a sidecar that has since died would make
        // waitForSocketFile() return immediately (the file still exists) before
        // the freshly launched sidecar has actually bound — and the subsequent
        // connect() would then race against that stale path. Remove it first so
        // we only ever observe the genuinely new sidecar's socket. The sidecar
        // also unlinks stale sockets on its side, so this is safe to do blindly.
        try? FileManager.default.removeItem(atPath: socketPath)

        try launchSidecar(sidecarDirectory: sidecarDirectory)
        try await waitForSocketFile()
        return socketPath
    }

    /// Terminates the sidecar process (called on app quit).
    func terminate() {
        sidecarProcess?.terminate()
        sidecarProcess = nil
    }

    // MARK: - Private

    private func launchSidecar(sidecarDirectory: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")

        // A login shell (-lc) picks up the user's Python toolchain from their
        // shell profile, matching how the app launches other helper scripts.
        //
        // NOTE: the app must be able to exec run.sh from `sidecarDirectory`. macOS
        // denies this app's child `exec`/read of files under a protected folder
        // (e.g. ~/Downloads), so a DEV build must NOT point BrowserSubagentPath at a
        // repo checkout that lives there — build-perch-dev.sh stages the sidecar into
        // a non-protected dir (~/.perch-dev-sidecar) and points here at the copy.
        // Keeping the sidecar the app's own child is what lets its `osascript` Apple
        // Events persist their Automation grant (a detached sidecar re-prompts forever).
        let quotedDirectory = Self.shellQuote(sidecarDirectory)
        let quotedSocketPath = Self.shellQuote(socketPath)
        let command = "cd \(quotedDirectory) && ./run.sh --socket \(quotedSocketPath)"
        process.arguments = ["-lc", command]

        // Route the sidecar's LLM calls through the Worker /agent proxy: the install
        // token authenticates and meters the calls (X-Perch-Feature: agent_run on
        // the Worker side), and the real OpenRouter key stays on the Worker — never
        // in the shipped sidecar binary. The sidecar reads OPENROUTER_BASE_URL +
        // OPENROUTER_API_KEY from its env, and load_dotenv(override=False) means
        // these injected values win over any local .env. Only injected when we hold
        // a token; otherwise the sidecar falls back to its own .env (local dev).
        var environment = ProcessInfo.processInfo.environment
        if let installToken = PerchInstallIdentity.currentInstallToken() {
            environment["OPENROUTER_BASE_URL"] = "\(Self.workerBaseURL)/agent"
            environment["OPENROUTER_API_KEY"] = installToken
            // Same credential swap for Exa web search: the sidecar POSTs to
            // EXA_BASE_URL/search with EXA_API_KEY as x-api-key, so pointing it at
            // the Worker keeps the real Exa key server-side (never in the binary).
            environment["EXA_BASE_URL"] = "\(Self.workerBaseURL)/exa"
            environment["EXA_API_KEY"] = installToken

            // Composio rides the same credential swap: the Worker holds the real
            // project key and pins every call to this install's own Composio
            // entity, so COMPOSIO_USER_ID must be the install id — a shared or
            // default entity would commingle users' connected accounts (the
            // sidecar refuses to enable Composio in that case, see config.py).
            //
            // EXCEPT on the dev line (`isComposioDirect`): there we inject NOTHING,
            // so the sidecar falls back to its own `browser-subagent/.env` — a
            // separate dev Composio project key — and its SDK talks to Composio
            // DIRECTLY. That keeps dev's Composio fully isolated from beta's, and
            // is why the local Worker needs no Composio proxy for dev.
            if !Self.isComposioDirect, let installId = PerchInstallIdentity.currentInstallId() {
                environment["COMPOSIO_BASE_URL"] = "\(Self.workerBaseURL)/composio"
                environment["COMPOSIO_API_KEY"] = installToken
                environment["COMPOSIO_USER_ID"] = installId
            }
        }

        // When the sidecar runs from the read-only, code-signed app bundle (the
        // release/beta build, where package-release.sh copied it into Resources),
        // run.sh CANNOT create its .venv / download Chromium next to the source —
        // writing into the bundle would fail and would break the code signature.
        // Point run.sh's mutable state at the writable support dir instead; run.sh
        // reads PERCH_SIDECAR_STATE_DIR. A dev build points BrowserSubagentPath at a
        // staged copy in ~/.perch-dev-sidecar (not the bundle, not ~/Downloads), so
        // this stays unset there and .venv lives in-place beside the staged copy.
        if sidecarDirectory.hasPrefix(Bundle.main.bundlePath) {
            environment["PERCH_SIDECAR_STATE_DIR"] = PerchSupportPaths.directory("sidecar").path
        }

        // Force the sidecar (Python) to use the exact same support directory the
        // app uses for composio-manifest.json, agent-runs.json, ipc socket, etc.
        // This is required so that active Composio connections (written by the
        // sidecar via build_manifest/save_manifest) are visible to
        // ComposioManifestReader + ActiveIntegrationsStore in the notch UI.
        environment["PERCH_SUPPORT_DIRECTORY"] = PerchSupportPaths.supportDirectoryURL.path

        // The on-computer browser lane (local Playwright / Chrome) is DEV-ONLY. Enable
        // it in the sidecar ONLY when this build opted in via the Info.plist flag —
        // dev builds set PerchLocalBrowserEnabled (see build-perch-dev.sh); the signed
        // release strips it (see package-release.sh). Absent/false → the sidecar never
        // registers the browser tool, so no local Chrome is launched for beta users.
        if Self.isLocalBrowserEnabled {
            environment["PERCH_LOCAL_BROWSER_ENABLED"] = "1"
        }

        process.environment = environment

        // Redirect the sidecar's stdout + stderr to a log file so launch
        // failures (exec denied, Python traceback, missing venv) are recoverable
        // instead of vanishing into a discarded pipe. Append, so successive runs
        // accumulate rather than clobber the previous failure.
        if let logHandle = Self.sidecarLogFileHandle() {
            process.standardOutput = logHandle
            process.standardError = logHandle
        }

        do {
            try process.run()
        } catch {
            throw SupervisorError.launchFailed(error.localizedDescription)
        }
        sidecarProcess = process
    }

    private func waitForSocketFile() async throws {
        let deadline = Date().addingTimeInterval(Self.socketAppearanceTimeoutSeconds)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: socketPath) {
                return
            }
            try? await Task.sleep(nanoseconds: UInt64(Self.socketPollIntervalSeconds * 1_000_000_000))
        }
        throw SupervisorError.socketNeverAppeared
    }

    /// Single-quotes a string for safe interpolation into a shell command.
    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Opens (creating if needed) the sidecar log file for appending and returns
    /// a handle positioned at the end. Writes a timestamped launch marker so the
    /// output of each spawn attempt is delimited in the log. Returns nil if the
    /// file cannot be opened, in which case the launch proceeds without capture.
    private static func sidecarLogFileHandle() -> FileHandle? {
        let fileManager = FileManager.default
        let logDirectory = (sidecarLogPath as NSString).deletingLastPathComponent
        try? fileManager.createDirectory(atPath: logDirectory, withIntermediateDirectories: true)

        if !fileManager.fileExists(atPath: sidecarLogPath) {
            fileManager.createFile(atPath: sidecarLogPath, contents: nil)
        }

        guard let fileHandle = FileHandle(forWritingAtPath: sidecarLogPath) else {
            return nil
        }
        _ = try? fileHandle.seekToEnd()

        let marker = "\n===== sidecar launch \(ISO8601DateFormatter().string(from: Date())) =====\n"
        if let markerData = marker.data(using: .utf8) {
            try? fileHandle.write(contentsOf: markerData)
        }
        return fileHandle
    }
}
