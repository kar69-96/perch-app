import AppKit
import SwiftUI

/// Owns the browser subagent lifecycle on the app side.
///
/// Held by `CompanionManager`. Starts the sidecar, connects over the unix socket,
/// and is a **registry of concurrent runs**: each background task the user fires
/// spawns a new `BrowserSubagentRun`, and the manager routes every sidecar event
/// to the matching run by the `subagentId` the event carries. This is what lets
/// Perch work several agents in parallel — a second task no longer overwrites the
/// first. The native preview panels and the top-right agent-swarm triangles each
/// observe a single `BrowserSubagentRun`. Frames arrive as base64 JPEG and are
/// decoded to `NSImage` for display.
@MainActor
final class BrowserSubagentManager: ObservableObject {

    /// Every live (and just-finished, not-yet-pruned) run, newest last. The swarm
    /// and `CompanionManager` observe this to know which agents exist.
    @Published private(set) var runs: [BrowserSubagentRun] = []

    /// The run for a given subagent id, or `nil` if it's unknown / already pruned.
    func run(for subagentId: String) -> BrowserSubagentRun? {
        runs.first { $0.id == subagentId }
    }

    /// UI state for Chrome record-and-replay. The manager owns the single socket, so
    /// it drives the `record.*` RPCs and forwards `record.*` events into here; the
    /// Agents-tab control observes this coordinator.
    let recordingCoordinator = ChromeRecordingCoordinator()

    private let processSupervisor = BrowserSubagentProcessSupervisor()
    private let ipcClient = BrowserSubagentIPCClient()

    private var eventConsumptionTask: Task<Void, Never>?
    private var isConnected = false

    /// Token for the `NSWorkspace` app-activation observer that drives the notch icon
    /// to whatever native app a run brings to the foreground (e.g. it opens Excel).
    private var appActivationObserver: NSObjectProtocol?

    init() {
        observeForegroundedApps()
        #if DEBUG
        // PREVIEW: seed stale mock running-agents so the Agents tab shows the running
        // layout in the real notch while iterating on the design. DEBUG-only (never
        // ships). To stop seeing the fake agents, delete this block / seedPreviewRuns().
        seedPreviewRuns()
        #endif
    }

    #if DEBUG
    /// Seeds stale mock runs so the Agents tab's running layout can be inspected in the
    /// real notch with no sidecar. DEBUG + `PERCH_PREVIEW_AGENTS=1` only. The hero
    /// falls back to the last running run, so the richest mock is placed last.
    private func seedPreviewRuns() {
        // IDs chosen so the deterministic palette hash lands each mock on a visibly
        // distinct identity colour (violet / green / blue) — the hero is the last run.
        runs = [
            .previewMock(
                id: "sa_demo0002", task: "Buy Adizero shoes",
                steps: ["Starting", "Working"], state: .working
            ),
            .previewMock(
                id: "sa_demo0004", task: "Research competitors",
                steps: ["Starting", "Working"], state: .working
            ),
            .previewMock(
                id: "sa_demo0007", task: "Drafting vendor replies",
                steps: ["Starting", "Connecting Gmail", "Working", "Finishing"],
                state: .completing, foregroundApp: "com.apple.mail"
            ),
        ]
    }
    #endif

    deinit {
        if let appActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(appActivationObserver)
        }
    }

    /// Watches which native app comes to the foreground while a run works, so the
    /// notch shows the app the agent is actually using. "open Excel"/"open Spotify"
    /// run as model-composed AppleScript in the sidecar and never reach the in-app
    /// desktop hooks, so this OS-level signal is how we learn the target app. A web
    /// run launches nothing (its sub-browser is headless), so nothing is captured and
    /// the icon stays Chrome.
    private func observeForegroundedApps() {
        appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let activatedApp = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
            else { return }
            // The notification is delivered on the main queue; hop onto the main actor
            // to touch run state.
            Task { @MainActor [weak self] in
                self?.attributeForegroundedApp(activatedApp)
            }
        }
    }

    /// Attributes a foregrounded app to the run it most likely belongs to (the newest
    /// still-working run). Ignores Perch itself and the app that was already frontmost
    /// when the run spawned, so a web run never adopts the terminal the user launched
    /// from — only a genuinely newly-opened app (Excel, Spotify) is adopted.
    private func attributeForegroundedApp(_ activatedApp: NSRunningApplication) {
        guard let activatedBundleId = activatedApp.bundleIdentifier,
              activatedBundleId != Bundle.main.bundleIdentifier,
              let workingRun = runs.last(where: { $0.isWorking }),
              activatedBundleId != workingRun.desktopTool.targetApplicationBundleIdentifier
        else { return }
        workingRun.noteForegroundedApp(bundleIdentifier: activatedBundleId)
    }

    // MARK: - Desktop actuation lock
    //
    // Desktop (AX/AppleScript) steps drive the user's REAL keyboard, clipboard, and
    // frontmost app — two runs cannot do that at once without garbling each other's
    // input. So a desktop run takes this lock on its first desktop callback and
    // holds it until it finishes, serializing physical actuation across runs while
    // browser-only runs (isolated headless sub-browsers) run fully in parallel and
    // never touch it. Implemented as a MainActor-confined async mutex: safe because
    // every method here runs on the main actor, so the held flag and the waiter
    // queue are only ever mutated serially.
    /// The subagent id that currently holds the lock, or `nil` when it's free.
    private var desktopActuationLockHolder: String?
    /// Runs parked waiting for the lock, in FIFO order, tagged by id so a run that
    /// terminates while still queued can be removed without corrupting ownership.
    private var desktopActuationLockWaiters: [(subagentId: String, continuation: CheckedContinuation<Void, Never>)] = []
    /// Subagent ids currently holding OR queued for the desktop lock, so a run's
    /// later callbacks skip re-acquiring and its terminal event releases exactly once.
    private var subagentIdsHoldingDesktopLock: Set<String> = []

    /// Starts a background browser task as a NEW concurrent run. Safe to call from
    /// the voice pipeline while other runs are in flight. `runDocument` is the
    /// originating turn's trace doc; the agent's lifecycle and executed AppleScript
    /// are appended to it as the run progresses. Returns the spawned run, or `nil`
    /// if the spawn failed.
    @discardableResult
    func startTask(_ task: String, runDocument: PerchRunLog.RunDocument? = nil) async -> BrowserSubagentRun? {
        PerchRunLog.append(runDocument, .action, "subagent.startTask: \(task)")
        do {
            // Capture which native app the user is looking at BEFORE we touch the
            // socket. Perch's notch is a non-activating panel, so the user's app
            // (Excel, Notes, whatever) stays frontmost — system steps use this name
            // to act on the document they already have open instead of a new one.
            let focusedApplicationName =
                NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
            // The same app's bundle id — sent to the sidecar so a system/desktop step
            // can load that app's per-app skill doc (app-skills/<bundle>.md).
            let focusedApplicationBundleIdentifier =
                NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""

            try await connectIfNeeded()
            PerchRunLog.append(
                runDocument, .action,
                "subagent connected, sending spawn RPC (focused app: "
                    + "\(focusedApplicationName.isEmpty ? "unknown" : focusedApplicationName))"
            )

            // The Composio apps the user COULD connect on demand (the curated
            // catalog). The planner routes a task about one of these to the api family
            // even when it isn't connected yet, so the connection gate can prompt the
            // user to connect it — instead of silently driving a browser sign-in.
            let connectableToolkitSlugs = ServiceCatalog.loadFromBundle().entries
                .filter { $0.kind == .composio }
                .map { $0.toolkitSlug }

            // The login gate is no longer requested up front: it fires reactively in
            // the sidecar only when a step hits a real auth wall mid-run.
            let result = try await ipcClient.sendRequest(
                method: BrowserSubagentRequestMethod.spawn,
                params: [
                    "task": task,
                    "mode": "auto",
                    "focusedApp": focusedApplicationName,
                    "focusedAppBundleIdentifier": focusedApplicationBundleIdentifier,
                    "connectableToolkits": connectableToolkitSlugs,
                    // The current Daily Dashboard widgets, so a dashboard EDIT task can
                    // name the target widget by id ("my news widget" → a concrete id).
                    // Always embedded (it's small); only consulted if the planner routes
                    // this task to the dashboard family.
                    "dashboardWidgets": DashboardAgentApplier.shared.snapshot(),
                ]
            )
            guard let subagentId = result["subagentId"] as? String else {
                PerchRunLog.append(runDocument, .error, "subagent spawn returned no subagentId")
                return nil
            }

            // Build the run only now that we have its stable id, so the triangle and
            // preview panel that key off it appear with a fixed identity.
            let newRun = BrowserSubagentRun(
                id: subagentId,
                taskDescription: task,
                runDocument: runDocument
            )
            // Pin this run's desktop "hands" to the app the user was looking at, so any
            // synthetic paste/keystroke it makes lands THERE — not in whatever window
            // drifts into focus mid-run (the wrong-app paste bug).
            newRun.desktopTool.targetApplicationBundleIdentifier =
                focusedApplicationBundleIdentifier.isEmpty ? nil : focusedApplicationBundleIdentifier
            runs.append(newRun)
            PerchRunLog.append(runDocument, .action, "subagent spawned, id=\(subagentId)")
            return newRun
        } catch {
            PerchRunLog.append(runDocument, .error, "subagent FAILED to start: \(error)")
            print("⚠️ Browser subagent failed to start: \(error)")
            return nil
        }
    }

    /// Removes a finished run from the registry. Called by `CompanionManager` once it
    /// has announced completion and begun the triangle's merge-away animation.
    func discardRun(_ subagentId: String) {
        runs.removeAll { $0.id == subagentId }
    }

    /// Called from a run's preview panel "Done logging in" button — tells the sidecar
    /// to close the headful login window and continue that run headlessly.
    func completeLoginGate(subagentId: String) async {
        run(for: subagentId)?.setPendingLoginGateMessage(nil)
        _ = try? await ipcClient.sendRequest(
            method: BrowserSubagentRequestMethod.loginComplete,
            params: ["subagentId": subagentId]
        )
    }

    /// Tells the sidecar the app has finished driving the connect flow for a run's
    /// connection gate. The sidecar re-queries the live connected set to decide what
    /// to do per toolkit (keep on api, or fall back to the web lane).
    func completeConnectionRequest(subagentId: String) async {
        run(for: subagentId)?.setPendingConnectionRequest(nil)
        _ = try? await ipcClient.sendRequest(
            method: BrowserSubagentRequestMethod.connectionComplete,
            params: ["subagentId": subagentId]
        )
    }

    /// Kill switch — hard-stops one run. Other runs are unaffected.
    func cancel(subagentId: String) async {
        run(for: subagentId)?.desktopTool.endClipboardRun()
        releaseDesktopActuationLockIfHeld(by: subagentId)
        _ = try? await ipcClient.sendRequest(
            method: BrowserSubagentRequestMethod.cancel,
            params: ["subagentId": subagentId]
        )
    }

    /// Forwards a run's answer to its confirmation gate.
    func respondToConfirmation(subagentId: String, approved: Bool) async {
        guard let activeRun = run(for: subagentId),
              let confirmation = activeRun.pendingConfirmation else { return }
        activeRun.setPendingConfirmation(nil)
        _ = try? await ipcClient.sendRequest(
            method: BrowserSubagentRequestMethod.confirm,
            params: [
                "subagentId": subagentId,
                "actionId": confirmation.id,
                "approved": approved,
            ]
        )
    }

    /// Adjusts one run's live preview frame rate (collapsed = low, expanded = high).
    func setPreviewQuality(subagentId: String, targetFps: Double) async {
        _ = try? await ipcClient.sendRequest(
            method: BrowserSubagentRequestMethod.setPreviewQuality,
            params: ["subagentId": subagentId, "targetFps": targetFps]
        )
    }

    // MARK: - Chrome record-and-replay

    /// Opens the headful recording window and begins capturing a demonstration.
    /// `name` is an optional hint for the saved skill's slug. Safe to call only when
    /// no recording is already busy (the control enforces that).
    func startRecording(name: String) async {
        // Flip the UI to "Opening Chrome…" immediately — connecting the sidecar and
        // launching the headful window can take a few seconds, and the user needs to
        // see that their click registered.
        recordingCoordinator.markStarting()
        do {
            try await connectIfNeeded()
            let result = try await ipcClient.sendRequest(
                method: BrowserSubagentRequestMethod.recordStart,
                params: ["name": name]
            )
            guard let recordingId = result["recordingId"] as? String else {
                recordingCoordinator.markFailed("The sidecar returned no recording id.")
                return
            }
            recordingCoordinator.markStarted(recordingId: recordingId)
        } catch {
            recordingCoordinator.markFailed("Couldn't start recording: \(error.localizedDescription)")
        }
    }

    /// Ends the recording, synthesizes the skill, and saves it. The stop RPC blocks
    /// while the synthesis model drafts the skill, so mark synthesizing first for the UI.
    ///
    /// Only valid while actually recording — a stray Finish in any other state (a
    /// double-tap, `.starting`, or an already-`.synthesizing` run) would fire a
    /// `record.stop` with no active recording and strand the UI in `.synthesizing`.
    func stopRecording() async {
        guard recordingCoordinator.state == .recording else { return }
        recordingCoordinator.markSynthesizing()
        do {
            let result = try await ipcClient.sendRequest(
                method: BrowserSubagentRequestMethod.recordStop,
                params: [:]
            )
            recordingCoordinator.markSaved(
                SavedChromeSkill(
                    slug: result["slug"] as? String ?? "",
                    title: result["title"] as? String ?? "Chrome recording",
                    path: result["path"] as? String ?? ""
                )
            )
        } catch {
            recordingCoordinator.markFailed("Couldn't save the skill: \(error.localizedDescription)")
        }
    }

    /// Discards the active recording without synthesizing.
    func cancelRecording() async {
        _ = try? await ipcClient.sendRequest(
            method: BrowserSubagentRequestMethod.recordCancel,
            params: [:]
        )
        recordingCoordinator.markCancelled()
    }

    /// Read-only data fetch for a Daily Dashboard widget. Reuses the one sidecar +
    /// socket (lazily started) via the existing IPC client, but does NOT spawn a
    /// subagent — the sidecar's `dashboard.fetch` handler answers directly from
    /// Exa/Composio and never touches the browser. Returns the raw item dictionaries
    /// (`{title, subtitle?, url?, timestamp?}`); the caller maps + ranks them.
    func sendDashboardFetch(provider: String, query: String, limit: Int) async throws -> [[String: Any]] {
        try await connectIfNeeded()
        let result = try await ipcClient.sendRequest(
            method: BrowserSubagentRequestMethod.dashboardFetch,
            params: ["provider": provider, "query": query, "limit": limit]
        )
        return result["items"] as? [[String: Any]] ?? []
    }

    /// Agent-driven importance filter for notch alerts. Returns at most one
    /// compact alert, or nil when nothing is urgent enough to surface.
    func sendNotchAlertEvaluate(
        candidates: [NotchAlertCandidate],
        dismissedFingerprints: [String]
    ) async throws -> NotchAlert? {
        try await connectIfNeeded()
        let candidateDictionaries = candidates.map { $0.asDictionary() }
        let result = try await ipcClient.sendRequest(
            method: BrowserSubagentRequestMethod.notchAlertEvaluate,
            params: [
                "candidates": candidateDictionaries,
                "dismissedFingerprints": dismissedFingerprints,
                "now": ISO8601DateFormatter().string(from: Date()),
            ]
        )
        guard let alertRaw = result["alert"] as? [String: Any] else { return nil }
        return NotchAlert.fromDictionary(alertRaw)
    }

    // `DashboardFetchTransport` conformance is the `sendDashboardFetch` above — see
    // the extension at the bottom of this file.

    /// Terminates the sidecar (called on app quit).
    func shutdown() {
        eventConsumptionTask?.cancel()
        Task { await ipcClient.disconnect() }
        processSupervisor.terminate()
    }

    // MARK: - Private

    /// DEV warm-up: eagerly spawn + connect the sidecar at app launch so the first
    /// agent action doesn't pay the spawn/venv cost — the sidecar is already "up".
    /// Gated by the dev-only Info.plist flag `PerchWarmSidecarOnLaunch` (set by
    /// build-perch-dev.sh, stripped by package-release.sh), so BETA keeps spawning the
    /// sidecar lazily on first use. Best-effort: on failure the normal lazy path in
    /// startTask() still applies. No Apple Events are sent by warming, so this never
    /// triggers a permission prompt on its own.
    func warmUpIfConfigured() {
        let flag = AppBundleConfiguration.stringValue(forKey: "PerchWarmSidecarOnLaunch")
        guard let flag, ["1", "true", "yes", "on"].contains(flag.lowercased()) else { return }
        Task { [weak self] in
            do { try await self?.connectIfNeeded() } catch {
                print("⚠️ BrowserSubagentManager: sidecar warm-up failed (lazy path still applies): \(error)")
            }
        }
    }

    private func connectIfNeeded() async throws {
        guard !isConnected else { return }
        let socketPath = try await processSupervisor.ensureRunning()
        try await ipcClient.connect(socketPath: socketPath)
        isConnected = true
        startConsumingEvents()
    }

    private func startConsumingEvents() {
        eventConsumptionTask = Task { [weak self] in
            guard let self else { return }
            let stream = await self.ipcClient.events()
            for await event in stream {
                self.handle(event)
            }
            // The stream only finishes when the sidecar connection drops (crashed,
            // killed, or socket closed). Reset the connection flag so the next
            // startTask() does a full respawn + reconnect.
            self.handleSidecarConnectionLost()
        }
    }

    /// Invoked when the sidecar's event stream finishes. Clears `isConnected` so the
    /// manager re-establishes the sidecar on the next task, and fails any runs that
    /// were still in flight.
    private func handleSidecarConnectionLost() {
        isConnected = false
        for activeRun in runs where activeRun.isWorking {
            PerchRunLog.append(activeRun.runDocument, .error, "sidecar connection lost (was working)")
            activeRun.markErrored()
            activeRun.desktopTool.endClipboardRun()
            releaseDesktopActuationLockIfHeld(by: activeRun.id)
        }
    }

    private func handle(_ event: BrowserSubagentEvent) {
        switch event {
        case let .state(subagentId, state):
            guard let activeRun = run(for: subagentId) else { return }
            activeRun.update(state: state)
            PerchRunLog.append(activeRun.runDocument, .state, "subagent state → \(state)")

        case let .frame(subagentId, jpegBase64, _):
            guard let activeRun = run(for: subagentId) else { return }
            if let imageData = Data(base64Encoded: jpegBase64),
               let image = NSImage(data: imageData) {
                activeRun.update(frame: image)
            }

        case let .confirmRequest(subagentId, actionId, description, tier):
            guard let activeRun = run(for: subagentId) else { return }
            PerchRunLog.append(activeRun.runDocument, .action, "confirmation gate: \(description) (tier \(tier ?? "—"))")
            activeRun.setPendingConfirmation(
                PendingBrowserSubagentConfirmation(
                    id: actionId, subagentId: subagentId, description: description, tier: tier
                )
            )

        case let .loginGate(subagentId, message):
            guard let activeRun = run(for: subagentId) else { return }
            PerchRunLog.append(activeRun.runDocument, .state, "login gate: \(message)")
            activeRun.setPendingLoginGateMessage(message)

        case let .connectionRequired(subagentId, toolkitSlugs):
            guard let activeRun = run(for: subagentId) else { return }
            PerchRunLog.append(
                activeRun.runDocument, .state,
                "connection gate: needs \(toolkitSlugs.joined(separator: ", "))"
            )
            // An empty list would block the sidecar forever — resolve immediately.
            guard !toolkitSlugs.isEmpty else {
                Task { await self.completeConnectionRequest(subagentId: subagentId) }
                return
            }
            activeRun.setPendingConnectionRequest(toolkitSlugs)

        case let .done(subagentId, handoffWindowReady, finalUrlString, resultSummary, deliverableLabel):
            guard let activeRun = run(for: subagentId) else { return }
            let finalUrl = finalUrlString.flatMap { URL(string: $0) }
            activeRun.applyDone(
                handoffWindowReady: handoffWindowReady,
                finalUrl: finalUrl,
                resultSummary: resultSummary,
                deliverableLabel: deliverableLabel
            )
            // Run is over — restore this run's clipboard (saved on its first desktop
            // action and held across the run) and free the desktop lock if it held it.
            activeRun.desktopTool.endClipboardRun()
            releaseDesktopActuationLockIfHeld(by: subagentId)
            PerchRunLog.append(
                activeRun.runDocument, .action,
                "subagent done — handoffReady=\(handoffWindowReady) finalUrl=\(finalUrlString ?? "—") summary=\(resultSummary ?? "—")"
            )
            // Inline any AppleScript the agent ran in its OWN process (the Python
            // "system" family via osascript) by reading this run's trace.
            PerchRunLog.appendAppleScriptFromSubagentTrace(activeRun.runDocument, subagentId: subagentId)

        case let .error(subagentId, message):
            guard let activeRun = run(for: subagentId) else { return }
            print("⚠️ Browser subagent error: \(message)")
            PerchRunLog.append(activeRun.runDocument, .error, "subagent error: \(message)")
            activeRun.markErrored()
            activeRun.desktopTool.endClipboardRun()
            releaseDesktopActuationLockIfHeld(by: subagentId)

        case let .needsInput(subagentId, question):
            // The run ended by asking the user a free-form question — NOT a completion.
            // Move the run to the terminal `.needsInput` state; `CompanionManager` speaks
            // the question (never an "all done" wrap-up) and prunes the run.
            guard let activeRun = run(for: subagentId) else { return }
            PerchRunLog.append(activeRun.runDocument, .action, "subagent needs input: \(question)")
            activeRun.applyNeedsInput(question: question)
            activeRun.desktopTool.endClipboardRun()
            releaseDesktopActuationLockIfHeld(by: subagentId)

        case let .desktopPerceive(subagentId, requestId):
            // Perceiving and actuating are async; answer on a detached task so the
            // event-consumption loop keeps draining (and a slow app can't stall it).
            // The desktop lock serializes physical actuation across runs.
            Task { await self.respondToDesktopPerceive(subagentId: subagentId, requestId: requestId) }

        case let .desktopAction(subagentId, requestId, action):
            guard let activeRun = run(for: subagentId) else { return }
            // Log what the agent is about to do, inlining the AppleScript source when
            // the decided action is an AppleScript run.
            PerchRunLog.append(activeRun.runDocument, .action, "desktop action: \(desktopActionSummary(action))")
            if let appleScriptSource = appleScriptSource(from: action) {
                PerchRunLog.appendAppleScript(activeRun.runDocument, source: appleScriptSource, result: nil)
            }
            Task {
                await self.respondToDesktopAction(
                    subagentId: subagentId, requestId: requestId, action: action
                )
            }

        case let .dashboardSnapshot(subagentId, requestId):
            // Read-only — no run lookup needed, no actuation lock. Answer off the
            // event loop so a slow read can't stall event consumption.
            Task { await self.respondToDashboardSnapshot(subagentId: subagentId, requestId: requestId) }

        case let .dashboardCreate(subagentId, requestId, widget):
            guard let activeRun = run(for: subagentId) else { return }
            PerchRunLog.append(
                activeRun.runDocument, .action,
                "dashboard create: \(widget["title"] as? String ?? "widget")"
            )
            Task {
                await self.respondToDashboardCreate(
                    subagentId: subagentId, requestId: requestId, widget: widget
                )
            }

        case let .dashboardEdit(subagentId, requestId, widgetId, patch):
            guard let activeRun = run(for: subagentId) else { return }
            PerchRunLog.append(activeRun.runDocument, .action, "dashboard edit: \(widgetId)")
            Task {
                await self.respondToDashboardEdit(
                    subagentId: subagentId, requestId: requestId, widgetId: widgetId, patch: patch
                )
            }

        case .recordState, .recordFrame, .recordSaved, .recordError:
            // Chrome record-and-replay events are independent of any run — forward
            // them to the recording coordinator that the Agents-tab control observes.
            recordingCoordinator.handle(event)
        }
    }

    /// The decided desktop action's type label (e.g. "type_text", "applescript").
    private func desktopActionSummary(_ action: [String: Any]) -> String {
        return (action["type"] as? String) ?? "action"
    }

    /// Extracts the full AppleScript source from a decided desktop action when it is
    /// an `applescript` action.
    private func appleScriptSource(from action: [String: Any]) -> String? {
        guard (action["type"] as? String) == "applescript",
              let source = action["source"] as? String, !source.isEmpty else {
            return nil
        }
        return source
    }

    /// Answer a desktop perceive callback: snapshot the focused app, send it up. Holds
    /// the desktop actuation lock so a second run's physical work can't interleave.
    private func respondToDesktopPerceive(subagentId: String, requestId: String) async {
        guard let activeRun = run(for: subagentId) else { return }
        // This run has now touched the desktop — let its notch icon resolve to the
        // real target app instead of the browser glyph.
        activeRun.markDesktopActivity()
        await acquireDesktopActuationLock(for: subagentId)
        let snapshot = await activeRun.desktopTool.perceive()
        _ = try? await ipcClient.sendRequest(
            method: BrowserSubagentRequestMethod.desktopPerceiveResult,
            params: ["subagentId": subagentId, "requestId": requestId].merging(
                snapshot, uniquingKeysWith: { current, _ in current }
            )
        )
    }

    /// Answer a desktop action callback: actuate the decided action, send the AX
    /// read-back up. The action arrives already decided and gated by Core.
    private func respondToDesktopAction(
        subagentId: String, requestId: String, action: [String: Any]
    ) async {
        guard let activeRun = run(for: subagentId) else { return }

        // Hands turned off in the menu → refuse every desktop touch (cursor / click /
        // type) and report it back so the subagent can stop rather than hang. Checked
        // before the actuation lock or any input synthesis.
        guard PerchCapabilityToggles.isHandsEnabledNow() else {
            PerchRunLog.append(
                activeRun.runDocument, .action,
                "desktop action BLOCKED — Hands permission is turned off in Perch's menu")
            _ = try? await ipcClient.sendRequest(
                method: BrowserSubagentRequestMethod.desktopActionResult,
                params: [
                    "subagentId": subagentId,
                    "requestId": requestId,
                    "ok": false,
                    "error": "Hands permission is disabled — desktop actuation is turned off in Perch's menu.",
                ]
            )
            return
        }

        // A decided desktop action is a real desktop touch too (in case it arrives
        // without a preceding perceive) — switch the notch icon to the target app.
        activeRun.markDesktopActivity()
        await acquireDesktopActuationLock(for: subagentId)
        let result = await activeRun.desktopTool.performAction(action)
        _ = try? await ipcClient.sendRequest(
            method: BrowserSubagentRequestMethod.desktopActionResult,
            params: ["subagentId": subagentId, "requestId": requestId].merging(
                result, uniquingKeysWith: { current, _ in current }
            )
        )
    }

    // MARK: - Dashboard step callbacks (create / edit / snapshot the user's board)

    /// Answer a dashboard snapshot callback: send up the current data-driven widgets so
    /// an edit step can name its target by id. No actuation lock (a read of the store).
    private func respondToDashboardSnapshot(subagentId: String, requestId: String) async {
        let widgets = DashboardAgentApplier.shared.snapshot()
        _ = try? await ipcClient.sendRequest(
            method: BrowserSubagentRequestMethod.dashboardSnapshotResult,
            params: ["subagentId": subagentId, "requestId": requestId, "widgets": widgets]
        )
    }

    /// Answer a dashboard create callback: build + place the widget on the user's board
    /// and run its first fetch, then send the outcome (ok / itemCount / summary) up.
    private func respondToDashboardCreate(
        subagentId: String, requestId: String, widget: [String: Any]
    ) async {
        let result = await DashboardAgentApplier.shared.applyCreate(widget)
        _ = try? await ipcClient.sendRequest(
            method: BrowserSubagentRequestMethod.dashboardCreateResult,
            params: ["subagentId": subagentId, "requestId": requestId].merging(
                result, uniquingKeysWith: { current, _ in current }
            )
        )
    }

    /// Answer a dashboard edit callback: merge the patch onto the existing widget and
    /// re-fetch, then send the outcome up (ok:false when the widget id no longer exists).
    private func respondToDashboardEdit(
        subagentId: String, requestId: String, widgetId: String, patch: [String: Any]
    ) async {
        let result = await DashboardAgentApplier.shared.applyEdit(widgetId: widgetId, patch: patch)
        _ = try? await ipcClient.sendRequest(
            method: BrowserSubagentRequestMethod.dashboardEditResult,
            params: ["subagentId": subagentId, "requestId": requestId].merging(
                result, uniquingKeysWith: { current, _ in current }
            )
        )
    }

    // MARK: - Desktop actuation lock (MainActor-confined async mutex)

    /// Acquire the desktop lock for a run if it doesn't already hold it. A run's first
    /// desktop callback acquires it; the run holds it until its terminal event releases
    /// it. The set membership is reserved synchronously (no `await` before it), so two
    /// callbacks for the same run never both try to acquire.
    private func acquireDesktopActuationLock(for subagentId: String) async {
        if subagentIdsHoldingDesktopLock.contains(subagentId) { return }
        subagentIdsHoldingDesktopLock.insert(subagentId)
        if desktopActuationLockHolder == nil {
            desktopActuationLockHolder = subagentId
            return
        }
        await withCheckedContinuation { continuation in
            desktopActuationLockWaiters.append((subagentId: subagentId, continuation: continuation))
        }
    }

    /// Release the desktop lock if `subagentId` was holding it, handing ownership to
    /// the next queued run; or, if the run was still queued (never granted), drop its
    /// waiter so the lock never gets stuck. A no-op for runs that did no desktop work.
    private func releaseDesktopActuationLockIfHeld(by subagentId: String) {
        guard subagentIdsHoldingDesktopLock.remove(subagentId) != nil else { return }

        if desktopActuationLockHolder == subagentId {
            // The holder is leaving: hand ownership to the next waiter, if any.
            if desktopActuationLockWaiters.isEmpty {
                desktopActuationLockHolder = nil
            } else {
                let nextWaiter = desktopActuationLockWaiters.removeFirst()
                desktopActuationLockHolder = nextWaiter.subagentId
                nextWaiter.continuation.resume()
            }
        } else if let queuedIndex = desktopActuationLockWaiters.firstIndex(where: { $0.subagentId == subagentId }) {
            // The run ended while still queued: remove and resume its parked acquire
            // so the awaiting task unblocks (it will simply find its run terminal).
            let removedWaiter = desktopActuationLockWaiters.remove(at: queuedIndex)
            removedWaiter.continuation.resume()
        }
    }
}

extension BrowserSubagentManager: NotchAlertEvaluating {}

// The dashboard's live-data fetch goes through the one sidecar via this manager. The
// conforming method (`sendDashboardFetch`) is defined above; this extension just
// declares the conformance so the dashboard can hold the manager as an opaque
// `DashboardFetchTransport` without a compile-time dependency on this type.
extension BrowserSubagentManager: DashboardFetchTransport {}
