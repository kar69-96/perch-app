//
//  ContentView.swift
//  notchApp
//
//  Created by Harsh Vardhan Goswami  on 02/08/24
//  Modified by Richard Kunkli on 24/08/2024.
//

import AVFoundation
import Combine
import Defaults
import KeyboardShortcuts
import SwiftUI
import SwiftUIIntrospect

@MainActor
struct ContentView: View {
    @EnvironmentObject var vm: ViewModel
    @EnvironmentObject var companionManager: CompanionManager
    @ObservedObject var webcamManager = WebcamManager.shared

    @ObservedObject var coordinator = ViewCoordinator.shared
    @ObservedObject var textInput = NotchTextInputController.shared
    @ObservedObject var musicManager = MusicManager.shared
    @ObservedObject var batteryModel = BatteryStatusViewModel.shared
    @ObservedObject var brightnessManager = BrightnessManager.shared
    @ObservedObject var volumeManager = VolumeManager.shared
    @State private var hoverTask: Task<Void, Never>?
    @State private var isHovering: Bool = false
    @State private var anyDropDebounceTask: Task<Void, Never>?

    @State private var gestureProgress: CGFloat = .zero

    /// Keeps the voice tracing line mounted briefly after voice ends so it can
    /// condense back into the notch instead of disappearing instantly.
    @State private var voiceLineMounted: Bool = false
    @State private var voiceLineUnmountTask: Task<Void, Never>?

    /// Separate trigger for the Dashboard-launch haptic so it can use a firmer,
    /// clearly-felt "click" (`.levelChange`) distinct from the soft `.alignment`
    /// tick used elsewhere — the user should feel a definite detent the instant
    /// the Dashboard releases open.
    @State private var dashboardLaunchHaptics: Bool = false

    /// Latches so one downward swipe over the open notch launches Perch's dashboard
    /// exactly once (the pan gesture fires `handleDownGesture` repeatedly while dragging).
    @State private var didLaunchDashboardThisSwipe = false

    /// Opening the Dashboard is a deliberate, high-effort gesture: it requires a
    /// downward swipe this many times longer than simply opening the notch, so it
    /// can never fire by accident from an ordinary scroll.
    private let dashboardLaunchResistanceMultiplier: CGFloat = 2.5

    @Namespace var albumArtNamespace

    @Default(.useMusicVisualizer) var useMusicVisualizer

    @Default(.showNotHumanFace) var showNotHumanFace

    // Shared interactive spring for movement/resizing to avoid conflicting animations
    private let animationSpring = Animation.interactiveSpring(response: 0.38, dampingFraction: 0.8, blendDuration: 0)

    private let extendedHoverPadding: CGFloat = 30
    private let zeroHeightHoverPadding: CGFloat = 10

    private var topCornerRadius: CGFloat {
       ((vm.notchState == .open) && Defaults[.cornerRadiusScaling])
                ? cornerRadiusInsets.opened.top
                : cornerRadiusInsets.closed.top
    }

    private var currentNotchShape: NotchShape {
        NotchShape(
            topCornerRadius: topCornerRadius,
            bottomCornerRadius: ((vm.notchState == .open) && Defaults[.cornerRadiusScaling])
                ? cornerRadiusInsets.opened.bottom
                : cornerRadiusInsets.closed.bottom
        )
    }

    /// True when the voice agent is active and the notch is closed — drives the
    /// voice live-activity row and the tracing-line overlay.
    private var isVoiceActivityVisible: Bool {
        companionManager.voiceState != .idle && vm.notchState == .closed
    }

    /// Whether the music live activity is eligible to occupy the closed island
    /// (music is present and the feature is on). The agent live activity only
    /// claims the closed island when this is false; otherwise the agent rides
    /// MusicLiveActivity's right flank instead (Option 1 coexistence).
    private var isMusicLiveActivityEligible: Bool {
        (musicManager.isPlaying || !musicManager.isPlayerIdle) && coordinator.musicLiveActivityEnabled
    }

    /// The blue tracing-line glow wraps the notch for BOTH voice activity and the
    /// typed-input composer — they share the exact same outline treatment.
    private var isNotchAuraActive: Bool {
        isVoiceActivityVisible || textInput.isActive
    }

    /// While music is playing, the voice aura matches the now-playing album accent;
    /// otherwise it uses the default blue family.
    private var voiceAuraPalette: VoiceAuraPalette {
        VoiceAuraPaletteResolver.resolve(musicManager: musicManager)
    }

    /// The palette the notch glow actually draws with. Voice activity tints with
    /// the now-playing album accent; the typed-input composer is ALWAYS the
    /// canonical blue (it has no album identity of its own).
    private var notchAuraPalette: VoiceAuraPalette {
        isVoiceActivityVisible ? voiceAuraPalette : .blue
    }

    private var computedChinWidth: CGFloat {
        // Voice activity AND the typed-input composer widen the notch to the same
        // width (the composer is the listening bar, just taller).
        if isVoiceActivityVisible || textInput.isActive {
            return vm.closedNotchSize.width
                + VoiceLiveActivity.leftEarWidth + VoiceLiveActivity.rightEarWidth
                + 2 * VoiceLiveActivity.earGap
        }

        var chinWidth: CGFloat = vm.closedNotchSize.width

        if coordinator.expandingView.type == .battery && coordinator.expandingView.show
            && vm.notchState == .closed && Defaults[.showPowerStatusNotifications]
        {
            chinWidth = 640
        } else if (!coordinator.expandingView.show || coordinator.expandingView.type == .music)
            && vm.notchState == .closed && (musicManager.isPlaying || !musicManager.isPlayerIdle)
            && coordinator.musicLiveActivityEnabled && !vm.hideOnClosed
        {
            chinWidth += (2 * max(0, vm.effectiveClosedNotchHeight - 12) + 20)
        } else if !coordinator.expandingView.show && vm.notchState == .closed
            && (!musicManager.isPlaying && musicManager.isPlayerIdle) && Defaults[.showNotHumanFace]
            && !vm.hideOnClosed
        {
            chinWidth += (2 * max(0, vm.effectiveClosedNotchHeight - 12) + 20)
        }

        return chinWidth
    }

    var body: some View {
        // Calculate scale based on gesture progress only
        let gestureScale: CGFloat = {
            guard gestureProgress != 0 else { return 1.0 }
            let scaleFactor = 1.0 + gestureProgress * 0.01
            return max(0.6, scaleFactor)
        }()
        
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                let mainLayout = NotchLayout()
                    .frame(alignment: .top)
                    .padding(
                        .horizontal,
                        vm.notchState == .open
                        ? Defaults[.cornerRadiusScaling]
                        ? (cornerRadiusInsets.opened.top) : (cornerRadiusInsets.opened.bottom)
                        : cornerRadiusInsets.closed.bottom
                    )
                    .padding([.horizontal, .bottom], vm.notchState == .open ? 12 : 0)
                    // While the voice outline is mounted, grow the black notch fill
                    // down by the same amount the outline used to overshoot, so the
                    // tracing line hugs the bottom of the fill instead of floating
                    // 6px below it in the wallpaper. (Pairs with bottomExtension: 0
                    // on NotchVoiceOutline — the outline now traces this taller fill.)
                    .padding(.bottom, voiceLineMounted && vm.notchState != .open
                        ? NotchVoiceOutline.fillBottomExtension : 0)
                    .background(.black)
                    .clipShape(currentNotchShape)
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(.black)
                            .frame(height: 1)
                            .padding(.horizontal, topCornerRadius)
                    }
                    // Voice agent: the blue tracing line that draws in around the
                    // notch outline and then floats calmly while voice is active.
                    .overlay {
                        // Stays mounted through the condense-out so the line can
                        // retract back into the notch instead of vanishing.
                        if voiceLineMounted {
                            NotchVoiceOutline(
                                topCornerRadius: topCornerRadius,
                                bottomCornerRadius: cornerRadiusInsets.closed.bottom,
                                palette: .blue,
                                isActive: isNotchAuraActive
                            )
                            .allowsHitTesting(false)
                        }
                    }
                    .shadow(
                        color: ((vm.notchState == .open || isHovering) && Defaults[.enableShadow])
                            ? .black.opacity(0.7) : .clear, radius: Defaults[.cornerRadiusScaling] ? 6 : 4
                    )
                    .padding(
                        .bottom,
                        vm.effectiveClosedNotchHeight == 0 ? 10 : 0
                    )
                
                mainLayout
                    // Pin to the top so the tab header always sits at the same place:
                    // if a tab's content ever exceeds the open height it bleeds DOWN,
                    // never upward into / above the header.
                    .frame(height: vm.notchState == .open ? vm.notchSize.height : nil, alignment: .top)
                    .conditionalModifier(true) { view in
                        let openAnimation = Animation.spring(response: 0.42, dampingFraction: 0.8, blendDuration: 0)
                        let closeAnimation = Animation.spring(response: 0.45, dampingFraction: 1.0, blendDuration: 0)
                        
                        return view
                            .animation(vm.notchState == .open ? openAnimation : closeAnimation, value: vm.notchState)
                            .animation(.smooth, value: gestureProgress)
                            // Smoothly grow/shrink the notch as voice activity comes and goes.
                            .animation(.smooth(duration: 0.3), value: companionManager.voiceState)
                            // Same easing when the typed-input composer opens/closes.
                            .animation(.smooth(duration: 0.3), value: textInput.isActive)
                    }
                    .contentShape(Rectangle())
                    .onChange(of: isNotchAuraActive) { _, isActive in
                        voiceLineUnmountTask?.cancel()
                        if isActive {
                            // Mount immediately so the line can draw in.
                            voiceLineMounted = true
                        } else {
                            // Keep it mounted through the condense-out, then remove.
                            voiceLineUnmountTask = Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(420))
                                guard !Task.isCancelled, !isNotchAuraActive else { return }
                                voiceLineMounted = false
                            }
                        }
                    }


                    .onAppear {
                        companionManager.configureNotchAlertPresentation(
                            isNotchOpen: { vm.notchState == .open },
                            isHigherPrioritySurfaceVisible: {
                                companionManager.voiceState != .idle
                                    || coordinator.sneakPeek.show
                                    || companionManager.serviceConnectionOfferCoordinator.currentOffer != nil
                                    || companionManager.pendingAgentConfirmation != nil
                            }
                        )
                    }
                    .onChange(of: vm.notchState) { _, newState in
                        if newState == .open {
                            companionManager.notchAlertCoordinator.refreshPresentation()
                            Task {
                                await companionManager.pollNotchAlertsOnce()
                            }
                        }
                        // When the tray closes, bring the composer back (with its
                        // staged context intact) if the "+" button opened the tray.
                        if newState == .closed {
                            textInput.restoreComposerAfterTray()
                        }
                    }
                    // The composer's "+" button opens the tray (Shelf) as a context
                    // drop zone. Open it directly rather than via `doOpen()`, whose
                    // guard bails while the composer is (was) active.
                    .onReceive(NotificationCenter.default.publisher(for: .perchShowShelf)) { _ in
                        coordinator.currentView = .shelf
                        withAnimation(animationSpring) {
                            vm.open()
                        }
                    }
                    // A background agent needs an answer (confirmation gate /
                    // connect-integration request): auto-open the closed notch on the
                    // home view, where the card renders — an unseen confirmation is
                    // auto-denied by the sidecar after ~120s. Skip while the composer
                    // is active (mirrors doOpen's guard) or a system Focus is on; the
                    // card still shows whenever the user opens the notch themselves.
                    .onReceive(
                        NotificationCenter.default.publisher(for: .perchAgentAttentionRequired)
                    ) { _ in
                        guard vm.notchState == .closed,
                              !textInput.isActive,
                              !companionManager.systemFocusStatusMonitor.isFocusActive
                        else { return }
                        coordinator.currentView = .home
                        withAnimation(animationSpring) {
                            vm.open()
                        }
                    }
                    .onChange(of: companionManager.systemFocusStatusMonitor.isFocusActive) { _, isFocusActive in
                        if isFocusActive {
                            companionManager.notchAlertCoordinator.clearCurrentAlertForSystemFocus()
                        } else {
                            companionManager.notchAlertCoordinator.refreshPresentation()
                        }
                    }
                    .onHover { hovering in
                        handleHover(hovering)
                    }
                    .onTapGesture {
                        doOpen()
                    }
                    .conditionalModifier(Defaults[.enableGestures]) { view in
                        view
                            .panGesture(direction: .down) { translation, phase in
                                handleDownGesture(translation: translation, phase: phase)
                            }
                    }
                    .conditionalModifier(Defaults[.closeGestureEnabled] && Defaults[.enableGestures]) { view in
                        view
                            .panGesture(direction: .up) { translation, phase in
                                handleUpGesture(translation: translation, phase: phase)
                            }
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .sharingDidFinish)) { _ in
                        if vm.notchState == .open && !isHovering && !vm.isBatteryPopoverActive {
                            hoverTask?.cancel()
                            hoverTask = Task {
                                try? await Task.sleep(for: .milliseconds(100))
                                guard !Task.isCancelled else { return }
                                await MainActor.run {
                                    if self.vm.notchState == .open && !self.isHovering && !self.vm.isBatteryPopoverActive && !SharingStateManager.shared.preventNotchClose {
                                        self.vm.close()
                                    }
                                }
                            }
                        }
                    }
                    .onChange(of: vm.notchState) { _, newState in
                        if newState == .closed && isHovering {
                            withAnimation {
                                isHovering = false
                            }
                        }
                        // Fire a haptic tap on every notch open AND close,
                        // regardless of how the transition was triggered (hover,
                        // swipe, or programmatic). Centralizing it here — instead
                        // of scattering `haptics.toggle()` across the individual
                        // open/close paths — guarantees both edges always tick.
                        // We perform it directly via NSHapticFeedbackManager
                        // rather than `.sensoryFeedback` because the latter does
                        // not reliably fire for hover-driven opens (there is no
                        // active trackpad gesture for SwiftUI to attach feedback to).
                        if Defaults[.enableHaptics] {
                            NSHapticFeedbackManager.defaultPerformer.perform(
                                .alignment,
                                performanceTime: .now
                            )
                        }
                    }
                    .onChange(of: vm.isBatteryPopoverActive) {
                        if !vm.isBatteryPopoverActive && !isHovering && vm.notchState == .open && !SharingStateManager.shared.preventNotchClose {
                            hoverTask?.cancel()
                            hoverTask = Task {
                                try? await Task.sleep(for: .milliseconds(100))
                                guard !Task.isCancelled else { return }
                                await MainActor.run {
                                    if !self.vm.isBatteryPopoverActive && !self.isHovering && self.vm.notchState == .open && !SharingStateManager.shared.preventNotchClose {
                                        self.vm.close()
                                    }
                                }
                            }
                        }
                    }
                    .sensoryFeedback(.levelChange, trigger: dashboardLaunchHaptics)
                    .contextMenu {
                        Button("Settings") {
                            DispatchQueue.main.async {
                                SettingsWindowController.shared.showWindow()
                            }
                        }
                        .keyboardShortcut(KeyEquivalent(","), modifiers: .command)
                        //                    Button("Edit") { // Doesnt work....
                        //                        let dn = DynamicNotch(content: EditPanelView())
                        //                        dn.toggle()
                        //                    }
                        //                    .keyboardShortcut("E", modifiers: .command)
                    }
                if vm.chinHeight > 0 {
                    Rectangle()
                        .fill(Color.black.opacity(0.01))
                        .frame(width: computedChinWidth, height: vm.chinHeight)
                }
            }
        }
        .padding(.bottom, 8)
        // Only let content grow past the normal notch window once the typed chat
        // thread actually has messages — an empty composer stays at the base size and
        // never grows on its own. With messages, content grows to intrinsic height
        // (the notch window is resized to match in AppDelegate; the transcript caps
        // itself to the screen).
        .frame(
            maxWidth: windowSize.width,
            maxHeight: (textInput.isActive && !companionManager.typedChatMessages.isEmpty)
                ? (NSScreen.main?.frame.height ?? 1200)
                : windowSize.height,
            alignment: .top
        )
        .compositingGroup()
        .scaleEffect(
            x: gestureScale,
            y: gestureScale,
            anchor: .top
        )
        .animation(.smooth, value: gestureProgress)
        .background(dragDetector)
        .preferredColorScheme(.dark)
        .environmentObject(vm)
        .onChange(of: vm.anyDropZoneTargeting) { _, isTargeted in
            anyDropDebounceTask?.cancel()

            if isTargeted {
                if vm.notchState == .closed {
                    coordinator.currentView = .shelf
                    doOpen()
                }
                return
            }

            anyDropDebounceTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }

                if vm.dropEvent {
                    vm.dropEvent = false
                    return
                }

                vm.dropEvent = false
                if !SharingStateManager.shared.preventNotchClose {
                    vm.close()
                }
            }
        }
    }

    @ViewBuilder
    func NotchLayout() -> some View {
        VStack(alignment: .leading) {
            VStack(alignment: .leading) {
                if coordinator.helloAnimationRunning {
                    Spacer()
                    HelloAnimation(onFinish: {
                        vm.closeHello()
                    }).frame(
                        width: getClosedNotchSize().width,
                        height: 80
                    )
                    .padding(.top, 40)
                    Spacer()
                } else {
                    if textInput.isActive {
                        // Typed-input composer: the listening bar, but taller, with
                        // the text field at the bottom. Shares the notch's blue glow.
                        NotchTextInputComposer()
                            .transition(.opacity)
                    } else if isVoiceActivityVisible {
                        VoiceLiveActivity()
                            .frame(alignment: .center)
                            .transition(.opacity)
                    } else if coordinator.expandingView.type == .battery && coordinator.expandingView.show
                        && vm.notchState == .closed && Defaults[.showPowerStatusNotifications]
                    {
                        HStack(spacing: 0) {
                            HStack {
                                Text(batteryModel.statusText)
                                    .font(.subheadline)
                                    .foregroundStyle(.white)
                            }

                            Rectangle()
                                .fill(.black)
                                .frame(width: vm.closedNotchSize.width + 10)

                            HStack {
                                NotchBatteryView(
                                    batteryWidth: 30,
                                    isCharging: batteryModel.isCharging,
                                    isInLowPowerMode: batteryModel.isInLowPowerMode,
                                    isPluggedIn: batteryModel.isPluggedIn,
                                    levelBattery: batteryModel.levelBattery,
                                    isForNotification: true
                                )
                            }
                            .frame(width: 76, alignment: .trailing)
                        }
                        .frame(height: vm.effectiveClosedNotchHeight, alignment: .center)
                      } else if coordinator.sneakPeek.show && Defaults[.inlineHUD] && (coordinator.sneakPeek.type != .music) && (coordinator.sneakPeek.type != .battery) && vm.notchState == .closed {
                          InlineHUD(type: $coordinator.sneakPeek.type, value: $coordinator.sneakPeek.value, icon: $coordinator.sneakPeek.icon, hoverAnimation: $isHovering, gestureProgress: $gestureProgress)
                              .transition(.opacity)
                      } else if (!coordinator.expandingView.show || coordinator.expandingView.type == .music) && vm.notchState == .closed && (musicManager.isPlaying || !musicManager.isPlayerIdle) && coordinator.musicLiveActivityEnabled && !vm.hideOnClosed {
                          MusicLiveActivity()
                              .frame(alignment: .center)
                      } else if !coordinator.expandingView.show && vm.notchState == .closed && (!musicManager.isPlaying && musicManager.isPlayerIdle) && Defaults[.showNotHumanFace] && !vm.hideOnClosed  {
                          FaceAnimation()
                       } else if vm.notchState == .open {
                           Header()
                               .frame(height: max(24, vm.effectiveClosedNotchHeight))
                               .opacity(gestureProgress != 0 ? 1.0 - min(abs(gestureProgress) * 0.1, 0.3) : 1.0)
                       } else {
                           Rectangle().fill(.clear).frame(width: vm.closedNotchSize.width - 20, height: vm.effectiveClosedNotchHeight)
                       }

                      if coordinator.sneakPeek.show {
                          if (coordinator.sneakPeek.type != .music) && (coordinator.sneakPeek.type != .battery) && !Defaults[.inlineHUD] && vm.notchState == .closed {
                              SystemEventIndicatorModifier(
                                  eventType: $coordinator.sneakPeek.type,
                                  value: $coordinator.sneakPeek.value,
                                  icon: $coordinator.sneakPeek.icon,
                                  sendEventBack: { newVal in
                                      switch coordinator.sneakPeek.type {
                                      case .volume:
                                          VolumeManager.shared.setAbsolute(Float32(newVal))
                                      case .brightness:
                                          BrightnessManager.shared.setAbsolute(value: Float32(newVal))
                                      default:
                                          break
                                      }
                                  }
                              )
                              .padding(.bottom, 10)
                              .padding(.leading, 4)
                              .padding(.trailing, 8)
                          }
                          // Old sneak peek music
                          else if coordinator.sneakPeek.type == .music {
                              if vm.notchState == .closed && !vm.hideOnClosed && Defaults[.sneakPeekStyles] == .standard {
                                  HStack(alignment: .center) {
                                      Image(systemName: "music.note")
                                      GeometryReader { geo in
                                          MarqueeText(.constant(musicManager.songTitle + " - " + musicManager.artistName),  textColor: Defaults[.playerColorTinting] ? Color(nsColor: musicManager.avgColor).ensureMinimumBrightness(factor: 0.6) : .gray, minDuration: 1, frameWidth: geo.size.width)
                                      }
                                  }
                                  .foregroundStyle(.gray)
                                  .padding(.bottom, 10)
                              }
                          }
                      }
                  }
              }
              .conditionalModifier((coordinator.sneakPeek.show && (coordinator.sneakPeek.type == .music) && vm.notchState == .closed && !vm.hideOnClosed && Defaults[.sneakPeekStyles] == .standard) || (coordinator.sneakPeek.show && (coordinator.sneakPeek.type != .music) && (vm.notchState == .closed))) { view in
                  view
                      .fixedSize()
              }
              .zIndex(2)
            if vm.notchState == .open {
                VStack {
                    switch coordinator.currentView {
                    case .home:
                        NotchHomeView(
                            serviceConnectionOfferCoordinator: companionManager.serviceConnectionOfferCoordinator,
                            albumArtNamespace: albumArtNamespace
                        )
                    case .shelf:
                        ShelfView()
                    case .settings:
                        NotchInlineSettingsView()
                    }
                }
                .transition(
                    .scale(scale: 0.8, anchor: .top)
                    .combined(with: .opacity)
                    .animation(.smooth(duration: 0.35))
                )
                .zIndex(1)
                .allowsHitTesting(vm.notchState == .open)
                .opacity(gestureProgress != 0 ? 1.0 - min(abs(gestureProgress) * 0.1, 0.3) : 1.0)
            }
        }
        .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data], delegate: GeneralDropTargetDelegate(isTargeted: $vm.generalDropTargeting))
    }

    @ViewBuilder
    func FaceAnimation() -> some View {
        HStack {
            HStack {
                Rectangle()
                    .fill(.clear)
                    .frame(
                        width: max(0, vm.effectiveClosedNotchHeight - 12),
                        height: max(0, vm.effectiveClosedNotchHeight - 12)
                    )
                Rectangle()
                    .fill(.black)
                    .frame(width: vm.physicalNotchCenterWidth)
                MinimalFaceFeatures()
            }
        }.frame(
            height: vm.effectiveClosedNotchHeight,
            alignment: .center
        )
    }

    @ViewBuilder
    func MusicLiveActivity() -> some View {
        HStack {
            Image(nsImage: musicManager.albumArt)
                .resizable()
                .clipped()
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: MusicPlayerImageSizes.cornerRadiusInset.closed)
                )
                .matchedGeometryEffect(id: "albumArt", in: albumArtNamespace)
                .frame(
                    width: max(0, vm.effectiveClosedNotchHeight - 12),
                    height: max(0, vm.effectiveClosedNotchHeight - 12)
                )

            Rectangle()
                .fill(.black)
                .overlay(
                    HStack(alignment: .top) {
                        if coordinator.expandingView.show
                            && coordinator.expandingView.type == .music
                        {
                            MarqueeText(
                                .constant(musicManager.songTitle),
                                textColor: Defaults[.coloredSpectrogram]
                                    ? Color(nsColor: musicManager.avgColor) : Color.gray,
                                minDuration: 0.4,
                                frameWidth: 100
                            )
                            .opacity(
                                (coordinator.expandingView.show
                                    && Defaults[.sneakPeekStyles] == .inline)
                                    ? 1 : 0
                            )
                            Spacer(minLength: vm.closedNotchSize.width)
                            // Song Artist
                            Text(musicManager.artistName)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .foregroundStyle(
                                    Defaults[.coloredSpectrogram]
                                        ? Color(nsColor: musicManager.avgColor)
                                        : Color.gray
                                )
                                .opacity(
                                    (coordinator.expandingView.show
                                        && coordinator.expandingView.type == .music
                                        && Defaults[.sneakPeekStyles] == .inline)
                                        ? 1 : 0
                                )
                        }
                    }
                )
                .frame(
                    width: (coordinator.expandingView.show
                        && coordinator.expandingView.type == .music
                        && Defaults[.sneakPeekStyles] == .inline)
                        ? 380
                        : vm.physicalNotchCenterWidth
                )

            HStack {
                // The closed notch's right slot: the normal music visualizer /
                // animation. (A running agent no longer takes over the closed island —
                // the notch stays on music / its default while work happens in the
                // open Agents tab.)
                if useMusicVisualizer {
                    Rectangle()
                        .fill(
                            Defaults[.coloredSpectrogram]
                                ? Color(nsColor: musicManager.avgColor).gradient
                                : Color.gray.gradient
                        )
                        .frame(width: 50, alignment: .center)
                        .matchedGeometryEffect(id: "spectrum", in: albumArtNamespace)
                        .mask {
                            AudioSpectrumView(isPlaying: $musicManager.isPlaying)
                                .frame(width: 16, height: 12)
                        }
                } else {
                    LottieAnimationContainer()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(
                width: max(
                    0,
                    vm.effectiveClosedNotchHeight - 12
                        + gestureProgress / 2
                ),
                height: max(
                    0,
                    vm.effectiveClosedNotchHeight - 12
                ),
                alignment: .center
            )
        }
        .frame(
            height: vm.effectiveClosedNotchHeight,
            alignment: .center
        )
    }

    @ViewBuilder
    var dragDetector: some View {
        if Defaults[.shelf] && vm.notchState == .closed {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data], isTargeted: $vm.dragDetectorTargeting) { providers in
            vm.dropEvent = true
            ShelfStateViewModel.shared.load(providers)
            return true
        }
        } else {
            EmptyView()
        }
    }

    private func doOpen() {
        // The text-input composer lives in the closed notch and is interactive
        // (typing, buttons). Don't let a stray tap on it expand the notch to the
        // full dashboard size and tear the composer down.
        if textInput.isActive { return }
        // The open/close haptic is fired centrally from `.onChange(of: vm.notchState)`,
        // so it covers this path too without an explicit toggle here.
        withAnimation(animationSpring) {
            vm.open()
        }
    }

    // MARK: - Hover Management

    private func handleHover(_ hovering: Bool) {
        if coordinator.firstLaunch { return }
        // Ignore hover while the text-input composer is up so it neither opens the
        // full notch nor closes the composer out from under the user.
        if textInput.isActive { return }
        hoverTask?.cancel()
        
        if hovering {
            withAnimation(animationSpring) {
                isHovering = true
            }
            
            guard vm.notchState == .closed,
                  !coordinator.sneakPeek.show,
                  Defaults[.openNotchOnHover] else { return }
            
            hoverTask = Task {
                try? await Task.sleep(for: .seconds(Defaults[.minimumHoverDuration]))
                guard !Task.isCancelled else { return }
                
                await MainActor.run {
                    guard self.vm.notchState == .closed,
                          self.isHovering,
                          !self.coordinator.sneakPeek.show else { return }
                    
                    self.doOpen()
                }
            }
        } else {
            hoverTask = Task {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                
                await MainActor.run {
                    withAnimation(animationSpring) {
                        self.isHovering = false
                    }
                    
                    if self.vm.notchState == .open && !self.vm.isBatteryPopoverActive && !SharingStateManager.shared.preventNotchClose {
                        self.vm.close()
                    }
                }
            }
        }
    }

    // MARK: - Gesture Handling

    private func handleDownGesture(translation: CGFloat, phase: NSEvent.Phase) {
        // When the notch is already open, a downward swipe launches Perch's Daily
        // Dashboard ("scroll up" / swipe down on the trackpad). The closed-state swipe
        // still opens the notch (below), so this only repurposes the otherwise-unused
        // open-state down swipe.
        if vm.notchState == .open {
            // Launching the Dashboard demands a much longer, deliberate downward pull
            // than opening the notch — it must read as intentional, never accidental —
            // and releases with a firm haptic click once the swipe clears the higher
            // threshold. We deliberately do NOT drive `gestureProgress` here: that
            // scales the notch contents (a distracting zoom). The longer threshold
            // alone provides the resistance — you simply have to keep scrolling.
            if phase == .ended {
                didLaunchDashboardThisSwipe = false
                return
            }

            let dashboardLaunchThreshold = Defaults[.gestureSensitivity] * dashboardLaunchResistanceMultiplier

            if translation > dashboardLaunchThreshold, !didLaunchDashboardThisSwipe {
                didLaunchDashboardThisSwipe = true
                if Defaults[.enableHaptics] { dashboardLaunchHaptics.toggle() }
                DailyBriefLauncher.open()
            }
            return
        }

        guard vm.notchState == .closed else { return }

        if phase == .ended {
            withAnimation(animationSpring) { gestureProgress = .zero }
            return
        }

        withAnimation(animationSpring) {
            gestureProgress = (translation / Defaults[.gestureSensitivity]) * 20
        }

        if translation > Defaults[.gestureSensitivity] {
            withAnimation(animationSpring) {
                gestureProgress = .zero
            }
            doOpen()
        }
    }

    private func handleUpGesture(translation: CGFloat, phase: NSEvent.Phase) {
        guard vm.notchState == .open && !vm.isHoveringCalendar else { return }

        withAnimation(animationSpring) {
            gestureProgress = (translation / Defaults[.gestureSensitivity]) * -20
        }

        if phase == .ended {
            withAnimation(animationSpring) {
                gestureProgress = .zero
            }
        }

        if translation > Defaults[.gestureSensitivity] {
            withAnimation(animationSpring) {
                isHovering = false
            }
            if !SharingStateManager.shared.preventNotchClose {
                gestureProgress = .zero
                vm.close()
            }
            // Close haptic handled centrally by `.onChange(of: vm.notchState)`.
        }
    }
}

struct FullScreenDropDelegate: DropDelegate {
    @Binding var isTargeted: Bool
    let onDrop: () -> Void

    func dropEntered(info _: DropInfo) {
        isTargeted = true
    }

    func dropExited(info _: DropInfo) {
        isTargeted = false
    }

    func performDrop(info _: DropInfo) -> Bool {
        isTargeted = false
        onDrop()
        return true
    }

}

struct GeneralDropTargetDelegate: DropDelegate {
    @Binding var isTargeted: Bool

    func dropEntered(info: DropInfo) {
        isTargeted = true
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        return DropProposal(operation: .cancel)
    }

    func performDrop(info: DropInfo) -> Bool {
        return false
    }
}

#Preview {
    let vm = ViewModel()
    vm.open()
    return ContentView()
        .environmentObject(vm)
        .environmentObject(CompanionManager())
        .frame(width: vm.notchSize.width, height: vm.notchSize.height)
}
