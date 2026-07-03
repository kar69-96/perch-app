//
//  PerchBackendShims.swift
//  notch
//
//  Backend-side shims for the few symbols that lived in Perch's notch UI layer — which is
//  NOT ported (notch is the front-end now). This provides:
//   • `PerchCursorColor` — the cursor-color enum `CompanionManager` publishes (was defined
//     in the notch's NotchSurfaceComponents.swift).
//   • the two notch-originated notifications the backend posts/observes.
//  Dashboard-originated notifications come from the ported `Dashboard/` folder, so they are
//  intentionally NOT redefined here.
//

import AppKit
import Foundation
import SwiftUI

enum PerchCursorColor: String, CaseIterable, Identifiable {
    case red
    case blue
    case yellow
    case green

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .red: return DS.Colors.cursorRed
        case .blue: return DS.Colors.cursorBlue
        case .yellow: return DS.Colors.cursorYellow
        case .green: return DS.Colors.cursorGreen
        }
    }

    var nsColor: NSColor {
        switch self {
        case .red: return NSColor(red: 1.00, green: 0.26, blue: 0.22, alpha: 1)
        case .blue: return NSColor(red: 0.20, green: 0.50, blue: 1.00, alpha: 1)
        case .yellow: return NSColor(red: 0.96, green: 0.73, blue: 0.13, alpha: 1)
        case .green: return NSColor(red: 0.20, green: 0.78, blue: 0.35, alpha: 1)
        }
    }
}

extension Notification.Name {
    /// Posted by the backend to ask the front-end to dismiss the open notch panel.
    static let perchDismissPanel = Notification.Name("perchDismissPanel")
    /// Posted to open the front-end's text-input surface (Control-double-tap).
    static let perchShowTextInput = Notification.Name("perchShowTextInput")
    /// Posted when the text-input surface is dismissed, so the notch window can
    /// relinquish keyboard focus (mirror of `.perchShowTextInput`).
    static let perchTextInputDidDismiss = Notification.Name("perchTextInputDidDismiss")
    /// Posted to open the notch's tray (Shelf) page as a drop zone for query
    /// context — fired by the composer's "+" button.
    static let perchShowShelf = Notification.Name("perchShowShelf")
    /// Posted when a background agent needs the user's answer (a confirmation
    /// gate or a connect-integration request). The front-end auto-opens the
    /// closed notch so the card is actually seen — the sidecar auto-denies a
    /// confirmation after ~120s, so an invisible ask is a denied ask.
    static let perchAgentAttentionRequired = Notification.Name("perchAgentAttentionRequired")
}
