import Foundation
import SwiftWhisper

/// Result of a single batch transcription pass.
struct ASRTranscriptionResult {
    let text: String
    let confidence: Float

    init(text: String, confidence: Float = 1.0) {
        self.text = text
        self.confidence = confidence
    }
}

/// On-device transcription via whisper.cpp (SwiftWhisper). Works on Intel and Apple Silicon.
/// Models are downloaded from HuggingFace on first use and cached under `<repo>/support/models/whisper/`.
/// Ported from FluidVoice (altic-dev/FluidVoice) with app-specific dependencies removed.
///
/// This is a batch engine: it transcribes a complete utterance in one pass. The streaming
/// seam (`WhisperTranscriptionProvider`) buffers microphone audio and calls `transcribe`
/// once the user releases push-to-talk.
final class WhisperProvider {
    let name = "Whisper"

    var isAvailable: Bool { true }

    private var whisper: Whisper?
    private(set) var isReady: Bool = false
    private var loadedModelFileName: String?

    // MARK: - Model Selection

    private var modelFileName: String {
        let configValue = AppBundleConfiguration.stringValue(forKey: "WhisperModel") ?? "base"
        switch configValue.lowercased() {
        case "tiny":     return "ggml-tiny.bin"
        case "small":    return "ggml-small.bin"
        case "medium":   return "ggml-medium.bin"
        case "large", "large-v3": return "ggml-large-v3.bin"
        default:         return "ggml-base.bin"
        }
    }

    private var modelURL: URL {
        PerchSupportPaths.directory("models")
            .appendingPathComponent("whisper")
            .appendingPathComponent(modelFileName)
    }

    private var modelDirectory: URL {
        modelURL.deletingLastPathComponent()
    }

    // MARK: - Lifecycle

    func prepare(progressHandler: ((Double) -> Void)? = nil) async throws {
        let targetFileName = self.modelFileName

        if isReady, loadedModelFileName != targetFileName {
            print("[Whisper] Model changed to \(targetFileName), reloading")
            isReady = false
            whisper = nil
            loadedModelFileName = nil
        }

        guard !isReady else { return }

        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)

        if FileManager.default.fileExists(atPath: modelURL.path), !isModelFileValid(at: modelURL) {
            print("[Whisper] Removing corrupted model at \(modelURL.path)")
            try? FileManager.default.removeItem(at: modelURL)
        }

        if !FileManager.default.fileExists(atPath: modelURL.path) {
            print("[Whisper] Downloading \(targetFileName)…")
            try await downloadModel(fileName: targetFileName, progressHandler: progressHandler)
        }

        guard isModelFileValid(at: modelURL) else {
            throw NSError(
                domain: "WhisperProvider",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "Whisper model file is missing or corrupted. It will be re-downloaded on next use."]
            )
        }

        let requiredGB = requiredMemoryGB(for: targetFileName)
        let availableGB = Self.availableMemoryGB()
        if availableGB < requiredGB {
            throw NSError(
                domain: "WhisperProvider",
                code: -4,
                userInfo: [NSLocalizedDescriptionKey: "Insufficient memory for Whisper \(targetFileName). Need \(String(format: "%.1f", requiredGB)) GB, have \(String(format: "%.1f", availableGB)) GB. Try a smaller model via the WhisperModel Info.plist key."]
            )
        }

        print("[Whisper] Loading \(targetFileName)…")
        whisper = Whisper(fromFileURL: modelURL)
        loadedModelFileName = targetFileName
        isReady = true
        print("[Whisper] Ready (\(targetFileName))")
    }

    func transcribe(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        guard samples.count >= 16_000 else {
            throw NSError(
                domain: "WhisperProvider",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Audio too short for Whisper transcription (minimum 1 second)"]
            )
        }

        guard let whisper else {
            throw NSError(
                domain: "WhisperProvider",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Whisper model not loaded. Call prepare() first."]
            )
        }

        let segments = try await whisper.transcribe(audioFrames: samples)
        let text = segments.map { $0.text }.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ASRTranscriptionResult(text: text, confidence: 1.0)
    }

    func modelsExistOnDisk() -> Bool {
        isModelFileValid(at: modelURL)
    }

    func clearCache() async throws {
        if FileManager.default.fileExists(atPath: modelURL.path) {
            try FileManager.default.removeItem(at: modelURL)
        }
        isReady = false
        whisper = nil
        loadedModelFileName = nil
    }

    // MARK: - Private Helpers

    private func isModelFileValid(at url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber, size.int64Value > 0 else { return false }
        if let minBytes = minimumBytesForModel(url.lastPathComponent), size.int64Value < minBytes {
            return false
        }
        return true
    }

    private func minimumBytesForModel(_ fileName: String) -> Int64? {
        switch fileName {
        case "ggml-tiny.bin":    return 50 * 1024 * 1024
        case "ggml-base.bin":    return 100 * 1024 * 1024
        case "ggml-small.bin":   return 300 * 1024 * 1024
        case "ggml-medium.bin":  return 1_000 * 1024 * 1024
        case "ggml-large-v3.bin": return 2_000 * 1024 * 1024
        default: return nil
        }
    }

    private func requiredMemoryGB(for fileName: String) -> Double {
        switch fileName {
        case "ggml-tiny.bin":    return 0.5
        case "ggml-base.bin":    return 1.0
        case "ggml-small.bin":   return 2.0
        case "ggml-medium.bin":  return 5.0
        case "ggml-large-v3.bin": return 10.0
        default: return 1.0
        }
    }

    private static func availableMemoryGB() -> Double {
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)

        var vmStats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &vmStats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }

        guard result == KERN_SUCCESS else { return 16.0 }

        let availableBytes = (UInt64(vmStats.free_count) + UInt64(vmStats.inactive_count) + UInt64(vmStats.purgeable_count)) * UInt64(pageSize)
        return Double(availableBytes) / (1024 * 1024 * 1024)
    }

    // MARK: - Download

    private func downloadModel(fileName: String, progressHandler: ((Double) -> Void)?) async throws {
        let urlString = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(fileName)"
        guard let url = URL(string: urlString) else {
            throw NSError(domain: "WhisperProvider", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid model URL"])
        }

        for attempt in 1...3 {
            do {
                if attempt == 1 { progressHandler?(0.0) }
                try await downloadFile(from: url, to: modelURL, progressHandler: progressHandler)
                print("[Whisper] Downloaded \(fileName)")
                return
            } catch {
                guard attempt < 3 else { throw error }
                print("[Whisper] Download attempt \(attempt)/3 failed: \(error.localizedDescription). Retrying…")
                try await Task.sleep(nanoseconds: UInt64(1_000_000_000) << UInt64(attempt - 1))
            }
        }
    }

    private func downloadFile(from sourceURL: URL, to destination: URL, progressHandler: ((Double) -> Void)?) async throws {
        let delegate = DownloadDelegate(onProgress: progressHandler)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let lock = NSLock()
            var didResume = false

            func resumeOnce(_ result: Result<Void, Error>) {
                lock.lock()
                defer { lock.unlock() }
                guard !didResume else { return }
                didResume = true
                session.finishTasksAndInvalidate()
                continuation.resume(with: result)
            }

            delegate.onFinish = { [weak self] tempURL, response in
                guard let self else { resumeOnce(.failure(NSError(domain: "WhisperProvider", code: -1, userInfo: nil))); return }
                do {
                    guard let http = response as? HTTPURLResponse else {
                        throw NSError(domain: "WhisperProvider", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid server response"])
                    }
                    guard http.statusCode == 200 else {
                        throw NSError(domain: "WhisperProvider", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode) downloading model"])
                    }
                    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if FileManager.default.fileExists(atPath: destination.path) {
                        try FileManager.default.removeItem(at: destination)
                    }
                    try FileManager.default.moveItem(at: tempURL, to: destination)
                    guard self.isModelFileValid(at: destination) else {
                        try? FileManager.default.removeItem(at: destination)
                        throw NSError(domain: "WhisperProvider", code: -1, userInfo: [NSLocalizedDescriptionKey: "Downloaded model validation failed"])
                    }
                    resumeOnce(.success(()))
                } catch {
                    resumeOnce(.failure(error))
                }
            }
            delegate.onError = { resumeOnce(.failure($0)) }

            session.downloadTask(with: sourceURL).resume()
        }
    }

    private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
        private let onProgress: ((Double) -> Void)?
        var onFinish: ((URL, URLResponse) -> Void)?
        var onError: ((Error) -> Void)?

        init(onProgress: ((Double) -> Void)?) {
            self.onProgress = onProgress
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            guard let response = downloadTask.response else { return }
            onFinish?(location, response)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error { onError?(error) }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            guard totalBytesExpectedToWrite > 0 else { return }
            onProgress?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        }
    }
}
