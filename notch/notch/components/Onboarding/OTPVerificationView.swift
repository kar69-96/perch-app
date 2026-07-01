//
//  OTPVerificationView.swift
//  notch
//
//  Onboarding account step, part 2 of 2: the 6-digit code box. The user arrives
//  here after `EmailVerificationView` has sent a code to their email; they type
//  the code and it's checked via PerchInstallIdentity → the Worker.
//
//  The code is captured by an invisible TextField layered over six digit boxes,
//  so the boxes are purely visual and all keyboard/click input goes to one field
//  (the reliable SwiftUI OTP pattern — no per-box focus juggling). A full 6-digit
//  entry auto-submits. On success, onboarding advances; a wrong or expired code
//  is reported inline and the box is cleared for another try.
//
//  This view holds no network or account logic of its own; it only calls
//  PerchInstallIdentity.
//

import SwiftUI

struct OTPVerificationView: View {
    /// The email the code was sent to (already normalized). Shown to the user and
    /// passed straight back to the verify call so it matches the address the code went to.
    let email: String
    /// Called once the code is confirmed; onboarding advances to permissions.
    let onVerified: () -> Void
    /// Called when the user wants to correct their email; returns to part 1.
    let onChangeEmail: () -> Void

    @ObservedObject private var identity = PerchInstallIdentity.shared

    /// The digits typed so far (0…6 characters, digits only).
    @State private var code: String = ""
    @State private var isVerifying: Bool = false
    @State private var isResending: Bool = false
    /// An inline status line. `statusIsError` picks red vs. muted styling so a
    /// "new code sent" confirmation doesn't look like a failure.
    @State private var statusMessage: String?
    @State private var statusIsError: Bool = true
    @FocusState private var isCodeFocused: Bool

    private let codeLength = 6
    private let boxWidth: CGFloat = 44
    private let boxSpacing: CGFloat = 10

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "lock.circle.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 58, height: 58)
                .foregroundColor(.effectiveAccent)
                .padding(.top, 36)

            Text("Enter the code")
                .font(.title)
                .fontWeight(.semibold)

            Text("We sent a 6-digit code to \(email). Enter it below to continue.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            // Mail from a new sender often lands in Spam/Promotions on the first
            // send, so tell the user exactly what to look for.
            Text("Don't see it? Check your spam folder for an email from heyperch@agentmail.to.")
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            codeEntryField
                .padding(.top, 4)

            if let statusMessage {
                Text(statusMessage)
                    .font(.footnote)
                    .foregroundColor(statusIsError ? .red : .secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Button(action: { Task { await verify() } }) {
                Text(isVerifying ? "Verifying…" : "Verify")
                    .frame(maxWidth: 260)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isVerifying || code.count < codeLength)

            HStack(spacing: 16) {
                Button("Use a different email", action: onChangeEmail)
                    .buttonStyle(.link)
                Button(isResending ? "Sending…" : "Resend code") {
                    Task { await resend() }
                }
                .buttonStyle(.link)
                .disabled(isResending || isVerifying)
            }
            .font(.footnote)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            VisualEffectView(material: .underWindowBackground, blendingMode: .behindWindow)
                .ignoresSafeArea()
        )
        .onAppear { isCodeFocused = true }
    }

    // MARK: - Code entry (six boxes + one invisible capture field)

    private var codeEntryField: some View {
        let fieldWidth = CGFloat(codeLength) * boxWidth + CGFloat(codeLength - 1) * boxSpacing
        return ZStack {
            HStack(spacing: boxSpacing) {
                ForEach(0..<codeLength, id: \.self) { index in
                    digitBox(at: index)
                }
            }

            // The real input: invisible (clear text + clear caret) but on top, so
            // every click and keystroke lands here regardless of which box shows.
            TextField("", text: $code)
                .textFieldStyle(.plain)
                .font(.system(size: 22, weight: .semibold, design: .monospaced))
                .multilineTextAlignment(.center)
                .foregroundColor(.clear)
                .tint(.clear)
                .focused($isCodeFocused)
                .frame(width: fieldWidth, height: 54)
                .contentShape(Rectangle())
                .onChange(of: code) { _, newValue in
                    // Keep only digits, cap at the code length. Guarded so this
                    // normalization doesn't re-trigger itself.
                    let digitsOnly = String(newValue.filter(\.isNumber).prefix(codeLength))
                    if digitsOnly != code { code = digitsOnly }
                    statusMessage = nil
                    if code.count == codeLength { Task { await verify() } }
                }
        }
        .onTapGesture { isCodeFocused = true }
    }

    private func digitBox(at index: Int) -> some View {
        let characters = Array(code)
        let digit = index < characters.count ? String(characters[index]) : ""
        // Highlight the next-empty box while focused so the user sees the caret's
        // position without a real caret.
        let isActive = isCodeFocused && index == characters.count && characters.count < codeLength
        return Text(digit)
            .font(.system(size: 22, weight: .semibold, design: .monospaced))
            .frame(width: boxWidth, height: 54)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        isActive ? Color.effectiveAccent : Color.primary.opacity(0.15),
                        lineWidth: isActive ? 2 : 1
                    )
            )
    }

    // MARK: - Actions

    private func verify() async {
        guard code.count == codeLength, !isVerifying else { return }
        isVerifying = true
        statusMessage = nil
        let result = await identity.confirmEmailVerificationCode(email: email, code: code)
        isVerifying = false
        switch result {
        case .verified:
            onVerified()
        case .incorrect:
            showError("That code isn't right. Check it and try again.")
            resetCodeForRetry()
        case .expired:
            showError("That code expired. Tap “Resend code” to get a new one.")
            resetCodeForRetry()
        case .failed(let message):
            showError(message)
        }
    }

    private func resend() async {
        guard !isResending else { return }
        isResending = true
        statusMessage = nil
        let result = await identity.sendEmailVerificationCode(to: email)
        isResending = false
        switch result {
        case .sent:
            code = ""
            statusIsError = false
            statusMessage = "A new code is on its way to \(email)."
            isCodeFocused = true
        case .failed(let message):
            showError(message)
        }
    }

    private func resetCodeForRetry() {
        code = ""
        isCodeFocused = true
    }

    private func showError(_ message: String) {
        statusIsError = true
        statusMessage = message
    }
}

#Preview {
    OTPVerificationView(email: "you@example.com", onVerified: {}, onChangeEmail: {})
        .frame(width: 400, height: 600)
}
