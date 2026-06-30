import AVFoundation
import Foundation

/// Exposes the offline Whisper.cpp engine through Perch's `BuddyTranscriptionProvider`
/// streaming seam. Whisper is batch-only — it transcribes a complete utterance in one
/// pass — so the session accumulates the streamed microphone buffers, resamples them to
/// the 16 kHz mono float that whisper.cpp expects, and runs the model when push-to-talk
/// is released (`requestFinalTranscript`).
///
/// This provider is the automatic **offline fallback** — chosen when no cloud provider
/// (AssemblyAI/OpenAI) is configured — and can also be forced via
/// `VoiceTranscriptionProvider = whisper`. When a cloud provider IS configured it stays
/// the default, so normal setups are unchanged.
final class WhisperTranscriptionProvider: BuddyTranscriptionProvider {
    let displayName = "Whisper (offline)"

    /// Whisper needs only microphone access, not Speech-recognition authorization.
    let requiresSpeechRecognitionPermission = false

    /// The model self-provisions (downloads on first use), so the provider is always usable.
    let isConfigured = true

    let unavailableExplanation: String? = nil

    private let engine = WhisperProvider()

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        // Download (first run only) and load the model BEFORE we accept audio, so the
        // final pass has a warm model and completes well inside the fallback window.
        try await engine.prepare { fraction in
            print("[Whisper] preparing model: \(Int(fraction * 100))%")
        }

        return WhisperTranscriptionSession(
            engine: engine,
            onFinalTranscriptReady: onFinalTranscriptReady,
            onError: onError
        )
    }
}

/// A single push-to-talk utterance: buffers + resamples microphone audio, then runs the
/// Whisper model once on finalize. Whisper.cpp cannot stream partial results, so this
/// session delivers only the final transcript (no live `onTranscriptUpdate` callbacks).
private final class WhisperTranscriptionSession: NSObject, BuddyStreamingTranscriptionSession {

    /// Whisper is a batch engine; allow generous time for the final pass, matching the
    /// other batch provider (OpenAI = 8.0). A warm whisper-base pass finishes in well
    /// under a second, so the fallback timer is a safety net, not the common path.
    let finalTranscriptFallbackDelaySeconds: TimeInterval = 8.0

    private let engine: WhisperProvider
    private let onFinalTranscriptReady: (String) -> Void
    private let onError: (Error) -> Void

    private let audioBuffer16k = ThreadSafeAudioBuffer()
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    // Touched only on the audio-tap thread (appendAudioBuffer), so no lock is needed.
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?

    private var hasRequestedFinalTranscript = false
    private var hasDeliveredFinalTranscript = false

    init(
        engine: WhisperProvider,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.engine = engine
        self.onFinalTranscriptReady = onFinalTranscriptReady
        self.onError = onError
        super.init()
    }

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        guard !hasRequestedFinalTranscript else { return }
        guard let resampled = resampleToTargetFormat(audioBuffer) else { return }
        audioBuffer16k.append(resampled)
    }

    func requestFinalTranscript() {
        guard !hasRequestedFinalTranscript else { return }
        hasRequestedFinalTranscript = true

        var samples = audioBuffer16k.getAll()
        audioBuffer16k.clear()

        // whisper.cpp asserts on buffers shorter than one second; pad with silence.
        if samples.count < 16_000 {
            samples.append(contentsOf: repeatElement(0.0, count: 16_000 - samples.count))
        }

        Task { [weak self] in
            await self?.runFinalPass(samples)
        }
    }

    func cancel() {
        hasRequestedFinalTranscript = true
        hasDeliveredFinalTranscript = true
        audioBuffer16k.clear()
    }

    // MARK: - Private

    private func runFinalPass(_ samples: [Float]) async {
        do {
            let result = try await engine.transcribe(samples)
            deliverFinalTranscriptIfNeeded(result.text.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            guard !hasDeliveredFinalTranscript else { return }
            print("[Whisper] final transcription failed: \(error.localizedDescription)")
            onError(error)
        }
    }

    private func deliverFinalTranscriptIfNeeded(_ transcriptText: String) {
        guard !hasDeliveredFinalTranscript else { return }
        hasDeliveredFinalTranscript = true
        onFinalTranscriptReady(transcriptText)
    }

    /// Converts an arbitrary-format microphone buffer to 16 kHz mono float32 samples.
    /// The converter is created lazily and rebuilt if the input format ever changes.
    private func resampleToTargetFormat(_ inputBuffer: AVAudioPCMBuffer) -> [Float]? {
        let inputFrameCount = inputBuffer.frameLength
        guard inputFrameCount > 0 else { return nil }

        if converter == nil || converterInputFormat != inputBuffer.format {
            converter = AVAudioConverter(from: inputBuffer.format, to: targetFormat)
            converterInputFormat = inputBuffer.format
        }
        guard let converter else { return nil }

        let sampleRateRatio = targetFormat.sampleRate / inputBuffer.format.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(inputFrameCount) * sampleRateRatio) + 16
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else { return nil }

        var hasProvidedInput = false
        let status = converter.convert(to: outputBuffer, error: nil) { _, inputStatus in
            if hasProvidedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            hasProvidedInput = true
            inputStatus.pointee = .haveData
            return inputBuffer
        }

        guard status != .error, let channelData = outputBuffer.floatChannelData else { return nil }
        let outputFrameCount = Int(outputBuffer.frameLength)
        guard outputFrameCount > 0 else { return nil }

        return Array(UnsafeBufferPointer(start: channelData[0], count: outputFrameCount))
    }
}
