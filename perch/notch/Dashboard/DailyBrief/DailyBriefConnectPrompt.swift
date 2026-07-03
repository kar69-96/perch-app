//
//  DailyBriefConnectPrompt.swift
//  notch
//
//  The centered "Connect to <Service>" call-to-action a brief section shows when the
//  integration that feeds it isn't connected and the section is empty (see
//  `DailyBriefConnectCoordinator`). Tapping it runs the real OAuth connect flow; while that's
//  in flight it morphs to a spinner + "Connecting to <Service>…", and on success the parent
//  re-fetches so the prompt gives way to real content.
//
//  Styled to match the brief's quiet empty states (the same caption ink and body font as
//  "Nothing scheduled today."), just made tappable — a soft, printed-page prompt, not a
//  loud button.
//

import AppKit
import SwiftUI

struct DailyBriefConnectPrompt: View {
    /// The toolkit slug to connect (e.g. "googlecalendar", "gmail").
    let toolkitSlug: String
    @ObservedObject var coordinator: DailyBriefConnectCoordinator
    /// Called after a successful connect so the parent can reload the now-available data.
    var onConnected: () -> Void = {}
    /// Vertical breathing room so the prompt centers in the section like its empty text did.
    var minHeight: CGFloat = 120

    private var serviceName: String { coordinator.displayName(forSlug: toolkitSlug) }
    private var isConnecting: Bool { coordinator.isConnecting(toolkitSlug) }

    var body: some View {
        Button {
            coordinator.connect(slug: toolkitSlug, onSuccess: onConnected)
        } label: {
            HStack(spacing: 8) {
                if isConnecting {
                    ProgressView()
                        .controlSize(.small)
                    Text("Connecting to \(serviceName)…")
                } else {
                    Text("Connect to \(serviceName)")
                }
            }
            .font(DailyBriefStyle.body(size: 17))
            .foregroundColor(DailyBriefStyle.captionInk)
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .center)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isConnecting)
        .onHover { isHovering in
            guard !isConnecting else { return }
            if isHovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}
