//
//  DailyBriefViewModel.swift
//  notch
//
//  Drives the Daily Brief page. The title-card facts (name, date, weekday, artwork) are
//  computed locally and render instantly; everything else is fetched LIVE the first time
//  the page appears:
//
//    • calendar  — today's real events via the `.calendar` provider (sidecar `dashboard.fetch`)
//    • summary   — a Claude-synthesized one-liner from the real email + calendar context
//                  (`DailyBriefGenerator`); on synthesis failure it degrades to a quiet,
//                  non-fabricated line derived from the real calendar (never invented prose).
//    • catch-up / priorities — the same synthesis fills the two editable lists once per day
//                  (`DailyBriefStore.applyDailyBrief`), preserving any same-day user edits.
//    • news + comic — real headlines and the day's XKCD strip (already live).
//
//  Every source degrades gracefully: a missing transport / failed fetch yields an empty
//  section (a quiet "Nothing scheduled" / "No headlines") rather than fabricated content.
//

import SwiftUI

@MainActor
final class DailyBriefViewModel: ObservableObject {

    // MARK: Instant, local facts (the title card renders from these immediately)

    @Published private(set) var firstName: String
    @Published private(set) var weekdayName: String
    @Published private(set) var dateLine: String
    @Published private(set) var artwork: DailyBriefArtwork

    // MARK: Live body content (filled in as each source resolves)

    @Published private(set) var synthesis: DailyBriefSynthesis?
    @Published private(set) var isSynthesizing = false
    /// Unused by the view (the catch-up/priorities lists live in `DailyBriefStore`); kept so
    /// the live email fetch has a typed home and the view API stays stable.
    @Published private(set) var emails: [DashboardWidgetItem] = []
    @Published private(set) var calendarEntries: [DailyBriefCalendarEntry] = []
    @Published private(set) var headlines: [DailyBriefHeadline] = []
    @Published private(set) var comic: DailyBriefComic?

    @Published private(set) var isLoadingCalendar = false
    @Published private(set) var isLoadingNews = false

    /// The day this brief is for — used to format event times and to key the once-per-day
    /// seeding of the editable lists. A `var` (not `let`) so the brief can roll over to the
    /// new day when it's re-shown after midnight (see `loadIfNeeded`).
    private var date: Date
    private let generator = DailyBriefGenerator()
    /// The `yyyy-MM-dd` key of the day currently loaded, or nil before the first load.
    /// Replaces a plain "loaded once" flag so the brief reloads when the day changes
    /// rather than staying frozen on the day it was first opened until an app relaunch.
    private var loadedDayKey: String?

    init(date: Date = Date()) {
        self.date = date
        self.firstName = DashboardGreetingText.accountFirstName
        self.weekdayName = DailyBriefDateText.weekdayName(for: date)
        self.dateLine = DailyBriefDateText.ordinalDateLine(for: date)
        self.artwork = DailyBriefArtworkLibrary.artwork(for: date)
    }

    /// Fetch every live element once: the comic, real news headlines, today's calendar, and
    /// the Claude-synthesized prose (summary + the day's catch-up / priorities). Each runs
    /// independently so a slow source never blocks the others.
    func loadIfNeeded() {
        // Reload whenever the calendar day has changed since the last load (including the
        // very first load, when `loadedDayKey` is nil). Because the window is re-shown via
        // `.onAppear`, a brief left open across midnight refreshes the next time it's opened
        // — no app relaunch — instead of staying frozen on its original day.
        let today = Self.dayKey(for: Date())
        guard loadedDayKey != today else { return }
        loadedDayKey = today

        // Advance the brief to the new day and re-derive the instant, local facts so the
        // title card (weekday, date line, artwork) matches the day being loaded.
        date = Date()
        weekdayName = DailyBriefDateText.weekdayName(for: date)
        dateLine = DailyBriefDateText.ordinalDateLine(for: date)
        artwork = DailyBriefArtworkLibrary.artwork(for: date)

        Task { comic = await DailyComicService.fetchTodaysComic(for: date) }
        Task { await loadLiveNews() }
        Task { await loadDayContext() }
    }

    // MARK: Calendar + synthesis (the "real info" path)

    /// Re-run just the calendar + synthesis path (not news/comic). Called after the user
    /// connects a missing integration from a "Connect to …" prompt, so the now-available
    /// calendar events and email-driven catch-up / priorities load in without waiting for
    /// the next day's rollover. The lists re-seed because an earlier empty synthesis never
    /// marked the day as seeded (`applyDailyBrief` skips an all-empty result).
    func refreshDayContext() {
        Task { await loadDayContext() }
    }

    /// Fetch today's real calendar + priority emails, publish the agenda, then synthesize the
    /// brief's prose from that context. The calendar renders as soon as it resolves; the prose
    /// follows once the model replies.
    private func loadDayContext() async {
        isLoadingCalendar = true
        isSynthesizing = true

        async let calendarItemsTask = Self.fetchItems(provider: .calendar, query: "today's events", limit: 12)
        // Gmail's `q` param is search-operator syntax, not natural language — a plain
        // phrase like "important unread emails today" is matched as literal keywords and
        // returns nothing. Use real operators so the brief sees today's priority unread.
        async let emailItemsTask = Self.fetchItems(provider: .email, query: "is:important is:unread newer_than:1d", limit: 10)
        var calendarItems = await calendarItemsTask
        let emailItems = await emailItemsTask

        // Fall back to the local macOS Calendar (EventKit) when no cloud calendar is
        // connected — so the agenda shows real events without a Composio connection.
        if calendarItems.isEmpty {
            calendarItems = await LocalDailyCalendar.todaysEvents(for: date)
        }

        emails = emailItems
        calendarEntries = Self.makeCalendarEntries(from: calendarItems)
        isLoadingCalendar = false

        // With no real email or calendar context there is nothing to synthesize — skip the
        // model call entirely and show the quiet, calendar-derived line (so we neither waste
        // a request nor risk the model writing generic, ungrounded prose).
        guard !emailItems.isEmpty || !calendarItems.isEmpty else {
            synthesis = DailyBriefSynthesis(
                summary: Self.localSummary(firstName: firstName, entries: calendarEntries),
                catchUp: [],
                priorities: []
            )
            isSynthesizing = false
            return
        }

        let result = await generator.synthesize(
            firstName: firstName,
            weekdayName: weekdayName,
            dateLine: dateLine,
            emails: emailItems,
            slackMessages: [],
            calendarEntries: calendarItems
        )

        if let result {
            // The summary feeds the summary row; the catch-up / priorities feed the editable
            // lists (owned by the store), seeded at most once per day so user edits survive.
            synthesis = DailyBriefSynthesis(summary: result.summary, catchUp: [], priorities: [])
            DailyBriefStore.shared.applyDailyBrief(
                day: dayKey,
                catchUp: result.catchUp,
                priorities: result.priorities
            )
        } else {
            // Graceful, non-fabricated fallback: a one-line summary built from the REAL
            // calendar (never invented prose), so the row never reads blank or fake.
            synthesis = DailyBriefSynthesis(
                summary: Self.localSummary(firstName: firstName, entries: calendarEntries),
                catchUp: [],
                priorities: []
            )
        }
        isSynthesizing = false
    }

    /// A stable "yyyy-MM-dd" key for the brief's day, used to seed the editable lists once
    /// per calendar day.
    private var dayKey: String { Self.dayKey(for: date) }

    /// The "yyyy-MM-dd" key for a given date. Static so `loadIfNeeded` can key "today"
    /// independently of the brief's (possibly stale) `date` to detect a day rollover.
    private static func dayKey(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// Map raw provider items into ordered timeline entries: a "h:mm a" time label from the
    /// event's start (or "All day" when it carries no time), sorted with all-day events first.
    private static func makeCalendarEntries(from items: [DashboardWidgetItem]) -> [DailyBriefCalendarEntry] {
        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.dateFormat = "h:mm a"

        let entries = items.map { item -> DailyBriefCalendarEntry in
            let timeLabel = item.timestamp.map { timeFormatter.string(from: $0) } ?? "All day"
            return DailyBriefCalendarEntry(
                id: item.id,
                timeLabel: timeLabel,
                title: item.title,
                startTime: item.timestamp
            )
        }
        return entries.sorted { lhs, rhs in
            switch (lhs.startTime, rhs.startTime) {
            case let (left?, right?): return left < right
            case (nil, _):            return true   // all-day events sort to the top
            case (_, nil):            return false
            }
        }
    }

    /// A quiet, factual summary derived only from the real calendar — the fallback when the
    /// Claude synthesis is unavailable. It states what's actually on the day; it never invents.
    private static func localSummary(firstName: String, entries: [DailyBriefCalendarEntry]) -> String {
        guard !entries.isEmpty else {
            return "Nothing on your calendar today, \(firstName) — an open day."
        }
        let count = entries.count
        let eventNoun = count == 1 ? "event" : "events"
        if let firstTimed = entries.first(where: { $0.startTime != nil }) {
            return "\(count) \(eventNoun) on today's calendar, \(firstName) — first up at \(firstTimed.timeLabel)."
        }
        return "\(count) \(eventNoun) on today's calendar, \(firstName)."
    }

    // MARK: News

    /// The day's news is a single globally-shared set generated once daily by the backend
    /// (identical for every user), fetched from the gateway rather than run per-user here.
    /// This is what makes the headlines the same for everyone and genuinely date-scoped to
    /// today; the diverse tech/world/markets/science/sports spread is chosen server-side.
    private func loadLiveNews() async {
        isLoadingNews = true
        headlines = await DailyHeadlinesClient.fetch()
        isLoadingNews = false
    }

    // MARK: Fetch helper

    /// Fetch a provider's live items through the shared data service. Returns `[]` (never
    /// throws) when the transport is unattached or the provider has nothing.
    private static func fetchItems(
        provider: DashboardWidgetSource, query: String, limit: Int
    ) async -> [DashboardWidgetItem] {
        let plan = DashboardWidgetFetchPlan(
            provider: provider, query: query, limit: limit, refreshCadenceSeconds: 0
        )
        return await DashboardDataService.shared.fetch(plan: plan)
    }
}
