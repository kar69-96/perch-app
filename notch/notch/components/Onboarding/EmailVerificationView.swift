//
//  EmailVerificationView.swift
//  notch
//
//  Onboarding account step: capture the user's email. No verification code is
//  sent — the email is recorded against this install as a label, and ownership is
//  proven later at upgrade time by Stripe (the payer controls the email + card).
//  The free tier (25 messages) works with or without an email, so this step is
//  skippable; entering it just pre-fills checkout and labels the account when the
//  user upgrades.
//
//  Talks only to PerchInstallIdentity (which calls the Worker /register); this
//  view holds no network or account logic of its own.
//

import SwiftUI

struct EmailVerificationView: View {
    /// Called when the user has submitted their email, or chosen to skip, and
    /// onboarding should advance to the next step.
    let onContinue: () -> Void

    @ObservedObject private var identity = PerchInstallIdentity.shared

    @State private var emailAddress: String = ""
    @State private var isSubmitting: Bool = false

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "envelope.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 60, height: 50)
                .foregroundColor(.effectiveAccent)
                .padding(.top, 36)

            Text("Link your account")
                .font(.title)
                .fontWeight(.semibold)

            Text("Enter your email to link this Mac to your account.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            TextField("you@example.com", text: $emailAddress)
                .textFieldStyle(.roundedBorder)
                .textContentType(.emailAddress)
                .disableAutocorrection(true)
                .frame(maxWidth: 260)
                .onSubmit(submit)

            HStack(spacing: 12) {
                Button("Skip for now") { onContinue() }
                    .buttonStyle(.bordered)
                Button(action: submit) {
                    Text(isSubmitting ? "Saving…" : "Continue")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSubmitting || !isValidEmail(emailAddress))
            }
            .padding(.top, 8)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            VisualEffectView(material: .underWindowBackground, blendingMode: .behindWindow)
                .ignoresSafeArea()
        )
    }

    // MARK: - Actions

    private func submit() {
        guard isValidEmail(emailAddress), !isSubmitting else { return }
        isSubmitting = true
        Task {
            // Records the email on this install and refreshes the install token /
            // entitlement. Best-effort: even if the network call fails, onboarding
            // proceeds (the free tier works regardless).
            await identity.register(emailToLink: emailAddress)
            isSubmitting = false
            onContinue()
        }
    }

    private func isValidEmail(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.contains("@") && trimmed.contains(".") && trimmed.count >= 5
    }
}

#Preview {
    EmailVerificationView(onContinue: { })
        .frame(width: 400, height: 600)
}
