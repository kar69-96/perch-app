//
//  PerchFreshInstallDetector.swift
//  Perch
//
//  Onboarding, permissions, and sign-in reset on a FRESH DOWNLOAD but never on
//  an in-place UPDATE or a plain RELAUNCH. The three are told apart like this:
//
//    • Sparkle auto-update → the outgoing build calls markPendingUpdateRelaunch()
//                            before it hands off, so the next launch sees the
//                            one-shot marker and keeps everything.
//    • plain relaunch       → the fingerprint (bundle path + creation date) is
//                            byte-identical to what was stored → keep everything.
//    • fresh download       → anything else: a newly written copy has a new bundle
//                            creation date (a new location changes the path too),
//                            or the stored fingerprint predates this scheme → wipe
//                            UserDefaults and clear the stored identity.
//
//  The fingerprint and the pending-update marker live in a tiny sidecar plist that
//  survives preference wipes, so the decision is made before any UserDefaults key
//  is trusted.
//
//  Caveat we cannot fix in code: macOS keeps Accessibility/Screen-Recording/Mic
//  grants keyed to the app's signing identity + bundle id, so reinstalling the
//  same signed build leaves those OS grants in place — the app re-shows its
//  onboarding permission screens but cannot force the system dialogs again.
//
//  Transition note: the marker only protects updates from builds that already ship
//  this code. A user auto-updating from an OLDER build (which cannot set the marker)
//  is reset once on that update — an unavoidable one-time migration; every update
//  after that is marker-protected.
//
//  Dev builds (running from a repo checkout) use a stable "dev" sentinel instead of
//  the creation date so rebuilding — which recreates Perch.app — is not mistaken for
//  a reinstall, and they never clear the dogfood identity.
//

import Foundation

enum PerchFreshInstallDetector {
    private static let fingerprintKey = "lastInstallFingerprint"
    private static let pendingUpdateKey = "pendingUpdateRelaunch"

    /// PER-BUNDLE-ID state plist. The three flavors (Perch / Perch Dev / Perch
    /// Beta) each keep their own fingerprint file — a single shared name meant
    /// every launch of a DIFFERENT flavor overwrote the stored fingerprint, so
    /// the next launch of the first flavor looked like a fresh download and had
    /// its identity wiped (Composio connections orphaned with it).
    private static var installStatePlistName: String {
        "\(Bundle.main.bundleIdentifier ?? "app.perch.notch").install-state"
    }

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

    /// Wipes all UserDefaults for this bundle and clears the stored identity only on
    /// a genuinely fresh download — never for an in-place Sparkle update and never
    /// for a plain relaunch. Safe on every launch; no-op when the install is
    /// unchanged.
    static func resetPreferencesIfFreshInstall(defaults: UserDefaults = .standard) {
        let currentFingerprint = makeInstallFingerprint()
        var state = readState()
        let storedFingerprint = state[fingerprintKey] as? String
        let isPendingUpdate = (state[pendingUpdateKey] as? Bool) ?? false
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }

        // Always refresh the fingerprint to the current install and consume the
        // one-shot update marker, whatever branch we take below.
        defer {
            state[fingerprintKey] = currentFingerprint
            state[pendingUpdateKey] = nil
            writeState(state)
        }

        // In-place Sparkle update: the binary changed but the user already onboarded.
        if isPendingUpdate { return }

        // Exact same install relaunched: path AND creation date match → keep state.
        if storedFingerprint == currentFingerprint { return }

        // Anything else is a fresh copy (new download, new location, or a fingerprint
        // predating this scheme). Reset — unless this is a truly pristine first launch
        // with nothing to clear, so we don't emit a spurious reset on a clean machine.
        let hasExistingState = storedFingerprint != nil
            || !(defaults.persistentDomain(forName: bundleIdentifier)?.isEmpty ?? true)
        guard hasExistingState else { return }

        clearPreferencesDomain(named: bundleIdentifier, defaults: defaults, reason: "fresh install")
        clearInstallIdentity()
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
    /// so deleting the app alone would otherwise leave them signed in. Dev/repo
    /// builds keep their dogfood identity (seeded from dev-autologin) untouched.
    private static func clearInstallIdentity() {
        guard PerchSupportPaths.repoRootURL == nil else { return }
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
    /// A plain relaunch keeps both identical; a freshly downloaded copy changes the
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

    private static func readState() -> [String: Any] {
        (NSDictionary(contentsOf: installStateURL) as? [String: Any]) ?? [:]
    }

    private static func writeState(_ state: [String: Any]) {
        (state as NSDictionary).write(to: installStateURL, atomically: true)
    }
}
