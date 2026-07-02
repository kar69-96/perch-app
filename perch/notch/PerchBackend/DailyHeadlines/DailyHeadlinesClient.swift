//
//  DailyHeadlinesClient.swift
//  notch
//
//  Fetches the globally-shared "top news this morning" set from the Perch gateway's
//  `GET /daily-headlines`. The set is generated once a day by the Worker's cron job and
//  is identical for every install, so the Daily Brief shows the same headlines to
//  everyone and no longer runs its own per-user, per-open web searches.
//
//  Degrades quietly: any transport error, non-2xx, or unparseable body yields `[]`, so
//  the news section shows its calm "No headlines" state rather than surfacing an error
//  (matching how the brief's other live sources fail).
//

import Foundation

enum DailyHeadlinesClient {

    /// One item in the gateway's `{ items: [{ category, title, url }] }` payload. The
    /// app only renders `title` + `url`; `category` is decoded for forward-compatibility
    /// but currently unused by the view.
    private struct HeadlineDTO: Decodable {
        let category: String?
        let title: String
        let url: String?
    }

    private struct Envelope: Decodable {
        let items: [HeadlineDTO]
    }

    /// Fetch today's shared headlines. Returns `[]` on any failure (never throws).
    static func fetch() async -> [DailyBriefHeadline] {
        guard let data = await PerchInstallIdentity.shared.gatewayGet(path: "/daily-headlines") else {
            return []
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            return []
        }
        return envelope.items.compactMap { item in
            // Keep only headlines with a real click-through URL, mirroring the old
            // per-topic path (a headline with no article to open is dropped).
            guard let url = item.url, !url.isEmpty else { return nil }
            return DailyBriefHeadline(id: url, title: item.title, url: url)
        }
    }
}
