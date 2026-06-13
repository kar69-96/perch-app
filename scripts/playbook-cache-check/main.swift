//
//  playbook-cache-check/main.swift
//  Standalone, no-Xcode verification of the playbook caching core: the
//  MATCH-directive parsing that decides update-vs-create, and the playbook
//  store's list + update-in-place behavior that keeps slugs stable for
//  schedules and agent-run cards.
//
//  Compiled by scripts/check-playbook-cache.sh together with the REAL product
//  sources (WorkflowPlaybookSynthesizer / WorkflowPlaybookStore / …), so it
//  exercises the actual shipping logic — not a copy. The canonical tests live
//  in leanring-buddyTests/WorkflowPlaybookCacheTests.swift (run via Xcode ⌘U);
//  this is the CLI mirror for a machine with only Command Line Tools.
//

import Foundation

var failureCount = 0
func check(_ condition: Bool, _ label: String) {
    print(condition ? "  ok  - \(label)" : "  FAIL- \(label)")
    if !condition { failureCount += 1 }
}

// MARK: - Match-directive parsing

print("match-directive parsing:")
await Task.yield()  // hop onto the main actor so the @MainActor statics are callable
do {
    let matched = WorkflowPlaybookSynthesizer.parseMatchDirective(
        from: "MATCH: fill-contacts-into-excel\n\n# Fill contacts into Excel\nBody."
    )
    check(matched.matchedSlug == "fill-contacts-into-excel",
          "MATCH: <slug> first line yields the slug")
    check(matched.remainingMarkdown == "# Fill contacts into Excel\nBody.",
          "directive line is stripped from the markdown")

    let noMatch = WorkflowPlaybookSynthesizer.parseMatchDirective(
        from: "MATCH: none\n# A new workflow\nBody."
    )
    check(noMatch.matchedSlug == nil, "MATCH: none yields no slug")
    check(noMatch.remainingMarkdown == "# A new workflow\nBody.",
          "MATCH: none line is also stripped")

    let tolerant = WorkflowPlaybookSynthesizer.parseMatchDirective(
        from: "  match:  `fill-contacts-into-excel`  \n# Title"
    )
    check(tolerant.matchedSlug == "fill-contacts-into-excel",
          "directive parsing tolerates case, whitespace, and backticks")

    let missingDirective = WorkflowPlaybookSynthesizer.parseMatchDirective(
        from: "# Just a playbook\nNo directive at all."
    )
    check(missingDirective.matchedSlug == nil
            && missingDirective.remainingMarkdown == "# Just a playbook\nNo directive at all.",
          "missing directive degrades to no-match with the full text kept")

    let emptyValue = WorkflowPlaybookSynthesizer.parseMatchDirective(
        from: "MATCH:\n# Title"
    )
    check(emptyValue.matchedSlug == nil, "empty directive value means no match")

    let uppercaseNone = WorkflowPlaybookSynthesizer.parseMatchDirective(
        from: "MATCH: NONE\n# Title"
    )
    check(uppercaseNone.matchedSlug == nil, "NONE is recognized case-insensitively")
}

// MARK: - Store: update-in-place + listing

func makeTemporaryStore() -> WorkflowPlaybookStore {
    WorkflowPlaybookStore(
        directoryURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("playbook-cache-check-\(UUID().uuidString)", isDirectory: true)
    )
}

print("store update-in-place:")
do {
    let store = makeTemporaryStore()
    let original = try store.save(
        markdown: "# Fill contacts into Excel\nOriginal body.",
        title: "Fill contacts into Excel"
    )

    let updated = try store.updateExistingPlaybook(
        slug: original.slug,
        markdown: "# Fill contacts into spreadsheet\nRefined body."
    )
    check(updated.slug == original.slug, "update preserves the slug")
    check(updated.fileURL == original.fileURL, "update preserves the file URL")
    check(updated.title == "Fill contacts into spreadsheet",
          "title is re-extracted from the refined markdown")

    let reloaded = try store.load(slug: original.slug)
    check(reloaded.markdown == "# Fill contacts into spreadsheet\nRefined body.",
          "refined markdown round-trips from disk")

    let markdownFiles = try FileManager.default
        .contentsOfDirectory(atPath: store.directoryURL.path)
        .filter { $0.hasSuffix(".md") }
    check(markdownFiles.count == 1,
          "save → update keeps exactly one file (no -2 duplicate)")

    var unknownSlugThrew = false
    do {
        _ = try store.updateExistingPlaybook(slug: "never-saved", markdown: "# X")
    } catch WorkflowPlaybookStoreError.playbookNotFound {
        unknownSlugThrew = true
    }
    check(unknownSlugThrew, "updating an unknown slug throws playbookNotFound")
}

print("store listing:")
do {
    let store = makeTemporaryStore()
    let older = try store.save(markdown: "# Older workflow\nBody.", title: "Older workflow")
    let newer = try store.save(markdown: "# Newer workflow\nBody.", title: "Newer workflow")

    // Push the newer file's modification date clearly ahead so the recency
    // sort doesn't depend on sub-second write timing.
    try FileManager.default.setAttributes(
        [.modificationDate: Date().addingTimeInterval(60)],
        ofItemAtPath: newer.fileURL!.path
    )
    try "not a playbook".write(
        to: store.directoryURL.appendingPathComponent("junk.txt"),
        atomically: true, encoding: .utf8
    )

    let listed = store.listAllPlaybooks()
    check(listed.count == 2, "listing returns only .md playbooks (junk skipped)")
    check(listed.first?.slug == newer.slug && listed.last?.slug == older.slug,
          "listing is most-recently-modified first")
    check(listed.first?.title == "Newer workflow",
          "listed playbooks carry their extracted titles")

    let emptyStore = makeTemporaryStore()
    check(emptyStore.listAllPlaybooks().isEmpty,
          "a missing directory lists as empty, not an error")
}

if failureCount > 0 {
    print("\(failureCount) CHECK(S) FAILED")
    exit(1)
}
print("all checks passed")
