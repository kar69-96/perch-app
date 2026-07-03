//
//  NotchHomeView.swift
//  notch
//
//  Created by Hugo Persson on 2024-08-18.
//  Modified by Harsh Vardhan Goswami & Richard Kunkli & Mustafa Ramadan
//

import AppKit
import Combine
import Defaults
import SwiftUI

// MARK: - Music Player Components

struct MusicPlayerView: View {
    @EnvironmentObject var vm: ViewModel
    @ObservedObject var notchAlertCoordinator: NotchAlertCoordinator
    @ObservedObject var serviceConnectionOfferCoordinator: ServiceConnectionOfferCoordinator
    let albumArtNamespace: Namespace.ID

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            AlbumArtView(vm: vm, albumArtNamespace: albumArtNamespace).padding(.all, 5)
            NotchHomeCenterColumn(
                notchAlertCoordinator: notchAlertCoordinator,
                serviceConnectionOfferCoordinator: serviceConnectionOfferCoordinator
            )
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AlbumArtView: View {
    @ObservedObject var musicManager = MusicManager.shared
    @ObservedObject var vm: ViewModel
    let albumArtNamespace: Namespace.ID

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if Defaults[.lightingEffect] {
                albumArtBackground
            }
            albumArtButton
        }
    }

    private var albumArtBackground: some View {
        Image(nsImage: musicManager.albumArt)
            .resizable()
            .clipped()
            .clipShape(
                RoundedRectangle(
                    cornerRadius: Defaults[.cornerRadiusScaling]
                        ? MusicPlayerImageSizes.cornerRadiusInset.opened
                        : MusicPlayerImageSizes.cornerRadiusInset.closed)
            )
            .aspectRatio(1, contentMode: .fit)
            .scaleEffect(x: 1.3, y: 1.4)
            .rotationEffect(.degrees(92))
            .blur(radius: 40)
            .opacity(musicManager.isPlaying ? 0.5 : 0)
    }

    private var albumArtButton: some View {
        ZStack {
            Button {
                musicManager.openMusicApp()
            } label: {
                ZStack(alignment:.bottomTrailing) {
                    albumArtImage
                    appIconOverlay
                }
            }
            .buttonStyle(PlainButtonStyle())
            .scaleEffect(musicManager.isPlaying ? 1 : 0.85)
            
            albumArtDarkOverlay
        }
    }

    private var albumArtDarkOverlay: some View {
        Rectangle()
            .aspectRatio(1, contentMode: .fit)
            .foregroundColor(Color.black)
            .opacity(musicManager.isPlaying ? 0 : 0.8)
            .blur(radius: 50)
    }
                

    private var albumArtImage: some View {
        Image(nsImage: musicManager.albumArt)
            .resizable()
            .aspectRatio(1, contentMode: .fit)
            .matchedGeometryEffect(id: "albumArt", in: albumArtNamespace)
            .clipped()
            .clipShape(
                RoundedRectangle(
                    cornerRadius: Defaults[.cornerRadiusScaling]
                        ? MusicPlayerImageSizes.cornerRadiusInset.opened
                        : MusicPlayerImageSizes.cornerRadiusInset.closed)
            )
    }

    @ViewBuilder
    private var appIconOverlay: some View {
        if vm.notchState == .open && !musicManager.usingAppIconForArtwork {
            AppIcon(for: musicManager.bundleIdentifier ?? "com.apple.Music")
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 30, height: 30)
                .offset(x: 10, y: 10)
                .transition(.scale.combined(with: .opacity))
                .zIndex(2)
        }
    }
}

struct MusicControlsView: View {
    @ObservedObject var musicManager = MusicManager.shared
        @EnvironmentObject var vm: ViewModel
        @ObservedObject var webcamManager = WebcamManager.shared
    @State private var sliderValue: Double = 0
    @State private var dragging: Bool = false
    @State private var lastDragged: Date = .distantPast
    @State private var songInfoAvailableWidth: CGFloat = 200
    @Default(.musicControlSlots) private var slotConfig
    @Default(.musicControlSlotLimit) private var slotLimit

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            songInfoAndSlider
            slotToolbar
        }
        .buttonStyle(PlainButtonStyle())
    }

    private var songInfoAndSlider: some View {
        VStack(alignment: .leading, spacing: 4) {
            songInfo(width: songInfoAvailableWidth)
            musicSlider
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 5)
        .background {
            GeometryReader { geometryProxy in
                Color.clear
                    .onAppear {
                        songInfoAvailableWidth = geometryProxy.size.width
                    }
                    .onChange(of: geometryProxy.size.width) { _, newWidth in
                        songInfoAvailableWidth = newWidth
                    }
            }
        }
    }

    private func songInfo(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            MarqueeText(
                $musicManager.songTitle, font: .headline, nsFont: .headline, textColor: .white,
                frameWidth: width)
            MarqueeText(
                $musicManager.artistName,
                font: .headline,
                nsFont: .headline,
                textColor: Defaults[.playerColorTinting]
                    ? Color(nsColor: musicManager.avgColor)
                        .ensureMinimumBrightness(factor: 0.6) : .gray,
                frameWidth: width
            )
            .fontWeight(.medium)
            if Defaults[.enableLyrics] {
                TimelineView(.animation(minimumInterval: 0.25)) { timeline in
                    let currentElapsed: Double = {
                        guard musicManager.isPlaying else { return musicManager.elapsedTime }
                        let delta = timeline.date.timeIntervalSince(musicManager.timestampDate)
                        let progressed = musicManager.elapsedTime + (delta * musicManager.playbackRate)
                        return min(max(progressed, 0), musicManager.songDuration)
                    }()
                    let line: String = {
                        if musicManager.isFetchingLyrics { return "Loading lyrics…" }
                        if !musicManager.syncedLyrics.isEmpty {
                            return musicManager.lyricLine(at: currentElapsed)
                        }
                        let trimmed = musicManager.currentLyrics.trimmingCharacters(in: .whitespacesAndNewlines)
                        return trimmed.isEmpty ? "No lyrics found" : trimmed.replacingOccurrences(of: "\n", with: " ")
                    }()
                    let isPersian = line.unicodeScalars.contains { scalar in
                        let v = scalar.value
                        return v >= 0x0600 && v <= 0x06FF
                    }
                    MarqueeText(
                        .constant(line),
                        font: .subheadline,
                        nsFont: .subheadline,
                        textColor: musicManager.isFetchingLyrics ? .gray.opacity(0.7) : .gray,
                        frameWidth: width
                    )
                    .font(isPersian ? .custom("Vazirmatn-Regular", size: NSFont.preferredFont(forTextStyle: .subheadline).pointSize) : .subheadline)
                    .lineLimit(1)
                    .opacity(musicManager.isPlaying ? 1 : 0)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    private var musicSlider: some View {
        TimelineView(.animation(minimumInterval: musicManager.playbackRate > 0 ? 0.1 : nil)) { timeline in
            MusicSliderView(
                sliderValue: $sliderValue,
                duration: $musicManager.songDuration,
                lastDragged: $lastDragged,
                color: musicManager.avgColor,
                dragging: $dragging,
                currentDate: timeline.date,
                timestampDate: musicManager.timestampDate,
                elapsedTime: musicManager.elapsedTime,
                playbackRate: musicManager.playbackRate,
                isPlaying: musicManager.isPlaying
            ) { newValue in
                MusicManager.shared.seek(to: newValue)
            }
        }
    }

    private var slotToolbar: some View {
        let slots = activeSlots
        return HStack(spacing: 6) {
            ForEach(Array(slots.enumerated()), id: \.offset) { index, slot in
                slotView(for: slot)
                    .frame(alignment: .center)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var activeSlots: [MusicControlButton] {
        let sanitizedLimit = min(
            max(slotLimit, MusicControlButton.minSlotCount),
            MusicControlButton.maxSlotCount
        )
        let padded = slotConfig.padded(to: sanitizedLimit, filler: .none)
        let result = Array(padded.prefix(sanitizedLimit))
        // If calendar and camera are both visible alongside music, hide the edge slots
        let shouldHideEdges = Defaults[.showCalendar] && Defaults[.showMirror] && webcamManager.cameraAvailable && vm.isCameraExpanded
        if shouldHideEdges && result.count >= 5 {
            return Array(result.dropFirst().dropLast())
        }

        return result
    }

    @ViewBuilder
    private func slotView(for slot: MusicControlButton) -> some View {
        switch slot {
        case .shuffle:
            HoverButton(icon: "shuffle", iconColor: musicManager.isShuffled ? .red : .primary, scale: .medium) {
                MusicManager.shared.toggleShuffle()
            }
        case .previous:
            HoverButton(icon: "backward.fill", scale: .medium) {
                MusicManager.shared.previousTrack()
            }
        case .playPause:
            HoverButton(icon: musicManager.isPlaying ? "pause.fill" : "play.fill", scale: .large) {
                MusicManager.shared.togglePlay()
            }
        case .next:
            HoverButton(icon: "forward.fill", scale: .medium) {
                MusicManager.shared.nextTrack()
            }
        case .repeatMode:
            HoverButton(icon: repeatIcon, iconColor: repeatIconColor, scale: .medium) {
                MusicManager.shared.toggleRepeat()
            }
        case .volume:
            VolumeControlView()
        case .favorite:
            FavoriteControlButton()
        case .goBackward:
            HoverButton(icon: "gobackward.15", scale: .medium) {
                MusicManager.shared.skip(seconds: -15)
            }
        case .goForward:
            HoverButton(icon: "goforward.15", scale: .medium) {
                MusicManager.shared.skip(seconds: 15)
            }
        case .none:
            Color.clear.frame(height: 1)
        }
    }

    private var repeatIcon: String {
        switch musicManager.repeatMode {
        case .off:
            return "repeat"
        case .all:
            return "repeat"
        case .one:
            return "repeat.1"
        }
    }

    private var repeatIconColor: Color {
        switch musicManager.repeatMode {
        case .off:
            return .primary
        case .all, .one:
            return .red
        }
    }
}

struct FavoriteControlButton: View {
    @ObservedObject var musicManager = MusicManager.shared

    var body: some View {
        HoverButton(icon: iconName, iconColor: iconColor, scale: .medium) {
            MusicManager.shared.toggleFavoriteTrack()
        }
        .disabled(!musicManager.canFavoriteTrack)
        .opacity(musicManager.canFavoriteTrack ? 1 : 0.35)
    }

    private var iconName: String {
        musicManager.isFavoriteTrack ? "heart.fill" : "heart"
    }

    private var iconColor: Color {
        musicManager.isFavoriteTrack ? .red : .primary
    }
}

private extension Array where Element == MusicControlButton {
    func padded(to length: Int, filler: MusicControlButton) -> [MusicControlButton] {
        if count >= length { return self }
        return self + Array(repeating: filler, count: length - count)
    }
}

// MARK: - Volume Control View

struct VolumeControlView: View {
    @ObservedObject var musicManager = MusicManager.shared
    @State private var volumeSliderValue: Double = 0.5
    @State private var dragging: Bool = false
    @State private var showVolumeSlider: Bool = false
    @State private var lastVolumeUpdateTime: Date = Date.distantPast
    private let volumeUpdateThrottle: TimeInterval = 0.1
    
    var body: some View {
        HStack(spacing: 4) {
            Button(action: {
                if musicManager.volumeControlSupported {
                    withAnimation(.easeInOut(duration: 0.12)) {
                        showVolumeSlider.toggle()
                    }
                }
            }) {
                Image(systemName: volumeIcon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(musicManager.volumeControlSupported ? .white : .gray)
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(!musicManager.volumeControlSupported)
            .frame(width: 24)

            if showVolumeSlider && musicManager.volumeControlSupported {
                CustomSlider(
                    value: $volumeSliderValue,
                    range: 0.0...1.0,
                    color: .white,
                    dragging: $dragging,
                    lastDragged: .constant(Date.distantPast),
                    onValueChange: { newValue in
                        MusicManager.shared.setVolume(to: newValue)
                    },
                    onDragChange: { newValue in
                        let now = Date()
                        if now.timeIntervalSince(lastVolumeUpdateTime) > volumeUpdateThrottle {
                            MusicManager.shared.setVolume(to: newValue)
                            lastVolumeUpdateTime = now
                        }
                    }
                )
                .frame(width: 48, height: 8)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .clipped()
        .onReceive(musicManager.$volume) { volume in
            if !dragging {
                volumeSliderValue = volume
            }
        }
        .onReceive(musicManager.$volumeControlSupported) { supported in
            if !supported {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showVolumeSlider = false
                }
            }
        }
        .onChange(of: showVolumeSlider) { _, isShowing in
            if isShowing {
                // Sync volume from app when slider appears
                Task {
                    await MusicManager.shared.syncVolumeFromActiveApp()
                }
            }
        }
        .onDisappear {
            // volumeUpdateTask?.cancel() // No longer needed
        }
    }
    
    
    private var volumeIcon: String {
        if !musicManager.volumeControlSupported {
            return "speaker.slash"
        } else if volumeSliderValue == 0 {
            return "speaker.slash.fill"
        } else if volumeSliderValue < 0.33 {
            return "speaker.1.fill"
        } else if volumeSliderValue < 0.66 {
            return "speaker.2.fill"
        } else {
            return "speaker.3.fill"
        }
    }
}

// MARK: - Main View

struct NotchHomeView: View {
    @EnvironmentObject var vm: ViewModel
    @EnvironmentObject var companionManager: CompanionManager
    @ObservedObject var webcamManager = WebcamManager.shared
    @ObservedObject var batteryModel = BatteryStatusViewModel.shared
    @ObservedObject var coordinator = ViewCoordinator.shared
    // Observed so the agent-driven connect prompt appears/updates/hides reactively,
    // exactly like the alert surface reacts to `notchAlertCoordinator`.
    @ObservedObject var serviceConnectionOfferCoordinator: ServiceConnectionOfferCoordinator
    let albumArtNamespace: Namespace.ID

    private var currentConnectionOffer: ServiceConnectionOffer? {
        serviceConnectionOfferCoordinator.currentOffer
    }

    private var isNotchAlertVisible: Bool {
        companionManager.notchAlertCoordinator.currentAlert != nil
    }

    /// Any open-notch surface (agent confirmation, alert, or connect prompt) is
    /// occupying the center.
    private var isNotchCenterSurfaceVisible: Bool {
        isNotchAlertVisible
            || currentConnectionOffer != nil
            || companionManager.pendingAgentConfirmation != nil
    }

    var body: some View {
        Group {
            if !coordinator.firstLaunch {
                mainContent
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // simplified: use a straightforward opacity transition
        .transition(.opacity)
        // Auto-open the notch when a running task needs a connection, so the connect
        // card is visible immediately instead of collapsed in the closed notch. Only
        // for agent-driven requests (a blocking gate the user's task depends on) — a
        // proactive "connect this?" nag must never force the notch open.
        .onChange(of: currentConnectionOffer) { _, newOffer in
            if newOffer != nil, serviceConnectionOfferCoordinator.isCurrentOfferAgentDriven {
                vm.open()
            }
        }
    }

    private var shouldShowCamera: Bool {
        Defaults[.showMirror] && webcamManager.cameraAvailable && vm.isCameraExpanded
    }

    private var mainRowSpacing: CGFloat {
        (shouldShowCamera && Defaults[.showCalendar]) ? 10 : 15
    }

    private var calendarColumnWidth: CGFloat {
        guard Defaults[.showCalendar] else { return 0 }
        return shouldShowCamera ? 170 : 215
    }

    /// Album art (90) + outer padding (10) + Spotify badge bleed.
    private var albumArtReservedWidth: CGFloat { 112 }

    private var trailingReservedWidth: CGFloat {
        calendarColumnWidth + mainRowSpacing
    }

    private var mainContent: some View {
        HStack(alignment: .top, spacing: mainRowSpacing) {
            MusicPlayerView(
                notchAlertCoordinator: companionManager.notchAlertCoordinator,
                serviceConnectionOfferCoordinator: serviceConnectionOfferCoordinator,
                albumArtNamespace: albumArtNamespace
            )

            if Defaults[.showCalendar] {
                CalendarView(notchAlertCoordinator: companionManager.notchAlertCoordinator)
                    .frame(width: calendarColumnWidth)
                    .onHover { isHovering in
                        vm.isHoveringCalendar = isHovering
                    }
                    .environmentObject(vm)
                    .environment(\.notchCalendarDisplayMode, isNotchCenterSurfaceVisible ? .notificationCompact : .expanded)
                    .transition(.opacity)
            }

            if shouldShowCamera {
                CameraPreviewView(webcamManager: webcamManager)
                    .scaledToFit()
                    .opacity(vm.notchState == .closed ? 0 : 1)
                    .blur(radius: vm.notchState == .closed ? 20 : 0)
                    .animation(.interactiveSpring(response: 0.32, dampingFraction: 0.76, blendDuration: 0), value: shouldShowCamera)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay {
            // Surface priority, most time-critical first: an agent confirmation is
            // auto-denied by the sidecar after ~120s, so it outranks the connect
            // prompt (which blocks indefinitely) and the (lowest) notch alert.
            if let agentConfirmation = companionManager.pendingAgentConfirmation {
                GeometryReader { geometry in
                    let confirmationBandWidth = max(
                        0,
                        geometry.size.width - albumArtReservedWidth - trailingReservedWidth
                    )
                    NotchAgentConfirmationContentView(
                        confirmation: agentConfirmation,
                        onApprove: {
                            companionManager.respondToAgentConfirmation(approved: true)
                        },
                        onDeny: {
                            companionManager.respondToAgentConfirmation(approved: false)
                        }
                    )
                    .frame(width: confirmationBandWidth, height: geometry.size.height)
                    .position(
                        x: geometry.size.width / 2,
                        y: geometry.size.height / 2
                    )
                }
            } else if let connectionOffer = currentConnectionOffer {
                GeometryReader { geometry in
                    let offerBandWidth = max(
                        0,
                        geometry.size.width - albumArtReservedWidth - trailingReservedWidth
                    )
                    NotchConnectionOfferContentView(
                        offer: connectionOffer,
                        connectState: serviceConnectionOfferCoordinator.connectState,
                        onConnect: {
                            serviceConnectionOfferCoordinator.acceptCurrentOffer()
                        },
                        onDecline: {
                            serviceConnectionOfferCoordinator.dismissCurrentOffer()
                        },
                        onDismiss: {
                            serviceConnectionOfferCoordinator.cancelCurrentOffer()
                        }
                    )
                    .frame(width: offerBandWidth, height: geometry.size.height)
                    .position(
                        x: geometry.size.width / 2,
                        y: geometry.size.height / 2
                    )
                }
            } else if isNotchAlertVisible, let alert = companionManager.notchAlertCoordinator.currentAlert {
                GeometryReader { geometry in
                    let alertBandWidth = max(
                        0,
                        geometry.size.width - albumArtReservedWidth - trailingReservedWidth
                    )
                    NotchAlertContentView(
                        alert: alert,
                        onAction: {
                            NotchAlertActionRouter.perform(
                                action: alert.action,
                                companionManager: companionManager,
                                browserSubagentManager: companionManager.browserSubagentManager,
                                coordinator: companionManager.notchAlertCoordinator
                            )
                        },
                        onDismiss: {
                            companionManager.notchAlertCoordinator.dismissCurrentAlert()
                        }
                    )
                    .frame(width: alertBandWidth, height: geometry.size.height)
                    // Center in the full open-notch row — not just the middle band —
                    // so the alert sits on the visual midpoint between album art and calendar.
                    .position(
                        x: geometry.size.width / 2,
                        y: geometry.size.height / 2
                    )
                }
            }
        }
        .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .top)), removal: .opacity))
        .blur(radius: vm.notchState == .closed ? 30 : 0)
    }
}

// MARK: - Perch Dashboard Widgets (dragged into the notch)
//
// A widget dragged from Perch's dashboard arrives as a self-contained JSON snapshot on a
// custom cross-app pasteboard type (Perch and notch are separate apps, so the drag
// carries the data, not a reference). These types decode it, persist the pinned widgets,
// render them in the notch's own dark style, and catch the drop. They live in this file
// (rather than new files) because notch's Xcode project lists sources individually
// — a brand-new file wouldn't be compiled until it's added to the project.

/// The decoded, persisted widget shown in the notch. The cross-app JSON has no id; one is
/// assigned on drop for list identity + removal.
struct DroppedDashboardWidget: Codable, Identifiable, Equatable {
    struct Item: Codable, Equatable, Identifiable {
        let title: String
        let subtitle: String?
        let url: String?
        let publisher: String?
        var id: String { (url ?? "") + "|" + title }
    }

    let id: String
    let title: String
    let iconSystemName: String
    let isHeadlineOnly: Bool
    let items: [Item]

    /// Decode the cross-app snapshot JSON (whose shape is the contract Perch encodes) and
    /// assign a fresh id. Returns nil if the payload isn't a valid widget snapshot.
    static func decode(from snapshotData: Data) -> DroppedDashboardWidget? {
        struct Transport: Codable {
            struct Item: Codable {
                let title: String
                let subtitle: String?
                let url: String?
                let publisher: String?
            }
            let title: String
            let iconSystemName: String
            let isHeadlineOnly: Bool
            let items: [Item]
        }
        guard let transport = try? JSONDecoder().decode(Transport.self, from: snapshotData) else {
            return nil
        }
        return DroppedDashboardWidget(
            id: UUID().uuidString,
            title: transport.title,
            iconSystemName: transport.iconSystemName,
            isHeadlineOnly: transport.isHeadlineOnly,
            items: transport.items.map {
                Item(title: $0.title, subtitle: $0.subtitle, url: $0.url, publisher: $0.publisher)
            }
        )
    }
}

/// Source of truth for the widgets pinned into the notch. Persists to a JSON file in
/// Application Support, mirroring notch's `ShelfPersistenceService` pattern.
@MainActor
final class DroppedWidgetStore: ObservableObject {
    static let shared = DroppedWidgetStore()

    @Published private(set) var widgets: [DroppedDashboardWidget] = []

    private let fileURL: URL

    init() {
        let fileManager = FileManager.default
        let supportDirectory = try? fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let widgetsDirectory = (supportDirectory ?? fileManager.temporaryDirectory)
            .appendingPathComponent("notch", isDirectory: true)
            .appendingPathComponent("Widgets", isDirectory: true)
        try? fileManager.createDirectory(at: widgetsDirectory, withIntermediateDirectories: true)
        fileURL = widgetsDirectory.appendingPathComponent("dropped-widgets.json")
        load()
    }

    func add(_ widget: DroppedDashboardWidget) {
        widgets = widgets + [widget]
        save()
    }

    func remove(id: String) {
        widgets = widgets.filter { $0.id != id }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([DroppedDashboardWidget].self, from: data)
        else { return }
        widgets = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(widgets) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// A compact dark widget card in the notch's visual language (black surface, hairline
/// border, white/gray SF Pro). Rows open their URL on click; the card shows an × on hover.
struct DroppedWidgetCardView: View {
    let widget: DroppedDashboardWidget
    var onRemove: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: widget.iconSystemName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.gray)
                Text(widget.title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.gray)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if isHovering {
                    Button(action: onRemove) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.gray)
                    }
                    .buttonStyle(.plain)
                }
            }

            ForEach(widget.items.prefix(3)) { item in
                widgetRow(item)
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(width: 150)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .onHover { isHovering = $0 }
    }

    @ViewBuilder
    private func widgetRow(_ item: DroppedDashboardWidget.Item) -> some View {
        Button {
            if let urlString = item.url, let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
            }
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                if widget.isHeadlineOnly, let publisher = item.publisher {
                    Text(publisher)
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundColor(Color(red: 0.4, green: 0.62, blue: 1.0))
                        .lineLimit(1)
                }
                Text(item.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if !widget.isHeadlineOnly, let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 9))
                        .foregroundColor(.gray)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// An AppKit drop destination (bridged into SwiftUI) that accepts the custom cross-app
/// widget-snapshot pasteboard type. Used as a `.background` so it never blocks the notch's
/// foreground controls — the drag falls through to it when nothing in front claims it.
struct PerchWidgetDropCatcher: NSViewRepresentable {
    var onDropSnapshot: (Data) -> Void

    func makeNSView(context: Context) -> NSView {
        let dropView = DropReceivingView()
        dropView.onDropSnapshotData = onDropSnapshot
        return dropView
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? DropReceivingView)?.onDropSnapshotData = onDropSnapshot
    }

    final class DropReceivingView: NSView {
        var onDropSnapshotData: ((Data) -> Void)?

        /// Must match the identifier Perch registers on the drag
        /// (`com.perch.dashboard-widget-snapshot`).
        private let snapshotType = NSPasteboard.PasteboardType("com.perch.dashboard-widget-snapshot")

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            registerForDraggedTypes([snapshotType])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        private func carriesSnapshot(_ sender: NSDraggingInfo) -> Bool {
            sender.draggingPasteboard.types?.contains(snapshotType) == true
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            carriesSnapshot(sender) ? .copy : []
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            carriesSnapshot(sender) ? .copy : []
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            guard let snapshotData = sender.draggingPasteboard.data(forType: snapshotType) else {
                return false
            }
            onDropSnapshotData?(snapshotData)
            return true
        }
    }
}

struct MusicSliderView: View {
    @Binding var sliderValue: Double
    @Binding var duration: Double
    @Binding var lastDragged: Date
    var color: NSColor
    @Binding var dragging: Bool
    let currentDate: Date
    let timestampDate: Date
    let elapsedTime: Double
    let playbackRate: Double
    let isPlaying: Bool
    var onValueChange: (Double) -> Void


    var body: some View {
        VStack {
            CustomSlider(
                value: $sliderValue,
                range: 0...duration,
                color: Defaults[.sliderColor] == SliderColorEnum.albumArt
                    ? Color(nsColor: color).ensureMinimumBrightness(factor: 0.8)
                    : Defaults[.sliderColor] == SliderColorEnum.accent ? .effectiveAccent : .white,
                dragging: $dragging,
                lastDragged: $lastDragged,
                onValueChange: onValueChange
            )
            .frame(height: 10, alignment: .center)

            HStack {
                Text(timeString(from: sliderValue))
                Spacer()
                Text(timeString(from: duration))
            }
            .fontWeight(.medium)
            .foregroundColor(
                Defaults[.playerColorTinting]
                    ? Color(nsColor: color).ensureMinimumBrightness(factor: 0.6) : .gray
            )
            .font(.caption)
        }
        .onChange(of: currentDate) {
           guard !dragging, timestampDate.timeIntervalSince(lastDragged) > -1 else { return }
            sliderValue = MusicManager.shared.estimatedPlaybackPosition(at: currentDate)
        }
    }

    func timeString(from seconds: Double) -> String {
        let totalMinutes = Int(seconds) / 60
        let remainingSeconds = Int(seconds) % 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        } else {
            return String(format: "%d:%02d", minutes, remainingSeconds)
        }
    }
}

struct CustomSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var color: Color = .white
    @Binding var dragging: Bool
    @Binding var lastDragged: Date
    var onValueChange: ((Double) -> Void)?
    var onDragChange: ((Double) -> Void)?

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = CGFloat(dragging ? 9 : 5)
            let rangeSpan = range.upperBound - range.lowerBound

            let progress = rangeSpan == .zero ? 0 : (value - range.lowerBound) / rangeSpan
            let filledTrackWidth = min(max(progress, 0), 1) * width

            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(.gray.opacity(0.3))
                    .frame(height: height)

                Rectangle()
                    .fill(color)
                    .frame(width: filledTrackWidth, height: height)
            }
            .cornerRadius(height / 2)
            .frame(height: 10)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        withAnimation {
                            dragging = true
                        }
                        let newValue = range.lowerBound + Double(gesture.location.x / width) * rangeSpan
                        value = min(max(newValue, range.lowerBound), range.upperBound)
                        onDragChange?(value)
                    }
                    .onEnded { _ in
                        onValueChange?(value)
                        dragging = false
                        lastDragged = Date()
                    }
            )
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: dragging)
        }
    }
}

// MARK: - Connect Offer Surface

/// Agent-driven "Connect [Service] to Perch?" prompt for the open-notch home row.
/// A running background task paused at a connection gate needs a Composio/native app
/// connected to proceed; this surface lets the user connect it (Yes) or decline (Not
/// now → the task falls back to driving the site itself). Modeled on
/// NotchAlertContentView so it matches the existing open-notch surface styling.
///
/// Minimal by design: the idle (offer) state shows the two buttons; while the connect
/// runs we show a plain status line (no shimmer/dots) and the surface auto-hides when
/// the coordinator clears `currentOffer` after the connect outcome.
struct NotchConnectionOfferContentView: View {
    let offer: ServiceConnectionOffer
    let connectState: ServiceConnectState
    /// "Yes" — begin connecting the offered service.
    var onConnect: () -> Void
    /// "Not now" — decline; the paused task falls back to driving the site itself.
    var onDecline: () -> Void
    /// The top-right ✕ — hard-dismiss at ANY state, including cancelling an in-flight
    /// connect (so a stuck/never-finishing OAuth doesn't trap the surface up).
    var onDismiss: () -> Void

    @ObservedObject private var musicManager = MusicManager.shared

    private var accentColor: Color {
        NotchAccentColor.fromMusicAccent(musicManager.avgColor)
    }

    private var isIdle: Bool { connectState == .idle }

    var body: some View {
        VStack(alignment: .center, spacing: 6) {
            Text(headerText)
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity)

            Text(subheaderText)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Color(white: 0.72))
                .multilineTextAlignment(.center)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity)

            // Buttons only while the offer is live; once connecting/connected/failed
            // the coordinator drives the outcome and clears the surface.
            if isIdle {
                HStack(spacing: 8) {
                    Button(action: onDecline) {
                        Text("Not now")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Color(white: 0.82))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Color(white: 0.22)))
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .onHover { isHovering in
                        if isHovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                    }

                    Button(action: onConnect) {
                        Text("Yes")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(NotchAccentColor.labelColor(on: accentColor))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(accentColor))
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .onHover { isHovering in
                        if isHovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        // ✕ dismiss — always available, at every connect state. Unlike "Not now"
        // (idle-only), this also aborts an in-flight connect so a stuck OAuth that
        // never lands can be dismissed instead of polling for the full timeout.
        .overlay(alignment: .topTrailing) {
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(Color(white: 0.62))
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color(white: 0.20)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
            .onHover { isHovering in
                if isHovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        }
    }

    private var headerText: String {
        switch connectState {
        case .idle:
            return "Connect \(offer.displayName) to Perch?"
        case .connecting:
            return "Connecting \(offer.displayName)…"
        case .connected:
            return "\(offer.displayName) connected"
        case .failed:
            return "Couldn't connect \(offer.displayName)"
        }
    }

    private var subheaderText: String {
        switch connectState {
        case .idle:
            return offer.capabilityHint ?? "so Perch can finish your task"
        case .connecting:
            return offer.kind == .composio
                ? "Finish signing in — I opened it in your browser."
                : "Turning it on…"
        case .connected:
            return "All set — Perch can use it now."
        case .failed:
            return "No changes made — I'll handle it in the browser instead."
        }
    }
}

/// The center-band card for a background agent's confirmation gate — the sidecar
/// is blocked awaiting the user's Approve/Deny (and auto-denies after ~120s, so
/// this ask must actually be seen; the notch auto-opens when it lands). Modeled
/// on `NotchConnectionOfferContentView` above; the description can be a full
/// sentence ("Calendar can't be controlled by script… Allow Perch to control it
/// visibly on your screen?") so it gets two lines.
struct NotchAgentConfirmationContentView: View {
    let confirmation: PendingBrowserSubagentConfirmation
    var onApprove: () -> Void
    var onDeny: () -> Void

    @ObservedObject private var musicManager = MusicManager.shared

    private var accentColor: Color {
        // A destructive-tier ask gets a warning tint; external/unclassified rides
        // the ambient accent like every other notch surface.
        confirmation.tier == "destructive"
            ? Color(red: 0.95, green: 0.62, blue: 0.18)
            : NotchAccentColor.fromMusicAccent(musicManager.avgColor)
    }

    var body: some View {
        VStack(alignment: .center, spacing: 6) {
            Text("Perch needs your OK")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity)

            Text(confirmation.description)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Color(white: 0.72))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity)

            HStack(spacing: 8) {
                Button(action: onDeny) {
                    Text("Deny")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Color(white: 0.82))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color(white: 0.22)))
                }
                .buttonStyle(.plain)
                .fixedSize()
                .onHover { isHovering in
                    if isHovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }

                Button(action: onApprove) {
                    Text("Approve")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(NotchAccentColor.labelColor(on: accentColor))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(accentColor))
                }
                .buttonStyle(.plain)
                .fixedSize()
                .onHover { isHovering in
                    if isHovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}
