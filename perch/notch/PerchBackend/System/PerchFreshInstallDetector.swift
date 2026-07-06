//
//  PerchFreshInstallDetector.swift
//  Perch
//
//  A genuinely fresh install — a newly downloaded copy of the app, whether it
//  lands at a new location or replaces the existing /Applications/Perch.app —
//  must start at true onboarding with permissions re-prompted and identity
//  cleared. Merely RELAUNCHING the same installed binary must keep everything
//  (settings, permissions, sign-in). A Sparkle auto-update is the one binary
//  replacement that is NOT a fresh install: the user already onboarded, so it
//  is exempted explicitly via a one-shot marker set during the update relaunch.
//
//  How the three cases are told apart:
//    • restart            → same bundle path AND same bundle creation date → keep
//    • fresh download      → creation date changed (a new copy was written), or a
//                            new location → wipe UserDefaults + clear identity
//    • Sparkle auto-update → binary is replaced too, but markPendingUpdateRelaunch()
//                            was called first, so this launch is exempt from reset
//
//  The fingerprint (bundle path + creation epoch) and the pending-update marker
//  live in a tiny sidecar plist that survives preference wipes, so the decision
//  is made before any UserDefaults key is trusted.
//
//  Dev builds (running from a repo checkout) deliberately skip the creation-date
//  component so rebuilding — which recreates Perch.app with a new creation date —
//  does not look like a reinstall and nuke dogfood state on every build.
//

import Foundation

enum PerchFreshInstallDetector {
    private static let fingerprintKey = "lastInstallFingerprint"
    private static let pendingUpdateKey = "pendingUpdateRelaunch"
    private static let installStatePlistName = "app.perch.notch.install-state"

    /// Sentinel used in place of a real creation epoch for dev/repo builds, so a
    /// rebuild at the same path compares equal and never triggers a reset.
    private static let devBirthSentinel = "dev"
    private static let fingerprintVersionPrefix = "v2"

    private static var installStateURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(installStatePlistName).plist")
    }

    /// Called by the Sparkle updater delegate immediately before an update
    /// relaunch/install so the next launch is recognized as an in-place update and
    /// exempted from the fresh-install reset. Persisted in the sidecar plist so it
    /// survives even though the binary is being swapped underneath us.
    static func markPendingUpdateRelaunch() {
        var state = readState()
        state[pendingUpdateKey] = true
        writeState(state)
    }

    /// Wipes all UserDefaults for this bundle and clears the stored identity only
    /// when the app is a genuinely fresh copy (new location or newly written
    /// binary), never for an in-place Sparkle update and never for a plain
    /// restart. Safe on every launch; no-op when the install is unchanged.
    static func resetPreferencesIfFreshInstall(defaults: UserDefaults = .standard) {
        let currentFingerprint = makeInstallFingerprint()
        var state = readState()
        let storedFingerprint = (state[fingerprintKey] as? String).map(normalizeStoredFingerprint)
        let isPendingUpdate = (state[pendingUpdateKey] as? Bool) ?? false
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }

        // Always refresh the fingerprint to the current install and consume the
        // one-shot update marker, whatever branch we take below.
        defer {
            state[fingerprintKey] = currentFingerprint
            state[pendingUpdateKey] = nil
            writeState(state)
        }

        // A Sparkle auto-update replaces the binary (new creation date) but is not
        // a fresh install — adopt the new fingerprint and keep all state.
        if isPendingUpdate { return }

        if let storedFingerprint {
            guard isFreshInstall(stored: storedFingerprint, current: currentFingerprint) else { return }
            clearPreferencesDomain(named: bundleIdentifier, defaults: defaults, reason: "fresh install")
            clearInstallIdentity()
            return
        }

        // First launch after this tracker shipped: install-state did not exist yet,
        // so onboarding keys (firstLaunch=false, etc.) may be stale from a prior DMG
        // copy. Re-onboard once, but do NOT clear identity — this fires for every
        // existing user upgrading from a pre-tracker build, who must stay signed in.
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

    /// Removes the persisted install identity (installId, email, install token) so a
    /// fresh download starts fully signed out and re-enters onboarding's email step.
    /// For real users this file lives outside the app bundle (`~/.perch-support/`),
    /// so deleting the app alone would otherwise leave them signed in.
    private static func clearInstallIdentity() {
        let identityURL = PerchSupportPaths.file("install-identity.json")
        do {
            try FileManager.default.removeItem(at: identityURL)
            print("📦 Perch identity cleared (fresh install) — removed install-identity.json")
        } catch CocoaError.fileNoSuchFile {
            // Nothing to clear — already absent.
        } catch {
            print("⚠️ Perch identity clear failed: \(error.localizedDescription)")
        }
    }

    /// Fingerprints the install by WHERE it lives and WHEN its bundle was written.
    /// A plain restart keeps both identical; a freshly downloaded copy changes the
    /// creation date (a new location changes the path too). Deliberately excludes
    /// version/build — a Sparkle update is told apart by the pending-update marker,
    /// not by version. Dev/repo builds use a stable sentinel instead of the real
    /// creation date so rebuilds are not mistaken for reinstalls.
    private static func makeInstallFingerprint() -> String {
        let bundlePath = Bundle.main.bundlePath
        let birth = PerchSupportPaths.repoRootURL == nil ? bundleCreationEpoch() : devBirthSentinel
        return "\(fingerprintVersionPrefix)|\(bundlePath)|\(birth)"
    }

    /// Integer seconds of the app bundle's creation date, or "0" when unreadable.
    /// A newly written copy gets a fresh creation date; a relaunched binary does not.
    private static func bundleCreationEpoch() -> String {
        if let values = try? Bundle.main.bundleURL.resourceValues(forKeys: [.creationDateKey]),
           let created = values.creationDate {
            return String(Int(created.timeIntervalSince1970))
        }
        return "0"
    }

    /// True when `current` represents a different install than `stored`.
    ///
    /// Back-compat: a stored fingerprint with no creation-date component (a legacy
    /// `version|path|mtime` value, or the path-only form shipped between the two)
    /// is compared on path alone, so an existing user upgrading INTO this build at
    /// the same location is treated as an update — not a reinstall — and is neither
    /// reset nor signed out. Only once a path+creation fingerprint has been written
    /// does the creation date participate in the comparison.
    private static func isFreshInstall(stored: String, current: String) -> Bool {
        let storedParts = parseFingerprint(stored)
        let currentParts = parseFingerprint(current)
        guard let storedBirth = storedParts.birth else {
            return storedParts.path != currentParts.path
        }
        return storedParts.path != currentParts.path || storedBirth != currentParts.birth
    }

    /// Splits a fingerprint into its path and (optional) creation-date component.
    /// Handles the new `v2|path|birth` form, the legacy `version|path|mtime` form
    /// (path only — mtime is not a reliable creation signal), and a bare path.
    private static func parseFingerprint(_ value: String) -> (path: String, birth: String?) {
        let components = value.components(separatedBy: "|")
        if components.first == fingerprintVersionPrefix, components.count == 3 {
            return (components[1], components[2])
        }
        if components.count == 3 {
            return (components[1], nil)
        }
        return (value, nil)
    }

    /// Builds up to and including v2.7.6 stored the fingerprint as
    /// `version(build)|bundlePath|mtime`; a later build stored a bare bundle path.
    /// Both are handled by `parseFingerprint`, so this now just passes the raw value
    /// through — kept as the single normalization seam for stored fingerprints.
    private static func normalizeStoredFingerprint(_ stored: String) -> String { stored }

    private static func readState() -> [String: Any] {
        (NSDictionary(contentsOf: installStateURL) as? [String: Any]) ?? [:]
    }

    private static func writeState(_ state: [String: Any]) {
        (state as NSDictionary).write(to: installStateURL, atomically: true)
    }
}
