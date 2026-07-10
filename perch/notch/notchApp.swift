//
//  notchApp.swift
//  notchApp
//
//  Created by Harsh Vardhan  Goswami  on 02/08/24.
//

import AVFoundation
import Combine
import Defaults
import KeyboardShortcuts
import Sparkle
import SwiftUI

@main
struct DynamicNotchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Default(.menubarIcon) var showMenuBarIcon
    @Environment(\.openWindow) var openWindow

    let updaterController: SPUStandardUpdaterController
    // Held strongly: SPUStandardUpdaterController references its delegate weakly.
    private let updaterDelegate = PerchUpdaterDelegate()

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: updaterDelegate, userDriverDelegate: nil)

        // Initialize the settings window controller with the updater controller
        SettingsWindowController.shared.setUpdaterController(updaterController)
    }

    var body: some Scene {
        MenuBarExtra("Perch", systemImage: "sparkle", isInserted: $showMenuBarIcon) {
            // Window presentation (not the default native menu) so the permission rows
            // can render as real switch toggles instead of checkmark menu items.
            PerchMenuBarContent(
                toggles: PerchCapabilityToggles.shared,
                updater: updaterController.updater)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Marks the next launch as an in-place Sparkle update so the fresh-install
/// detector keeps the user's onboarding, permissions, and sign-in. Without this,
/// an auto-update — which replaces the app binary just like a fresh download —
/// would wipe state and re-onboard on every release. Both hooks set the same
/// one-shot marker (idempotent) to cover install-and-relaunch and install-on-quit.
final class PerchUpdaterDelegate: NSObject, SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        PerchFreshInstallDetector.markPendingUpdateRelaunch()
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        PerchFreshInstallDetector.markPendingUpdateRelaunch()
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var windows: [String: NSWindow] = [:] // UUID -> NSWindow
    var viewModels: [String: ViewModel] = [:] // UUID -> ViewModel
    var window: NSWindow?
    let vm: ViewModel = .init()
    /// The ported Perch backend (voice → Claude → TTS → cursor pointing, browser/desktop
    /// agents, workflows, integrations). Retained for the app's lifetime. Slice 1 only
    /// constructs it — `start()` is NOT called yet, so it has no runtime side effects.
    let companionManager = CompanionManager()
    @ObservedObject var coordinator = ViewCoordinator.shared
    var quickShareService = QuickShareService.shared
    var whatsNewWindow: NSWindow?
    var timer: Timer?
    var closeNotchTask: Task<Void, Never>?
    private var previousScreens: [NSScreen]?
    private var onboardingWindowController: NSWindowController?
    private var musicSourceWindowController: NSWindowController?
    private var screenLockedObserver: Any?
    private var screenUnlockedObserver: Any?
    private var isScreenLocked: Bool = false
    private var windowScreenDidChangeObserver: Any?
    private var dragDetectors: [String: DragDetector] = [:] // UUID -> DragDetector

    /// While the typed composer is open, drives the notch window's height from the
    /// composer's measured content height so the notch grows/shrinks to fit the chat
    /// thread. Cancelled when the composer closes.
    private var typedChatHeightCancellable: AnyCancellable?
    /// While the typed composer is open, a global mouse monitor that dismisses it
    /// when the user clicks anywhere outside the notch. Removed on dismiss.
    private var clickOutsideToDismissMonitor: Any?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        companionManager.stop()
        NotificationCenter.default.removeObserver(self)
        if let observer = screenLockedObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            screenLockedObserver = nil
        }
        if let observer = screenUnlockedObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            screenUnlockedObserver = nil
        }
        MusicManager.shared.destroy()
        cleanupDragDetectors()
        cleanupWindows()
        XPCHelperClient.shared.stopMonitoringAccessibilityAuthorization()
    }

    @MainActor
    func onScreenLocked(_ notification: Notification) {
        isScreenLocked = true
        if !Defaults[.showOnLockScreen] {
            cleanupWindows()
        } else {
            enableSkyLightOnAllWindows()
        }
    }

    @MainActor
    func onScreenUnlocked(_ notification: Notification) {
        isScreenLocked = false
        if !Defaults[.showOnLockScreen] {
            adjustWindowPosition(changeAlpha: true)
        } else {
            disableSkyLightOnAllWindows()
        }
    }
    
    @MainActor
    private func enableSkyLightOnAllWindows() {
        if Defaults[.showOnAllDisplays] {
            windows.values.forEach { window in
                if let skyWindow = window as? NotchSkyLightWindow {
                    skyWindow.enableSkyLight()
                }
            }
        } else {
            if let skyWindow = window as? NotchSkyLightWindow {
                skyWindow.enableSkyLight()
            }
        }
    }
    
    @MainActor
    private func disableSkyLightOnAllWindows() {
        // Delay disabling SkyLight to avoid flicker during unlock transition
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            await MainActor.run {
                if Defaults[.showOnAllDisplays] {
                    self.windows.values.forEach { window in
                        if let skyWindow = window as? NotchSkyLightWindow {
                            skyWindow.disableSkyLight()
                        }
                    }
                } else {
                    if let skyWindow = self.window as? NotchSkyLightWindow {
                        skyWindow.disableSkyLight()
                    }
                }
            }
        }
    }

    private func cleanupWindows(shouldInvert: Bool = false) {
        let shouldCleanupMulti = shouldInvert ? !Defaults[.showOnAllDisplays] : Defaults[.showOnAllDisplays]
        
        if shouldCleanupMulti {
            windows.values.forEach { window in
                window.close()
                NotchSpaceManager.shared.notchSpace.windows.remove(window)
            }
            windows.removeAll()
            viewModels.removeAll()
        } else if let window = window {
            window.close()
            NotchSpaceManager.shared.notchSpace.windows.remove(window)
            if let obs = windowScreenDidChangeObserver {
                NotificationCenter.default.removeObserver(obs)
                windowScreenDidChangeObserver = nil
            }
            self.window = nil
        }
    }

    private func cleanupDragDetectors() {
        dragDetectors.values.forEach { detector in
            detector.stopMonitoring()
        }
        dragDetectors.removeAll()
    }

    private func setupDragDetectors() {
        cleanupDragDetectors()

        guard Defaults[.expandedDragDetection] else { return }

        if Defaults[.showOnAllDisplays] {
            for screen in NSScreen.screens {
                setupDragDetectorForScreen(screen)
            }
        } else {
            let preferredScreen: NSScreen? = window?.screen
                ?? NSScreen.screen(withUUID: coordinator.selectedScreenUUID)
                ?? NSScreen.main

            if let screen = preferredScreen {
                setupDragDetectorForScreen(screen)
            }
        }
    }

    private func setupDragDetectorForScreen(_ screen: NSScreen) {
        guard let uuid = screen.displayUUID else { return }
        
        let screenFrame = screen.frame
        let notchHeight = openNotchSize.height
        let notchWidth = openNotchSize.width
        
        // Create notch region at the top-center of the screen where an open notch would occupy
        let notchRegion = CGRect(
            x: screenFrame.midX - notchWidth / 2,
            y: screenFrame.maxY - notchHeight,
            width: notchWidth,
            height: notchHeight
        )
        
        let detector = DragDetector(notchRegion: notchRegion)
        
        detector.onDragEntersNotchRegion = { [weak self] in
            Task { @MainActor in
                self?.handleDragEntersNotchRegion(onScreen: screen)
            }
        }
        
        dragDetectors[uuid] = detector
        detector.startMonitoring()
    }

    private func handleDragEntersNotchRegion(onScreen screen: NSScreen) {
        guard let uuid = screen.displayUUID else { return }

        if Defaults[.showOnAllDisplays], let viewModel = viewModels[uuid] {
            viewModel.open()
            coordinator.currentView = .shelf
        } else if !Defaults[.showOnAllDisplays], let windowScreen = window?.screen, screen == windowScreen {
            vm.open()
            coordinator.currentView = .shelf
        }
    }

    private func createNotchWindow(for screen: NSScreen, with viewModel: ViewModel) -> NSWindow {
        let rect = NSRect(x: 0, y: 0, width: windowSize.width, height: windowSize.height)
        let styleMask: NSWindow.StyleMask = [.borderless, .nonactivatingPanel, .utilityWindow, .hudWindow]
        
        let window = NotchSkyLightWindow(contentRect: rect, styleMask: styleMask, backing: .buffered, defer: false)
        
        // Enable SkyLight only when screen is locked
        if isScreenLocked {
            window.enableSkyLight()
        } else {
            window.disableSkyLight()
        }

        window.contentView = NSHostingView(
            rootView: ContentView()
                .environmentObject(viewModel)
                .environmentObject(companionManager)
        )

        window.orderFrontRegardless()
        NotchSpaceManager.shared.notchSpace.windows.insert(window)

        // Observe when the window's screen changes so we can update drag detectors
        windowScreenDidChangeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification,
            object: window,
            queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.setupDragDetectors()
                }
        }
        return window
    }

    @MainActor
    private func positionWindow(_ window: NSWindow, on screen: NSScreen, changeAlpha: Bool = false) {
        if changeAlpha {
            window.alphaValue = 0
        }

        let screenFrame = screen.frame
        window.setFrameOrigin(
            NSPoint(
                x: screenFrame.origin.x + (screenFrame.width / 2) - window.frame.width / 2,
                y: screenFrame.origin.y + screenFrame.height - window.frame.height
            ))
        window.alphaValue = 1
    }

    /// Every notch panel currently on screen (one per display when "show on all
    /// displays" is on, otherwise the single primary window).
    @MainActor
    private func allNotchWindows() -> [NSWindow] {
        var result = Array(windows.values)
        if let window, !result.contains(window) {
            result.append(window)
        }
        return result
    }

    /// The notch panel the composer should focus — the one on the user's selected
    /// screen, falling back to whatever single window exists.
    @MainActor
    private func activeNotchWindow() -> NSWindow? {
        if let windowForSelectedScreen = windows[coordinator.selectedScreenUUID] {
            return windowForSelectedScreen
        }
        return windows.values.first ?? window
    }

    /// Allow the notch panel(s) to become key, then bring the active one up so its
    /// text field can take keystrokes. The panel is `.nonactivatingPanel`, so this
    /// grabs keyboard input WITHOUT activating this (LSUIElement) app or stealing
    /// the foreground from whatever app the user is working in.
    @MainActor
    private func grantNotchKeyFocusForTextInput() {
        for case let skyLightWindow as NotchSkyLightWindow in allNotchWindows() {
            skyLightWindow.acceptsKeyInput = true
        }
        // The OS delivers keystrokes to the key window of the *active* app. As an
        // LSUIElement accessory we aren't active, so the composer would never get
        // typed characters without this — briefly activate (Spotlight-style) so the
        // notch panel can become the key window that receives input.
        NSApp.activate(ignoringOtherApps: true)
        activeNotchWindow()?.makeKeyAndOrderFront(nil)

        // Grow the notch to fit the chat thread: track the composer's measured
        // content height so the window is always exactly as tall as the content
        // needs (up to the screen), and dismiss when the user clicks outside.
        beginTypedChatWindowSizing()
        installClickOutsideToDismissMonitor()
    }

    /// Relinquish keyboard focus once the composer closes: the notch goes back to
    /// being a passive overlay that never steals input, and the app the user was
    /// working in regains the foreground.
    @MainActor
    private func relinquishNotchKeyFocusForTextInput() {
        for case let skyLightWindow as NotchSkyLightWindow in allNotchWindows() {
            skyLightWindow.acceptsKeyInput = false
            skyLightWindow.resignKey()
        }
        NSApp.deactivate()

        // Stop tracking content height and clicks, then shrink the notch window back
        // to its normal height now that the chat thread is gone.
        typedChatHeightCancellable?.cancel()
        typedChatHeightCancellable = nil
        removeClickOutsideToDismissMonitor()
        resizeNotchWindows(toHeight: windowSize.height, animated: true)
    }

    /// Subscribe to the composer's measured content height and keep the notch window
    /// sized to it (plus the shadow allowance), clamped so it never collapses below
    /// the input bar or grows past the usable screen. The visible black notch fill is
    /// already intrinsic-height, so the window resizing in lockstep makes the notch
    /// appear to grow smoothly with each message.
    @MainActor
    private func beginTypedChatWindowSizing() {
        typedChatHeightCancellable?.cancel()
        // Apply the current height immediately, then on every change.
        applyTypedChatContentHeight(NotchTextInputController.shared.measuredComposerContentHeight)
        typedChatHeightCancellable = NotchTextInputController.shared
            .$measuredComposerContentHeight
            .removeDuplicates()
            .sink { [weak self] contentHeight in
                // The controller is @MainActor and mutated on the main thread, so this
                // fires on main during the SwiftUI update — apply synchronously so the
                // window tracks the content's animation frame-for-frame (a Task hop
                // would defer to the next runloop and visibly lag the growth).
                MainActor.assumeIsolated {
                    self?.applyTypedChatContentHeight(contentHeight)
                }
            }
    }

    /// Resize the notch window(s) to fit `contentHeight` of composer content.
    @MainActor
    private func applyTypedChatContentHeight(_ contentHeight: CGFloat) {
        guard NotchTextInputController.shared.isActive else { return }

        // The notch only grows once the chat thread has messages — an empty composer
        // (just the input bar) stays at the normal notch size and never grows on its
        // own. The bar itself is drawn by the intrinsic-height black fill within this
        // base window.
        guard !companionManager.typedChatMessages.isEmpty, contentHeight > 0 else {
            resizeNotchWindows(toHeight: windowSize.height, animated: false)
            return
        }

        // With messages present, the window fits the content (plus the shadow
        // allowance), clamped so a long thread never runs off the screen (it scrolls
        // internally past this point).
        let minimumWindowHeight = windowSize.height
        let usableScreenHeight = (activeNotchWindow()?.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        let maximumWindowHeight = usableScreenHeight - 40
        let targetWindowHeight = min(
            max(contentHeight + shadowPadding, minimumWindowHeight),
            maximumWindowHeight
        )
        // Track content instantly (no window animation) — the black fill animates
        // its own growth in SwiftUI, and the window follows in lockstep so nothing
        // clips and the growth reads as one smooth motion.
        resizeNotchWindows(toHeight: targetWindowHeight, animated: false)
    }

    /// Dismiss the typed composer when the user clicks anywhere outside the notch.
    /// A global monitor only sees clicks destined for OTHER apps, which is exactly
    /// "clicked away from Perch" — clicks inside the notch never reach it.
    @MainActor
    private func installClickOutsideToDismissMonitor() {
        removeClickOutsideToDismissMonitor()
        clickOutsideToDismissMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { _ in
            Task { @MainActor in
                NotchTextInputController.shared.dismiss()
            }
        }
    }

    @MainActor
    private func removeClickOutsideToDismissMonitor() {
        if let monitor = clickOutsideToDismissMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideToDismissMonitor = nil
        }
    }

    /// Resize every notch panel to `targetHeight`, keeping its top edge pinned to
    /// the top of the screen so it grows/shrinks downward (matching how the notch is
    /// anchored).
    @MainActor
    private func resizeNotchWindows(toHeight targetHeight: CGFloat, animated: Bool) {
        for window in allNotchWindows() {
            guard abs(window.frame.height - targetHeight) > 0.5 else { continue }
            var newFrame = window.frame
            let topEdgeY = newFrame.origin.y + newFrame.size.height
            newFrame.size.height = targetHeight
            newFrame.origin.y = topEdgeY - targetHeight
            window.setFrame(newFrame, display: true, animate: animated)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {

        // Dogfood auto-login: if support/dev-autologin.json is present, mark onboarding
        // + the skippable screen-content permission complete BEFORE the firstLaunch gate
        // below reads them. Runs AFTER ViewCoordinator's fresh-install reset (its static
        // init), so the flags stick. No-op without the gitignored config.
        PerchDevBootstrap.applyOnboardingAndPermissionSkips()

        // Legacy key migration + fresh-install preference reset already ran inside
        // ViewCoordinator.shared's static initializer (before any @AppStorage read).

        // Cursor overlay is intentionally DISABLED (product decision: no screen
        // cursor that follows or points). Suppress every overlay window at the
        // single chokepoint so it never appears, then start the backend:
        // push-to-talk tap, transcription, Claude, TTS, and the workflow
        // scheduler all run without any cursor overlay.
        companionManager.overlayWindowManager.isSuppressed = true
        companionManager.start()

        // Multi-user identity: register this install with the Worker gateway,
        // refreshing its install token and the server-side tracing kill switch.
        // Best-effort and non-blocking — the app runs fine before it completes.
        //
        // DEV: pre-warm the browser subagent right AFTER register() — warming spawns
        // the sidecar, and the app injects the install token register() caches (the
        // sidecar's OPENROUTER_API_KEY); warming before register races that to nil and
        // the sidecar exits on MissingConfiguration. No-op in beta/release — gated by
        // the dev-only PerchWarmSidecarOnLaunch flag inside warmUpIfConfigured().
        Task {
            await PerchInstallIdentity.shared.register()
            companionManager.browserSubagentManager.warmUpIfConfigured()
        }

        // Telemetry: flush any traces that failed to upload while offline, then
        // watch the sidecar's trace directory and ship completed agent runs.
        TurnTraceUploader.shared.start()
        SubagentTraceUploader.shared.start()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenConfigurationDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            forName: Notification.Name.selectedScreenChanged, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.adjustWindowPosition(changeAlpha: true)
                self?.setupDragDetectors()
            }
        }

        NotificationCenter.default.addObserver(
            forName: Notification.Name.notchHeightChanged, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.adjustWindowPosition()
                self?.setupDragDetectors()
            }
        }

        NotificationCenter.default.addObserver(
            forName: Notification.Name.automaticallySwitchDisplayChanged, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self = self, let window = self.window else { return }
            Task { @MainActor in
                window.alphaValue = self.coordinator.selectedScreenUUID == self.coordinator.preferredScreenUUID ? 1 : 0
            }
        }

        NotificationCenter.default.addObserver(
            forName: Notification.Name.showOnAllDisplaysChanged, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.cleanupWindows(shouldInvert: true)
                self.adjustWindowPosition(changeAlpha: true)
                self.setupDragDetectors()
            }
        }

        NotificationCenter.default.addObserver(
            forName: Notification.Name.expandedDragDetectionChanged, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.setupDragDetectors()
            }
        }

        // The notch text-input composer needs the (normally focus-refusing) notch
        // window to accept keystrokes while it's on screen. Grant key focus when it
        // opens and relinquish it when it closes.
        NotificationCenter.default.addObserver(
            forName: .perchShowTextInput, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.grantNotchKeyFocusForTextInput()
            }
        }

        NotificationCenter.default.addObserver(
            forName: .perchTextInputDidDismiss, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.relinquishNotchKeyFocusForTextInput()
            }
        }

        // The notch's "Connect Music" empty-state prompt asks the app to open
        // the standalone music-source picker.
        NotificationCenter.default.addObserver(
            forName: .connectMusicRequested, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.showMusicSourcePicker()
            }
        }

        // Use closure-based observers for DistributedNotificationCenter and keep tokens for removal
        screenLockedObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(rawValue: "com.apple.screenIsLocked"),
            object: nil, queue: .main) { [weak self] notification in
                Task { @MainActor in
                    self?.onScreenLocked(notification)
                }
        }

        screenUnlockedObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(rawValue: "com.apple.screenIsUnlocked"),
            object: nil, queue: .main) { [weak self] notification in
                Task { @MainActor in
                    self?.onScreenUnlocked(notification)
                }
        }

        KeyboardShortcuts.onKeyDown(for: .toggleSneakPeek) { [weak self] in
            guard let self = self else { return }
            if Defaults[.sneakPeekStyles] == .inline {
                let newStatus = !self.coordinator.expandingView.show
                self.coordinator.toggleExpandingView(status: newStatus, type: .music)
            } else {
                self.coordinator.toggleSneakPeek(
                    status: !self.coordinator.sneakPeek.show,
                    type: .music,
                    duration: 3.0
                )
            }
        }

        KeyboardShortcuts.onKeyDown(for: .toggleNotchOpen) { [weak self] in
            Task { [weak self] in
                guard let self = self else { return }

                let mouseLocation = NSEvent.mouseLocation

                var viewModel = self.vm

                if Defaults[.showOnAllDisplays] {
                    for screen in NSScreen.screens {
                        if screen.frame.contains(mouseLocation) {
                            if let uuid = screen.displayUUID, let screenViewModel = self.viewModels[uuid] {
                                viewModel = screenViewModel
                                break
                            }
                        }
                    }
                }

                self.closeNotchTask?.cancel()
                self.closeNotchTask = nil

                switch viewModel.notchState {
                case .closed:
                    await MainActor.run {
                        viewModel.open()
                    }

                    let task = Task { [weak viewModel] in
                        do {
                            try await Task.sleep(for: .seconds(3))
                            await MainActor.run {
                                viewModel?.close()
                            }
                        } catch { }
                    }
                    self.closeNotchTask = task
                case .open:
                    await MainActor.run {
                        viewModel.close()
                    }
                }
            }
        }

        if !Defaults[.showOnAllDisplays] {
            let viewModel = self.vm
            let window = createNotchWindow(
                for: NSScreen.main ?? NSScreen.screens.first!, with: viewModel)
            self.window = window
            adjustWindowPosition(changeAlpha: true)
        } else {
            adjustWindowPosition(changeAlpha: true)
        }

        setupDragDetectors()

        print("🚀 Onboarding gate — firstLaunch: \(coordinator.firstLaunch)")

        if coordinator.firstLaunch {
            DispatchQueue.main.async {
                self.showOnboardingWindow()
            }
            playWelcomeSound()
        } else if MusicManager.shared.isNowPlayingDeprecated
            && Defaults[.mediaController] == .nowPlaying
        {
            DispatchQueue.main.async {
                self.showMusicSourcePicker()
            }
        }

        previousScreens = NSScreen.screens
    }

    func playWelcomeSound() {
        let audioPlayer = AudioPlayer()
        audioPlayer.play(fileName: "notch", fileExtension: "m4a")
    }

    func deviceHasNotch() -> Bool {
        if #available(macOS 12.0, *) {
            for screen in NSScreen.screens {
                if screen.safeAreaInsets.top > 0 {
                    return true
                }
            }
        }
        return false
    }

    @objc func screenConfigurationDidChange() {
        let currentScreens = NSScreen.screens

        let screensChanged =
            currentScreens.count != previousScreens?.count
            || Set(currentScreens.compactMap { $0.displayUUID })
                != Set(previousScreens?.compactMap { $0.displayUUID } ?? [])
            || Set(currentScreens.map { $0.frame }) != Set(previousScreens?.map { $0.frame } ?? [])

        previousScreens = currentScreens

        if screensChanged {
            DispatchQueue.main.async { [weak self] in
                self?.cleanupWindows()
                self?.adjustWindowPosition()
                self?.setupDragDetectors()
            }
        }
    }

    @objc func adjustWindowPosition(changeAlpha: Bool = false) {
        if Defaults[.showOnAllDisplays] {
            let currentScreenUUIDs = Set(NSScreen.screens.compactMap { $0.displayUUID })

            // Remove windows for screens that no longer exist
            for uuid in windows.keys where !currentScreenUUIDs.contains(uuid) {
                if let window = windows[uuid] {
                    window.close()
                    NotchSpaceManager.shared.notchSpace.windows.remove(window)
                    windows.removeValue(forKey: uuid)
                    viewModels.removeValue(forKey: uuid)
                }
            }

            // Create or update windows for all screens
            for screen in NSScreen.screens {
                guard let uuid = screen.displayUUID else { continue }
                
                if windows[uuid] == nil {
                    let viewModel = ViewModel(screenUUID: uuid)
                    let window = createNotchWindow(for: screen, with: viewModel)

                    windows[uuid] = window
                    viewModels[uuid] = viewModel
                }

                if let window = windows[uuid], let viewModel = viewModels[uuid] {
                    positionWindow(window, on: screen, changeAlpha: changeAlpha)

                    if viewModel.notchState == .closed {
                        viewModel.close()
                    }
                }
            }
        } else {
            let selectedScreen: NSScreen

            if let notchScreen = NSScreen.builtInNotchScreen,
               let notchUUID = notchScreen.displayUUID {
                // Always map Perch's notch onto the Mac's built-in display (the one
                // with the real hardware notch), regardless of which display is
                // currently "main". Handles display hot-plug (e.g. opening the lid
                // in a clamshell setup).
                coordinator.selectedScreenUUID = notchUUID
                selectedScreen = notchScreen
            } else if let preferredScreen = NSScreen.screen(withUUID: coordinator.preferredScreenUUID ?? "") {
                coordinator.selectedScreenUUID = coordinator.preferredScreenUUID ?? ""
                selectedScreen = preferredScreen
            } else if Defaults[.automaticallySwitchDisplay], let mainScreen = NSScreen.main,
                      let mainUUID = mainScreen.displayUUID {
                coordinator.selectedScreenUUID = mainUUID
                selectedScreen = mainScreen
            } else {
                if let window = window {
                    window.alphaValue = 0
                }
                return
            }

            vm.screenUUID = selectedScreen.displayUUID
            vm.notchSize = getClosedNotchSize(screenUUID: selectedScreen.displayUUID)

            if window == nil {
                window = createNotchWindow(for: selectedScreen, with: vm)
            }

            if let window = window {
                positionWindow(window, on: selectedScreen, changeAlpha: changeAlpha)

                if vm.notchState == .closed {
                    vm.close()
                }
            }
        }
    }

    @objc func togglePopover(_ sender: Any?) {
        if window?.isVisible == true {
            window?.orderOut(nil)
        } else {
            window?.orderFrontRegardless()
        }
    }

    @objc func showMenu() {
        statusItem?.menu?.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc func quitAction() {
        NSApplication.shared.terminate(self)
    }

    private func showOnboardingWindow(step: OnboardingStep = .welcome) {
        // Resume an interrupted onboarding (e.g. after the relaunch macOS forces
        // when you grant Screen Recording / Accessibility) at the step the user
        // left off, rather than restarting from the welcome screen.
        let resumedStep = OnboardingProgress.resumeStep(defaultingTo: step)
        if onboardingWindowController == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 600),
                styleMask: [.titled, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.center()
            window.title = "Onboarding"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            // Match SettingsWindowController: an LSUIElement (menu-bar-only) app
            // cannot reliably surface a titled window on macOS 14+ unless we
            // temporarily promote to a regular app. Without this the onboarding
            // flow was created but stayed invisible behind the frontmost app.
            window.collectionBehavior = [.managed, .participatesInCycle, .fullScreenAuxiliary]
            window.hidesOnDeactivate = false
            window.isExcludedFromWindowsMenu = false
            window.contentView = NSHostingView(
                rootView: OnboardingView(
                    step: resumedStep,
                    onFinish: {
                        window.orderOut(nil)
                        window.close()
                        NSApp.setActivationPolicy(.accessory)
                        NSApp.deactivate()

                        // A fresh Accessibility grant only goes live on the next launch,
                        // so relaunch once here when onboarding finishes: the push-to-talk
                        // CGEvent tap only delivers events in a process trusted at launch,
                        // and macOS does NOT force a relaunch for Accessibility on its own,
                        // so without this the hotkeys are silently dead even though Settings
                        // shows Perch ON. (See accessibilityTapNeedsRelaunch…) Screen
                        // Recording is no longer part of onboarding — it's requested
                        // just-in-time on the first screenshot, which owns its own relaunch.
                        if WindowPositionManager.accessibilityTapNeedsRelaunchToActivate() {
                            ApplicationRelauncher.restart()
                            return
                        }

                        // Greet the user in the notch now that setup is complete.
                        // closeHello() (HelloAnimation.onFinish) flips this back off
                        // once the animation has played through once.
                        ViewCoordinator.shared.helloAnimationRunning = true
                    },
                    onOpenSettings: {
                        window.close()
                        SettingsWindowController.shared.showWindow()
                    }
                ))
            window.isRestorable = false
            window.identifier = NSUserInterfaceItemIdentifier(OnboardingProgress.windowIdentifier)

            onboardingWindowController = NSWindowController(window: window)
        }

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindowController?.window?.orderFrontRegardless()
        onboardingWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    /// Presents the music-source picker on its own, outside onboarding — used by
    /// the notch's "Connect Music" prompt and the now-playing-deprecated
    /// re-prompt. Reuses `MusicControllerSelectionView`, whose Continue writes
    /// `.mediaController` and posts `.mediaControllerChanged` so `MusicManager`
    /// rebuilds the controller live; here `onContinue` just closes the window.
    func showMusicSourcePicker() {
        if musicSourceWindowController == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 600),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.center()
            window.title = "Music Source"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.collectionBehavior = [.managed, .participatesInCycle, .fullScreenAuxiliary]
            window.hidesOnDeactivate = false
            window.isExcludedFromWindowsMenu = false
            window.isRestorable = false
            window.identifier = NSUserInterfaceItemIdentifier("MusicSourceWindow")
            window.contentView = NSHostingView(
                rootView: MusicControllerSelectionView(
                    onContinue: { [weak self] in
                        self?.musicSourceWindowController?.window?.orderOut(nil)
                        NSApp.setActivationPolicy(.accessory)
                        NSApp.deactivate()
                    }
                )
            )
            musicSourceWindowController = NSWindowController(window: window)
        }

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        musicSourceWindowController?.window?.center()
        musicSourceWindowController?.window?.orderFrontRegardless()
        musicSourceWindowController?.window?.makeKeyAndOrderFront(nil)
    }
}

extension Notification.Name {
    static let selectedScreenChanged = Notification.Name("SelectedScreenChanged")
    static let notchHeightChanged = Notification.Name("NotchHeightChanged")
    static let showOnAllDisplaysChanged = Notification.Name("showOnAllDisplaysChanged")
    static let automaticallySwitchDisplayChanged = Notification.Name("automaticallySwitchDisplayChanged")
    static let expandedDragDetectionChanged = Notification.Name("expandedDragDetectionChanged")
}

extension CGRect: @retroactive Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(origin.x)
        hasher.combine(origin.y)
        hasher.combine(size.width)
        hasher.combine(size.height)
    }

    public static func == (lhs: CGRect, rhs: CGRect) -> Bool {
        return lhs.origin == rhs.origin && lhs.size == rhs.size
    }
}


// MARK: - Dogfood auto-login (dev only)

/// A DEV-ONLY launch shortcut so a freshly (re)built local dogfood app lands
/// straight in the main UI — logged into the developer's account, with no
/// onboarding and no permission screens.
///
/// Everything is gated behind a **gitignored** `support/dev-autologin.json`
/// (`enabled: true`). Without that file this is a complete no-op, so it is safe
/// to leave compiled into any build — and it never ships, because the config is
/// gitignored and `Useperch/perch-app` is a PUBLIC repo (no secret lives in code
/// here; the email/token live only in the ignored config on the machine).
///
/// Note: the live OS TCC grants (Accessibility / Screen Recording / Microphone)
/// cannot be injected from a file — they must be granted once in System Settings.
/// They persist for the stable-signed "Perch Dev" bundle across rebuilds, so this
/// only needs to skip the onboarding *screens*, not grant the capabilities.
enum PerchDevBootstrap {

    private struct Config: Decodable {
        var enabled: Bool
        var installId: String?
        var email: String?
        var emailVerified: Bool?
        var installToken: String?
        var markScreenContentPermission: Bool?
    }

    private static func loadConfig() -> Config? {
        let url = PerchSupportPaths.file("dev-autologin.json")
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(Config.self, from: data),
              config.enabled else { return nil }
        return config
    }

    /// Patch the on-disk identity so the app boots logged in. Merges the account
    /// email + verified flag into the EXISTING identity file (preserving installId,
    /// install token, and entitlement/usage of the current registered install); if no
    /// identity file exists yet, writes a minimal verified one. Uses JSONSerialization
    /// so unknown fields (e.g. `entitlement`) are preserved verbatim. No-op without the
    /// gitignored config. Called from PerchInstallIdentity.loadOrMintIdentity().
    static func seedIdentityIfConfigured(at identityURL: URL) {
        guard let config = loadConfig() else { return }

        var dict: [String: Any] = [:]
        if let data = try? Data(contentsOf: identityURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            dict = existing
        }
        if (dict["installId"] as? String)?.isEmpty ?? true {
            let seededId = (config.installId?.isEmpty == false ? config.installId! : UUID().uuidString)
            dict["installId"] = seededId.lowercased()
        }
        if dict["tracingEnabled"] == nil { dict["tracingEnabled"] = true }

        let email = (config.email?.isEmpty == false) ? config.email : (dict["email"] as? String)
        if let email, !email.isEmpty {
            dict["email"] = email
            dict["emailVerified"] = config.emailVerified ?? true
        }
        if let token = config.installToken, !token.isEmpty {
            dict["installToken"] = token
        }

        guard JSONSerialization.isValidJSONObject(dict),
              let out = try? JSONSerialization.data(
                withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(
            at: identityURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? out.write(to: identityURL, options: .atomic)
        NSLog("[PerchDevBootstrap] dev auto-login: identity seeded (email attached).")
    }

    /// Mark onboarding + the one persisted permission gate complete so the launch
    /// flow skips straight to the main UI. No-op without the gitignored config.
    static func applyOnboardingAndPermissionSkips() {
        guard let config = loadConfig() else { return }
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: "firstLaunch")
        defaults.set(true, forKey: "hasCompletedOnboarding")
        defaults.set(true, forKey: "hasSubmittedEmail")
        defaults.removeObject(forKey: "perch.onboarding.resumeStep")
        if config.markScreenContentPermission ?? true {
            defaults.set(true, forKey: "hasScreenContentPermission")
        }
        NSLog("[PerchDevBootstrap] dev auto-login: onboarding + screen-content permission skipped.")
    }
}
