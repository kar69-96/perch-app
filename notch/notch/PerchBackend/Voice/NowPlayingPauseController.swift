//
//  NowPlayingPauseController.swift
//  notch
//
//  Pauses the user's now-playing media while Perch is mid-exchange (the user is
//  talking to Perch, or Perch is speaking its reply) and resumes it the moment
//  the exchange ends. Acts on whichever media app the notch's "now playing" is
//  tracking — via the same `MusicManager` the notch already uses — so Perch's
//  own spoken reply is never competing with music that's only turned down.
//

import Foundation

@MainActor
final class NowPlayingPauseController {
    /// Whether *Perch* is the reason the now-playing media is currently paused.
    /// We only resume media that Perch itself paused, so we never auto-start
    /// music the user had deliberately paused before an exchange began. This
    /// also doubles as the idempotency marker (true ⇒ already paused by Perch).
    private var didPauseNowPlayingForPerch = false

    private let musicManager: MusicManager

    init(musicManager: MusicManager = .shared) {
        self.musicManager = musicManager
    }

    /// Whether Perch is currently holding the now-playing media paused.
    var isPaused: Bool { didPauseNowPlayingForPerch }

    /// Pauses the now-playing media so it doesn't compete with Perch's reply.
    /// No-op when nothing is playing (so we never later resume music the user
    /// wasn't playing) or when Perch has already paused it.
    func pauseNowPlayingForPerchVoice() {
        guard !didPauseNowPlayingForPerch else { return }
        guard musicManager.isPlaying else { return }

        didPauseNowPlayingForPerch = true
        musicManager.pause()
    }

    /// Resumes the now-playing media that Perch paused for the exchange.
    /// No-op when Perch didn't pause anything.
    func resumeNowPlayingAfterPerchVoice() {
        guard didPauseNowPlayingForPerch else { return }
        didPauseNowPlayingForPerch = false
        musicManager.play()
    }
}
