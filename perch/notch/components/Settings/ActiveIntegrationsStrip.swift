//
//  ActiveIntegrationsStrip.swift
//  notch
//
//  The dark rounded strip of connected-integration chips followed by the "+"
//  searchable picker of connectable services. Shared between notch surfaces;
//  both render `ActiveIntegrationsStrip(store:)` against
//  `CompanionManager.activeIntegrationsStore`.
//

import AppKit
import SwiftUI

// MARK: - Active Integrations Strip

/// The dark rounded strip of connected-integration chips followed by the "+"
/// picker of connectable services. Observes the store so it re-renders when a
/// connect completes (a new chip appears) or a connect is in flight.
struct ActiveIntegrationsStrip: View {
    @ObservedObject var store: ActiveIntegrationsStore

    var body: some View {
        HStack(spacing: 8) {
            ForEach(store.connectedIntegrations, id: \.toolkitSlug) { entry in
                IntegrationChip(entry: entry, isConnecting: store.isConnecting(entry))
            }

            ForEach(pendingConnectingEntries, id: \.toolkitSlug) { entry in
                IntegrationChip(entry: entry, isConnecting: true)
            }

            AddIntegrationPickerPopover(store: store)

            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(DS.Colors.notchSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(DS.Colors.notchBorder, lineWidth: 0.5)
        )
        .onAppear { store.refresh() }
    }

    private var pendingConnectingEntries: [ServiceCatalogEntry] {
        let connectedSlugs = Set(store.connectedIntegrations.map { $0.toolkitSlug })
        return store.connectableIntegrations.filter {
            store.isConnecting($0) && !connectedSlugs.contains($0.toolkitSlug)
        }
    }
}

// MARK: - Integration Chip

private struct IntegrationChip: View {
    let entry: ServiceCatalogEntry
    let isConnecting: Bool

    var body: some View {
        IntegrationIcon(entry: entry)
            .frame(width: 16, height: 16)
            .frame(width: 28, height: 28)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(DS.Colors.notchChipFill)
            )
            .overlay {
                if isConnecting {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.black.opacity(0.45))
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                }
            }
            .help(entry.displayName)
    }
}

// MARK: - Integration Icon

private struct IntegrationIcon: View {
    let entry: ServiceCatalogEntry

    @StateObject private var logoLoader = IntegrationLogoLoader()

    var body: some View {
        Group {
            if entry.toolkitSlug == "figma" {
                FigmaLogoMark()
            } else if let resolvedAppIcon = resolvedAppIcon {
                NotchAppIconTile(appIcon: resolvedAppIcon, tileSize: 16)
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            } else if let loadedLogo = logoLoader.image {
                Image(nsImage: loadedLogo)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            } else {
                monogram
            }
        }
        .task(id: entry.toolkitSlug) {
            guard entry.toolkitSlug != "figma", resolvedAppIcon == nil else { return }
            await logoLoader.load(Self.logoURL(for: entry))
        }
    }

    private var resolvedAppIcon: NSImage? {
        guard let bundleIdentifier = entry.appIconBundleIdentifierForTile else { return nil }
        return NotchAppIconResolver.icon(forBundleIdentifier: bundleIdentifier)
    }

    private var monogram: some View {
        Text(String(entry.displayName.prefix(1)).uppercased())
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(DS.Colors.textSecondary)
            .frame(width: 16, height: 16)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
    }

    static func logoURL(for entry: ServiceCatalogEntry) -> URL? {
        let slug = entry.toolkitSlug.lowercased()

        // Prefer logo directly from Composio (via the sidecar manifest). This gives
        // high-quality, mutually exclusive icons for every connected toolkit without
        // hardcoding or falling back to generic favicons.
        let manifestLogos = ComposioManifestReader.standard().currentState().toolkitLogos
        if let urlString = manifestLogos[slug], let url = URL(string: urlString) {
            return url
        }

        if let overrideURLString = brandLogoOverrideURLStrings[entry.toolkitSlug] {
            return URL(string: overrideURLString)
        }
        return faviconURL(forHost: entry.matchHosts.first)
    }

    static let brandLogoOverrideURLStrings: [String: String] = [
        // Google family – distinct branded icons (favicons on docs/sheets subdomains are often generic or Drive-like)
        "gmail":
            "https://upload.wikimedia.org/wikipedia/commons/thumb/7/7e/Gmail_icon_%282020%29.svg/120px-Gmail_icon_%282020%29.svg.png",
        "googlecalendar":
            "https://upload.wikimedia.org/wikipedia/commons/thumb/a/a5/Google_Calendar_icon_%282020%29.svg/120px-Google_Calendar_icon_%282020%29.svg.png",
        "googledrive":
            "https://upload.wikimedia.org/wikipedia/commons/thumb/1/12/Google_Drive_icon_%282020%29.svg/120px-Google_Drive_icon_%282020%29.svg.png",
        "googledocs":
            "https://upload.wikimedia.org/wikipedia/commons/thumb/0/01/Google_Docs_logo_%282020%29.svg/120px-Google_Docs_logo_%282020%29.svg.png",
        "googlesheets":
            "https://upload.wikimedia.org/wikipedia/commons/thumb/3/30/Google_Sheets_logo_%282020%29.svg/120px-Google_Sheets_logo_%282020%29.svg.png",
        "googlemeet":
            "https://upload.wikimedia.org/wikipedia/commons/thumb/9/9b/Google_Meet_icon_%282020%29.svg/120px-Google_Meet_icon_%282020%29.svg.png",

        // Microsoft family – distinct (favicons often collapse to generic blue "M" or cloud)
        "outlook":
            "https://upload.wikimedia.org/wikipedia/commons/thumb/0/0d/Microsoft_Office_Outlook_%282019%E2%80%93present%29.svg/120px-Microsoft_Office_Outlook_%282019%E2%80%93present%29.svg.png",
        "microsoft_teams":
            "https://upload.wikimedia.org/wikipedia/commons/thumb/c/c9/Microsoft_Office_Teams_%282018%E2%80%93present%29.svg/120px-Microsoft_Office_Teams_%282018%E2%80%93present%29.svg.png",
        "one_drive":
            "https://upload.wikimedia.org/wikipedia/commons/thumb/3/3c/Microsoft_Office_OneDrive_%282019%E2%80%93present%29.svg/120px-Microsoft_Office_OneDrive_%282019%E2%80%93present%29.svg.png",

        // Others that benefit from clear branded marks instead of generic favicons
        "github":
            "https://upload.wikimedia.org/wikipedia/commons/thumb/9/91/Octicons-mark-github.svg/120px-Octicons-mark-github.svg.png",
        "gitlab":
            "https://upload.wikimedia.org/wikipedia/commons/thumb/1/18/GitLab_Logo.svg/120px-GitLab_Logo.svg.png",
        "youtube":
            "https://upload.wikimedia.org/wikipedia/commons/thumb/0/09/YouTube_full-color_icon_%282017%29.svg/120px-YouTube_full-color_icon_%282017%29.svg.png",
        "twitter":  // displayed as "X"
            "https://upload.wikimedia.org/wikipedia/commons/thumb/c/ce/X_logo_2023.svg/120px-X_logo_2023.svg.png",
        "reddit":
            "https://upload.wikimedia.org/wikipedia/commons/thumb/5/58/Reddit_logo_new.svg/120px-Reddit_logo_new.svg.png",
        "dropbox":
            "https://upload.wikimedia.org/wikipedia/commons/thumb/7/7e/Dropbox_Icon.svg/120px-Dropbox_Icon.svg.png",
        "stripe":
            "https://upload.wikimedia.org/wikipedia/commons/thumb/3/3c/Stripe_Logo%2C_revised_2016.svg/120px-Stripe_Logo%2C_revised_2016.svg.png",
        "shopify":
            "https://upload.wikimedia.org/wikipedia/commons/thumb/0/0e/Shopify_logo_2018.svg/120px-Shopify_logo_2018.svg.png",
        "hubspot":
            "https://upload.wikimedia.org/wikipedia/commons/thumb/7/71/HubSpot_Logo.svg/120px-HubSpot_Logo.svg.png",
        "salesforce":
            "https://upload.wikimedia.org/wikipedia/commons/thumb/f/f9/Salesforce_logo.svg/120px-Salesforce_logo.svg.png",
        "zendesk":
            "https://upload.wikimedia.org/wikipedia/commons/thumb/4/4f/Zendesk_logo.svg/120px-Zendesk_logo.svg.png",
        "intercom":
            "https://upload.wikimedia.org/wikipedia/commons/thumb/0/0b/Intercom_logo.svg/120px-Intercom_logo.svg.png",
        "asana":
            "https://upload.wikimedia.org/wikipedia/commons/thumb/1/1b/Asana_logo.svg/120px-Asana_logo.svg.png",
        "trello":
            "https://upload.wikimedia.org/wikipedia/commons/thumb/7/7a/Trello_logo.svg/120px-Trello_logo.svg.png",
        "discord":
            "https://upload.wikimedia.org/wikipedia/commons/thumb/7/7e/Discord_logo_2021.svg/120px-Discord_logo_2021.svg.png",
        "zoom":
            "https://upload.wikimedia.org/wikipedia/commons/thumb/6/6e/Zoom_logo.svg/120px-Zoom_logo.svg.png",
    ]

    static func faviconURL(forHost host: String?) -> URL? {
        guard let host, !host.isEmpty else { return nil }
        return URL(string: "https://www.google.com/s2/favicons?domain=\(host)&sz=64")
    }
}

@MainActor
private final class IntegrationLogoLoader: ObservableObject {
    @Published private(set) var image: NSImage?
    private static var cache: [String: NSImage] = [:]

    func load(_ url: URL?) async {
        guard let url else { return }
        let cacheKey = url.absoluteString
        if let cachedImage = Self.cache[cacheKey] {
            image = cachedImage
            return
        }
        do {
            var request = URLRequest(url: url)
            request.setValue("notch/1.0", forHTTPHeaderField: "User-Agent")
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let loadedImage = NSImage(data: data) else { return }
            Self.cache[cacheKey] = loadedImage
            image = loadedImage
        } catch {
            // Leave nil — the chip shows its monogram fallback.
        }
    }
}

// MARK: - Add Integration Picker

private struct AddIntegrationPickerPopover: View {
    @ObservedObject var store: ActiveIntegrationsStore
    @State private var isPopoverPresented = false
    @State private var integrationSearchText = ""
    @FocusState private var isSearchFieldFocused: Bool

    /// Every Composio service — connected and not-yet-connected — sorted by name,
    /// so the picker doubles as the connection-status list.
    private var allIntegrations: [ServiceCatalogEntry] {
        (store.connectedIntegrations + store.connectableIntegrations)
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private var filteredIntegrations: [ServiceCatalogEntry] {
        let trimmedSearchText = integrationSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSearchText.isEmpty else { return allIntegrations }
        return allIntegrations.filter { entry in
            entry.displayName.localizedCaseInsensitiveContains(trimmedSearchText)
                || entry.toolkitSlug.localizedCaseInsensitiveContains(trimmedSearchText)
        }
    }

    private func isConnected(_ entry: ServiceCatalogEntry) -> Bool {
        store.connectedIntegrations.contains { $0.toolkitSlug == entry.toolkitSlug }
    }

    var body: some View {
        Button(action: { isPopoverPresented.toggle() }) {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Colors.textTertiary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(DS.Colors.notchChipFill)
                )
        }
        .buttonStyle(.plain)
        .help("Add integration")
        .pointerCursor()
        .popover(isPresented: $isPopoverPresented, arrowEdge: .bottom) {
            pickerContent
                .onAppear {
                    integrationSearchText = ""
                    isSearchFieldFocused = true
                }
        }
        // The popover renders in its own window OUTSIDE the notch's hover-tracking
        // area, so moving the mouse into it would otherwise trip the notch's
        // mouse-exit auto-close and tear the popover down. Hold the notch open
        // while the picker is presented (the same escape hatch the close paths
        // already honor), and release it when the picker dismisses.
        .onChange(of: isPopoverPresented) { _, presented in
            SharingStateManager.shared.preventNotchClose = presented
        }
        .onDisappear { SharingStateManager.shared.preventNotchClose = false }
    }

    private var pickerContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                TextField("Search integrations…", text: $integrationSearchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($isSearchFieldFocused)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(DS.Colors.notchSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(DS.Colors.notchBorder, lineWidth: 0.5)
            )

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if !store.composioAvailable && allIntegrations.isEmpty {
                        pickerEmptyRow("Composio not configured")
                    } else if allIntegrations.isEmpty {
                        pickerEmptyRow("No integrations available")
                    } else if filteredIntegrations.isEmpty {
                        pickerEmptyRow("No matches")
                    } else {
                        ForEach(filteredIntegrations, id: \.toolkitSlug) { entry in
                            pickerRow(for: entry)
                        }
                    }
                }
            }
            .frame(maxHeight: 220)
        }
        .padding(10)
        .frame(width: 240)
    }

    private func pickerEmptyRow(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 12))
            .foregroundColor(DS.Colors.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
    }

    @ViewBuilder
    private func pickerRow(for entry: ServiceCatalogEntry) -> some View {
        if isConnected(entry) {
            // Already connected — a non-interactive status row (no disconnect).
            pickerRowChrome(for: entry) {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Connected")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(.green)
            }
        } else {
            // Not connected — the whole row is a Connect button. The popover stays
            // open so the row can flip to "Connected" once the flow completes.
            Button(action: { store.connect(entry) }) {
                pickerRowChrome(for: entry) {
                    if store.isConnecting(entry) {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.7)
                    } else {
                        Text("Connect")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Color.effectiveAccent)
                    }
                }
            }
            .buttonStyle(.plain)
            .pointerCursor(isEnabled: !store.isConnecting(entry))
            .disabled(store.isConnecting(entry))
        }
    }

    /// Shared row chrome: icon + name on the left, a trailing status accessory.
    private func pickerRowChrome<Accessory: View>(
        for entry: ServiceCatalogEntry,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        HStack(spacing: 8) {
            IntegrationIcon(entry: entry)
                .frame(width: 16, height: 16)

            Text(entry.displayName)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1)

            Spacer(minLength: 0)

            accessory()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.clear)
        )
        .contentShape(Rectangle())
    }
}

// MARK: - App Icon Helpers

private enum NotchAppIconResolver {
    static func icon(forBundleIdentifier bundleIdentifier: String) -> NSImage? {
        guard let applicationURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleIdentifier
        ) else { return nil }
        return NSWorkspace.shared.icon(forFile: applicationURL.path)
    }
}

private struct NotchAppIconTile: View {
    let appIcon: NSImage
    var tileSize: CGFloat = 16

    var body: some View {
        Image(nsImage: appIcon)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: tileSize, height: tileSize)
    }
}

// MARK: - Figma Logo Mark

struct FigmaLogoMark: View {
    var body: some View {
        GeometryReader { geometry in
            let unit = geometry.size.width / 2
            let cornerRadius = unit / 2

            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    UnevenRoundedRectangle(
                        topLeadingRadius: cornerRadius,
                        bottomLeadingRadius: cornerRadius,
                        bottomTrailingRadius: 0,
                        topTrailingRadius: 0
                    )
                    .fill(Color(hex: "#F24E1E"))
                    Circle()
                        .fill(Color(hex: "#FF7262"))
                }
                .frame(height: unit * 2 / 3)

                HStack(spacing: 0) {
                    UnevenRoundedRectangle(
                        topLeadingRadius: cornerRadius,
                        bottomLeadingRadius: cornerRadius,
                        bottomTrailingRadius: 0,
                        topTrailingRadius: 0
                    )
                    .fill(Color(hex: "#A259FF"))
                    Circle()
                        .fill(Color(hex: "#1ABCFE"))
                }
                .frame(height: unit * 2 / 3)

                HStack(spacing: 0) {
                    UnevenRoundedRectangle(
                        topLeadingRadius: cornerRadius,
                        bottomLeadingRadius: cornerRadius,
                        bottomTrailingRadius: cornerRadius,
                        topTrailingRadius: 0
                    )
                    .fill(Color(hex: "#0ACF83"))
                    Color.clear
                }
                .frame(height: unit * 2 / 3)
            }
        }
    }
}