//
//  PerchDefaultsMigration.swift
//  Perch
//
//  One-shot migration of UserDefaults keys that were renamed from the legacy
//  `com.learningbuddy.*` namespace to `app.perch.*` when the project was
//  rebranded to Perch. Without this, an existing beta user updating to a build
//  with the new keys would appear "fresh" to the onboarding/permission-state
//  checks in WindowPositionManager and get re-prompted for Screen Recording.
//
//  Runs once (guarded by a version flag), copies each old value to its new key
//  when the new key is unset, and clears the old key. New installs are a no-op.
//

import Foundation

enum PerchDefaultsMigration {
    /// Bumped only when a new batch of key renames needs migrating.
    private static let migrationVersionKey = "app.perch.defaultsMigrationVersion"
    private static let currentVersion = 1

    /// (legacy key, new key) pairs. Keep in sync with the string literals in the
    /// owning types (currently WindowPositionManager).
    private static let renamedKeys: [(old: String, new: String)] = [
        ("com.learningbuddy.hasPreviouslyConfirmedScreenRecordingPermission",
         "app.perch.hasPreviouslyConfirmedScreenRecordingPermission"),
        ("com.learningbuddy.screenRecordingRequestedDuringOnboarding",
         "app.perch.screenRecordingRequestedDuringOnboarding"),
        ("com.learningbuddy.didAutoRelaunchAfterOnboardingForScreenRecording",
         "app.perch.didAutoRelaunchAfterOnboardingForScreenRecording"),
        // didScreenCaptureDirectAccessWarmup was dropped from this table when the
        // direct-access warm-up became per-launch (no persisted flag anymore).
    ]

    /// Idempotent. Safe to call on every launch; does work only once.
    static func runIfNeeded(defaults: UserDefaults = .standard) {
        guard defaults.integer(forKey: migrationVersionKey) < currentVersion else { return }

        for pair in renamedKeys {
            // Only migrate when the legacy key was actually set and the new key
            // hasn't been written yet — never clobber a fresh value.
            guard defaults.object(forKey: pair.old) != nil else { continue }
            if defaults.object(forKey: pair.new) == nil {
                defaults.set(defaults.bool(forKey: pair.old), forKey: pair.new)
            }
            defaults.removeObject(forKey: pair.old)
        }

        defaults.set(currentVersion, forKey: migrationVersionKey)
    }
}
