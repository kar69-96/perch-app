//
//  ServiceConnectManager.swift
//  Perch
//
//  Runs the actual "connect" side effect when the user accepts a connect offer,
//  and reports the outcome back to the coordinator.
//
//  Composio services: spawns the standalone `run.sh --connect <slug>` process
//  (the same login-shell spawn idiom as BrowserSubagentProcessSupervisor). That
//  Python flow opens the OAuth URL in the user's real browser and, on success,
//  rewrites the capability manifest. Swift detects completion purely by polling
//  the manifest for the slug — no stdout parsing, no coupling to the long-lived
//  sidecar. Output is captured to <repo>/support/connect.log so a launch/auth
//  failure is diagnosable.
//
//  Native services (Word, Excel, Numbers): no OAuth — Perch already actuates
//  them via AppleScript. "Connecting" is recorded by the coordinator
//  (EnabledIntegrationsStore); here it just succeeds immediately. Any missing
//  macOS Automation/Accessibility grant surfaces through the app's existing
//  permission flow the first time Perch acts on the app.
//

import AppKit
import Foundation

@MainActor
final class ServiceConnectManager: ServiceConnecting {

    /// Info.plist key holding the absolute path to the `browser-subagent/` directory.
    private static let sidecarPathInfoKey = "BrowserSubagentPath"

    /// How often to re-check the manifest for the new connection, and how long to
    /// wait before giving up. Matches the Python connect flow's own 3s/300s cadence.
    private static let pollInterval: TimeInterval = 3.0
    private static let timeout: TimeInterval = 300.0

    /// File the connect process's stdout + stderr are redirected to.
    private static let connectLogPath = PerchSupportPaths.file("connect.log").path

    /// The Worker gateway base URL (same Info.plist key the sidecar supervisor
    /// uses). The connect flow's Composio calls route through `<base>/composio`
    /// so the real Composio project key never ships on the user's machine.
    private static let workerBaseURL = AppBundleConfiguration.stringValue(forKey: "WorkerBaseURL")
        ?? "https://your-worker-name.your-subdomain.workers.dev"

    /// DEV-ONLY: when set (dev builds, via `build-perch-dev.sh`), the connect flow
    /// reaches Composio DIRECTLY with the sidecar's own `browser-subagent/.env` key
    /// instead of routing through the Worker proxy — keeping dev's Composio project
    /// isolated from beta. Mirrors `BrowserSubagentProcessSupervisor.isComposioDirect`;
    /// absent for beta (asserted by `verify-release-config.sh`), so the release keeps
    /// the proxy swap that holds the real key server-side.
    private static var isComposioDirect: Bool {
        AppBundleConfiguration.isFlagEnabled(forKey: "PerchComposioDirect")
    }

    private let manifestReader: ComposioManifestReader

    private var connectProcess: Process?
    private var pollTask: Task<Void, Never>?

    init(manifestReader: ComposioManifestReader) {
        self.manifestReader = manifestReader
    }

    // MARK: - ServiceConnecting

    func connect(_ offer: ServiceConnectionOffer, onOutcome: @escaping (Bool) -> Void) {
        switch offer.kind {
        case .native:
            // Native apps need no account link — Perch already drives them via
            // AppleScript. Enablement is recorded by the coordinator on success.
            onOutcome(true)
        case .composio:
            connectComposioToolkit(slug: offer.toolkitSlug, onOutcome: onOutcome)
        }
    }

    /// Abort an in-flight connect: stop the manifest poll and terminate the OAuth
    /// helper process. Called when the user dismisses the connect prompt mid-connect
    /// (the ✕), so a never-completing OAuth stops immediately instead of polling for
    /// the full 300s timeout. Safe to call when nothing is in flight.
    func cancel() {
        pollTask?.cancel()
        pollTask = nil
        if let process = connectProcess, process.isRunning {
            process.terminate()
        }
        connectProcess = nil
    }

    // MARK: - Composio OAuth

    private func connectComposioToolkit(slug: String, onOutcome: @escaping (Bool) -> Void) {
        guard let sidecarDirectory = AppBundleConfiguration.stringValue(forKey: Self.sidecarPathInfoKey) else {
            print("⚠️ ServiceConnectManager: BrowserSubagentPath not configured — cannot connect")
            onOutcome(false)
            return
        }
        let runScriptPath = (sidecarDirectory as NSString).appendingPathComponent("run.sh")
        guard FileManager.default.fileExists(atPath: runScriptPath) else {
            print("⚠️ ServiceConnectManager: run.sh not found at \(runScriptPath)")
            onOutcome(false)
            return
        }

        let didSpawn = spawnConnectProcess(sidecarDirectory: sidecarDirectory, slug: slug)
        guard didSpawn else {
            onOutcome(false)
            return
        }

        // Poll the manifest until the toolkit shows as connected, the spawned
        // process exits without connecting, or we hit the timeout.
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            await self?.pollForConnection(slug: slug, onOutcome: onOutcome)
        }
    }

    private func spawnConnectProcess(sidecarDirectory: String, slug: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")

        // A login shell (-lc) picks up the user's Python toolchain, matching how
        // the app launches the sidecar.
        let quotedDirectory = Self.shellQuote(sidecarDirectory)
        let quotedSlug = Self.shellQuote(slug)
        let command = "cd \(quotedDirectory) && ./run.sh --connect \(quotedSlug)"
        process.arguments = ["-lc", command]

        // Same Composio credential swap as the sidecar launch (see
        // BrowserSubagentProcessSupervisor): the OAuth connect must run against
        // THIS install's own Composio entity via the Worker proxy, or the new
        // connection would land in a shared entity visible to other users. Only
        // injected when the install is registered; otherwise the connect flow
        // falls back to the local .env (developer running their own key).
        //
        // On the dev line (`isComposioDirect`) we skip the injection entirely, so
        // the connect runs against the sidecar's own dev Composio key from
        // `browser-subagent/.env` — the same isolated dev project the agent uses.
        var environment = ProcessInfo.processInfo.environment
        if !Self.isComposioDirect,
           let installToken = PerchInstallIdentity.currentInstallToken(),
           let installId = PerchInstallIdentity.currentInstallId() {
            environment["COMPOSIO_BASE_URL"] = "\(Self.workerBaseURL)/composio"
            environment["COMPOSIO_API_KEY"] = installToken
            environment["COMPOSIO_USER_ID"] = installId
        }
        process.environment = environment

        if let logHandle = Self.connectLogFileHandle() {
            process.standardOutput = logHandle
            process.standardError = logHandle
        }

        do {
            try process.run()
        } catch {
            print("⚠️ ServiceConnectManager: failed to launch connect process: \(error)")
            return false
        }
        connectProcess = process
        return true
    }

    private func pollForConnection(slug: String, onOutcome: @escaping (Bool) -> Void) async {
        let pollIntervalNanoseconds = UInt64(Self.pollInterval * 1_000_000_000)
        let deadline = Date().addingTimeInterval(Self.timeout)
        while Date() < deadline {
            if Task.isCancelled { return }

            if manifestReader.isConnected(toolkitSlug: slug) {
                onOutcome(true)
                return
            }

            let connectProcessExited = connectProcess.map { !$0.isRunning } ?? false
            // One poll interval between reads. After the connect process has exited the
            // manifest may take a beat to land, so the sleep above also serves as that
            // grace period before the final read below.
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
            if connectProcessExited {
                onOutcome(manifestReader.isConnected(toolkitSlug: slug))
                return
            }
        }
        onOutcome(manifestReader.isConnected(toolkitSlug: slug))
    }

    // MARK: - Helpers

    /// Single-quotes a string for safe interpolation into a shell command.
    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Opens (creating if needed) the connect log file for appending, with a
    /// timestamped marker. Returns nil if it can't be opened (launch proceeds
    /// without capture).
    private static func connectLogFileHandle() -> FileHandle? {
        let fileManager = FileManager.default
        let logDirectory = (connectLogPath as NSString).deletingLastPathComponent
        try? fileManager.createDirectory(atPath: logDirectory, withIntermediateDirectories: true)

        if !fileManager.fileExists(atPath: connectLogPath) {
            fileManager.createFile(atPath: connectLogPath, contents: nil)
        }

        guard let fileHandle = FileHandle(forWritingAtPath: connectLogPath) else {
            return nil
        }
        _ = try? fileHandle.seekToEnd()

        let marker = "\n===== connect launch \(ISO8601DateFormatter().string(from: Date())) =====\n"
        if let markerData = marker.data(using: .utf8) {
            try? fileHandle.write(contentsOf: markerData)
        }
        return fileHandle
    }
}
