import Foundation

/// Thread-safe `[Float]` audio buffer shared between AVAudioEngine's realtime tap
/// callback thread (which appends) and the transcription session that drains it on
/// finalize. Ported from FluidVoice (altic-dev/FluidVoice).
final class ThreadSafeAudioBuffer {
    private var buffer: [Float] = []
    private let lock = NSLock()

    func append(_ newSamples: [Float]) {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(contentsOf: newSamples)
    }

    func clear(keepingCapacity: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        buffer.removeAll(keepingCapacity: keepingCapacity)
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return buffer.count
    }

    func getAll() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }
}
