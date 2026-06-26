//
//  vision-gate-check/main.swift
//  Standalone, no-Xcode verification of the vision gate's deterministic deictic
//  guard (VisionGateDeicticGuard).
//
//  Compiled by scripts/check-vision-gate.sh together with the real product source
//  (ClickyBackend/LLM/VisionGateDeicticGuard.swift), so it exercises the actual
//  shipping logic — not a copy. This guard short-circuits the LLM classifier to
//  ALWAYS capture the screen when the message points at on-screen content, which
//  fixes the regression where "which of these movies are on netflix?" was routed
//  to the blind text path and answered "i'd need a list of movies".
//

import Foundation

var failureCount = 0
func check(_ condition: Bool, _ label: String) {
    print(condition ? "  ok  - \(label)" : "  FAIL- \(label)")
    if !condition { failureCount += 1 }
}

// ── Must capture the screen: phrases that point at on-screen content ──

let mustCaptureScreen: [String] = [
    // The exact regression that motivated this guard.
    "Which of these movies are on Netflix?",
    "which of these are open source",
    "summarize those for me",
    "compare these two options",
    "what does this error mean?",
    "translate that paragraph",
    "what's this button do",
    "what is that dialog asking",
    "is the highlighted one available",
    "read what's on my screen",
    "what's on-screen right now",
    "which of these is cheapest",
]

for transcript in mustCaptureScreen {
    check(
        VisionGateDeicticGuard.transcriptMentionsOnScreenReference(transcript),
        "captures screen for: \"\(transcript)\""
    )
}

// ── Must NOT short-circuit: self-contained questions with no on-screen anchor ──
// (These fall through to the LLM classifier, which may still pick either path —
//  the guard simply must not force-capture on them.)

let mustNotForceCapture: [String] = [
    "what is the capital of France",
    "how do promises work in javascript",
    "write me a haiku about spring",
    "what's the weather like this week",
    "remind me to call mom",
    "how do I center a div",
    "theses are due next week",          // "theses" must not match "\bthese\b"
    "nevertheless I disagree",           // "these" inside a word must not match
]

for transcript in mustNotForceCapture {
    check(
        !VisionGateDeicticGuard.transcriptMentionsOnScreenReference(transcript),
        "does NOT force-capture for: \"\(transcript)\""
    )
}

if failureCount == 0 {
    print("\nALL CHECKS PASSED")
} else {
    print("\n\(failureCount) CHECK(S) FAILED")
    exit(1)
}
