//
//  PerchInstallIdentity.swift
//  notch
//
//  Stable per-install identity for multi-user Perch. On first run this mints a
//  random UUID and persists it to `<repo>/support/install-identity.json` (durable
//  state belongs in support/, never UserDefaults). The install can optionally be
//  linked to an email captured at onboarding.
//
//  Identity is exchanged with the Cloudflare Worker via /register, which returns:
//    • installToken     — the opaque bearer the app sends on every Worker call
//                         (X-Perch-Install-Token). Stored only as a hash server-side,
//                         so each register mints a NEW token; the install id is stable.
//    • serverTracingEnabled — the owner's remote kill switch for trace collection.
//
//  Network code on any actor reads the current token through the thread-safe
//  `currentInstallToken()` accessor — the same nonisolated pattern that
//  `PerchCapabilityToggles.isEyesEnabledNow()` uses.
//

import Combine
import Foundation

@MainActor
final class PerchInstallIdentity: ObservableObject {
    static let shared = PerchInstallIdentity()

    /// The stable per-install UUID, minted once and persisted.
    @Published private(set) var installId: String
    /// The email linked at onboarding, if any.
    @Published private(set) var email: String?
    /// Whether the linked email has been proven via the onboarding OTP flow.
    /// Persisted so a verified user is never re-challenged on relaunch.
    @Published private(set) var emailVerified: Bool
    /// The owner's server-side kill switch from the last /register response.
    /// When false, trace collection is disabled for this install regardless of
    /// the local opt-in toggle. Mirrored to a cross-actor cache for the uploaders.
    @Published private(set) var serverTracingEnabled: Bool {
        didSet { Self.cacheServerTracingEnabled(serverTracingEnabled) }
    }
    /// Whether we currently hold an install token (have registered at least once).
    @Published private(set) var isRegistered: Bool

    /// The account's plan + this month's usage, as last reported by the Worker.
    /// Read-only snapshot for the UI; the Worker remains the enforcer. Defaults to
    /// the free plan until the first /register or /account/entitlement response.
    @Published private(set) var entitlement: PerchEntitlement

    /// The bearer token. Setting it mirrors the value into the cross-actor cache.
    private var installToken: String? {
        didSet { Self.cacheInstallToken(installToken) }
    }

    private init() {
        let persisted = Self.loadOrMintIdentity()
        installId = persisted.installId
        email = persisted.email
        emailVerified = persisted.emailVerified ?? false
        serverTracingEnabled = persisted.tracingEnabled
        installToken = persisted.installToken
        isRegistered = persisted.installToken != nil
        entitlement = persisted.entitlement ?? .free
        Self.cacheInstallToken(persisted.installToken)
        Self.cacheServerTracingEnabled(persisted.tracingEnabled)
    }

    // MARK: - Cross-actor token accessor

    private static let tokenLock = NSLock()
    nonisolated(unsafe) private static var cachedInstallToken: String?

    /// The current install token, readable from any actor (network request
    /// builders run off the main actor). nil before the first successful register.
    nonisolated static func currentInstallToken() -> String? {
        tokenLock.lock()
        defer { tokenLock.unlock() }
        return cachedInstallToken
    }

    private static func cacheInstallToken(_ token: String?) {
        tokenLock.lock()
        cachedInstallToken = token
        tokenLock.unlock()
    }

    private static let serverTracingLock = NSLock()
    nonisolated(unsafe) private static var cachedServerTracingEnabled = true

    /// The owner's server-side tracing kill switch, readable from any actor (the
    /// uploaders run off the main actor). Defaults true until the first register.
    nonisolated static func isServerTracingEnabled() -> Bool {
        serverTracingLock.lock()
        defer { serverTracingLock.unlock() }
        return cachedServerTracingEnabled
    }

    private static func cacheServerTracingEnabled(_ enabled: Bool) {
        serverTracingLock.lock()
        cachedServerTracingEnabled = enabled
        serverTracingLock.unlock()
    }

    // MARK: - Registration

    /// Registers (or re-registers) this install with the Worker, refreshing the
    /// install token and the server tracing kill switch. Best-effort: a network
    /// failure leaves the prior token and state untouched. Pass `emailToLink` to
    /// associate the onboarding email with this install.
    func register(emailToLink: String? = nil) async {
        guard let registerURL = URL(string: "\(Self.workerBaseURL)/register") else { return }

        var requestBody: [String: Any] = [
            "installId": installId,
            "appVersion": Self.appVersion,
            "osVersion": Self.osVersion,
        ]
        if let emailToLink, !emailToLink.isEmpty {
            requestBody["email"] = emailToLink
        }

        var request = URLRequest(url: registerURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        request.httpBody = try? JSONSerialization.data(withJSONObject: requestBody)

        do {
            let (data, response) = try await Self.registrationSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let issuedToken = json["installToken"] as? String else {
                perchDebugLog("install-identity: register failed (no token in response)")
                return
            }

            installToken = issuedToken
            isRegistered = true
            if let tracingEnabled = json["tracingEnabled"] as? Bool {
                serverTracingEnabled = tracingEnabled
            }
            if let emailToLink, !emailToLink.isEmpty {
                email = emailToLink
            }
            // The Worker returns the current entitlement on /register; decode it
            // from the same response so the app's plan state is fresh on launch.
            if let decodedEntitlement = Self.decodeEntitlement(from: data) {
                entitlement = decodedEntitlement
            }
            persist()
            perchDebugLog("install-identity: registered install \(installId.prefix(8))")
        } catch {
            perchDebugLog("install-identity: register error \(error.localizedDescription)")
        }
    }

    // MARK: - Entitlement

    /// Re-fetches the entitlement from the Worker. Cheap; call on launch and at
    /// feature entry points so an upgrade made on the website shows up without a
    /// restart (the install token already points at the now-upgraded account).
    func refreshEntitlement() async {
        guard isRegistered,
              let url = URL(string: "\(Self.workerBaseURL)/account/entitlement") else { return }

        var request = authorizedRequest(url: url, method: "GET")
        do {
            let (data, _) = try await Self.registrationSession.data(for: request)
            if let decodedEntitlement = Self.decodeEntitlement(from: data) {
                entitlement = decodedEntitlement
                persist()
            }
        } catch {
            perchDebugLog("install-identity: refresh-entitlement error \(error.localizedDescription)")
        }
    }

    // MARK: - Email verification (onboarding OTP)

    /// The outcome of asking the Worker to send a verification code.
    enum EmailVerificationSendResult {
        case sent
        /// A user-presentable reason the code could not be sent.
        case failed(String)
    }

    /// The outcome of checking a verification code.
    enum EmailVerificationCheckResult {
        case verified
        /// The code did not match.
        case incorrect
        /// The code expired or was never issued — the user should request a new one.
        case expired
        /// A transport/server error; the message is user-presentable.
        case failed(String)
    }

    /// Asks the Worker (which generates the code and sends the email) to email a
    /// 6-digit code to `email`. Does not mutate identity state — the email is only recorded once a
    /// code is confirmed. The install token is attached when present so the
    /// request is attributed and rate-limited per install.
    func sendEmailVerificationCode(to email: String) async -> EmailVerificationSendResult {
        guard let url = URL(string: "\(Self.workerBaseURL)/account/verify-request") else {
            return .failed("Verification is unavailable right now.")
        }
        var request = authorizedRequest(url: url, method: "POST")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["email": email])

        do {
            let (data, response) = try await Self.registrationSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .failed("Verification is unavailable right now.")
            }
            if (200...299).contains(httpResponse.statusCode) {
                return .sent
            }
            perchDebugLog("email-verify: send failed (status \(httpResponse.statusCode))")
            return .failed(Self.errorMessage(from: data, fallback: "Couldn't send the code. Please try again."))
        } catch {
            perchDebugLog("email-verify: send error \(error.localizedDescription)")
            return .failed("Couldn't reach the server. Check your connection and try again.")
        }
    }

    /// Checks `code` for `email` with the Worker. On success, records the email as
    /// linked + verified on this install (and best-effort links it server-side via
    /// /register), then persists so the user is never re-challenged.
    func confirmEmailVerificationCode(email: String, code: String) async -> EmailVerificationCheckResult {
        guard let url = URL(string: "\(Self.workerBaseURL)/account/verify-confirm") else {
            return .failed("Verification is unavailable right now.")
        }
        var request = authorizedRequest(url: url, method: "POST")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "email": email,
            "code": code,
            "installId": installId,
        ])

        do {
            let (data, response) = try await Self.registrationSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                perchDebugLog("email-verify: confirm failed (non-2xx or unparseable)")
                return .failed(Self.errorMessage(from: data, fallback: "Couldn't verify the code. Please try again."))
            }

            if (json["verified"] as? Bool) == true {
                if !email.isEmpty { self.email = email }
                emailVerified = true
                persist()
                // Best-effort: link the (now verified) email to this install on the
                // Worker so the account is labeled and the install token refreshes.
                await register(emailToLink: email)
                return .verified
            }

            // verified:false — distinguish an expired code (request a new one) from
            // a simply-wrong one so the UI can guide the user correctly.
            let reason = json["reason"] as? String
            return reason == "expired" ? .expired : .incorrect
        } catch {
            perchDebugLog("email-verify: confirm error \(error.localizedDescription)")
            return .failed("Couldn't reach the server. Check your connection and try again.")
        }
    }

    /// Pulls a user-presentable message out of a Worker JSON error body
    /// (`{"error": "…"}`), falling back to a generic line.
    private static func errorMessage(from data: Data?, fallback: String) -> String {
        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["error"] as? String, !message.isEmpty else {
            return fallback
        }
        return message
    }

    /// Builds a request carrying the install token (the Worker's auth principal).
    private func authorizedRequest(url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let installToken {
            request.setValue(installToken, forHTTPHeaderField: "X-Perch-Install-Token")
        }
        return request
    }

    /// Decodes the `entitlement` field shared by the /register, verify-confirm,
    /// and /account/entitlement responses.
    private struct EntitlementEnvelope: Decodable { let entitlement: PerchEntitlement? }
    private static func decodeEntitlement(from data: Data) -> PerchEntitlement? {
        (try? JSONDecoder().decode(EntitlementEnvelope.self, from: data))?.entitlement
    }

    // MARK: - Persistence

    private struct PersistedIdentity: Codable {
        let installId: String
        var installToken: String?
        var email: String?
        // Optional for forward/backward compatibility with identity files written
        // before the onboarding email-OTP flow existed (decode → treat as false).
        var emailVerified: Bool?
        var tracingEnabled: Bool
        // Cached so the app remembers a paid plan offline. Optional for forward/
        // backward compatibility with identity files written before this field.
        var entitlement: PerchEntitlement?
    }

    private static let identityFileURL = PerchSupportPaths.file("install-identity.json")

    /// A long-lived URLSession for the registration handshake. Disk caches are
    /// disabled so no bearer token is cached on disk.
    private static let registrationSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }()

    private static func loadOrMintIdentity() -> PersistedIdentity {
        if let data = try? Data(contentsOf: identityFileURL),
           let decoded = try? JSONDecoder().decode(PersistedIdentity.self, from: data) {
            return decoded
        }
        // First run: mint a fresh id. tracingEnabled defaults true (the server's
        // default); the actual value is confirmed on the first /register.
        let minted = PersistedIdentity(
            installId: UUID().uuidString.lowercased(),
            installToken: nil,
            email: nil,
            emailVerified: false,
            tracingEnabled: true,
            entitlement: nil
        )
        Self.write(minted)
        return minted
    }

    private func persist() {
        Self.write(PersistedIdentity(
            installId: installId,
            installToken: installToken,
            email: email,
            emailVerified: emailVerified,
            tracingEnabled: serverTracingEnabled,
            entitlement: entitlement
        ))
    }

    private static func write(_ identity: PersistedIdentity) {
        guard let data = try? JSONEncoder().encode(identity) else { return }
        try? data.write(to: identityFileURL, options: .atomic)
    }

    // MARK: - Environment

    private static let workerBaseURL = AppBundleConfiguration.stringValue(forKey: "WorkerBaseURL")
        ?? "https://your-worker-name.your-subdomain.workers.dev"

    private static let appVersion =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"

    private static let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
}
