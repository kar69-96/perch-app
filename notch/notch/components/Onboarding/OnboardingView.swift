//
//  OnboardingView.swift
//  notch
//
//  Created by Alexander on 2025-06-23.
//

import SwiftUI
import AVFoundation
import CoreGraphics

// Permission flow follows the "Hear → See → Act" ordering principle from
// docs/onboarding-permissions.md: lead with the three core capabilities Perch
// uses the moment you press a hotkey — Microphone (Ears), Screen Recording
// (Eyes), and Accessibility (Hands) — then the optional notch widgets (Calendar /
// Reminders) and the music source.
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
    case screenRecordingPermission
    case accessibilityPermission
    case calendarPermission
    case remindersPermission
    case musicPermission
    case hotkeyTutorial
    case finished
}

/// Where Perch remembers how far the user got in onboarding. macOS forces a
/// relaunch after you grant Screen Recording or Accessibility, which throws away
/// the in-memory `step`; persisting it lets the next launch resume at the same
/// place instead of restarting from the welcome screen (the "back to the
/// beginning every time I grant a permission" loop).
enum OnboardingProgress {
    static let resumeStepKey = "perch.onboarding.resumeStep"

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

private let calendarService = CalendarService()

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
                                step = .screenRecordingPermission
                            }
                        }
                    },
                    onSkip: {
                        withAnimation(.easeInOut(duration: 0.6)) {
                            step = .screenRecordingPermission
                        }
                    }
                )
                .transition(.opacity)

            // MARK: Eyes — Screen Recording (core)
            case .screenRecordingPermission:
                PermissionRequestView(
                    icon: Image(systemName: "eye.fill"),
                    title: "Let Perch Take a Screenshot",
                    description: "Only when you hold ⌃⌥ or ask for help, Perch takes a single screenshot so it can answer questions about what's on your screen. macOS calls this toggle “Screen Recording,” but Perch never records — it grabs one still image, and only when you ask. Perch will relaunch once after you grant this, and macOS will then ask one more time to let Perch see your screen directly — click Allow so you're not asked again later.",
                    privacyNote: "The screenshot is used to answer your question, then discarded — never recorded, never stored, and never linked to your account.",
                    onAllow: {
                        Task {
                            await requestScreenRecordingPermission()
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
            case .accessibilityPermission:
                PermissionRequestView(
                    icon: Image(systemName: "hand.raised.fill"),
                    title: "Grant Accessibility Access",
                    description: "Perch listens for the ⌃⌥ talk shortcut (and double-tap ⌃ to type) system-wide. macOS calls this “Accessibility.” Without it the hotkeys can't work — and macOS won't ask on its own, so grant it here. You may need to relaunch Perch once after granting.",
                    privacyNote: "Perch only watches for its own shortcut keys to know when you want to talk — it never logs your keystrokes, and nothing is linked to your account.",
                    onAllow: {
                        requestAccessibilityPermission()
                        withAnimation(.easeInOut(duration: 0.6)) {
                            step = .calendarPermission
                        }
                    },
                    onSkip: {
                        withAnimation(.easeInOut(duration: 0.6)) {
                            step = .calendarPermission
                        }
                    }
                )
                .transition(.opacity)

            // MARK: Optional notch widgets — Calendar
            case .calendarPermission:
                PermissionRequestView(
                    icon: Image(systemName: "calendar"),
                    title: "Enable Calendar Access",
                    description: "Perch can show all your upcoming events in one place. Access to your calendar is needed to display your schedule.",
                    privacyNote: "Your calendar data is only used to show your events and is never shared.",
                    onAllow: {
                        Task {
                            await requestCalendarPermission()
                            withAnimation(.easeInOut(duration: 0.6)) {
                                step = .remindersPermission
                            }
                        }
                    },
                    onSkip: {
                        withAnimation(.easeInOut(duration: 0.6)) {
                            step = .remindersPermission
                        }
                    }
                )
                .transition(.opacity)

            // MARK: Optional notch widgets — Reminders
            case .remindersPermission:
                PermissionRequestView(
                    icon: Image(systemName: "checklist"),
                    title: "Enable Reminders Access",
                    description: "Perch can show your scheduled reminders alongside your calendar events. Access to Reminders is needed to display your reminders.",
                    privacyNote: "Your reminders data is only used to show your reminders and is never shared.",
                    onAllow: {
                        Task {
                            await requestRemindersPermission()
                            withAnimation(.easeInOut(duration: 0.6)) {
                                step = .musicPermission
                            }
                        }
                    },
                    onSkip: {
                        withAnimation(.easeInOut(duration: 0.6)) {
                            step = .musicPermission
                        }
                    }
                )
                .transition(.opacity)

            // MARK: Music source (configuration, not a permission)
            case .musicPermission:
                MusicControllerSelectionView(
                    onContinue: {
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
            // after granting Screen Recording / Accessibility) resumes at this
            // step instead of restarting from the welcome screen.
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

    /// Eyes: screen capture. `CGRequestScreenCaptureAccess` shows the system
    /// prompt and returns the current status immediately; macOS only honors a
    /// fresh grant after the next launch, which the screen copy calls out.
    func requestScreenRecordingPermission() async {
        // Remember that the user passed through this step so onboarding can auto-relaunch
        // once at the end — macOS only applies a fresh Screen Recording grant on the next
        // launch, and relaunching for them avoids the "still asking after I granted it"
        // confusion on their very first prompt.
        WindowPositionManager.noteScreenRecordingRequestedDuringOnboarding()
        await Task.detached {
            _ = CGRequestScreenCaptureAccess()
        }.value
    }

    /// Hands: the global push-to-talk / double-Control hotkeys. They run off a
    /// listen-only CGEvent tap that only starts once Accessibility is granted
    /// (GlobalPushToTalkShortcutMonitor + CompanionManager.refreshAllPermissions).
    /// This fires the macOS system prompt on the first attempt and falls back to
    /// opening System Settings on later attempts.
    @MainActor
    func requestAccessibilityPermission() {
        WindowPositionManager.requestAccessibilityPermission()
    }

    func requestCalendarPermission() async {
        _ = try? await calendarService.requestAccess(to: .event)
    }

    func requestRemindersPermission() async {
        _ = try? await calendarService.requestAccess(to: .reminder)
    }
}
