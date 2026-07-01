//
//  CerebrasClient.swift
//  leanring-buddy
//
//  Text-only LLM backend on Cerebras (OpenAI-compatible chat-completions). Used
//  by the vision gate: a fast classifier decides whether a query needs the
//  screen, and — when it doesn't — Cerebras answers the query directly so the
//  app never captures a screenshot or pays for a multimodal round-trip.
//
//  The Cerebras key lives ONLY on the Worker: these calls go through the Worker's
//  `/vision-gate` route (authenticated with the per-install token), so the app
//  ships no provider key. The OpenAI chat-completions request/response bodies are
//  forwarded verbatim by the Worker.
//
//  Cerebras serves reasoning models, so every call sends `reasoning_effort:
//  "none"` to get a clean, direct answer with no chain-of-thought tokens (Perch
//  replies are one short sentence).
//
//  Mirrors the (text, duration) return shape of ClaudeAPI.swift.
//

import Foundation

/// Vision-gate (Cerebras) configuration. The Cerebras API key lives only on the
/// Worker — the app never carries it. These calls go through the Worker's
/// `/vision-gate` route and authenticate with the per-install token, exactly like
/// every other proxied call (`ClaudeAPI`, `ElevenLabsTTSClient`). Only the model
/// name is still a local knob (sent in the request body, overridable via `.env`).
enum CerebrasConfiguration {

    /// The Worker's vision-gate route. Reads the same `WorkerBaseURL` Info.plist
    /// key the rest of the backend uses, so switching backends needs no code edit.
    static var visionGateURL: URL {
        let workerBaseURL = AppBundleConfiguration.stringValue(forKey: "WorkerBaseURL")
            ?? "https://your-worker-name.your-subdomain.workers.dev"
        return URL(string: "\(workerBaseURL)/vision-gate")!
    }

    /// Default text model. Z.ai GLM 4.7 — strong general reasoning, ~1000 tok/s.
    /// Override with `CLICKY_CEREBRAS_MODEL`.
    static let defaultModel = "zai-glm-4.7"

    /// The text model to use, falling back to `defaultModel`. Sent in the request
    /// body and forwarded verbatim by the Worker to Cerebras.
    static var model: String {
        let rawValue = ProcessInfo.processInfo.environment["CLICKY_CEREBRAS_MODEL"]
            ?? DotEnvConfiguration.value(forKey: "CLICKY_CEREBRAS_MODEL")
        let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty { return trimmed }
        return defaultModel
    }

    /// True once we have an install token to authenticate the Worker call. Before
    /// the first `/register` there's no token, so the gate stays inert and the app
    /// keeps capturing the screen. (If the Worker has no Cerebras key, `/vision-gate`
    /// 503s and the classifier still falls back to screen capture — reliability
    /// over the saved round-trip.)
    static var isConfigured: Bool { PerchInstallIdentity.currentInstallToken() != nil }
}

/// Cerebras text-only client: a screen-need classifier and a streaming answerer.
final class CerebrasClient {
    static let shared = CerebrasClient()

    private let session: URLSession

    private init() {
        // Mirror ClaudeAPI/OpenAIAPI session config: cache TLS tickets (.default),
        // never persist responses or cookies.
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120
        config.waitsForConnectivity = true
        config.urlCache = nil
        config.httpCookieStorage = nil
        self.session = URLSession(configuration: config)
    }

    /// Builds a POST request to the Worker's `/vision-gate` route. Authenticates
    /// with the per-install token (never a provider key). `feature` tags the call
    /// for usage metering: the text-only answer path passes "companion" so it
    /// counts as a message exactly like the `/chat` path it replaces; the classifier
    /// call leaves it nil so the routing decision is never metered.
    private func makeRequest(feature: String? = nil) -> URLRequest {
        var request = URLRequest(url: CerebrasConfiguration.visionGateURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let installToken = PerchInstallIdentity.currentInstallToken() {
            request.setValue(installToken, forHTTPHeaderField: "X-Perch-Install-Token")
        }
        if let feature {
            request.setValue(feature, forHTTPHeaderField: "X-Perch-Feature")
        }
        return request
    }

    // MARK: - Vision gate classifier

    /// System prompt for the screen-need classifier. The reply is a single token,
    /// so the instruction is terse and unambiguous.
    private static let classifierSystemPrompt = """
    You are a routing classifier for Perch, a screen-aware desktop assistant. \
    Decide whether answering the user's latest message requires LOOKING at what is \
    currently on their screen. Answer YES whenever the message points at something \
    the user is currently looking at instead of naming it explicitly — including \
    demonstratives like "this", "that", "these", "those", "here", phrases like \
    "which of these", "the one at the top", "on my screen", "the highlighted one", \
    or reading their current window / pointing at a UI element. For example, "which \
    of these movies are on Netflix?" is YES, because "these movies" are on their \
    screen and you must read them to answer. \
    General knowledge, casual conversation, writing, math, and coding questions that \
    name their subject explicitly do NOT require the screen. When genuinely unsure, \
    answer YES. Reply with exactly one word: YES or NO.
    """

    /// Returns whether the query needs the screen. Any failure (unconfigured,
    /// HTTP error, ambiguous reply) returns `true` so the caller falls back to
    /// capturing the screen — reliability over savings.
    func classifyNeedsScreen(
        transcript: String,
        recentHistory: [(userPlaceholder: String, assistantResponse: String)] = []
    ) async -> Bool {
        // Deterministic deictic guard FIRST: certain phrases ("these movies",
        // "this error", "on my screen") point unambiguously at on-screen content.
        // Short-circuit to screen-capture without a classifier round-trip — both
        // faster and immune to the tiny model misrouting them to the blind text
        // path. Reliability over savings.
        if VisionGateDeicticGuard.transcriptMentionsOnScreenReference(transcript) {
            print("🚪 Vision gate: on-screen deictic reference → screen needed (classifier skipped)")
            return true
        }

        guard CerebrasConfiguration.isConfigured else { return true }

        var messages: [[String: Any]] = [
            ["role": "system", "content": Self.classifierSystemPrompt]
        ]
        // Include a little recent context so follow-ups ("what about that one?")
        // can be judged against the prior turn.
        for exchange in recentHistory.suffix(2) {
            messages.append(["role": "user", "content": exchange.userPlaceholder])
            messages.append(["role": "assistant", "content": exchange.assistantResponse])
        }
        messages.append(["role": "user", "content": transcript])

        let body: [String: Any] = [
            "model": CerebrasConfiguration.model,
            "max_completion_tokens": 5,
            // GLM/gpt-oss are reasoning models; without this they burn the tiny
            // token budget on hidden reasoning and never emit YES/NO.
            "reasoning_effort": "none",
            "messages": messages
        ]

        var request = makeRequest()
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                print("⚠️ Cerebras classifier non-2xx (status=\(statusCode)) — "
                    + "defaulting to capture screen")
                return true
            }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let content = ((json?["choices"] as? [[String: Any]])?.first?["message"]
                as? [String: Any])?["content"] as? String ?? ""
            let verdict = content.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            // The classifier is told to reply with exactly one word: YES or NO. Require
            // an EXACT "NO" to take the no-screen path — a substring check would route
            // "CANNOT"/"KNOW"/"NOpe" to text and answer blind (the worst failure mode).
            if verdict == "NO" {
                print("🚪 Vision gate: NO screen needed → Cerebras text path")
                return false
            }
            // "YES", empty, or anything ambiguous → capture the screen.
            print("🚪 Vision gate: screen needed (verdict=\(verdict.isEmpty ? "∅" : verdict)) → vision path")
            return true
        } catch {
            print("⚠️ Cerebras classifier error: \(error) — defaulting to capture screen")
            return true
        }
    }

    // MARK: - Text-only streaming answer

    /// Streams a text-only answer from Cerebras. Accumulates only
    /// `choices[0].delta.content` (reasoning is disabled, but we ignore any
    /// `delta.reasoning` defensively) and calls `onTextChunk` with the running
    /// text — matching ClaudeAPI.analyzeImageStreaming's contract.
    func respondTextOnlyStreaming(
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        maxTokens: Int = 1024,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        guard CerebrasConfiguration.isConfigured else {
            throw NSError(
                domain: "CerebrasClient",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Vision gate unavailable (no install token yet)"]
            )
        }

        let startTime = Date()

        var messages: [[String: Any]] = [
            ["role": "system", "content": systemPrompt]
        ]
        for exchange in conversationHistory {
            messages.append(["role": "user", "content": exchange.userPlaceholder])
            messages.append(["role": "assistant", "content": exchange.assistantResponse])
        }
        messages.append(["role": "user", "content": userPrompt])

        let body: [String: Any] = [
            "model": CerebrasConfiguration.model,
            "max_completion_tokens": maxTokens,
            "stream": true,
            "reasoning_effort": "none",
            "messages": messages
        ]

        // The text-only answer replaces a /chat companion turn, so meter it as
        // "companion" — one message either way, closing the vision-gate cap bypass.
        var request = makeRequest(feature: "companion")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (byteStream, response) = try await session.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "CerebrasClient",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"]
            )
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            var errorBodyChunks: [String] = []
            for try await line in byteStream.lines {
                errorBodyChunks.append(line)
            }
            let errorBody = errorBodyChunks.joined(separator: "\n")
            throw NSError(
                domain: "CerebrasClient",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Cerebras API Error (\(httpResponse.statusCode)): \(errorBody)"]
            )
        }

        var accumulatedResponseText = ""

        // OpenAI-style SSE: "data: {chunk}" lines, terminated by "data: [DONE]".
        for try await line in byteStream.lines {
            guard line.hasPrefix("data: ") else { continue }
            let jsonString = String(line.dropFirst(6))
            guard jsonString != "[DONE]" else { break }

            guard let jsonData = jsonString.data(using: .utf8),
                  let eventPayload = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let choices = eventPayload["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any] else {
                continue
            }

            // Only the visible answer text — never the (defensively ignored)
            // reasoning channel.
            guard let textChunk = delta["content"] as? String, !textChunk.isEmpty else {
                continue
            }
            accumulatedResponseText += textChunk
            let currentAccumulatedText = accumulatedResponseText
            await onTextChunk(currentAccumulatedText)
        }

        let duration = Date().timeIntervalSince(startTime)
        return (text: accumulatedResponseText, duration: duration)
    }
}
