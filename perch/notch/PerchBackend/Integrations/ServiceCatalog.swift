//
//  ServiceCatalog.swift
//  Perch
//
//  The curated registry of services Perch can integrate with, and the logic
//  that decides whether the user's current window matches one of them.
//
//  This is the data behind the proactive "Connect this to Perch?" notch offer:
//  the ServiceContextMonitor reads the frontmost window's URL/bundle id, and this
//  catalog tells it which known service (if any) that window belongs to. The list
//  is curated (built in below as `defaultEntries`), not a dynamic fetch of every
//  Composio app — deterministic matching is worth more than exhaustive coverage.
//
//  The catalog is BUILT IN (a Swift array), not loaded from a bundled JSON: the
//  no-Xcode `scripts/dev-build.sh` compiles sources but does not copy resources
//  into the hand-rolled .app bundle, so a JSON resource would silently fail to
//  load and no offer would ever fire. An optional on-disk override file is still
//  supported (`loadFromFile`) for power users / tests.
//
//  Two kinds of service:
//   • .composio — connected via the Composio OAuth flow. `toolkitSlug` MUST match
//     Composio's own toolkit slug (e.g. "gmail"); it is passed verbatim to
//     `python -m perch_subagent.main --connect <slug>`.
//   • .native — a macOS app Perch already actuates via AppleScript (Word, Excel,
//     Numbers). These need no OAuth; "connect" means enabling Perch to work with
//     the app. Their `toolkitSlug` is a local identity key (prefixed "native.")
//     and is never sent to Composio.
//
//  Deliberately AppKit-light and input-injected (entries can be supplied directly)
//  so the matching logic compiles and runs in a standalone harness without a
//  bundle or a concurrency runtime.
//

import Foundation

/// How a catalog entry is connected — drives both the offer copy and what the
/// "Yes" action does.
enum ServiceKind: String, Codable {
    case composio
    case native
}

/// One known, integrable service.
struct ServiceCatalogEntry: Codable, Equatable {
    /// Human name shown in the offer ("Gmail", "Notion").
    let displayName: String
    /// For `.composio`: Composio's toolkit slug, passed to `--connect`.
    /// For `.native`: a local identity key (e.g. "native.microsoft_word").
    let toolkitSlug: String
    let kind: ServiceKind
    /// URL hosts that identify this service (suffix-matched, leading "www." stripped).
    let matchHosts: [String]
    /// Optional URL path prefixes that further constrain a host match (case-insensitive,
    /// each begins with "/"). Empty means "host alone is enough". Non-empty disambiguates
    /// services that SHARE a host: Google Docs, Sheets, and Slides all live on
    /// docs.google.com, separated only by their first path segment (/document,
    /// /spreadsheets, /presentation). An entry with prefixes matches only when the URL's
    /// path begins with one of them.
    let matchPathPrefixes: [String]
    /// Frontmost-app bundle ids that identify this service (native or desktop clients).
    let matchBundleIdentifiers: [String]
    /// One-line reason shown under the offer title ("so Perch can read your email").
    let capabilityHint: String?
    /// Bundle id whose real app icon renders in the offer tile; nil falls back to a glyph.
    let appIconBundleIdentifierForTile: String?

    init(
        displayName: String,
        toolkitSlug: String,
        kind: ServiceKind,
        matchHosts: [String],
        matchPathPrefixes: [String] = [],
        matchBundleIdentifiers: [String] = [],
        capabilityHint: String? = nil,
        appIconBundleIdentifierForTile: String? = nil
    ) {
        self.displayName = displayName
        self.toolkitSlug = toolkitSlug
        self.kind = kind
        self.matchHosts = matchHosts
        self.matchPathPrefixes = matchPathPrefixes
        self.matchBundleIdentifiers = matchBundleIdentifiers
        self.capabilityHint = capabilityHint
        self.appIconBundleIdentifierForTile = appIconBundleIdentifierForTile
    }

    // A hand-written decoder (instead of the synthesized one) so an on-disk override
    // file may omit the list-valued fields and still decode — the same defaults the
    // memberwise init applies. Without this, a newly added field like
    // `matchPathPrefixes` would make every previously valid override JSON fail to load.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        displayName = try container.decode(String.self, forKey: .displayName)
        toolkitSlug = try container.decode(String.self, forKey: .toolkitSlug)
        kind = try container.decode(ServiceKind.self, forKey: .kind)
        matchHosts = try container.decodeIfPresent([String].self, forKey: .matchHosts) ?? []
        matchPathPrefixes =
            try container.decodeIfPresent([String].self, forKey: .matchPathPrefixes) ?? []
        matchBundleIdentifiers =
            try container.decodeIfPresent([String].self, forKey: .matchBundleIdentifiers) ?? []
        capabilityHint = try container.decodeIfPresent(String.self, forKey: .capabilityHint)
        appIconBundleIdentifierForTile =
            try container.decodeIfPresent(String.self, forKey: .appIconBundleIdentifierForTile)
    }
}

/// The loaded set of catalog entries plus the matching logic.
struct ServiceCatalog {

    /// Entries in priority order — first match wins, so list more-specific hosts first.
    let entries: [ServiceCatalogEntry]

    init(entries: [ServiceCatalogEntry]) {
        self.entries = entries
    }

    // MARK: - Loading

    /// The catalog the app uses. Built-in by default; an optional on-disk override
    /// at <repo>/support/service-catalog.json (if present and valid) replaces it,
    /// so the curated list can be tweaked without a rebuild.
    static func loadFromBundle(_ bundle: Bundle = .main) -> ServiceCatalog {
        let overrideURL = PerchSupportPaths.file("service-catalog.json")
        if FileManager.default.fileExists(atPath: overrideURL.path) {
            let overridden = loadFromFile(overrideURL)
            if !overridden.entries.isEmpty {
                return overridden
            }
        }
        return ServiceCatalog(entries: defaultEntries)
    }

    /// Loads a catalog from an explicit file URL (override file / tests). Returns
    /// an empty catalog on any failure.
    static func loadFromFile(_ fileURL: URL) -> ServiceCatalog {
        do {
            let catalogData = try Data(contentsOf: fileURL)
            let decodedEntries = try JSONDecoder().decode([ServiceCatalogEntry].self, from: catalogData)
            return ServiceCatalog(entries: decodedEntries)
        } catch {
            print("⚠️ ServiceCatalog: failed to decode override service-catalog.json: \(error)")
            return ServiceCatalog(entries: [])
        }
    }

    // MARK: - Lookup by toolkit slug

    /// The catalog entry for a Composio toolkit slug (case-insensitive), or `nil`
    /// when the slug isn't curated. Used to turn an agent's "needs this toolkit"
    /// request into offer copy. Pair with `Self.composioEntry(forToolkitSlug:)` to
    /// always get an entry (synthesizing a generic one for uncurated slugs).
    func entry(forToolkitSlug toolkitSlug: String) -> ServiceCatalogEntry? {
        let normalizedSlug = toolkitSlug.lowercased()
        return entries.first { $0.toolkitSlug.lowercased() == normalizedSlug }
    }

    /// Always returns a `.composio` entry for `toolkitSlug`: the curated one when it
    /// exists, otherwise a synthesized entry with a humanized display name so ANY
    /// toolkit the agent asks for can still be offered for connection.
    func composioEntry(forToolkitSlug toolkitSlug: String) -> ServiceCatalogEntry {
        if let curated = entry(forToolkitSlug: toolkitSlug) {
            return curated
        }
        return ServiceCatalogEntry(
            displayName: Self.humanizedDisplayName(fromToolkitSlug: toolkitSlug),
            toolkitSlug: toolkitSlug,
            kind: .composio,
            matchHosts: [],
            capabilityHint: "so Perch can finish your task"
        )
    }

    /// Turns a Composio toolkit slug into a presentable name ("google_sheets" →
    /// "Google Sheets"). Best-effort: splits on separators and title-cases each word.
    static func humanizedDisplayName(fromToolkitSlug toolkitSlug: String) -> String {
        let words = toolkitSlug
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
        return words.isEmpty ? toolkitSlug : words.joined(separator: " ")
    }

    // MARK: - Matching

    /// The catalog entry the user's current window belongs to, or nil.
    ///
    /// Prefers the URL host (so a browser tab on mail.google.com matches Gmail
    /// regardless of which browser); falls back to the frontmost app's bundle id
    /// (so the Slack desktop app or a native document app matches). First entry
    /// in catalog order to match wins.
    func match(_ context: FocusedWindowContext) -> ServiceCatalogEntry? {
        if let host = Self.normalizedHost(from: context.documentPathOrURL) {
            let path = Self.normalizedPath(from: context.documentPathOrURL)
            for entry in entries {
                guard entry.matchHosts.contains(where: { Self.host(host, matchesRegisteredHost: $0) })
                else {
                    continue
                }
                // A host-only entry matches on host alone. An entry that lists path
                // prefixes (services sharing a host, e.g. Google Docs vs Sheets) matches
                // only when the URL's path also begins with one of them — so a Google
                // Sheet at docs.google.com/spreadsheets no longer matches the Docs entry.
                if entry.matchPathPrefixes.isEmpty
                    || entry.matchPathPrefixes.contains(where: { path.hasPrefix($0.lowercased()) }) {
                    return entry
                }
            }
        }

        if let bundleIdentifier = context.applicationBundleIdentifier {
            for entry in entries {
                if entry.matchBundleIdentifiers.contains(bundleIdentifier) {
                    return entry
                }
            }
        }

        return nil
    }

    /// A stable key for the current context, used by the monitor to detect when
    /// the user has actually switched page/app (so it only does work on change).
    /// The host for web contexts; otherwise the bundle id; nil when neither is known.
    static func contextKey(for context: FocusedWindowContext) -> String? {
        if let host = normalizedHost(from: context.documentPathOrURL) {
            // Fold in the FIRST path segment so a move between two services that share a
            // host (docs.google.com/document → /spreadsheets) registers as a real context
            // change and is re-matched — otherwise the monitor would serve the stale
            // cached match (Google Docs) for every editor on docs.google.com. Only the
            // first segment, so in-document navigation/hash changes keep the key stable.
            let firstPathSegment = normalizedPath(from: context.documentPathOrURL)
                .split(separator: "/").first.map(String.init)
            if let firstPathSegment {
                return "host:\(host)/\(firstPathSegment)"
            }
            return "host:\(host)"
        }
        if let bundleIdentifier = context.applicationBundleIdentifier {
            return "app:\(bundleIdentifier)"
        }
        return nil
    }

    // MARK: - Host normalization

    /// Lowercased host with a leading "www." stripped, or nil when the string is
    /// not an http(s) URL with a host.
    static func normalizedHost(from urlString: String?) -> String? {
        guard let urlString,
              let components = URLComponents(string: urlString),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              var host = components.host?.lowercased(),
              !host.isEmpty
        else {
            return nil
        }
        if host.hasPrefix("www.") {
            host = String(host.dropFirst("www.".count))
        }
        return host
    }

    /// Lowercased URL path (always begins with "/"), or "/" when the string is not a
    /// URL or carries no path. Paired with the host to disambiguate services that share
    /// a host (e.g. docs.google.com/document vs docs.google.com/spreadsheets).
    static func normalizedPath(from urlString: String?) -> String {
        guard let urlString,
              let components = URLComponents(string: urlString)
        else {
            return "/"
        }
        let path = components.path.lowercased()
        return path.isEmpty ? "/" : path
    }

    /// Suffix match: the host equals the registered host, or is a subdomain of it
    /// (so "gist.github.com" matches a "github.com" entry). The registered host is
    /// normalized the same way (lowercased, "www." stripped).
    private static func host(_ host: String, matchesRegisteredHost registeredHost: String) -> Bool {
        var normalizedRegisteredHost = registeredHost.lowercased()
        if normalizedRegisteredHost.hasPrefix("www.") {
            normalizedRegisteredHost = String(normalizedRegisteredHost.dropFirst("www.".count))
        }
        return host == normalizedRegisteredHost || host.hasSuffix("." + normalizedRegisteredHost)
    }

    // MARK: - The curated catalog

    /// The built-in list. Composio slugs match Composio's own toolkit slugs.
    /// Order matters only when two entries could match the same host (none do
    /// today). Extend this array to add services.
    static let defaultEntries: [ServiceCatalogEntry] = [
        // Google
        .init(displayName: "Gmail", toolkitSlug: "gmail", kind: .composio,
              matchHosts: ["mail.google.com"],
              capabilityHint: "so Perch can read, search, and send your email"),
        .init(displayName: "Google Calendar", toolkitSlug: "googlecalendar", kind: .composio,
              matchHosts: ["calendar.google.com"],
              capabilityHint: "so Perch can check your schedule and create events"),
        .init(displayName: "Google Drive", toolkitSlug: "googledrive", kind: .composio,
              matchHosts: ["drive.google.com"],
              capabilityHint: "so Perch can find and organize your files"),
        // Docs, Sheets, and Slides all live on docs.google.com — disambiguated by the
        // first path segment, so a spreadsheet no longer mis-matches as a document.
        .init(displayName: "Google Docs", toolkitSlug: "googledocs", kind: .composio,
              matchHosts: ["docs.google.com"], matchPathPrefixes: ["/document"],
              capabilityHint: "so Perch can read and edit your documents"),
        .init(displayName: "Google Sheets", toolkitSlug: "googlesheets", kind: .composio,
              matchHosts: ["docs.google.com", "sheets.google.com"],
              matchPathPrefixes: ["/spreadsheets"],
              capabilityHint: "so Perch can read and fill your spreadsheets"),
        .init(displayName: "Google Meet", toolkitSlug: "googlemeet", kind: .composio,
              matchHosts: ["meet.google.com"],
              capabilityHint: "so Perch can manage your meetings"),

        // Productivity / docs / PM
        .init(displayName: "Notion", toolkitSlug: "notion", kind: .composio,
              matchHosts: ["notion.so", "notion.com"], matchBundleIdentifiers: ["notion.id"],
              capabilityHint: "so Perch can search and update your pages",
              appIconBundleIdentifierForTile: "notion.id"),
        .init(displayName: "Linear", toolkitSlug: "linear", kind: .composio,
              matchHosts: ["linear.app"], matchBundleIdentifiers: ["com.linear"],
              capabilityHint: "so Perch can triage and update your issues",
              appIconBundleIdentifierForTile: "com.linear"),
        .init(displayName: "Asana", toolkitSlug: "asana", kind: .composio,
              matchHosts: ["asana.com"],
              capabilityHint: "so Perch can manage your tasks and projects"),
        .init(displayName: "Trello", toolkitSlug: "trello", kind: .composio,
              matchHosts: ["trello.com"],
              capabilityHint: "so Perch can manage your boards and cards"),
        .init(displayName: "ClickUp", toolkitSlug: "clickup", kind: .composio,
              matchHosts: ["clickup.com"],
              capabilityHint: "so Perch can manage your tasks"),
        .init(displayName: "Todoist", toolkitSlug: "todoist", kind: .composio,
              matchHosts: ["todoist.com"],
              capabilityHint: "so Perch can manage your to-dos"),
        .init(displayName: "Monday", toolkitSlug: "monday", kind: .composio,
              matchHosts: ["monday.com"],
              capabilityHint: "so Perch can manage your boards"),
        .init(displayName: "Airtable", toolkitSlug: "airtable", kind: .composio,
              matchHosts: ["airtable.com"],
              capabilityHint: "so Perch can read and update your bases"),

        // Dev
        .init(displayName: "GitHub", toolkitSlug: "github", kind: .composio,
              matchHosts: ["github.com"],
              capabilityHint: "so Perch can work with issues, PRs, and repos",
              appIconBundleIdentifierForTile: "com.github.GitHubClient"),
        .init(displayName: "GitLab", toolkitSlug: "gitlab", kind: .composio,
              matchHosts: ["gitlab.com"],
              capabilityHint: "so Perch can work with your repos and MRs"),
        .init(displayName: "Jira", toolkitSlug: "jira", kind: .composio,
              matchHosts: ["atlassian.net"],
              capabilityHint: "so Perch can triage and update your issues",
              appIconBundleIdentifierForTile: "com.atlassian.jira"),
        .init(displayName: "Figma", toolkitSlug: "figma", kind: .composio,
              matchHosts: ["figma.com"],
              capabilityHint: "so Perch can work with your design files"),

        // Comms
        .init(displayName: "Slack", toolkitSlug: "slack", kind: .composio,
              matchHosts: ["app.slack.com", "slack.com"],
              matchBundleIdentifiers: ["com.tinyspeck.slackmacgap"],
              capabilityHint: "so Perch can read and send messages",
              appIconBundleIdentifierForTile: "com.tinyspeck.slackmacgap"),
        .init(displayName: "Discord", toolkitSlug: "discord", kind: .composio,
              matchHosts: ["discord.com"],
              capabilityHint: "so Perch can read and send messages",
              appIconBundleIdentifierForTile: "com.hnc.Discord"),
        .init(displayName: "Zoom", toolkitSlug: "zoom", kind: .composio,
              matchHosts: ["zoom.us"],
              capabilityHint: "so Perch can manage your meetings",
              appIconBundleIdentifierForTile: "us.zoom.xos"),
        .init(displayName: "Calendly", toolkitSlug: "calendly", kind: .composio,
              matchHosts: ["calendly.com"],
              capabilityHint: "so Perch can manage your scheduling"),

        // Microsoft 365 (web)
        .init(displayName: "Outlook", toolkitSlug: "outlook", kind: .composio,
              matchHosts: ["outlook.office.com", "outlook.live.com", "outlook.office365.com"],
              capabilityHint: "so Perch can read and send your email",
              appIconBundleIdentifierForTile: "com.microsoft.Outlook"),
        .init(displayName: "Microsoft Teams", toolkitSlug: "microsoft_teams", kind: .composio,
              matchHosts: ["teams.microsoft.com"],
              capabilityHint: "so Perch can read and send messages",
              appIconBundleIdentifierForTile: "com.microsoft.teams"),
        .init(displayName: "OneDrive", toolkitSlug: "one_drive", kind: .composio,
              matchHosts: ["onedrive.live.com"],
              capabilityHint: "so Perch can find and organize your files",
              appIconBundleIdentifierForTile: "com.microsoft.OneDrive"),

        // Files / storage
        .init(displayName: "Dropbox", toolkitSlug: "dropbox", kind: .composio,
              matchHosts: ["dropbox.com"],
              capabilityHint: "so Perch can find and organize your files",
              appIconBundleIdentifierForTile: "com.getdropbox.dropbox"),

        // CRM / support / marketing
        .init(displayName: "HubSpot", toolkitSlug: "hubspot", kind: .composio,
              matchHosts: ["hubspot.com"],
              capabilityHint: "so Perch can work with your CRM"),
        .init(displayName: "Salesforce", toolkitSlug: "salesforce", kind: .composio,
              matchHosts: ["salesforce.com", "lightning.force.com"],
              capabilityHint: "so Perch can work with your CRM"),
        .init(displayName: "Zendesk", toolkitSlug: "zendesk", kind: .composio,
              matchHosts: ["zendesk.com"],
              capabilityHint: "so Perch can work with your support tickets"),
        .init(displayName: "Intercom", toolkitSlug: "intercom", kind: .composio,
              matchHosts: ["intercom.com"],
              capabilityHint: "so Perch can work with your conversations"),

        // Commerce
        .init(displayName: "Stripe", toolkitSlug: "stripe", kind: .composio,
              matchHosts: ["dashboard.stripe.com"],
              capabilityHint: "so Perch can work with your payments data"),
        .init(displayName: "Shopify", toolkitSlug: "shopify", kind: .composio,
              matchHosts: ["myshopify.com", "admin.shopify.com"],
              capabilityHint: "so Perch can work with your store"),

        // Social / media
        .init(displayName: "X", toolkitSlug: "twitter", kind: .composio,
              matchHosts: ["x.com", "twitter.com"],
              capabilityHint: "so Perch can read and post for you"),
        .init(displayName: "Reddit", toolkitSlug: "reddit", kind: .composio,
              matchHosts: ["reddit.com"],
              capabilityHint: "so Perch can read and post for you"),
        .init(displayName: "YouTube", toolkitSlug: "youtube", kind: .composio,
              matchHosts: ["youtube.com"],
              capabilityHint: "so Perch can work with your videos"),

        // Native macOS apps (no OAuth — enabled, not connected)
        .init(displayName: "Microsoft Word", toolkitSlug: "native.microsoft_word", kind: .native,
              matchHosts: [], matchBundleIdentifiers: ["com.microsoft.Word"],
              capabilityHint: "so Perch can read and edit the document you're in",
              appIconBundleIdentifierForTile: "com.microsoft.Word"),
        .init(displayName: "Microsoft Excel", toolkitSlug: "native.microsoft_excel", kind: .native,
              matchHosts: [], matchBundleIdentifiers: ["com.microsoft.Excel"],
              capabilityHint: "so Perch can read and fill the sheet you're in",
              appIconBundleIdentifierForTile: "com.microsoft.Excel"),
        .init(displayName: "Numbers", toolkitSlug: "native.apple_numbers", kind: .native,
              matchHosts: [], matchBundleIdentifiers: ["com.apple.iWork.Numbers"],
              capabilityHint: "so Perch can read and fill the spreadsheet you're in",
              appIconBundleIdentifierForTile: "com.apple.iWork.Numbers"),
    ]
}
