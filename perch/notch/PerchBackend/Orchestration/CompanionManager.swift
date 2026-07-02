//
//  CompanionManager.swift
//  Perch
//
//  Central state manager for the companion voice mode. Owns the push-to-talk
//  pipeline (dictation manager + global shortcut monitor + overlay) and
//  exposes observable voice state for the panel UI.
//

import AVFoundation
import Combine
import Foundation
import ScreenCaptureKit
import SwiftUI

enum CompanionVoiceState {
    case idle
    case listening
    case processing
    case responding
}

@MainActor
final class CompanionManager: ObservableObject {
    @Published private(set) var voiceState: CompanionVoiceState = .idle {
        didSet {
            updateTTSMetering(previousState: oldValue)
            updateNowPlayingPause(previousState: oldValue)
        }
    }
    @Published private(set) var lastTranscript: String?

    /// Live, partial transcription of what the user is currently saying while
    /// holding push-to-talk. Streamed to the cursor overlay so the user sees
    /// their words appear in real time, the same way Perch's replies are typed.
    @Published private(set) var liveTranscriptionText: String = ""

    /// Text surfaced (and spoken) when a background browser task finishes.
    /// Non-empty drives a result bubble on the cursor overlay; cleared on a timer.
    @Published private(set) var backgroundTaskCompletionText: String = ""
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0

    /// Live playback amplitude (0…1) of Perch's own TTS voice while it is
    /// speaking (`voiceState == .responding`). Sampled from the TTS player's
    /// output meter by `ttsMeteringTask`; drives the voice orb's "speaking"
    /// repulsion so the orb pulses to the actual spoken words. 0 when not speaking.
    @Published private(set) var ttsAudioPowerLevel: CGFloat = 0

    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasScreenContentPermission = false

    /// Screen location (global AppKit coords) of a detected UI element the
    /// buddy should fly to and point at. Parsed from Claude's response;
    /// observed by BlueCursorView to trigger the flight animation.
    @Published var detectedElementScreenLocation: CGPoint?
    /// The display frame (global AppKit coords) of the screen the detected
    /// element is on, so BlueCursorView knows which screen overlay should animate.
    @Published var detectedElementDisplayFrame: CGRect?
    /// Custom speech bubble text for the pointing animation. When set,
    /// BlueCursorView uses this instead of a random pointer phrase.
    @Published var detectedElementBubbleText: String?

    // MARK: - Onboarding Video State (shared across all screen overlays)

    @Published var onboardingVideoPlayer: AVPlayer?
    @Published var showOnboardingVideo: Bool = false
    @Published var onboardingVideoOpacity: Double = 0.0
    var onboardingVideoEndObserver: NSObjectProtocol?
    var onboardingDemoTimeObserver: Any?

    // MARK: - Onboarding Prompt Bubble

    /// Text streamed character-by-character on the cursor after the onboarding video ends.
    @Published var onboardingPromptText: String = ""
    @Published var onboardingPromptOpacity: Double = 0.0
    @Published var showOnboardingPrompt: Bool = false

    // MARK: - Onboarding Music

    private var onboardingMusicPlayer: AVAudioPlayer?
    private var onboardingMusicFadeTimer: Timer?

    let buddyDictationManager = BuddyDictationManager()
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let overlayWindowManager = OverlayWindowManager()

    // Response text is now displayed inline on the cursor overlay via
    // streamingResponseText, so no separate response overlay manager is needed.

    /// Base URL for the Cloudflare Worker proxy. All API requests route
    /// through this so keys never ship in the app binary. Read from the
    /// `WorkerBaseURL` Info.plist key (same pattern as the production app)
    /// so the backend can be switched without editing source.
    private static let workerBaseURL = AppBundleConfiguration.stringValue(forKey: "WorkerBaseURL")
        ?? "https://your-worker-name.your-subdomain.workers.dev"

    lazy var claudeAPI: ClaudeAPI = {
        return ClaudeAPI(proxyURL: "\(Self.workerBaseURL)/chat", model: selectedModel)
    }()

    private lazy var elevenLabsTTSClient: ElevenLabsTTSClient = {
        return ElevenLabsTTSClient(proxyURL: "\(Self.workerBaseURL)/tts")
    }()

    /// Polls the TTS player's output meter while Perch is speaking and republishes
    /// it as `ttsAudioPowerLevel`. Started/stopped by `updateTTSMetering` as the
    /// voice state enters/leaves `.responding`.
    private var ttsMeteringTask: Task<Void, Never>?

    /// Starts sampling the TTS output amplitude when speaking begins and stops
    /// (resetting the level to 0) when it ends. Called from `voiceState.didSet`.
    private func updateTTSMetering(previousState: CompanionVoiceState) {
        guard voiceState != previousState else { return }

        if voiceState == .responding {
            ttsMeteringTask?.cancel()
            ttsMeteringTask = Task { @MainActor [weak self] in
                guard let self else { return }
                while !Task.isCancelled && self.voiceState == .responding {
                    let sampledLevel = self.elevenLabsTTSClient.currentOutputPowerLevel()
                    // Light smoothing so the orb breathes rather than jitters.
                    self.ttsAudioPowerLevel = self.ttsAudioPowerLevel * 0.55 + sampledLevel * 0.45
                    try? await Task.sleep(nanoseconds: 33_000_000) // ~30 Hz
                }
                self.ttsAudioPowerLevel = 0
            }
        } else {
            ttsMeteringTask?.cancel()
            ttsMeteringTask = nil
            ttsAudioPowerLevel = 0
        }
    }

    /// Pauses the now-playing media while Perch is mid-exchange so it doesn't
    /// compete with Perch's reply, then resumes it. Driven by `updateNowPlayingPause`.
    private let nowPlayingPauseController = NowPlayingPauseController()

    /// Pauses the user's now-playing media while Perch is mid-exchange — whether
    /// the user is talking (`.listening`), Perch is thinking (`.processing`), or
    /// Perch is speaking (`.responding`) — and resumes it once Perch returns to
    /// `.idle`. Treating the whole non-idle span as one exchange keeps the media
    /// paused across the brief `.listening → .processing → .responding`
    /// transitions instead of resuming between them. Called from
    /// `voiceState.didSet`, mirroring `updateTTSMetering`.
    private func updateNowPlayingPause(previousState: CompanionVoiceState) {
        guard voiceState != previousState else { return }

        if voiceState == .idle {
            nowPlayingPauseController.resumeNowPlayingAfterPerchVoice()
        } else {
            // Idempotent: only the first non-idle transition actually pauses.
            nowPlayingPauseController.pauseNowPlayingForPerchVoice()
        }
    }

    /// Conversation history so Claude remembers prior exchanges within a session.
    /// Each entry is the user's transcript and Claude's response.
    private var conversationHistory: [(userTranscript: String, assistantResponse: String)] = []

    /// The typed-chat thread the notch composer renders as message bubbles. This is
    /// a UI-only projection, kept parallel to (not merged with) `conversationHistory`
    /// — it holds full display text, per-message identity, a streaming flag, and
    /// attachment thumbnails. Only typed turns write here; voice never does, so the
    /// thread stays empty for spoken interactions.
    @Published private(set) var typedChatMessages: [TypedChatMessage] = []

    /// The id of the assistant bubble currently being streamed into, if any. Late
    /// chunks from a cancelled response are ignored because their id no longer matches.
    private var streamingAssistantMessageID: UUID?

    /// The currently running AI response task, if any. Cancelled when the user
    /// speaks again so a new response can begin immediately.
    private var currentResponseTask: Task<Void, Never>?

    private var shortcutTransitionCancellable: AnyCancellable?
    private var stopKeyPressedCancellable: AnyCancellable?
    private var controlDoubleTapCancellable: AnyCancellable?
    private var voiceStateCancellable: AnyCancellable?
    private var audioPowerCancellable: AnyCancellable?
    /// Observes the manager's `runs` registry to spin up per-run wiring as agents
    /// appear. Per-run state is observed separately via `runStateCancellables`.
    private var browserSubagentRunsCancellable: AnyCancellable?
    /// One state subscription per live run, keyed by subagent id, so each agent's
    /// lifecycle (triangle spawn/merge, completion wrap-up) is handled independently.
    private var runStateCancellables: [String: AnyCancellable] = [:]
    /// One connection-gate subscription per live run, keyed by subagent id. When a
    /// run needs an unconnected Composio app, this drives the connect popup(s).
    private var runConnectionRequestCancellables: [String: AnyCancellable] = [:]

    /// Owns the local browser subagent (sidecar + IPC). Background browser tasks
    /// tagged by Claude with [BACKGROUND_TASK:...] are routed here.
    let browserSubagentManager = BrowserSubagentManager()

    init() {
        // Wire the dashboard's data seam to the sidecar (read-only web/email/calendar/
        // app fetches). The dashboard view layer depends only on this protocol so it
        // previews standalone; creating/editing widgets is handled by the main agent's
        // dashboard tool family, not here.
        DashboardDataService.shared.attach(transport: browserSubagentManager)
        // The on-board "+" compose textbox routes its submit through the SAME agent a
        // spoken "add a widget" uses (one creation brain). The canvas model posts the
        // typed spec; dispatch it to the sidecar's dashboard family.
        dashboardComposeObserver = NotificationCenter.default.addObserver(
            forName: .perchDashboardComposeSubmit,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let spec = notification.userInfo?["spec"] as? String else { return }
            Task { @MainActor [weak self] in
                await self?.handleDashboardComposeSubmit(spec: spec)
            }
        }

        // When the typed composer closes (Escape / double-Control), the persistent
        // chat thread resets: clear the bubbles and stop any in-flight reply so a
        // reopened composer starts fresh.
        textInputDismissObserver = NotificationCenter.default.addObserver(
            forName: .perchTextInputDidDismiss,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.currentResponseTask?.cancel()
                self.elevenLabsTTSClient.stopPlayback()
                self.clearTypedChat()
            }
        }
    }

    /// Owns the Workflows capture pipeline (input observation → local
    /// repetition detector → proactive offer). `NotchPanelManager` observes its
    /// `currentOffer` to present the notch offer surface. See `workflows/`.
    let workflowCaptureManager = WorkflowCaptureManager(eventSource: LiveEventSource())

    /// "Show Perch once": after the user accepts an offer, records one
    /// demonstration, reads the source list, and fills the remaining rows.
    /// `NotchPanelManager` observes its `state` to drive the record surface.
    /// Lazy because it depends on `workflowCaptureManager` (pauses passive
    /// capture during a run).
    lazy var workflowRunCoordinator = WorkflowRunCoordinator(
        workflowCaptureManager: workflowCaptureManager,
        agentRunHistoryStore: agentRunHistoryStore
    )

    /// Saved "Repeat this" triggers, persisted to workflow-schedules.json.
    let workflowScheduleStore = WorkflowScheduleStore.standard()

    /// Fires due repeat-schedules through `workflowRunCoordinator`. Started in
    /// start(), stopped in stop().
    lazy var workflowScheduler = WorkflowScheduler(
        scheduleStore: workflowScheduleStore,
        workflowRunCoordinator: workflowRunCoordinator
    )

    /// Receiving side of "Send this workflow": handles perch://import URLs,
    /// fetches the shared playbook, and publishes the incoming-share offer
    /// `NotchPanelManager` renders.
    lazy var workflowShareImportCoordinator = WorkflowShareImportCoordinator(
        workflowRunCoordinator: workflowRunCoordinator
    )

    // MARK: - Integrations ("Connect [Service] to Perch?")

    /// Reads the sidecar's capability manifest to answer "is Composio available?"
    /// and "which toolkits are already connected?" without spawning the sidecar.
    /// Shared by the offer coordinator (gating) and the connect manager (polling
    /// for completion).
    let composioManifestReader = ComposioManifestReader.standard()

    /// Persists "Not now" snoozes (with a cooldown) so a declined connect offer
    /// isn't re-shown immediately, but isn't hidden forever either.
    let snoozedServicesStore = SnoozedServicesStore.standard()

    /// Persists which native integrations (Word, Excel, …) the user has enabled,
    /// so they aren't offered again once turned on.
    let enabledIntegrationsStore = EnabledIntegrationsStore.standard()

    /// Runs the connect side effect when the user accepts an offer: spawns
    /// `run.sh --connect <slug>` for Composio services, succeeds immediately for
    /// native apps.
    lazy var serviceConnectManager = ServiceConnectManager(
        manifestReader: composioManifestReader
    )

    /// Decides when the user's current window warrants a "Connect …?" offer and
    /// owns the connect lifecycle. `NotchPanelManager` observes its `currentOffer`
    /// and `connectState` to drive the offer surface.
    lazy var serviceConnectionOfferCoordinator = ServiceConnectionOfferCoordinator(
        manifestReader: composioManifestReader,
        snoozedStore: snoozedServicesStore,
        enabledStore: enabledIntegrationsStore,
        connector: serviceConnectManager
    )

    /// Backs the Home tab's "Active integrations" row: the real connected services
    /// (Composio toolkits + enabled native apps) and the "+" dropdown of connectable
    /// ones. Reuses `serviceConnectManager` so a dropdown connect runs the exact same
    /// OAuth/native flow as the proactive offer.
    lazy var activeIntegrationsStore = ActiveIntegrationsStore(
        manifestReader: composioManifestReader,
        enabledStore: enabledIntegrationsStore,
        catalog: ServiceCatalog.loadFromBundle(),
        connector: serviceConnectManager
    )

    /// Watches the frontmost window and feeds the matching catalog service (if
    /// any) to the offer coordinator each tick. Started from `NotchPanelManager`.
    lazy var serviceContextMonitor = ServiceContextMonitor(
        catalog: ServiceCatalog.loadFromBundle(),
        onMatchedService: { [weak self] matchedService in
            self?.serviceConnectionOfferCoordinator.handleContextTick(matchedService: matchedService)
        }
    )

    /// Reads macOS Focus / Do Not Disturb — notch alerts are suppressed while focused.
    let systemFocusStatusMonitor = SystemFocusStatusMonitor()

    private let dismissedNotchAlertsStore = DismissedNotchAlertsStore.standard()

    /// Policy brain for agent-driven notch alerts shown in the open-notch home row.
    lazy var notchAlertCoordinator = NotchAlertCoordinator(
        dismissedStore: dismissedNotchAlertsStore,
        evaluator: browserSubagentManager
    )

    private lazy var notchAlertIngestionService = NotchAlertIngestionService(
        coordinator: notchAlertCoordinator,
        focusMonitor: systemFocusStatusMonitor
    )

    /// Shares a persisted workflow playbook by slug: uploads it to the Worker
    /// and copies the returned share link to the clipboard. Drives the
    /// Agents-tab workflow card's "Send" action.
    func shareWorkflowPlaybook(slug: String) async throws -> WorkflowShareLink {
        let playbook = try WorkflowPlaybookStore.standard().load(slug: slug)
        let shareLink = try await WorkflowShareClient().uploadPlaybook(
            markdown: playbook.markdown, title: playbook.title
        )
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(shareLink.urlString, forType: .string)
        // Show the sender the landing page right away — the link is also on
        // the clipboard for pasting into a message.
        if let shareURL = URL(string: shareLink.urlString) {
            NSWorkspace.shared.open(shareURL)
        }
        WorkflowDebugLog.log("agents-card: share link copied — \(shareLink.urlString)")
        return shareLink
    }

    /// Republished from `browserSubagentManager` to track whether ANY background
    /// browser task is running. The main cursor no longer spins for this — the
    /// top-right agent swarm (a spinning triangle per working agent) is the
    /// working indicator.
    @Published private(set) var isBrowserSubagentWorking = false

    /// The run document for the turn currently being processed. Every input,
    /// plan, action, and spoken line for this turn is appended here. (Each background
    /// agent carries its own originating run document on its `BrowserSubagentRun`, so
    /// a late completion still lands in the turn that started it.)
    private var activeRun: PerchRunLog.RunDocument?
    /// Scheduled clear of `backgroundTaskCompletionText` so the result bubble
    /// auto-dismisses after the user has had time to read it.
    private var backgroundTaskCompletionClearTask: Task<Void, Never>?
    /// Observer for the on-board "+" compose submit, which dispatches a dashboard task
    /// to the same agent the voice `[DASHBOARD:…]` lane uses.
    private var dashboardComposeObserver: Any?
    private var textInputDismissObserver: Any?
    private var accessibilityCheckTimer: Timer?
    private var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    /// Scheduled hide for transient cursor mode — cancelled if the user
    /// speaks again before the delay elapses.
    private var transientHideTask: Task<Void, Never>?

    /// True when all three required permissions (accessibility, screen recording,
    /// microphone) are granted. Used by the panel to show a single "all good" state.
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission && hasScreenRecordingPermission && hasMicrophonePermission && hasScreenContentPermission
    }

    /// Whether the blue cursor overlay is currently visible on screen.
    /// Used by the panel to show accurate status text ("Active" vs "Ready").
    @Published private(set) var isOverlayVisible: Bool = false

    /// The Claude model used for voice responses. Persisted to UserDefaults.
    @Published var selectedModel: String = UserDefaults.standard.string(forKey: "selectedClaudeModel") ?? "claude-sonnet-4-6"

    func setSelectedModel(_ model: String) {
        selectedModel = model
        UserDefaults.standard.set(model, forKey: "selectedClaudeModel")
        claudeAPI.model = model
    }

    /// The user-selected Perch cursor color (notch panel "Cursor color"
    /// section). Drives the overlay cursor, the menu bar icon tint, and the
    /// docked cursor badge. Persisted to UserDefaults.
    @Published var cursorColor: PerchCursorColor =
        PerchCursorColor(rawValue: UserDefaults.standard.string(forKey: "perchCursorColor") ?? "") ?? .blue

    func setCursorColor(_ newCursorColor: PerchCursorColor) {
        cursorColor = newCursorColor
        UserDefaults.standard.set(newCursorColor.rawValue, forKey: "perchCursorColor")
    }

    /// Whether the cursor is "docked" — parked beside the notch house instead
    /// of following the mouse while idle (the notch panel's Dock button).
    @Published var isCursorDocked: Bool = UserDefaults.standard.bool(forKey: "perch.cursor.docked")

    func setCursorDocked(_ docked: Bool) {
        isCursorDocked = docked
        UserDefaults.standard.set(docked, forKey: "perch.cursor.docked")
    }

    /// The set of "funny" emoji the docked cursor can morph into when the user
    /// taps it. Picked from at random by `toggleFunnyCursor()`.
    static let funnyCursorEmojiChoices: [String] = [
        "🐌", "🍌", "👻", "🦀", "🚀", "💩", "🐸", "🌭",
        "👁️", "🤡", "🦆", "🐙", "🍕", "🪿", "🐳"
    ]

    /// The emoji the Perch cursor is currently wearing as a costume, or `nil`
    /// for the normal triangle. Tapping the docked cursor toggles it. Kept
    /// in-memory only (a gag that resets to the normal cursor on relaunch — not
    /// persisted like `cursorColor`).
    @Published var funnyCursorEmoji: String? = nil

    /// Tapping the docked cursor flips between a random funny emoji costume and
    /// the normal triangle.
    func toggleFunnyCursor() {
        if funnyCursorEmoji == nil {
            funnyCursorEmoji = Self.funnyCursorEmojiChoices.randomElement()
        } else {
            funnyCursorEmoji = nil
        }
    }

    /// History of completed background browser-agent runs, rendered as the
    /// colored cards in the notch panel's Agents tab.
    let agentRunHistoryStore = AgentRunHistoryStore()

    // MARK: - Live agent surface (the notch "Agents" page)
    // Convenience reads over `browserSubagentManager.runs`. Views that show these
    // must observe `browserSubagentManager` directly (it's where `runs` is
    // @Published), not just `CompanionManager`.

    /// Every agent currently doing work (spawning → handoff), newest last.
    var runningAgents: [BrowserSubagentRun] {
        browserSubagentManager.runs.filter { $0.isWorking }
    }

    /// The agent the notch features as the "now running" hero: the one that needs
    /// the user first, otherwise the most-recently-started working run.
    var primaryAgent: BrowserSubagentRun? {
        let working = runningAgents
        return working.first { $0.needsUserConfirmation } ?? working.last
    }

    /// True when at least one agent is working. (`isBrowserSubagentWorking` is the
    /// @Published mirror that drives ContentView updates; this reads the registry.)
    var isAnyAgentWorking: Bool {
        !runningAgents.isEmpty
    }

    /// The active background-agent indicators — one spinning triangle per
    /// working agent, stacked at the top-right of the notch screen. Fed by the
    /// browser-subagent lifecycle (see `bindBrowserSubagentObservation`) and
    /// rendered by the overlay's `BackgroundAgentSwarmView`.
    let backgroundAgentIndicatorStore = BackgroundAgentIndicatorStore()

    /// The notch overlay writes the main cursor's latest on-screen position
    /// here every frame; the agent swarm reads it on demand at spawn/merge so
    /// a budding/merging triangle knows where Perch currently is — without the
    /// cost of publishing the cursor position 60 times a second.
    let cursorPositionProbe = CursorPositionProbe()

    /// User preference for whether the Perch cursor should be shown.
    /// When toggled off, the overlay is hidden and push-to-talk is disabled.
    /// Persisted to UserDefaults so the choice survives app restarts.
    @Published var isPerchCursorEnabled: Bool = UserDefaults.standard.object(forKey: "isPerchCursorEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isPerchCursorEnabled")

    func setPerchCursorEnabled(_ enabled: Bool) {
        isPerchCursorEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isPerchCursorEnabled")
        transientHideTask?.cancel()
        transientHideTask = nil

        if enabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        } else {
            overlayWindowManager.hideOverlay()
            isOverlayVisible = false
        }
    }

    /// Whether the user has completed onboarding at least once. Persisted
    /// to UserDefaults so the Start button only appears on first launch.
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    /// Whether the user has submitted their email during onboarding.
    @Published var hasSubmittedEmail: Bool = UserDefaults.standard.bool(forKey: "hasSubmittedEmail")

    /// Records the user's onboarding email by linking it to this install. The
    /// email is a plain label (ownership is proven later at upgrade by Stripe);
    /// linking it lets checkout prefill and the account converge on one address.
    func submitEmail(_ email: String) {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty else { return }

        hasSubmittedEmail = true
        UserDefaults.standard.set(true, forKey: "hasSubmittedEmail")

        // Identify the user (no-op analytics shim in the notch port).
        PerchAnalytics.identify(trimmedEmail, userProperties: [
            "email": trimmedEmail
        ])

        // Link the email to this install (records installs.email on the Worker) and
        // refresh the install token / entitlement.
        Task { await PerchInstallIdentity.shared.register(emailToLink: trimmedEmail) }
    }

    /// Wires notch-alert presentation gates from the notch UI layer (open state,
    /// higher-priority surfaces). Called from `ContentView.onAppear`.
    func pollNotchAlertsOnce() async {
        await notchAlertIngestionService.pollOnce()
    }

    func configureNotchAlertPresentation(
        isNotchOpen: @escaping () -> Bool,
        isHigherPrioritySurfaceVisible: @escaping () -> Bool
    ) {
        notchAlertCoordinator.isNotchOpen = isNotchOpen
        notchAlertCoordinator.isHigherPrioritySurfaceVisible = isHigherPrioritySurfaceVisible
        notchAlertCoordinator.isVoiceActive = { [weak self] in
            self?.voiceState != .idle
        }
        notchAlertCoordinator.isFocusActive = { [weak self] in
            self?.systemFocusStatusMonitor.isFocusActive == true
        }
    }

    func start() {
        refreshAllPermissions()
        print("🔑 Perch start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), onboarded: \(hasCompletedOnboarding)")
        perchDebugLog("Perch start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), onboarded: \(hasCompletedOnboarding)")
        startPermissionPolling()
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindBrowserSubagentObservation()
        bindShortcutTransitions()
        // Repeat & Share follow-ups: begin checking saved repeat-schedules.
        workflowScheduler.start()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            self.systemFocusStatusMonitor.start()
            self.notchAlertIngestionService.start()
        }
        // Eagerly touch the Claude API so its TLS warmup handshake completes
        // well before the onboarding demo fires at ~40s into the video.
        _ = claudeAPI

        // On the first launch where the Screen Recording grant is live — however it was
        // obtained (onboarding, System Settings, or a re-grant after a signing change) —
        // do ONE throwaway direct capture. This surfaces macOS 15/26's separate "bypass
        // the private window picker" consent immediately and in-context at startup,
        // instead of ambushing the user on a later query. Runs at most once; the result
        // is discarded.
        maybeRunScreenCaptureDirectAccessWarmup()

        // If the user already completed onboarding AND all permissions are
        // still granted, show the cursor overlay immediately. If permissions
        // were revoked (e.g. signing change), don't show the cursor — the
        // panel will show the permissions UI instead.
        if hasCompletedOnboarding && allPermissionsGranted && isPerchCursorEnabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }
    }

    /// Called by BlueCursorView after the buddy finishes its pointing
    /// animation and returns to cursor-following mode.
    /// Triggers the onboarding sequence — dismisses the panel and restarts
    /// the overlay so the welcome animation and intro video play.
    func triggerOnboarding() {
        // Post notification so the panel manager can dismiss the panel
        NotificationCenter.default.post(name: .perchDismissPanel, object: nil)

        // Mark onboarding as completed so the Start button won't appear
        // again on future launches — the cursor will auto-show instead
        hasCompletedOnboarding = true

        PerchAnalytics.trackOnboardingStarted()

        // Play Besaid theme at 60% volume, fade out after 1m 30s
        startOnboardingMusic()

        // Show the overlay for the first time — isFirstAppearance triggers
        // the welcome animation and onboarding video
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    /// Replays the onboarding experience from the "Watch Onboarding Again"
    /// footer link. Same flow as triggerOnboarding but the cursor overlay
    /// is already visible so we just restart the welcome animation and video.
    func replayOnboarding() {
        NotificationCenter.default.post(name: .perchDismissPanel, object: nil)
        PerchAnalytics.trackOnboardingReplayed()
        startOnboardingMusic()
        // Tear down any existing overlays and recreate with isFirstAppearance = true
        overlayWindowManager.hasShownOverlayBefore = false
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    private func stopOnboardingMusic() {
        onboardingMusicFadeTimer?.invalidate()
        onboardingMusicFadeTimer = nil
        onboardingMusicPlayer?.stop()
        onboardingMusicPlayer = nil
    }

    private func startOnboardingMusic() {
        stopOnboardingMusic()
        guard let musicURL = Bundle.main.url(forResource: "ff", withExtension: "mp3") else {
            print("⚠️ Perch: ff.mp3 not found in bundle")
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: musicURL)
            player.volume = 0.3
            player.play()
            self.onboardingMusicPlayer = player

            // After 1m 30s, fade the music out over 3s
            onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: 90.0, repeats: false) { [weak self] _ in
                self?.fadeOutOnboardingMusic()
            }
        } catch {
            print("⚠️ Perch: Failed to play onboarding music: \(error)")
        }
    }

    private func fadeOutOnboardingMusic() {
        guard let player = onboardingMusicPlayer else { return }

        let fadeSteps = 30
        let fadeDuration: Double = 3.0
        let stepInterval = fadeDuration / Double(fadeSteps)
        let volumeDecrement = player.volume / Float(fadeSteps)
        var stepsRemaining = fadeSteps

        onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { [weak self] timer in
            stepsRemaining -= 1
            player.volume -= volumeDecrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.stop()
                self?.onboardingMusicPlayer = nil
                self?.onboardingMusicFadeTimer = nil
            }
        }
    }

    func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
    }

    func stop() {
        globalPushToTalkShortcutMonitor.stop()
        buddyDictationManager.cancelCurrentDictation()
        overlayWindowManager.hideOverlay()
        transientHideTask?.cancel()

        currentResponseTask?.cancel()
        currentResponseTask = nil
        shortcutTransitionCancellable?.cancel()
        stopKeyPressedCancellable?.cancel()
        voiceStateCancellable?.cancel()
        audioPowerCancellable?.cancel()
        browserSubagentRunsCancellable?.cancel()
        runStateCancellables.values.forEach { $0.cancel() }
        runStateCancellables.removeAll()
        runConnectionRequestCancellables.values.forEach { $0.cancel() }
        runConnectionRequestCancellables.removeAll()
        browserSubagentManager.shutdown()
        notchAlertIngestionService.stop()
        systemFocusStatusMonitor.stop()
        workflowScheduler.stop()
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil
    }

    func refreshAllPermissions() {
        let previouslyHadAccessibility = hasAccessibilityPermission
        let previouslyHadScreenRecording = hasScreenRecordingPermission
        let previouslyHadMicrophone = hasMicrophonePermission
        let previouslyHadAll = allPermissionsGranted

        let currentlyHasAccessibility = WindowPositionManager.hasAccessibilityPermission()
        hasAccessibilityPermission = currentlyHasAccessibility

        if currentlyHasAccessibility {
            globalPushToTalkShortcutMonitor.start()
        } else {
            globalPushToTalkShortcutMonitor.stop()
        }

        hasScreenRecordingPermission = WindowPositionManager.hasScreenRecordingPermission()

        let micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        hasMicrophonePermission = micAuthStatus == .authorized

        // Debug: log permission state on changes
        if previouslyHadAccessibility != hasAccessibilityPermission
            || previouslyHadScreenRecording != hasScreenRecordingPermission
            || previouslyHadMicrophone != hasMicrophonePermission {
            print("🔑 Permissions — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission)")
            perchDebugLog("permissions changed — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission)")
        }

        // Track individual permission grants as they happen
        if !previouslyHadAccessibility && hasAccessibilityPermission {
            PerchAnalytics.trackPermissionGranted(permission: "accessibility")
        }
        if !previouslyHadScreenRecording && hasScreenRecordingPermission {
            PerchAnalytics.trackPermissionGranted(permission: "screen_recording")
        }
        if !previouslyHadMicrophone && hasMicrophonePermission {
            PerchAnalytics.trackPermissionGranted(permission: "microphone")
        }
        // Screen content permission is persisted — once the user has approved the
        // SCShareableContent picker, we don't need to re-check it.
        if !hasScreenContentPermission {
            hasScreenContentPermission = UserDefaults.standard.bool(forKey: "hasScreenContentPermission")
        }

        if !previouslyHadAll && allPermissionsGranted {
            PerchAnalytics.trackAllPermissionsGranted()
        }
    }

    /// Triggers the macOS screen content picker by performing a dummy
    /// screenshot capture. Once the user approves, we persist the grant
    /// so they're never asked again during onboarding.
    @Published private(set) var isRequestingScreenContent = false

    func requestScreenContentPermission() {
        guard !isRequestingScreenContent else { return }
        isRequestingScreenContent = true
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    await MainActor.run { isRequestingScreenContent = false }
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 320
                config.height = 240
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                // Verify the capture actually returned real content — a 0x0 or
                // fully-empty image means the user denied the prompt.
                let didCapture = image.width > 0 && image.height > 0
                print("🔑 Screen content capture result — width: \(image.width), height: \(image.height), didCapture: \(didCapture)")
                await MainActor.run {
                    isRequestingScreenContent = false
                    guard didCapture else { return }
                    hasScreenContentPermission = true
                    UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")
                    PerchAnalytics.trackPermissionGranted(permission: "screen_content")

                    // If onboarding was already completed, show the cursor overlay now
                    if hasCompletedOnboarding && allPermissionsGranted && !isOverlayVisible && isPerchCursorEnabled {
                        overlayWindowManager.hasShownOverlayBefore = true
                        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                        isOverlayVisible = true
                    }
                }
            } catch {
                print("⚠️ Screen content permission request failed: \(error)")
                await MainActor.run { isRequestingScreenContent = false }
            }
        }
    }

    // MARK: - Private

    /// Triggers the system microphone prompt if the user has never been asked.
    /// Once granted/denied the status sticks and polling picks it up.
    private func promptForMicrophoneIfNotDetermined() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor [weak self] in
                self?.hasMicrophonePermission = granted
            }
        }
    }

    /// Polls all permissions frequently so the UI updates live after the
    /// user grants them in System Settings. Screen Recording is the exception —
    /// macOS requires an app restart for that one to take effect.
    private func startPermissionPolling() {
        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }
    }

    private func bindAudioPowerLevel() {
        audioPowerCancellable = buddyDictationManager.$currentAudioPowerLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] powerLevel in
                self?.currentAudioPowerLevel = powerLevel
            }
    }

    /// Observes the browser-subagent registry so each concurrent agent gets its own
    /// swarm triangle, preview panel, and completion wrap-up. As runs appear, a
    /// per-run state subscription is attached; finished runs merge away and are
    /// pruned. Replaces the old single-run observation.
    private func bindBrowserSubagentObservation() {
        browserSubagentRunsCancellable = browserSubagentManager.$runs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] runs in
                self?.synchronizeBrowserSubagentRunSubscriptions(runs)
            }
    }

    /// Ensures every live run has exactly one state subscription (and on first sight,
    /// its triangle + preview panel). Idempotent — safe to call on every `runs` change.
    private func synchronizeBrowserSubagentRunSubscriptions(_ runs: [BrowserSubagentRun]) {
        for newRun in runs where runStateCancellables[newRun.id] == nil {
            beginObservingBrowserSubagentRun(newRun)
        }
    }

    /// Wires up a newly spawned run by subscribing to its lifecycle. The run's live
    /// presence now lives in the notch's "Agents" page (closed live-activity chip +
    /// open hero), not the old top-right triangle swarm + hover preview panel.
    private func beginObservingBrowserSubagentRun(_ newRun: BrowserSubagentRun) {
        runStateCancellables[newRun.id] = newRun.$subagentState
            // The sidecar reports completion via TWO events — a `.state("done")` AND a
            // dedicated `.done(...)`, each assigning `.done`. De-dupe so completion side
            // effects (the spoken wrap-up) fire exactly once.
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak newRun] newState in
                guard let self, let newRun else { return }
                self.handleBrowserSubagentRunStateChange(run: newRun, newState: newState)
            }

        // Drive the connect popup(s) when this run pauses at a connection gate.
        runConnectionRequestCancellables[newRun.id] = newRun.$pendingConnectionRequest
            .removeDuplicates { $0 == $1 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak newRun] toolkitSlugs in
                guard let self, let newRun,
                      let toolkitSlugs, !toolkitSlugs.isEmpty else { return }
                self.handleBrowserSubagentConnectionRequest(
                    run: newRun, toolkitSlugs: toolkitSlugs
                )
            }
    }

    /// A run paused at a connection gate: show the connect popup for each needed
    /// toolkit in turn, then tell the sidecar we're done. The sidecar re-queries the
    /// live connected set, so a toolkit the user declined simply stays unconnected
    /// and that step falls back to the web lane — no per-toolkit reporting needed.
    private func handleBrowserSubagentConnectionRequest(
        run: BrowserSubagentRun, toolkitSlugs: [String]
    ) {
        let subagentId = run.id
        let catalog = ServiceCatalog.loadFromBundle()
        Task { @MainActor [weak self] in
            guard let self else { return }
            for toolkitSlug in toolkitSlugs {
                let entry = catalog.composioEntry(forToolkitSlug: toolkitSlug)
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    self.serviceConnectionOfferCoordinator.presentAgentConnectionRequest(
                        for: entry
                    ) { _ in
                        continuation.resume()
                    }
                }
            }
            await self.browserSubagentManager.completeConnectionRequest(subagentId: subagentId)
        }
    }

    /// Handles one run's state transition: keeps the aggregate working flag current,
    /// and on a terminal state merges the triangle away, announces completion, and
    /// prunes the run.
    private func handleBrowserSubagentRunStateChange(
        run finishedOrWorkingRun: BrowserSubagentRun,
        newState: BrowserSubagentState
    ) {
        isBrowserSubagentWorking = browserSubagentManager.runs.contains { $0.isWorking }

        guard finishedOrWorkingRun.isTerminal else { return }

        // Only a successful run speaks a wrap-up and is recorded in history.
        if newState == .done {
            // Surface the result the user can actually see: the browser sidecar runs an
            // isolated/headless Chromium, so without this the finished page never
            // appears on screen and the task reads as "nothing happened". Open the
            // deliverable in the user's real Chrome window.
            openDeliverableInBrowserIfAvailable(for: finishedOrWorkingRun)
            announceBackgroundTaskCompletion(for: finishedOrWorkingRun)
        }

        // Drop this run's subscription and remove it from the registry.
        let finishedSubagentId = finishedOrWorkingRun.id
        runStateCancellables[finishedSubagentId]?.cancel()
        runStateCancellables[finishedSubagentId] = nil
        runConnectionRequestCancellables[finishedSubagentId]?.cancel()
        runConnectionRequestCancellables[finishedSubagentId] = nil
        browserSubagentManager.discardRun(finishedSubagentId)
    }

    private func bindVoiceStateObservation() {
        voiceStateCancellable = buddyDictationManager.$isRecordingFromKeyboardShortcut
            .combineLatest(
                buddyDictationManager.$isFinalizingTranscript,
                buddyDictationManager.$isPreparingToRecord
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording, isFinalizing, isPreparing in
                guard let self else { return }
                // Don't override .responding — the AI response pipeline
                // manages that state directly until streaming finishes.
                guard self.voiceState != .responding else { return }

                if isFinalizing {
                    self.voiceState = .processing
                } else if isRecording {
                    self.voiceState = .listening
                } else if isPreparing {
                    self.voiceState = .processing
                } else {
                    self.voiceState = .idle
                    // If the user pressed and released the hotkey without
                    // saying anything, no response task runs — schedule the
                    // transient hide here so the overlay doesn't get stuck.
                    // Only do this when no response is in flight, otherwise
                    // the brief idle gap between recording and processing
                    // would prematurely hide the overlay.
                    if self.currentResponseTask == nil {
                        self.scheduleTransientHideIfNeeded()
                    }
                }
            }
    }

    private func bindShortcutTransitions() {
        shortcutTransitionCancellable = globalPushToTalkShortcutMonitor
            .shortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleShortcutTransition(transition)
            }

        stopKeyPressedCancellable = globalPushToTalkShortcutMonitor
            .stopKeyPressedPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.handleStopKeyPressed()
            }

        controlDoubleTapCancellable = globalPushToTalkShortcutMonitor
            .controlDoubleTapPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                // Opening a text box is low-risk and must be exactly as available
                // as push-to-talk, which only refuses while the onboarding video is
                // playing. In particular do NOT gate on `allPermissionsGranted`
                // (screen/mic grants matter at SEND time, not to pop the composer)
                // or `hasCompletedOnboarding` (false on this build for users who
                // never ran the formal onboarding) — both silently swallowed the
                // trigger.
                guard let self, !self.showOnboardingVideo else { return }
                // The composer owns its own show/hide state; a second double-tap
                // toggles it back off. Activation posts `.perchShowTextInput`,
                // which the AppDelegate uses to grant the notch window key focus.
                NotchTextInputController.shared.toggle()
            }
    }

    /// Pressing Escape stops Perch talking right now: it cancels any in-flight
    /// Claude response, halts TTS playback, clears any pending pointing, and
    /// returns the cursor to idle. A no-op if Perch isn't currently busy.
    private func handleStopKeyPressed() {
        // Escape first closes the typed-input composer if it's open. The global
        // CGEvent tap sees Escape regardless of SwiftUI focus, so this is the
        // reliable dismiss path (the in-view `.onExitCommand` gets swallowed by
        // the focused text field).
        if NotchTextInputController.shared.isActive {
            NotchTextInputController.shared.dismiss()
            return
        }
        currentResponseTask?.cancel()
        currentResponseTask = nil
        elevenLabsTTSClient.stopPlayback()
        clearDetectedElementLocation()
        voiceState = .idle
    }

    private func handleShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            guard !buddyDictationManager.isDictationInProgress else { return }
            // Don't register push-to-talk while the onboarding video is playing
            guard !showOnboardingVideo else { return }

            // Cancel any pending transient hide so the overlay stays visible
            transientHideTask?.cancel()
            transientHideTask = nil

            // If the cursor is hidden, bring it back transiently for this interaction
            if !isPerchCursorEnabled && !isOverlayVisible {
                overlayWindowManager.hasShownOverlayBefore = true
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }

            // Dismiss the menu bar panel so it doesn't cover the screen
            NotificationCenter.default.post(name: .perchDismissPanel, object: nil)

            // Cancel any in-progress response and TTS from a previous utterance
            currentResponseTask?.cancel()
            elevenLabsTTSClient.stopPlayback()
            clearDetectedElementLocation()

            // Dismiss the onboarding prompt if it's showing
            if showOnboardingPrompt {
                withAnimation(.easeOut(duration: 0.3)) {
                    onboardingPromptOpacity = 0.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self.showOnboardingPrompt = false
                    self.onboardingPromptText = ""
                }
            }
    

            PerchAnalytics.trackPushToTalkStarted()

            // Clear any prior live transcription so this utterance starts fresh.
            liveTranscriptionText = ""

            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = Task {
                await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                    currentDraftText: "",
                    updateDraftText: { [weak self] partialTranscript in
                        // Stream the live partial transcript onto the cursor overlay
                        // so the user watches their words appear as they speak.
                        self?.liveTranscriptionText = partialTranscript
                    },
                    submitDraftText: { [weak self] finalTranscript in
                        self?.lastTranscript = finalTranscript
                        print("🗣️ Companion received transcript: \(finalTranscript)")
                        PerchAnalytics.trackUserMessageSent(transcript: finalTranscript)
                        self?.sendTranscriptToClaudeWithScreenshot(transcript: finalTranscript, inputKind: "voice")
                    }
                )
            }
        case .released:
            // Cancel the pending start task in case the user released the shortcut
            // before the async startPushToTalk had a chance to begin recording.
            // Without this, a quick press-and-release drops the release event and
            // leaves the waveform overlay stuck on screen indefinitely.
            PerchAnalytics.trackPushToTalkReleased()
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = nil
            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
        case .none:
            break
        }
    }

    // MARK: - Companion Prompt

    private static let companionVoiceResponseSystemPrompt = """
    you're perch, a friendly always-on companion that lives in the user's menu bar. the user just spoke to you via push-to-talk and you can see their screen(s). your reply will be spoken aloud via text-to-speech, so write the way you'd actually talk. this is an ongoing conversation — you remember everything they've said before.

    rules:
    - keep every reply to ONE short sentence — ideally around five words. be super duper brief. never go longer, even if asked to elaborate.
    - all lowercase, casual, and SUPER enthusiastic — like a hyped-up friend who's thrilled to help. no emojis.
    - write for the ear, not the eye. short sentences. no lists, bullet points, markdown, or formatting — just natural speech.
    - don't use abbreviations or symbols that sound weird read aloud. write "for example" not "e.g.", spell out small numbers.
    - if the user's question relates to what's on their screen, reference specific things you see.
    - if the screenshot doesn't seem relevant to their question, just answer the question directly.
    - you can help with anything — coding, writing, general knowledge, brainstorming.
    - never say "simply" or "just".
    - don't read out code verbatim. describe what the code does or what needs to change conversationally.
    - stay brief above all else — one punchy, enthusiastic sentence beats a thorough one. don't pad, don't explain more than asked.
    - if you receive multiple screen images, the one labeled "primary focus" is where the cursor is — prioritize that one but reference others if relevant.

    intent — decide this FIRST, before you write anything:
    the single most important question on every message is: what does the user want to be TRUE right after you respond? reason about their actual goal — do NOT pattern-match on keywords. the same verb can go either way: "show me how to create a table" wants knowledge (SHOW); "create a table here" wants the table to exist (DO). there are three lanes:

    - DO: they want the world or their screen to be CHANGED — something created, typed, entered, sent, opened, renamed, moved, filled in, bought. go actually do it with a background task (see below). do NOT just point at where they'd do it themselves.
    - SHOW: they want to KNOW or SEE something — understand it, find it, learn where/what/how. answer them and, if a specific on-screen element is relevant, point at it with [POINT:...]. do NOT touch, type, or click anything.
    - CLARIFY: you genuinely cannot tell DO from SHOW, OR it's clearly a DO but you'd have to guess a detail that matters (which target, what value, or something hard to undo). ask ONE short question instead of guessing (see below).

    important: words like "here", "this cell", "this file", "this email" tell you WHERE to act — they do NOT mean "just point". "type hi in this cell" is a DO at that cell, not a request to point at it.

    don't over-clarify: if it's clearly a DO and a sensible default is obvious, just do it — only CLARIFY for real ambiguity or a guess you shouldn't make on the user's behalf.

    element pointing (SHOW lane only):
    you have a small blue triangle cursor that can fly to and point at things on screen. once you've decided the lane is SHOW, use it whenever pointing would genuinely help — if they're asking how to do something, looking for a menu, trying to find a button, or need help navigating an app, point at the relevant element. within the SHOW lane, err on the side of pointing rather than not, because it makes your help way more useful and concrete.

    don't point when it would be pointless — like a general knowledge question, a conversation with nothing to do with what's on screen, or something obvious they're already looking at. but if there's a specific UI element, menu, button, or area on screen that's relevant, point at it.

    when you point, append a coordinate tag at the very end of your response, AFTER your spoken text. the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. the origin (0,0) is the top-left corner of the image. x increases rightward, y increases downward.

    format: [POINT:x,y:label] where x,y are integer pixel coordinates in the screenshot's coordinate space, and label is a short 1-3 word description of the element (like "search bar" or "save button"). if the element is on the cursor's screen you can omit the screen number. if the element is on a DIFFERENT screen, append :screenN where N is the screen number from the image label (e.g. :screen2). this is important — without the screen number, the cursor will point at the wrong place.

    if pointing wouldn't help, append [POINT:none].

    examples:
    - user asks how to color grade in final cut: "ooh, hit the color inspector! [POINT:1100,42:color inspector]"
    - user asks what html is: "it's the skeleton of webpages! [POINT:none]"
    - user asks how to commit in xcode: "yes! click source control up top! [POINT:285,11:source control]"
    - element is on screen 2 (not where cursor is): "it's on your other monitor! [POINT:400,300:terminal:screen2]"
    - user (show, not do): "show me where to add a formula in excel": "right up top in the formula bar! [POINT:600,80:formula bar]"

    background do-it-for-me tasks (DO lane):
    when the lane is DO, the user wants you to GO DO something for them. this works whether the task lives in a web browser (e.g. "sign up for the newsletter on this site", "book the cheapest flight to NYC next friday"), in a native mac app they're looking at (e.g. "type my name in this excel cell", "rename this file in finder", "reply to this email"), or in a connected app. you hand it to a background agent that drives it to completion while the user keeps working — so do NOT also point at anything.

    end your response with a tag on its own at the very end: [BACKGROUND_TASK:<concise task description>]. include enough context for the agent to act (which app, which cell/file/element, what value). keep your spoken text to a short, natural confirmation BEFORE the tag — do not narrate steps. do NOT include a [POINT:...] tag when you include a [BACKGROUND_TASK:...] tag.

    examples:
    - user: "can you sign up for the newsletter on this page": "on it, handling that now! [BACKGROUND_TASK:sign up for the newsletter shown on the current page]"
    - user: "make me a figma file with a simple landing page mockup": "love it, mocking it up! [BACKGROUND_TASK:create a new figma file and design a simple landing page mockup]"
    - user: "type my name in this excel cell": "on it, typing that now! [BACKGROUND_TASK:type the user's name into the currently selected excel cell]"
    - user: "put 42 in the cell below": "done, dropping it in! [BACKGROUND_TASK:enter the value 42 in the excel cell directly below the currently selected cell]"
    - user: "create a new table here and just write hi there": "on it, building that table! [BACKGROUND_TASK:in the frontmost spreadsheet, starting at the selected cell, create a small table and enter the text \"hi there\"]"

    dashboard widgets (a special DO):
    you have your OWN daily dashboard — a board of live widgets (news, weather, email, calendar, github, and more). when the user asks you to ADD, CREATE, PUT, CHANGE, EDIT, or REMOVE a widget on "my dashboard" / "the dashboard", that is NOT a browser task — your dashboard handles it from the connected apps. end your response with a tag on its own at the very end: [DASHBOARD:<plain-english request — what to add, or how to change a widget>]. describe the data or the change, not the steps. keep your spoken text to a short confirmation BEFORE the tag, and do NOT include a [POINT:...] or [BACKGROUND_TASK:...] tag. only use this for YOUR dashboard — a request about some other app's dashboard on screen is still a [BACKGROUND_TASK:...].

    examples:
    - user: "add a widget to my dashboard for my top github repos": "on it, adding that! [DASHBOARD:add a widget for my top GitHub repositories]"
    - user: "put a widget on the dashboard with today's top tech news": "love it, pinning that up! [DASHBOARD:add a widget with today's top technology news]"
    - user: "change my news widget to only cnn": "you got it, switching it! [DASHBOARD:change my news widget to only source from CNN]"

    clarify questions (CLARIFY lane):
    when you truly can't tell what the user wants, ask ONE short question instead of guessing or half-doing it. end your response with a tag on its own at the very end: [CLARIFY:<one short question>]. the question is the only thing you say — keep it to one natural sentence, and do NOT include a [POINT:...] or [BACKGROUND_TASK:...] tag.

    examples:
    - user (ambiguous do/show): "can you do something with the s&p returns here": "[CLARIFY:want me to pull the numbers in myself, or did you have specific figures to use?]"
    - user (missing target): "rename this for me": "[CLARIFY:sure — what should i rename it to?]"
    """

    /// Text-only sibling of `companionVoiceResponseSystemPrompt`, used when the
    /// vision gate decides this turn does NOT need the screen (served by the fast
    /// Cerebras backend). Same persona and brevity rules, but there is no
    /// screenshot this turn — so it never points and never references the screen.
    /// DO (background task) and CLARIFY still work; SHOW just answers directly.
    private static let companionTextOnlyResponseSystemPrompt = """
    you're perch, a friendly always-on companion that lives in the user's menu bar. the user just spoke or typed to you, and this turn you are answering WITHOUT looking at their screen (no screenshot is available). your reply will be spoken aloud via text-to-speech, so write the way you'd actually talk. this is an ongoing conversation — you remember everything they've said before.

    rules:
    - keep every reply to ONE short sentence — ideally around five words. be super duper brief. never go longer, even if asked to elaborate.
    - all lowercase, casual, and SUPER enthusiastic — like a hyped-up friend who's thrilled to help. no emojis.
    - write for the ear, not the eye. short sentences. no lists, bullet points, markdown, or formatting — just natural speech.
    - don't use abbreviations or symbols that sound weird read aloud. write "for example" not "e.g.", spell out small numbers.
    - you have NO screenshot this turn, so never reference what's "on screen" and never claim to see anything. just answer from your own knowledge.
    - you can help with anything — coding, writing, general knowledge, brainstorming.
    - never say "simply" or "just".
    - don't read out code verbatim. describe what the code does or what needs to change conversationally.
    - stay brief above all else — one punchy, enthusiastic sentence beats a thorough one. don't pad, don't explain more than asked.
    - never emit a [POINT:...] tag — there's nothing to point at without a screenshot.

    intent — decide this FIRST, before you write anything: what does the user want to be TRUE right after you respond? reason about their actual goal, do NOT pattern-match on keywords. two lanes apply here:

    - DO: they want something CHANGED or done for them — created, typed, sent, opened, booked, signed up. hand it to a background agent (see below). do NOT narrate steps.
    - SHOW: they want to KNOW something — understand, learn, or get an answer. just answer them in one short enthusiastic sentence.
    - CLARIFY: only if you genuinely can't tell what they want, or a DO needs a detail you shouldn't guess. ask ONE short question.

    background do-it-for-me tasks (DO lane):
    when the lane is DO, hand it to a background agent that drives it to completion while the user keeps working. end your response with a tag on its own at the very end: [BACKGROUND_TASK:<concise task description>]. include enough context for the agent to act (which app or site, what value). keep your spoken text to a short, natural confirmation BEFORE the tag.

    examples:
    - user: "book the cheapest flight to nyc next friday": "on it, finding that flight! [BACKGROUND_TASK:book the cheapest flight to NYC for next Friday]"
    - user: "sign me up for the openai newsletter": "love it, signing you up! [BACKGROUND_TASK:sign up for the OpenAI newsletter]"

    dashboard widgets (a special DO):
    you have your OWN daily dashboard — a board of live widgets (news, weather, email, calendar, github, and more). when the user asks you to ADD, CREATE, PUT, CHANGE, EDIT, or REMOVE a widget on "my dashboard" / "the dashboard", that is NOT a browser task — your dashboard handles it from the connected apps. end your response with a tag on its own at the very end: [DASHBOARD:<plain-english request — what to add, or how to change a widget>]. describe the data or the change, not the steps. keep your spoken text to a short confirmation BEFORE the tag, and do NOT include a [BACKGROUND_TASK:...] tag.

    examples:
    - user: "add a widget to my dashboard for my top github repos": "on it, adding that! [DASHBOARD:add a widget for my top GitHub repositories]"
    - user: "change my news widget to only cnn": "you got it, switching it! [DASHBOARD:change my news widget to only source from CNN]"

    clarify questions (CLARIFY lane):
    when you truly can't tell what the user wants, ask ONE short question instead of guessing. end your response with a tag on its own at the very end: [CLARIFY:<one short question>]. the question is the only thing you say — keep it to one natural sentence, and do NOT include a [BACKGROUND_TASK:...] tag.

    examples:
    - user (missing target): "book me a flight": "[CLARIFY:sure — where to, and what day?]"
    """

    /// A system-prompt suffix that tells the intent gate which apps the user has
    /// connected, so a question about THEIR data in a connected app routes to a DO
    /// background task (which reaches that data through the app's API) instead of the
    /// model declining with "i can't see your github". Returns "" when nothing is
    /// connected, leaving the base prompt unchanged.
    ///
    /// The connected toolkits come from the sidecar's capability manifest (read here
    /// without spawning the sidecar) — so this stays correct as the user connects or
    /// disconnects apps, with no per-service hardcoding.
    private func connectedAccountsPromptClause() -> String {
        let connectedSlugs = composioManifestReader.currentState().connectedToolkitSlugs
        guard !connectedSlugs.isEmpty else { return "" }
        let appList = connectedSlugs.sorted().joined(separator: ", ")
        return """


        connected accounts — the user has connected these apps to perch, and a background agent can act on their REAL data in them through each app's API (no screen needed): \(appList).
        - when the user asks about THEIR data in one of these apps (how many, list, find, look up, check, who/what/when, or any change), that is a DO task: hand it to the background agent, which calls the app's API and reports back — even though you have no screenshot this turn. give a short confirmation then the [BACKGROUND_TASK:...] tag.
        - NEVER tell the user you can't see or access one of these connected accounts — you CAN, through the background agent. route it to DO instead of declining.
        - example — user: "how many repos do i have on github" (github connected): "on it, checking your github! [BACKGROUND_TASK:count how many repositories the user owns on their connected GitHub account]"
        """
    }

    // MARK: - AI Response Pipeline

    /// Sends a typed message to Perch — the text-input equivalent of holding
    /// push-to-talk and speaking. Runs the exact same pipeline (screenshot →
    /// Claude → spoken reply → pointing / background task), so typing and
    /// talking are interchangeable. Called from the menu bar panel's text field.
    func sendTypedMessage(_ text: String) {
        sendTypedMessage(text, attachments: [])
    }

    /// Typed message from the notch composer, optionally carrying image
    /// attachments. Images ride the vision path alongside (or in place of) the
    /// screen capture so Perch reasons about exactly what the user attached.
    func sendTypedMessage(_ text: String, attachments: [NotchTextInputAttachment]) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Allow an image-only send (no text) — the attachments carry the request.
        guard !trimmedText.isEmpty || !attachments.isEmpty else { return }

        // Pre-label the attachment images so the send path never touches image work.
        let attachmentImages: [(data: Data, label: String)] = attachments.enumerated().map { index, attachment in
            (data: attachment.jpegData, label: "User attachment \(index + 1): \(attachment.fileName)")
        }

        // Keep the overlay up for this interaction.
        transientHideTask?.cancel()
        transientHideTask = nil

        // Bring the cursor overlay back if it's hidden (transient / "Show Perch" off).
        if !isOverlayVisible {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }

        // Dismiss the menu bar panel so it isn't captured in the screenshot or
        // left covering whatever Perch might point at.
        NotificationCenter.default.post(name: .perchDismissPanel, object: nil)

        // Cancel any in-flight response and TTS from a previous message.
        currentResponseTask?.cancel()
        elevenLabsTTSClient.stopPlayback()
        clearDetectedElementLocation()

        // When the user attaches images without typing anything, give the model a
        // minimal instruction so the prompt is never empty.
        let effectiveTranscript = trimmedText.isEmpty
            ? "Take a look at the attached image\(attachments.count == 1 ? "" : "s")."
            : trimmedText

        lastTranscript = effectiveTranscript
        print("⌨️ Companion received typed message: \(effectiveTranscript) [\(attachments.count) attachment(s)]")
        PerchAnalytics.trackUserMessageSent(transcript: effectiveTranscript)

        // If a previous reply is still streaming when the user fires a rapid
        // follow-up, freeze it at its current partial text so the thread stays
        // coherent before the new bubbles are appended.
        if let stillStreaming = typedChatMessages.last, stillStreaming.isStreaming {
            finalizeStreamingAssistant(finalText: stillStreaming.text)
        }

        // Render the exchange as bubbles: the user's message, then an empty
        // streaming assistant bubble whose "thinking" dots cover the 0.25s delay
        // plus the vision-gate and first-token latency.
        appendTypedUserMessage(text: effectiveTranscript, thumbnails: attachments.map(\.thumbnail))
        beginTypedAssistantStreamingMessage()

        // Give the panel a beat to disappear before the screenshot is captured
        // so it doesn't end up in the image Perch reasons about.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.sendTranscriptToClaudeWithScreenshot(
                transcript: effectiveTranscript,
                inputKind: "typed",
                userAttachmentImages: attachmentImages
            )
        }
    }

    /// Captures a screenshot, sends it along with the transcript to Claude,
    /// and plays the response aloud via ElevenLabs TTS. The cursor stays in
    /// the spinner/processing state until TTS audio begins playing.
    /// Claude's response may include a [POINT:x,y:label] tag which triggers
    /// the buddy to fly to that element on screen.
    private func sendTranscriptToClaudeWithScreenshot(
        transcript: String,
        inputKind: String,
        userAttachmentImages: [(data: Data, label: String)] = []
    ) {
        currentResponseTask?.cancel()
        elevenLabsTTSClient.stopPlayback()

        // Open a fresh per-run document for this turn. Every input, plan, action,
        // and spoken line below is appended to it; the master index gets one
        // summary line linking back to it.
        let run = PerchRunLog.beginRun(inputKind: inputKind, input: transcript)
        activeRun = run
        PerchRunLog.append(run, .input, "\(inputKind) input: \(transcript)")
        currentResponseTask = Task {
            // Voice turns show the processing spinner; typed turns stay idle (no orb,
            // no media pause) — their feedback is the streaming bubble instead.
            if inputKind != "typed" {
                voiceState = .processing
            }

            do {
                // Pass conversation history so the model remembers prior exchanges.
                let historyForAPI = conversationHistory.map { entry in
                    (userPlaceholder: entry.userTranscript, assistantResponse: entry.assistantResponse)
                }
                let conversationHistoryDump = historyForAPI.enumerated().map { index, exchange in
                    "[\(index)] user: \(exchange.userPlaceholder)\n    assistant: \(exchange.assistantResponse)"
                }.joined(separator: "\n")

                // Vision gate: decide whether this turn needs to see the screen.
                // `.always` (or an unconfigured Cerebras key) keeps the original
                // always-capture behavior; otherwise a fast Cerebras text-only
                // classifier decides. A "no" routes the whole answer through the
                // text-only Cerebras path and never captures a screenshot.
                let needsScreen: Bool
                if !PerchCapabilityToggles.isEyesEnabledNow() {
                    // Eyes is turned off in the menu → Perch never captures the
                    // screen this turn, regardless of what the vision gate would
                    // have decided. The answer routes through the text-only path.
                    needsScreen = false
                } else if VisionGateConfiguration.mode == .always || !CerebrasConfiguration.isConfigured {
                    needsScreen = true
                } else {
                    needsScreen = await CerebrasClient.shared.classifyNeedsScreen(
                        transcript: transcript,
                        recentHistory: historyForAPI
                    )
                }

                // User-attached images must reach the model regardless of the gate.
                // When the user attached something but the gate decided the screen
                // isn't needed, route through the image path carrying just the
                // attachments (no screenshot).
                let hasUserAttachments = !userAttachmentImages.isEmpty
                let useImagePath = needsScreen || hasUserAttachments

                guard !Task.isCancelled else { return }

                // Make the intent gate aware of the user's connected accounts, so a
                // question about THEIR data in a connected app (e.g. "how many repos
                // do I have on GitHub") routes to a DO background task — which reaches
                // that data through the app's API — instead of being declined with
                // "i can't see your github". Empty when nothing is connected, leaving
                // the base prompt unchanged.
                let connectedAccountsClause = connectedAccountsPromptClause()
                let voiceSystemPrompt =
                    Self.companionVoiceResponseSystemPrompt + connectedAccountsClause
                let textOnlySystemPrompt =
                    Self.companionTextOnlyResponseSystemPrompt + connectedAccountsClause

                // Both branches converge on `fullResponseText` (and `screenCaptures`,
                // empty on the text-only path) so the downstream Intent-Gate /
                // pointing / TTS pipeline is identical.
                let fullResponseText: String
                let screenCaptures: [CompanionScreenCapture]

                if useImagePath {
                    // ===== Vision path: user attachments + (optionally) screens =====
                    // Capture the screen only when the gate asked for it; an
                    // attachment-only turn skips the screenshot entirely.
                    let captures: [CompanionScreenCapture]
                    if needsScreen {
                        captures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
                        PerchRunLog.append(run, .plan, "vision gate → screen NEEDED; captured \(captures.count) screen(s)")
                    } else {
                        captures = []
                        PerchRunLog.append(run, .plan, "vision gate → screen NOT needed; sending \(userAttachmentImages.count) user attachment(s) only")
                    }

                    guard !Task.isCancelled else { return }
                    screenCaptures = captures

                    // Build image labels with the actual screenshot pixel dimensions
                    // so Claude's coordinate space matches the image it sees. We
                    // scale from screenshot pixels to display points ourselves.
                    let screenLabeledImages = captures.map { capture in
                        let dimensionInfo = " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
                        return (data: capture.imageData, label: capture.label + dimensionInfo)
                    }

                    // User attachments come first so the model treats them as the
                    // subject of the request, with the screen (if any) as context.
                    let labeledImages = userAttachmentImages + screenLabeledImages

                    // Log the FULL context handed to Claude — verbatim.
                    PerchRunLog.append(
                        run, .plan,
                        "sending to claude — \(labeledImages.count) image(s): "
                            + labeledImages.map { $0.label }.joined(separator: " | ")
                    )
                    PerchRunLog.appendBlock(
                        run, .plan, "system prompt sent to claude",
                        body: voiceSystemPrompt
                    )
                    PerchRunLog.appendBlock(
                        run, .plan, "conversation history sent to claude (\(historyForAPI.count) exchange(s))",
                        body: conversationHistoryDump.isEmpty ? "(none)" : conversationHistoryDump
                    )
                    PerchRunLog.appendBlock(run, .plan, "user prompt sent to claude", body: transcript)

                    let (responseText, _) = try await claudeAPI.analyzeImageStreaming(
                        images: labeledImages,
                        systemPrompt: voiceSystemPrompt,
                        conversationHistory: historyForAPI,
                        userPrompt: transcript,
                        // Tags this turn as a billable "message" (voice or text) so it
                        // counts toward the free-tier cap at the Worker.
                        feature: "companion",
                        onTextChunk: { [weak self] accumulated in
                            // Stream into the typed-chat bubble for typed turns; voice
                            // stays spinner-only until TTS plays.
                            guard inputKind == "typed" else { return }
                            self?.updateStreamingAssistant(accumulatedText: accumulated)
                        }
                    )
                    fullResponseText = responseText
                } else {
                    // ===== Text-only path: no screenshot → Cerebras =====
                    screenCaptures = []
                    PerchRunLog.append(
                        run, .plan,
                        "vision gate → screen NOT needed; Cerebras text path (\(CerebrasConfiguration.model))"
                    )
                    PerchRunLog.appendBlock(
                        run, .plan, "system prompt sent to cerebras",
                        body: textOnlySystemPrompt
                    )
                    PerchRunLog.appendBlock(
                        run, .plan, "conversation history sent to cerebras (\(historyForAPI.count) exchange(s))",
                        body: conversationHistoryDump.isEmpty ? "(none)" : conversationHistoryDump
                    )
                    PerchRunLog.appendBlock(run, .plan, "user prompt sent to cerebras", body: transcript)

                    let (responseText, _) = try await CerebrasClient.shared.respondTextOnlyStreaming(
                        systemPrompt: textOnlySystemPrompt,
                        conversationHistory: historyForAPI,
                        userPrompt: transcript,
                        onTextChunk: { [weak self] accumulated in
                            // Stream into the typed-chat bubble for typed turns; voice
                            // stays spinner-only until TTS plays.
                            guard inputKind == "typed" else { return }
                            self?.updateStreamingAssistant(accumulatedText: accumulated)
                        }
                    )
                    fullResponseText = responseText
                }

                guard !Task.isCancelled else { return }

                PerchRunLog.appendBlock(run, .plan, "model full reply", body: fullResponseText)

                // The Intent Gate classifies the answer-vs-act split explicitly
                // (docs/DECISIONS.md D2). It reuses this single call's signal, so
                // the answer lane pays no extra latency. An act routes to the
                // browser subagent and skips the on-screen pointing pipeline
                // entirely — the work happens in an isolated headless browser.
                switch IntentGate.classify(claudeReply: fullResponseText) {
                case .act(let task, let spokenConfirmation):
                    PerchRunLog.append(run, .plan, "intent gate → ACT: routing to subagent: \(task)")
                    await handleBackgroundBrowserTask(
                        task: task,
                        spokenConfirmation: spokenConfirmation,
                        transcript: transcript,
                        inputKind: inputKind
                    )
                    // The decision turn ends here; the autonomous run is captured
                    // separately by the subagent trace.
                    PerchRunLog.endRun(run)
                    return
                case .dashboardWidget(let spec, let spokenConfirmation):
                    PerchRunLog.append(run, .plan, "intent gate → DASHBOARD: \(spec)")
                    await handleDashboardWidgetRequest(
                        spec: spec,
                        spokenConfirmation: spokenConfirmation,
                        transcript: transcript,
                        inputKind: inputKind
                    )
                    PerchRunLog.endRun(run)
                    return
                case .clarify(let question):
                    PerchRunLog.append(run, .plan, "intent gate → CLARIFY: \(question)")
                    await handleClarifyQuestion(question: question, transcript: transcript, inputKind: inputKind)
                    PerchRunLog.endRun(run)
                    return
                case .answer:
                    PerchRunLog.append(run, .plan, "intent gate → ANSWER: continuing with pointing pipeline")
                }

                // Parse the [POINT:...] tag from Claude's response
                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)
                let spokenText = parseResult.spokenText
                PerchRunLog.append(
                    run, .plan,
                    "parsed point tag — coord="
                        + (parseResult.coordinate.map { "(\(Int($0.x)),\(Int($0.y)))" } ?? "none")
                        + " label=\(parseResult.elementLabel ?? "—")"
                        + " screen=\(parseResult.screenNumber.map(String.init) ?? "cursor")"
                )

                // Handle element pointing if Claude returned coordinates.
                // Switch to idle BEFORE setting the location so the triangle
                // becomes visible and can fly to the target. Without this, the
                // spinner hides the triangle and the flight animation is invisible.
                let hasPointCoordinate = parseResult.coordinate != nil
                if hasPointCoordinate {
                    voiceState = .idle
                }

                // Pick the screen capture matching Claude's screen number,
                // falling back to the cursor screen if not specified.
                let targetScreenCapture: CompanionScreenCapture? = {
                    if let screenNumber = parseResult.screenNumber,
                       screenNumber >= 1 && screenNumber <= screenCaptures.count {
                        return screenCaptures[screenNumber - 1]
                    }
                    return screenCaptures.first(where: { $0.isCursorScreen })
                }()

                if let pointCoordinate = parseResult.coordinate,
                   let targetScreenCapture {
                    // Claude's coordinates are in the screenshot's pixel space
                    // (top-left origin, e.g. 1280x831). Scale to the display's
                    // point space (e.g. 1512x982), then convert to AppKit global coords.
                    let screenshotWidth = CGFloat(targetScreenCapture.screenshotWidthInPixels)
                    let screenshotHeight = CGFloat(targetScreenCapture.screenshotHeightInPixels)
                    let displayWidth = CGFloat(targetScreenCapture.displayWidthInPoints)
                    let displayHeight = CGFloat(targetScreenCapture.displayHeightInPoints)
                    let displayFrame = targetScreenCapture.displayFrame

                    // Clamp to screenshot coordinate space
                    let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
                    let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))

                    // Scale from screenshot pixels to display points
                    let displayLocalX = clampedX * (displayWidth / screenshotWidth)
                    let displayLocalY = clampedY * (displayHeight / screenshotHeight)

                    // Convert from top-left origin (screenshot) to bottom-left origin (AppKit)
                    let appKitY = displayHeight - displayLocalY

                    // Convert display-local coords to global screen coords
                    let globalLocation = CGPoint(
                        x: displayLocalX + displayFrame.origin.x,
                        y: appKitY + displayFrame.origin.y
                    )

                    // Typed turns are text-only — never fly the on-screen cursor.
                    // (The coordinates are still computed/logged above; we just don't
                    // hand them to the overlay.)
                    if inputKind != "typed" {
                        detectedElementScreenLocation = globalLocation
                        detectedElementDisplayFrame = displayFrame
                    }
                    PerchAnalytics.trackElementPointed(elementLabel: parseResult.elementLabel)
                    print("🎯 Element pointing: (\(Int(pointCoordinate.x)), \(Int(pointCoordinate.y))) → \"\(parseResult.elementLabel ?? "element")\"")
                    PerchRunLog.append(
                        run, .action,
                        "pointing at screenshot(\(Int(pointCoordinate.x)),\(Int(pointCoordinate.y)))"
                            + " → global(\(Int(globalLocation.x)),\(Int(globalLocation.y)))"
                            + " \"\(parseResult.elementLabel ?? "element")\""
                    )
                } else {
                    print("🎯 Element pointing: \(parseResult.elementLabel ?? "no element")")
                    PerchRunLog.append(run, .action, "no element to point at")
                }

                // Save this exchange to conversation history (with the point tag
                // stripped so it doesn't confuse future context)
                recordExchange(userTranscript: transcript, assistantResponse: spokenText)
                print("🧠 Conversation history: \(conversationHistory.count) exchanges")
                PerchRunLog.append(run, .state, "conversation history now \(conversationHistory.count) exchange(s)")

                PerchAnalytics.trackAIResponseReceived(response: spokenText)

                // Typed turns finish in text: land the clean (point-tag-stripped)
                // reply in the bubble. Voice turns speak it aloud instead.
                if inputKind == "typed" {
                    finalizeStreamingAssistant(finalText: spokenText)
                }

                // Play the response via TTS. Keep the spinner (processing state)
                // until the audio actually starts playing, then switch to responding.
                // Typed turns stay silent — the reply is shown, not spoken.
                await speakResponse(spokenText, silent: inputKind == "typed")
            } catch is CancellationError {
                // User spoke again — response was interrupted
            } catch let captureError as CompanionScreenCaptureError {
                // Screen Recording was granted while the app was already running, so
                // the grant isn't live in this process. Offer a single deterministic
                // relaunch instead of letting macOS re-prompt on every turn.
                PerchRunLog.append(run, .error, "screen capture blocked: \(captureError)")
                print("⚠️ Screen capture blocked: \(captureError)")
                if inputKind == "typed" {
                    finalizeStreamingAssistant(finalText: "I couldn't see your screen. Try again.")
                }
                promptScreenRecordingRelaunchIfNeeded()
            } catch {
                PerchAnalytics.trackResponseError(error: error.localizedDescription)
                PerchRunLog.append(run, .error, "response pipeline error (screenshot/claude/tts): \(error)")
                print("⚠️ Companion response error: \(error)")
                // Never leave the "thinking" bubble spinning forever on an error.
                if inputKind == "typed" {
                    finalizeStreamingAssistant(finalText: "Something went wrong. Try again.")
                }
                displayCreditsErrorMessage()
            }

            // Terminal point for the answer / error / cancellation paths (the
            // act/dashboard/clarify branches end their own runs above). Idempotent.
            PerchRunLog.endRun(run)

            if !Task.isCancelled {
                voiceState = .idle
                scheduleTransientHideIfNeeded()
            }
        }
    }

    /// Routes a Claude-tagged background task to the browser subagent: speaks a
    /// short confirmation and starts a NEW isolated headless browser run. Each call
    /// spawns its own concurrent agent (a second task no longer replaces the first).
    /// The on-screen pointing pipeline is skipped — the work happens off-screen.
    private func handleBackgroundBrowserTask(
        task: String,
        spokenConfirmation: String,
        transcript: String,
        inputKind: String
    ) async {
        // Hand the agent the current run's document so its asynchronous work —
        // lifecycle, executed AppleScript, completion — appends to THIS turn's doc
        // even if the user has started another turn by the time it finishes. The
        // task description and this document ride on the run object the manager
        // creates, so a concurrent later task never overwrites them.
        let runForBackgroundTask = activeRun
        PerchRunLog.append(runForBackgroundTask, .action, "handing task to browser subagent: \(task)")
        Task { await browserSubagentManager.startTask(task, runDocument: runForBackgroundTask) }

        recordExchange(userTranscript: transcript, assistantResponse: spokenConfirmation)
        // Typed turns land the confirmation in the bubble; voice speaks it.
        if inputKind == "typed" {
            finalizeStreamingAssistant(finalText: spokenConfirmation)
        }
        await speakResponse(spokenConfirmation, silent: inputKind == "typed")

        if !Task.isCancelled {
            voiceState = .idle
            scheduleTransientHideIfNeeded()
        }
    }

    /// Routes a spoken "add/change a widget on my dashboard" request to the main
    /// agent's dashboard tool family. Opens the board, hands the request to the
    /// sidecar (which plans a `dashboard` step, decides the source + fetch plan +
    /// refresh cadence, and applies it via `DashboardAgentApplier`), and speaks the
    /// short confirmation. Same dispatch path as the act lane — no in-app interpreter.
    private func handleDashboardWidgetRequest(
        spec: String,
        spokenConfirmation: String,
        transcript: String,
        inputKind: String
    ) async {
        PerchRunLog.append(activeRun, .action, "dashboard request → sidecar: \(spec)")
        // Reveal the board so the user sees the new/edited widget land. REVEAL (not show)
        // so an already-open board isn't re-centered and its greeting splash isn't
        // replayed — both read as the dashboard "restarting" mid-add.
        NotificationCenter.default.post(name: .perchRevealDashboard, object: nil)
        let runForDashboardTask = activeRun
        let task = Self.dashboardTaskString(for: spec)
        Task { await browserSubagentManager.startTask(task, runDocument: runForDashboardTask) }

        recordExchange(userTranscript: transcript, assistantResponse: spokenConfirmation)
        // Typed turns land the confirmation in the bubble; voice speaks it.
        if inputKind == "typed" {
            finalizeStreamingAssistant(finalText: spokenConfirmation)
        }
        await speakResponse(spokenConfirmation, silent: inputKind == "typed")

        if !Task.isCancelled {
            voiceState = .idle
            scheduleTransientHideIfNeeded()
        }
    }

    /// Handles the on-board "+" compose textbox submit: the same dashboard-create path
    /// as voice, but with no speech (the user is looking at the board). The draft's id
    /// is not threaded — the agent creates a fresh widget placed at the next free cell.
    private func handleDashboardComposeSubmit(spec: String) async {
        PerchRunLog.append(activeRun, .action, "dashboard compose → sidecar: \(spec)")
        let task = Self.dashboardTaskString(for: spec)
        await browserSubagentManager.startTask(task)
    }

    /// Phrase a dashboard request so the sidecar planner routes it to the `dashboard`
    /// family (its routing doctrine keys on "my/the dashboard").
    private static func dashboardTaskString(for spec: String) -> String {
        "On my own Daily Dashboard: \(spec)"
    }

    /// Handles the clarify lane: the request was ambiguous, so Perch speaks one
    /// short question and waits for the user's answer. Nothing is done and nothing
    /// is pointed at — the user's reply re-enters the same pipeline with this
    /// question in conversation history for context.
    private func handleClarifyQuestion(question: String, transcript: String, inputKind: String) async {
        recordExchange(userTranscript: transcript, assistantResponse: question)
        // Typed turns land the question in the bubble; the user's next typed reply
        // re-enters the pipeline with it in history. Voice speaks the question.
        if inputKind == "typed" {
            finalizeStreamingAssistant(finalText: question)
        }
        await speakResponse(question, silent: inputKind == "typed")

        if !Task.isCancelled {
            voiceState = .idle
            scheduleTransientHideIfNeeded()
        }
    }

    /// Appends one exchange to the rolling conversation history, capping it at the
    /// last 10 exchanges so context doesn't grow unbounded.
    private func recordExchange(userTranscript: String, assistantResponse: String) {
        conversationHistory.append((
            userTranscript: userTranscript,
            assistantResponse: assistantResponse
        ))
        if conversationHistory.count > 10 {
            conversationHistory.removeFirst(conversationHistory.count - 10)
        }
    }

    // MARK: - Typed-chat thread (UI-only bubbles)

    /// Append the user's typed message as a right-aligned bubble.
    func appendTypedUserMessage(text: String, thumbnails: [NSImage]) {
        let userMessage = TypedChatMessage(
            role: .user,
            text: text,
            isStreaming: false,
            attachmentThumbnails: thumbnails
        )
        typedChatMessages = typedChatMessages + [userMessage]
    }

    /// Append an empty, streaming assistant bubble and remember its id so the
    /// streamed tokens know which bubble to fill. Shows the "thinking" dots until
    /// the first token arrives.
    func beginTypedAssistantStreamingMessage() {
        let assistantMessage = TypedChatMessage(
            role: .assistant,
            text: "",
            isStreaming: true,
            attachmentThumbnails: []
        )
        streamingAssistantMessageID = assistantMessage.id
        typedChatMessages = typedChatMessages + [assistantMessage]
    }

    /// Replace the streaming assistant bubble's text with the latest accumulated
    /// reply. No-op if there is no active streaming bubble (e.g. a late chunk from a
    /// response the user already superseded), so a stale token can't clobber a newer
    /// bubble.
    func updateStreamingAssistant(accumulatedText: String) {
        guard let streamingID = streamingAssistantMessageID else { return }
        typedChatMessages = typedChatMessages.map { message in
            guard message.id == streamingID else { return message }
            var updated = message
            updated.text = accumulatedText
            return updated
        }
    }

    /// Finish the streaming assistant bubble: set its final text and stop streaming.
    /// No-op if there is no active streaming bubble.
    func finalizeStreamingAssistant(finalText: String) {
        guard let streamingID = streamingAssistantMessageID else { return }
        typedChatMessages = typedChatMessages.map { message in
            guard message.id == streamingID else { return message }
            var updated = message
            updated.text = finalText
            updated.isStreaming = false
            return updated
        }
        streamingAssistantMessageID = nil
    }

    /// Clear the whole typed-chat thread (on composer dismiss). Leaves
    /// `conversationHistory` alone so the model keeps its short-term memory.
    func clearTypedChat() {
        typedChatMessages = []
        streamingAssistantMessageID = nil
    }

    /// Speaks a reply via ElevenLabs TTS, keeping the spinner (processing state)
    /// up until audio actually starts playing, then switching to responding.
    /// Empty text is a no-op; a TTS failure falls back to the credits-error text.
    ///
    /// When `silent` is true (typed turns), the reply is shown in a bubble rather
    /// than spoken: the speak-trace is still recorded, but no audio plays and the
    /// voice state is left untouched.
    private func speakResponse(_ spokenText: String, silent: Bool = false) async {
        let trimmedText = spokenText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }
        // The verbatim words Perch would say — the "whenever something is said"
        // trace, captured whether or not it is actually spoken aloud.
        PerchRunLog.append(activeRun, .speak, trimmedText)
        // Typed turns are text-only: skip audio and the responding transition.
        guard !silent else { return }
        do {
            try await elevenLabsTTSClient.speakText(trimmedText)
            // speakText returns after player.play() — audio is now playing
            voiceState = .responding
        } catch {
            PerchAnalytics.trackTTSError(error: error.localizedDescription)
            PerchRunLog.append(activeRun, .error, "TTS failed, using credits fallback: \(error)")
            print("⚠️ ElevenLabs TTS error: \(error)")
            displayCreditsErrorMessage()
        }
    }

    /// Called when one background agent reports it finished. Brings the cursor
    /// overlay back if it was hidden, shows the result bubble, and — unless the
    /// user is mid-conversation — speaks the wrap-up aloud. Scoped to the finished
    /// run so concurrent agents each announce their own completion.
    private func announceBackgroundTaskCompletion(for finishedRun: BrowserSubagentRun) {
        // Make sure the cursor is on screen so the result bubble is visible,
        // even if "Show Perch" is off and the overlay had faded out.
        transientHideTask?.cancel()
        transientHideTask = nil
        if !isOverlayVisible {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }

        let completionMessage = backgroundTaskCompletionMessage(for: finishedRun)
        PerchRunLog.append(finishedRun.runDocument, .action, "background task completed: \(completionMessage)")

        // Remember this run so the notch panel's Agents tab can show it.
        agentRunHistoryStore.recordRun(
            taskDescription: finishedRun.taskDescription,
            resultSummary: completionMessage,
            finalUrl: finishedRun.finalUrl,
            didSucceed: true,
            deliverableLabel: finishedRun.deliverableLabel
        )

        // Show the result bubble and schedule it to auto-dismiss.
        backgroundTaskCompletionClearTask?.cancel()
        backgroundTaskCompletionText = completionMessage
        backgroundTaskCompletionClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled else { return }
            self?.backgroundTaskCompletionText = ""
            self?.scheduleTransientHideIfNeeded()
        }

        PerchAnalytics.trackAIResponseReceived(response: completionMessage)

        // Don't talk over an in-flight voice interaction — only speak the
        // wrap-up when Perch is otherwise idle.
        let isBusyWithVoice = voiceState != .idle || elevenLabsTTSClient.isPlaying
        guard !isBusyWithVoice else { return }

        let completionRunDocument = finishedRun.runDocument
        Task { @MainActor [weak self] in
            guard let self else { return }
            PerchRunLog.append(completionRunDocument, .speak, completionMessage)
            do {
                try await self.elevenLabsTTSClient.speakText(completionMessage)
                // `speakText` returns as soon as audio STARTS, so show "Speaking"
                // while it plays, then return to idle once playback finishes.
                // Unlike the push-to-talk paths, nothing else resets this state
                // (the voiceState observer leaves `.responding` untouched), so the
                // completion path MUST clear it itself or the notch sticks on
                // "Speaking" forever.
                self.voiceState = .responding
                while self.elevenLabsTTSClient.isPlaying {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
                // Only stand down if the user hasn't started a new interaction in
                // the meantime (which would have moved voiceState off .responding).
                if self.voiceState == .responding {
                    self.voiceState = .idle
                }
                self.scheduleTransientHideIfNeeded()
            } catch {
                PerchAnalytics.trackTTSError(error: error.localizedDescription)
                PerchRunLog.append(completionRunDocument, .error, "completion TTS failed: \(error)")
                print("⚠️ ElevenLabs TTS error (completion): \(error)")
                if self.voiceState == .responding {
                    self.voiceState = .idle
                }
            }
        }
    }

    /// Opens a finished browser run's deliverable in the user's real Chrome window so
    /// the result is actually visible (the sidecar itself runs an isolated headless
    /// browser). Prefers Google Chrome explicitly — the user asked to "open Chrome" —
    /// and falls back to the default browser when Chrome isn't installed. No-ops for a
    /// run with no `finalUrl` (a pure app-api/system task that opened nothing).
    private func openDeliverableInBrowserIfAvailable(for finishedRun: BrowserSubagentRun) {
        guard let finalUrl = finishedRun.finalUrl else { return }
        PerchRunLog.append(
            finishedRun.runDocument, .action,
            "opening deliverable in browser: \(finalUrl.absoluteString)"
        )
        let workspace = NSWorkspace.shared
        if let chromeURL = workspace.urlForApplication(withBundleIdentifier: "com.google.Chrome") {
            workspace.open(
                [finalUrl],
                withApplicationAt: chromeURL,
                configuration: NSWorkspace.OpenConfiguration(),
                completionHandler: nil
            )
        } else {
            // Chrome isn't installed — open in whatever the default browser is.
            workspace.open(finalUrl)
        }
    }

    /// Builds a short, natural wrap-up line for one finished background agent.
    private func backgroundTaskCompletionMessage(for finishedRun: BrowserSubagentRun) -> String {
        // No-browser run (pure app-api/system plan): nothing was opened, so speak
        // the sidecar's result summary instead of "opened it up to take a look".
        if !finishedRun.handoffWindowReady,
           let summary = finishedRun.resultSummary?
               .trimmingCharacters(in: .whitespacesAndNewlines),
           !summary.isEmpty {
            return "all done — \(summary)"
        }
        let task = finishedRun.taskDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !task.isEmpty {
            return "all done — i finished \(task) and opened it up for you to take a look."
        }
        return "all done — i finished that task and opened it up for you to take a look."
    }

    /// If the cursor is in transient mode (user toggled "Show Perch" off),
    /// waits for TTS playback and any pointing animation to finish, then
    /// fades out the overlay after a 1-second pause. Cancelled automatically
    /// if the user starts another push-to-talk interaction.
    private func scheduleTransientHideIfNeeded() {
        guard !isPerchCursorEnabled && isOverlayVisible else { return }

        transientHideTask?.cancel()
        transientHideTask = Task {
            // Wait for TTS audio to finish playing
            while elevenLabsTTSClient.isPlaying {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Wait for pointing animation to finish (location is cleared
            // when the buddy flies back to the cursor)
            while detectedElementScreenLocation != nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Pause 1s after everything finishes, then fade out
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            overlayWindowManager.fadeOutAndHideOverlay()
            isOverlayVisible = false
        }
    }

    /// Shows a hardcoded error message as text at the notch when API credits
    /// run out. This stays silent (no TTS) so it works even when ElevenLabs is
    /// down — the message is surfaced in the on-screen bubble near the cursor.
    /// Performs a single throwaway direct capture to surface macOS's "bypass the private
    /// window picker" consent in-context after onboarding. No-op unless a warm-up is
    /// pending and the classic Screen Recording grant is live in this process.
    private func maybeRunScreenCaptureDirectAccessWarmup() {
        guard WindowPositionManager.shouldRunScreenCaptureDirectAccessWarmup() else { return }
        WindowPositionManager.markScreenCaptureDirectAccessWarmupDone()
        Task { @MainActor [weak self] in
            guard self != nil else { return }
            // A brief settle so the window server / overlays are up before macOS shows
            // the consent, and the capture attribution is clean.
            try? await Task.sleep(for: .seconds(1))
            // Small maxDimension keeps this cheap — we only need SCK to fire the consent.
            _ = try? await CompanionScreenCaptureUtility.captureAllScreensAsJPEG(maxDimension: 320)
            PerchRunLog.append(nil, .state, "screen-capture direct-access warm-up fired")
        }
    }

    /// Shown at most once per launch so a user who keeps asking doesn't get nagged
    /// repeatedly. Reset only when we explicitly send them to System Settings, so the
    /// relaunch offer can come back after they flip the toggle there.
    private var hasPromptedScreenRecordingRelaunchThisLaunch = false

    /// Surfaces Perch's own one-time relaunch path when Screen Recording was granted
    /// while the app was already running. macOS only applies that grant to a freshly
    /// launched process, so a single Quit & Reopen makes it live — far better than the
    /// raw system prompt re-appearing on every turn.
    private func promptScreenRecordingRelaunchIfNeeded() {
        voiceState = .idle
        scheduleTransientHideIfNeeded()

        guard !hasPromptedScreenRecordingRelaunchThisLaunch else { return }
        hasPromptedScreenRecordingRelaunchThisLaunch = true

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Relaunch Perch to finish enabling screen access"
        alert.informativeText = """
        Perch needs Screen Recording to see your screen. macOS only applies that \
        permission after a relaunch.

        If you already enabled Perch under System Settings → Privacy & Security → \
        Screen Recording, just click Quit & Reopen. If not, open System Settings, \
        turn Perch on, then relaunch.
        """
        alert.addButton(withTitle: "Quit & Reopen")
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Not Now")

        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            // The user is asserting they've granted it. Trust that on the next launch so
            // the capture path actually tries ScreenCaptureKit (CGPreflight can report a
            // false negative even after a real grant) instead of looping on this card.
            WindowPositionManager.markScreenRecordingPermissionConfirmed()
            ApplicationRelauncher.restart()
        case .alertSecondButtonReturn:
            WindowPositionManager.openScreenRecordingSettings()
            // Let the offer return after they toggle the switch in System Settings.
            hasPromptedScreenRecordingRelaunchThisLaunch = false
        default:
            break
        }
    }

    private func displayCreditsErrorMessage() {
        let message = "I'm all out of credits. Please upgrade for more!"
        PerchRunLog.append(activeRun, .action, "\(message) (shown as text at notch)")

        // Make sure the cursor overlay is on screen so the text bubble is
        // visible, even if "Show Perch" is off and the overlay had faded out.
        transientHideTask?.cancel()
        transientHideTask = nil
        if !isOverlayVisible {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }

        // Surface the message in the same text bubble used for background-task
        // results, and schedule it to auto-dismiss after a few seconds.
        backgroundTaskCompletionClearTask?.cancel()
        backgroundTaskCompletionText = message
        backgroundTaskCompletionClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled else { return }
            self?.backgroundTaskCompletionText = ""
            self?.scheduleTransientHideIfNeeded()
        }
    }

}
