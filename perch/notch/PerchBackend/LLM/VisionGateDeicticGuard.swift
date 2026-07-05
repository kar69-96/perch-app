//
//  VisionGateDeicticGuard.swift
//  Perch
//
//  A deterministic safety net in front of the vision gate's LLM classifier
//  (ClaudeAPI.classifyNeedsScreen). Some user messages point unambiguously
//  at something the user is currently looking at — "which of these movies are on
//  netflix?", "what does this error mean?", "summarize what's on my screen". The
//  tiny classifier model has been observed to misroute exactly these to the blind
//  text-only path and then answer without the content ("i'd need a list of
//  movies"), which is the worst failure mode for a screen-aware assistant.
//
//  When the latest message matches one of these phrases we skip the classifier
//  entirely and capture the screen — both faster (no round-trip) and immune to
//  the model getting it wrong. Reliability over the saved classifier call.
//
//  Pure and dependency-free (Foundation only) so the no-Xcode check harness
//  (scripts/check-vision-gate.sh) can exercise it without an API key.
//

import Foundation

enum VisionGateDeicticGuard {

    /// Regular-expression fragments for phrases that point unambiguously at
    /// on-screen content. Each fragment uses `\b` word boundaries so it never
    /// fires inside a larger word (e.g. "these" must not match "thesecurity").
    static let onScreenDeicticReferencePatterns: [String] = [
        // Plural demonstratives almost always refer to a visible set the user is
        // looking at: "these movies", "which of those", "compare these".
        #"\b(?:these|those)\b"#,
        // Explicit references to the screen itself.
        #"\bon\s+(?:my|the)\s+screen\b"#,
        #"\b(?:on[-\s]screen|on\s+my\s+display)\b"#,
        // A current selection / highlight the user is calling out.
        #"\b(?:highlighted|currently\s+selected|the\s+selection|what'?s?\s+selected)\b"#,
        // A singular demonstrative bound to a concrete on-screen thing —
        // "what does this error mean", "translate that paragraph".
        #"\b(?:this|that)\s+(?:page|screen|window|tab|site|list|menu|image|photo|picture|document|doc|file|code|error|message|table|chart|graph|form|article|email|thread|paragraph|line|button|dialog|popup|notification|post|tweet|video|cell|column|row|field)\b"#,
        // Bare "what is / what's this/that" — a question about a thing on screen.
        #"\bwhat(?:'?s| is| does| are)\s+(?:this|that|these|those)\b"#,
        // "here" pointing at a spot on the screen — "what do I write here", "what
        // goes here", "help me with what to write here", "click right here". For a
        // desktop assistant "here" almost always means a place on screen, so
        // capture rather than answer blind (the user asked us to lean this way).
        #"\b(?:write|type|put|enter|fill|add|insert|paste|click|tap|select|choose|go|goes|belongs?)\b[^.?!]{0,40}\bhere\b"#,
        #"\b(?:what|where|which|how|help)\b[^.?!]{0,40}\bhere\b"#,
        #"\b(?:right|over)\s+here\b"#,
    ]

    /// Whether the latest message contains an unambiguous on-screen deictic
    /// reference, in which case the vision gate must capture the screen.
    static func transcriptMentionsOnScreenReference(_ transcript: String) -> Bool {
        for onScreenReferencePattern in onScreenDeicticReferencePatterns {
            if transcript.range(
                of: onScreenReferencePattern,
                options: [.regularExpression, .caseInsensitive]
            ) != nil {
                return true
            }
        }
        return false
    }
}
