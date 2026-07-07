//
//  OnboardingView.swift
//  notch
//
//  Created by Alexander on 2025-06-23.
//

import SwiftUI
import AVFoundation

// Onboarding asks for only the two permissions Perch needs the moment you press
// the talk hotkey: Microphone (Ears) and Accessibility (Hands). Everything else is
// deferred to the point of first use — Screen Recording is requested just-in-time
// with an in-notch prompt the first time Perch wants a screenshot, and Calendar /
// Music connect from empty-state prompts in the notch itself.
//
// Accessibility (Hands) MUST be requested here. The push-to-talk / double-Control
// hotkeys are a listen-only CGEvent tap gated on AXIsProcessTrusted()
// (GlobalPushToTalkShortcutMonitor): when the grant is missing the tap simply
// never starts — macOS shows NO prompt of its own — so without this step a
// first-time user's hotkeys are silently dead. (Automation is still left out; the
// system does surface that one in context.)
enum OnboardingStep: String {
    case welcome
    case emailVerification
    case emailCodeVerification
    case microphonePermission
    case accessibilityPermission
    case hotkeyTutorial
    case finished
}

/// Where Perch remembers how far the user got in onboarding. macOS forces a
/// relaunch after you grant Accessibility, which throws away the in-memory `step`;
/// persisting it lets the next launch resume at the same place instead of
/// restarting from the welcome screen (the "back to the beginning every time I
/// grant a permission" loop).
enum OnboardingProgress {
    static let resumeStepKey = "perch.onboarding.resumeStep"

    /// Identifier stamped on the onboarding `NSWindow` (see
    /// `AppDelegate.showOnboardingWindow`). Lets other subsystems detect when the
    /// onboarding window is actually on screen — a robust signal that onboarding is in
    /// progress, unlike `resumeStepKey`, which clears the instant the finish screen
    /// appears (before the user acts) and can go stale.
    static let windowIdentifier = "OnboardingWindow"

    /// The step to resume at: the persisted in-progress step if there is one,
    /// otherwise the caller-provided starting step.
    static func resumeStep(defaultingTo fallback: OnboardingStep) -> OnboardingStep {
        guard let savedRawValue = UserDefaults.standard.string(forKey: resumeStepKey),
              let savedStep = OnboardingStep(rawValue: savedRawValue)
        else { return fallback }
        return savedStep
    }

    /// Records the current step, or clears the marker once onboarding finishes.
    static func record(_ step: OnboardingStep) {
        if step == .finished {
            UserDefaults.standard.removeObject(forKey: resumeStepKey)
        } else {
            UserDefaults.standard.set(step.rawValue, forKey: resumeStepKey)
        }
    }
}

struct OnboardingView: View {
    @State var step: OnboardingStep = .welcome
    /// The email a code was sent to in `.emailVerification`, carried into the
    /// `.emailCodeVerification` step so the code is checked against the same
    /// address it was sent to.
    @State private var pendingVerificationEmail: String = ""
    let onFinish: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        ZStack {
            switch step {
            case .welcome:
                WelcomeView {
                    withAnimation(.easeInOut(duration: 0.6)) {
                        step = .emailVerification
                    }
                }
                .transition(.opacity)

            // MARK: Account — verify an email (mandatory). Part 1: enter email + send code.
            case .emailVerification:
                EmailVerificationView(
                    onCodeSent: { normalizedEmail in
                        pendingVerificationEmail = normalizedEmail
                        withAnimation(.easeInOut(duration: 0.6)) {
                            step = .emailCodeVerification
                        }
                    }
                )
                .transition(.opacity)

            // MARK: Account — verify an email (mandatory). Part 2: enter the 6-digit code.
            case .emailCodeVerification:
                OTPVerificationView(
                    email: pendingVerificationEmail,
                    onVerified: {
                        withAnimation(.easeInOut(duration: 0.6)) {
                            step = .microphonePermission
                        }
                    },
                    onChangeEmail: {
                        withAnimation(.easeInOut(duration: 0.6)) {
                            step = .emailVerification
                        }
                    }
                )
                .transition(.opacity)

            // MARK: Ears — Microphone (core)
            case .microphonePermission:
                PermissionRequestView(
                    icon: Image(systemName: "mic.fill"),
                    title: "Let Perch Hear You",
                    description: "Only while you hold ⌃⌥ to talk, Perch listens and transcribes your voice on your device so you can ask it anything hands-free.",
                    privacyNote: "Your mic is on only while you hold the talk shortcut, transcription stays on your device, and nothing is ever linked to your account.",
                    onAllow: {
                        Task {
                            await requestMicrophonePermission()
                            withAnimation(.easeInOut(duration: 0.6)) {
                                step = .accessibilityPermission
                            }
                        }
                    },
                    onSkip: {
                        withAnimation(.easeInOut(duration: 0.6)) {
                            step = .accessibilityPermission
                        }
                    }
                )
                .transition(.opacity)

            // MARK: Hands — Accessibility (core; powers the global hotkeys)
            // Unlike the microphone step this one only advances once
            // AXIsProcessTrusted() actually validates (or the user skips) — and
            // it walks the user through clearing a stale TCC entry left by an
            // older copy of Perch, the case where Settings shows the toggle ON
            // but the grant never takes. See AccessibilityPermissionStepView.
            // This is the last permission before the hotkey tutorial, so it marks
            // first launch complete (Calendar / Music / Screen Recording are all
            // deferred to in-notch prompts).
            case .accessibilityPermission:
                AccessibilityPermissionStepView(
                    onComplete: {
                        withAnimation(.easeInOut(duration: 0.6)) {
                            ViewCoordinator.shared.firstLaunch = false
                            step = .hotkeyTutorial
                        }
                    },
                    onSkip: {
                        withAnimation(.easeInOut(duration: 0.6)) {
                            ViewCoordinator.shared.firstLaunch = false
                            step = .hotkeyTutorial
                        }
                    }
                )
                .transition(.opacity)

            // MARK: How to use Perch — the hotkeys
            case .hotkeyTutorial:
                HotkeyTutorialView(
                    onContinue: {
                        withAnimation(.easeInOut(duration: 0.6)) {
                            step = .finished
                        }
                    }
                )
                .transition(.opacity)

            case .finished:
                OnboardingFinishView(onFinish: onFinish, onOpenSettings: onOpenSettings)
            }
        }
        .frame(width: 400, height: 600)
        .onAppear { OnboardingProgress.record(step) }
        .onChange(of: step) { _, newStep in
            // Persist progress so a mid-onboarding relaunch (which macOS forces
            // after granting Accessibility) resumes at this step instead of
            // restarting from the welcome screen.
            OnboardingProgress.record(newStep)
        }
    }

    // MARK: - Permission Request Logic

    /// Ears: push-to-talk capture (Microphone) only. Transcription runs through
    /// the configured provider (AssemblyAI by default, offline Whisper as the
    /// fallback) — none of which use Apple's Speech Recognition, so we never ask
    /// for it here. The legacy Apple Speech provider is an explicit opt-in and
    /// requests its own permission on demand if a user ever selects it.
    func requestMicrophonePermission() async {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
    }

    // Hands (Accessibility) lives in AccessibilityPermissionStepView — it needs
    // its own request/verify/stale-entry flow rather than fire-and-advance.
    //
    // Eyes (Screen Recording) and the Calendar / Music sources are no longer
    // requested here — Screen Recording is a just-in-time in-notch prompt and
    // Calendar / Music connect from empty-state prompts in the notch.
}
