//
//  PerchFreshInstallDetector.swift
//  Perch
//
//  A genuinely fresh install (a new copy dragged in at a new location, or the
//  very first launch on this machine) should start at true onboarding. But an
//  in-place UPGRADE — a Sparkle auto-update, or re-dragging a new DMG over the
//  existing /Applications/Perch.app — must NOT: the user already onboarded and
//  granted permissions, and re-prompting them on every update is hostile.
//
//  The two are told apart by WHERE the app lives, not which version it is. We
//  fingerprint the install by its bundle path (which an in-place update keeps
//  identical, but a fresh copy at a new location changes) and store it in a tiny
//  sidecar plist that survives preference wipes. Only when the path differs — or
//  there is stale state with no prior fingerprint at all — do we drop the whole
//  UserDefaults domain. Version/build changes alone never trigger a reset.
//

import Foundation

enum PerchFreshInstallDetector {
    private static let fingerprintKey = "lastInstallFingerprint"
    private static let installStatePlistName = "app.perch.notch.install-state"

    private static var installStateURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(installStatePlistName).plist")
    }

    /// Wipes all UserDefaults for this bundle only when the app is installed at a
    /// new location (a genuine fresh copy), never for an in-place version update.
    /// Safe on every launch; no-op when the install location is unchanged.
    static func resetPreferencesIfFreshInstall(defaults: UserDefaults = .standard) {
        let currentFingerprint = makeInstallFingerprint()
        let storedFingerprint = readStoredFingerprint()
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }

        defer { writeStoredFingerprint(currentFingerprint) }

        if let storedFingerprint {
            guard storedFingerprint != currentFingerprint else { return }
            clearPreferencesDomain(named: bundleIdentifier, defaults: defaults, reason: "fresh install")
            return
        }

        // First launch after this tracker shipped: install-state did not exist yet,
        // so the old guard let storedFingerprint check returned early and left
        // firstLaunch=false (and other stale keys) from a prior DMG copy in place.
        if let existingDomain = defaults.persistentDomain(forName: bundleIdentifier),
           !existingDomain.isEmpty {
            clearPreferencesDomain(
                named: bundleIdentifier,
                defaults: defaults,
                reason: "stale preferences on first fingerprint"
            )
        }
    }

    private static func clearPreferencesDomain(
        named bundleIdentifier: String,
        defaults: UserDefaults,
        reason: String
    ) {
        defaults.removePersistentDomain(forName: bundleIdentifier)
        defaults.synchronize()
        print("📦 Perch preferences reset (\(reason)) — cleared \(bundleIdentifier)")
    }

    /// Identifies the install by WHERE it lives. An in-place update (Sparkle, or a
    /// new DMG dropped over the existing app) keeps this identical, so it is not a
    /// fresh install; a new copy at a different path changes it. Deliberately does
    /// NOT include the version, build, or binary mtime — those change on every
    /// update and must not, by themselves, look like a reinstall.
    private static func makeInstallFingerprint() -> String {
        Bundle.main.bundlePath
    }

    private static func readStoredFingerprint() -> String? {
        guard let state = NSDictionary(contentsOf: installStateURL) as? [String: Any],
              let raw = state[fingerprintKey] as? String else { return nil }
        return normalizeStoredFingerprint(raw)
    }

    /// Builds up to and including v2.7.6 stored the fingerprint as
    /// `version(build)|bundlePath|mtime`. Reduce any such legacy value to just its
    /// bundle-path component, so upgrading FROM one of those builds — which kept the
    /// same install location — compares equal and is not mistaken for a reinstall.
    /// A value already in the new path-only form is returned unchanged.
    private static func normalizeStoredFingerprint(_ stored: String) -> String {
        let components = stored.components(separatedBy: "|")
        guard components.count == 3 else { return stored }
        return components[1]
    }

    private static func writeStoredFingerprint(_ fingerprint: String) {
        let state: [String: Any] = [fingerprintKey: fingerprint]
        (state as NSDictionary).write(to: installStateURL, atomically: true)
    }
}