//
//  EmailVerificationView.swift
//  notch
//
//  Onboarding account step, part 1 of 2: capture the user's email and send a
//  6-digit verification code to it (via PerchInstallIdentity → the Worker, which
//  generates the code and emails it). This step is MANDATORY — onboarding cannot
//  proceed until an email is verified — so there is no "skip". On a sent code,
//  onboarding advances to `OTPVerificationView` (part 2) to check the code.
//
//  This view holds no network or account logic of its own; it only calls
//  PerchInstallIdentity.
//

import SwiftUI

struct EmailVerificationView: View {
    /// Called once a code has been sent, carrying the normalized email the code
    /// went to. Onboarding advances to the code-entry step with this address.
    let onCodeSent: (String) -> Void

    @ObservedObject private var identity = PerchInstallIdentity.shared

    @State private var emailAddress: String = ""
    @State private var isSubmitting: Bool = false
    @State private var errorMessage: String?
    @FocusState private var isEmailFocused: Bool

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "envelope.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 60, height: 50)
                .foregroundColor(.effectiveAccent)
                .padding(.top, 36)

            Text("Verify your email")
                .font(.title)
                .fontWeight(.semibold)

            Text("Perch needs a verified email to set up your account. Enter it and we'll send you a 6-digit code.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            TextField("you@example.com", text: $emailAddress)
                .textFieldStyle(.roundedBorder)
                .textContentType(.emailAddress)
                .disableAutocorrection(true)
                .frame(maxWidth: 260)
                .focused($isEmailFocused)
                .onSubmit(sendCode)
                .onChange(of: emailAddress) { _, _ in errorMessage = nil }

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Button(action: sendCode) {
                Text(isSubmitting ? "Sending…" : "Send code")
                    .frame(maxWidth: 260)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isSubmitting || !isValidEmail(emailAddress))
            .padding(.top, 4)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            VisualEffectView(material: .underWindowBackground, blendingMode: .behindWindow)
                .ignoresSafeArea()
        )
        .onAppear { isEmailFocused = true }
    }

    // MARK: - Actions

    private func sendCode() {
        let normalizedEmail = emailAddress
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard isValidEmail(normalizedEmail), !isSubmitting else { return }
        isSubmitting = true
        errorMessage = nil
        Task {
            let result = await identity.sendEmailVerificationCode(to: normalizedEmail)
            isSubmitting = false
            switch result {
            case .sent:
                onCodeSent(normalizedEmail)
            case .failed(let message):
                errorMessage = message
            }
        }
    }

    private func isValidEmail(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.contains("@") && trimmed.contains(".") && trimmed.count >= 5
    }
}

#Preview {
    EmailVerificationView(onCodeSent: { _ in })
        .frame(width: 400, height: 600)
}
