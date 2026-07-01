//
//  NotchInlineSettingsView.swift
//  notch
//
//  Perch-flavored settings shown INSIDE the open notch (the gear in
//  Header toggles the `.settings` view instead of opening the separate
//  macOS Settings window). Laid out to match the notch's own theme — pure
//  black, top-aligned, no forced fill — so switching to it doesn't resize the
//  notch silhouette.
//
//  Two columns sized for the open notch (~640 wide): on the left the editable
//  accent color over a live integrations strip; on the right a read-only display
//  of the talk/type hotkeys as premium black "glint" keycaps.
//

import AppKit
import Defaults
import SwiftUI

// MARK: - Root

struct NotchInlineSettingsView: View {
    @EnvironmentObject var companionManager: CompanionManager
    // Drives the tier-aware section header ("Free Tier" / "Pro").
    @ObservedObject private var identity = PerchInstallIdentity.shared

    var body: some View {
        HStack(alignment: .top, spacing: 22) {
            VStack(alignment: .leading, spacing: 14) {
                accentSection
                integrationsSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Right column: hotkeys up top, a greyish hairline divider, then the
            // plan tucked into the space beneath.
            VStack(alignment: .leading, spacing: 10) {
                hotkeysSection

                Rectangle()
                    .fill(Color.white.opacity(0.15))
                    .frame(width: 200, height: 1)

                planSection
            }
            .fixedSize(horizontal: true, vertical: false)
            .offset(y: -6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, 2)
    }

    // MARK: Plan (tier label over usage, with the upgrade CTA alongside)

    private var planSection: some View {
        PlanStatusRow()
    }

    // MARK: Accent color (the one editable setting)

    private var accentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            InlineSettingsSectionHeader(title: "Accent color")
            AccentColorSwatchRow()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Active integrations (live strip with searchable + picker)

    private var integrationsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            InlineSettingsSectionHeader(title: "Integrations")
            ActiveIntegrationsStrip(store: companionManager.activeIntegrationsStore)
        }
    }

    // MARK: Hotkeys (display-only)

    private var hotkeysSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            InlineSettingsSectionHeader(title: "Hotkeys")

            HotkeyDisplayRow(
                title: "Talk",
                caption: "hold to speak",
                keys: [GlintKey(glyph: "⌃", label: "control"),
                       GlintKey(glyph: "⌥", label: "option")]
            )

            HotkeyDisplayRow(
                title: "Type",
                caption: "double-tap",
                keys: [GlintKey(glyph: "⌃", label: "control")],
                repeatedTimes: 2
            )
        }
    }
}

// MARK: - Section Header

private struct InlineSettingsSectionHeader: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .kerning(0.8)
            .foregroundColor(.white.opacity(0.45))
    }
}

// MARK: - Plan Status (tier + free-tier usage + upgrade CTA)

private struct PlanStatusRow: View {
    // The app-side mirror of the Worker's entitlement (plan + this month's usage).
    @ObservedObject private var identity = PerchInstallIdentity.shared
    @State private var isStartingCheckout = false

    private var isPro: Bool { identity.entitlement.isPro }

    private var companionMessagesUsed: Int {
        identity.entitlement.usage[PerchFeature.companion.rawValue] ?? 0
    }

    private var companionMessagesCap: Int {
        identity.entitlement.cap(for: .companion)
    }

    var body: some View {
        // Upgrade chip on the left; the tier label sits directly above this
        // month's usage count on the right. Kept compact so the block fits the
        // notch's fixed height.
        HStack(alignment: .center, spacing: 10) {
            if !isPro {
                InlineUpgradeButton(isStarting: isStartingCheckout, action: startCheckout)
            }

            VStack(alignment: .center, spacing: 2) {
                Text(isPro ? "Pro" : "Free Tier")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(isPro ? Color.effectiveAccent : .white.opacity(0.85))

                // Free tier shows this month's companion-message usage; Pro is
                // unlimited, so the count is intentionally omitted. The cap guard
                // hides the line until the entitlement snapshot has loaded.
                if !isPro && companionMessagesCap > 0 {
                    Text("\(companionMessagesUsed)/\(companionMessagesCap) messages")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.45))
                }
            }
        }
        .task {
            // Reflect any upgrade made on another device / the website.
            await identity.refreshEntitlement()
        }
    }

    private func startCheckout() {
        guard !isStartingCheckout else { return }
        isStartingCheckout = true
        Task {
            _ = await PerchBilling.startUpgradeCheckout()
            isStartingCheckout = false
        }
    }
}

// MARK: - Upgrade CTA
// A restrained, accent-tinted chip that reads as tappable without shouting —
// matched to the panel's translucent-pill language (same 7pt radius as the tier
// pill), not a saturated fill.

private struct InlineUpgradeButton: View {
    let isStarting: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(isStarting ? "Opening checkout…" : "Upgrade to Pro")
                    .font(.system(size: 12, weight: .semibold))
                if !isStarting {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .bold))
                }
            }
            .foregroundColor(.effectiveAccent)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.effectiveAccent.opacity(isHovering ? 0.20 : 0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.effectiveAccent.opacity(0.40), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isStarting)
        .onHover { isHovering = $0 }
        .help("$20/mo — unlimited messages, voice or text")
    }
}

// MARK: - Accent Color Swatches (4 primaries)

private struct AccentColorSwatchRow: View {
    @Default(.useCustomAccentColor) private var useCustomAccentColor
    @Default(.customAccentColorData) private var customAccentColorData

    private static let primaries: [(name: String, color: Color)] = [
        ("Blue", Color(red: 0.0, green: 0.478, blue: 1.0)),
        ("Red", Color(red: 1.0, green: 0.271, blue: 0.227)),
        ("Yellow", Color(red: 1.0, green: 0.8, blue: 0.0)),
        ("Green", Color(red: 0.4, green: 0.824, blue: 0.176)),
    ]

    var body: some View {
        HStack(spacing: 12) {
            ForEach(Self.primaries, id: \.name) { primary in
                swatch(for: primary.color)
            }
        }
    }

    private func swatch(for color: Color) -> some View {
        let isSelected = useCustomAccentColor && colorsAreEqual(currentCustomColor, color)
        return Button(action: { selectAccent(color) }) {
            Circle()
                .fill(color)
                .frame(width: 24, height: 24)
                .overlay(Circle().strokeBorder(.white, lineWidth: isSelected ? 2.5 : 0))
                .overlay(Circle().strokeBorder(.white.opacity(0.15), lineWidth: isSelected ? 0 : 0.5))
        }
        .buttonStyle(.plain)
    }

    private var currentCustomColor: Color {
        guard let data = customAccentColorData,
              let nsColor = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data)
        else { return .clear }
        return Color(nsColor: nsColor)
    }

    private func selectAccent(_ color: Color) {
        useCustomAccentColor = true
        let nsColor = NSColor(color)
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: nsColor, requiringSecureCoding: false) {
            customAccentColorData = data
        }
        NotificationCenter.default.post(name: Notification.Name("AccentColorChanged"), object: nil)
    }

    private func colorsAreEqual(_ a: Color, _ b: Color) -> Bool {
        let na = NSColor(a).usingColorSpace(.sRGB) ?? NSColor(a)
        let nb = NSColor(b).usingColorSpace(.sRGB) ?? NSColor(b)
        return abs(na.redComponent - nb.redComponent) < 0.01
            && abs(na.greenComponent - nb.greenComponent) < 0.01
            && abs(na.blueComponent - nb.blueComponent) < 0.01
    }
}

// MARK: - Glint Keycaps (display-only hotkeys)

struct GlintKey: Identifiable {
    let glyph: String
    let label: String
    var id: String { "\(glyph)-\(label)" }
}

private struct GlintKeyCap: View {
    let key: GlintKey
    private let cornerRadius: CGFloat = 7

    var body: some View {
        HStack(spacing: 4) {
            Text(key.glyph)
                .font(.system(size: 12, weight: .semibold))
            Text(key.label)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
        }
        .lineLimit(1)
        .fixedSize()
        .foregroundColor(.white.opacity(0.95))
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.149, green: 0.157, blue: 0.161),
                                 Color(red: 0.047, green: 0.051, blue: 0.055)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(0.55), Color.clear],
                        startPoint: .top,
                        endPoint: .center
                    ),
                    lineWidth: 1
                )
                .padding(0.5)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.5), radius: 3, x: 0, y: 2)
    }
}

private struct HotkeyDisplayRow: View {
    let title: String
    let caption: String
    let keys: [GlintKey]
    var repeatedTimes: Int = 1

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.85))
                Text(caption)
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.4))
            }
            .frame(width: 64, alignment: .leading)

            HStack(spacing: 6) {
                ForEach(Array(keys.enumerated()), id: \.offset) { index, key in
                    if index > 0 {
                        Text("+")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.4))
                    }
                    GlintKeyCap(key: key)
                }
                if repeatedTimes > 1 {
                    Text("×\(repeatedTimes)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.4))
                }
            }
        }
    }
}