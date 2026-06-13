//
//  workflow-share-check/main.swift
//  Standalone, no-Xcode verification of the Repeat & Share follow-ups' pure
//  core: schedule next-fire math, schedule-store JSON round-trips,
//  clicky://import URL parsing, and imported-playbook persistence.
//
//  Compiled by scripts/check-workflow-share.sh together with the REAL product
//  sources (WorkflowScheduleModels / WorkflowScheduleStore /
//  WorkflowShareModels / WorkflowPlaybookStore / …), so it exercises the
//  actual shipping logic — not a copy. The canonical tests live in
//  leanring-buddyTests/WorkflowShareAndScheduleTests.swift (run via Xcode ⌘U);
//  this is the CLI mirror for a machine with only Command Line Tools.
//

import Foundation

var failureCount = 0
func check(_ condition: Bool, _ label: String) {
    print(condition ? "  ok  - \(label)" : "  FAIL- \(label)")
    if !condition { failureCount += 1 }
}

/// Deterministic calendar so the checks don't depend on the machine's zone.
var utcCalendar = Calendar(identifier: .gregorian)
utcCalendar.timeZone = TimeZone(identifier: "UTC")!

func utcDate(
    year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int = 0
) -> Date {
    utcCalendar.date(
        from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
    )!
}

func makeSchedule(
    frequency: WorkflowScheduleFrequency,
    minute: Int,
    hourOfDay: Int = 9,
    weekday: Int? = nil,
    createdAt: Date,
    lastFiredAt: Date? = nil
) -> WorkflowSchedule {
    WorkflowSchedule(
        id: UUID(),
        playbookSlug: "fill-contacts-into-excel",
        playbookTitle: "Fill contacts into Excel",
        frequency: frequency,
        minute: minute,
        hourOfDay: hourOfDay,
        weekday: weekday,
        createdAt: createdAt,
        lastFiredAt: lastFiredAt
    )
}

// MARK: - nextFireDate

print("schedule next-fire math:")
do {
    // 2026-06-10 was a Wednesday.
    let wednesday1020 = utcDate(year: 2026, month: 6, day: 10, hour: 10, minute: 20)

    let hourlyAt15 = makeSchedule(frequency: .hourly, minute: 15, createdAt: wednesday1020)
    check(
        hourlyAt15.nextFireDate(after: wednesday1020, calendar: utcCalendar)
            == utcDate(year: 2026, month: 6, day: 10, hour: 11, minute: 15),
        "hourly :15 from 10:20 → 11:15"
    )

    let nineAndHalfSecondsPast = utcDate(year: 2026, month: 6, day: 10, hour: 9, minute: 0, second: 30)
    let dailyAt9 = makeSchedule(frequency: .daily, minute: 0, hourOfDay: 9, createdAt: nineAndHalfSecondsPast)
    check(
        dailyAt9.nextFireDate(after: nineAndHalfSecondsPast, calendar: utcCalendar)
            == utcDate(year: 2026, month: 6, day: 11, hour: 9, minute: 0),
        "daily 9:00 from 9:00:30 rolls to tomorrow"
    )

    let weeklyMonday9 = makeSchedule(
        frequency: .weekly, minute: 0, hourOfDay: 9, weekday: 2, createdAt: wednesday1020
    )
    check(
        weeklyMonday9.nextFireDate(after: wednesday1020, calendar: utcCalendar)
            == utcDate(year: 2026, month: 6, day: 15, hour: 9, minute: 0),
        "weekly Monday 9:00 from a Wednesday → next Monday"
    )

    // Catch-up: hourly schedule whose machine slept through three slots fires
    // exactly once — due-ness anchors on lastFiredAt, and marking fired
    // pushes the next fire into the future.
    let lastFired = utcDate(year: 2026, month: 6, day: 10, hour: 7, minute: 15)
    let nowAfterSleep = utcDate(year: 2026, month: 6, day: 10, hour: 10, minute: 20)
    let sleptHourly = makeSchedule(
        frequency: .hourly, minute: 15,
        createdAt: utcDate(year: 2026, month: 6, day: 9, hour: 12, minute: 0),
        lastFiredAt: lastFired
    )
    let dueDate = sleptHourly.nextFireDate(after: sleptHourly.lastFiredAt!, calendar: utcCalendar)
    check(dueDate <= nowAfterSleep, "slept hourly schedule is due after wake")
    let refiredSchedule = sleptHourly.markingFired(at: nowAfterSleep)
    check(
        refiredSchedule.nextFireDate(after: refiredSchedule.lastFiredAt!, calendar: utcCalendar)
            > nowAfterSleep,
        "marking fired pushes the next fire into the future (exactly one catch-up)"
    )
}

// MARK: - Schedule store round-trip

print("schedule store:")
do {
    let temporaryStoreURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("workflow-share-check-\(UUID().uuidString)")
        .appendingPathComponent("workflow-schedules.json")

    let store = WorkflowScheduleStore(storageFileURL: temporaryStoreURL)
    check(store.schedules.isEmpty, "fresh store starts empty")

    let createdAt = utcDate(year: 2026, month: 6, day: 10, hour: 10, minute: 20)
    let schedule = makeSchedule(frequency: .daily, minute: 30, hourOfDay: 14, createdAt: createdAt)
    store.add(schedule)

    let firedAt = utcDate(year: 2026, month: 6, day: 11, hour: 14, minute: 30)
    store.markFired(scheduleId: schedule.id, at: firedAt)

    let reloadedStore = WorkflowScheduleStore(storageFileURL: temporaryStoreURL)
    check(reloadedStore.schedules.count == 1, "schedule persists across store instances")
    check(reloadedStore.schedules.first?.id == schedule.id, "persisted schedule keeps its id")
    check(reloadedStore.schedules.first?.lastFiredAt == firedAt, "markFired persists lastFiredAt")

    reloadedStore.remove(scheduleId: schedule.id)
    let storeAfterRemoval = WorkflowScheduleStore(storageFileURL: temporaryStoreURL)
    check(storeAfterRemoval.schedules.isEmpty, "remove persists")
}

// MARK: - clicky://import URL parsing

print("share import URL parsing:")
do {
    let validShareId = "wXyZ0123456789_-AbCdEf"
    func parsed(_ urlString: String) -> String? {
        guard let url = URL(string: urlString) else { return nil }
        return WorkflowShareImportURL.parseWorkflowShareId(fromImportURL: url)
    }

    check(parsed("clicky://import/\(validShareId)") == validShareId, "accepts clicky://import/<id>")
    check(parsed("CLICKY://IMPORT/\(validShareId)") == validShareId, "scheme and host are case-insensitive")
    check(parsed("https://import/\(validShareId)") == nil, "rejects non-clicky scheme")
    check(parsed("clicky://open/\(validShareId)") == nil, "rejects non-import host")
    check(parsed("clicky://import/short") == nil, "rejects too-short id")
    check(parsed("clicky://import/bad!chars#in$id%%here") == nil, "rejects invalid characters")
    check(parsed("clicky://import/\(validShareId)/extra") == nil, "rejects extra path segments")
    check(parsed("clicky://import/") == nil, "rejects empty id")
}

// MARK: - Imported playbook persistence

print("imported playbook persistence:")
do {
    let temporaryPlaybookDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("workflow-share-check-playbooks-\(UUID().uuidString)")
    let playbookStore = WorkflowPlaybookStore(directoryURL: temporaryPlaybookDirectory)

    let markdown = "# Fill contacts into Excel\n\nSteps…"
    let firstImport = try playbookStore.save(markdown: markdown, title: "Fill contacts into Excel")
    check(firstImport.slug == "fill-contacts-into-excel", "imported playbook slugs from its title")

    let secondImport = try playbookStore.save(markdown: markdown, title: "Fill contacts into Excel")
    check(secondImport.slug == "fill-contacts-into-excel-2", "re-importing the same share gets a collision suffix")

    let reloaded = try playbookStore.load(slug: secondImport.slug)
    check(reloaded.markdown == markdown, "imported markdown round-trips")
    check(
        WorkflowPlaybookStore.extractTitle(fromMarkdown: "no heading here\njust text") == nil,
        "title extraction returns nil without a # heading (import falls back to sender title)"
    )
} catch {
    check(false, "imported playbook persistence threw: \(error)")
}

// MARK: - Result

if failureCount > 0 {
    print("\n\(failureCount) CHECK(S) FAILED")
    exit(1)
}
print("\nall checks passed")
