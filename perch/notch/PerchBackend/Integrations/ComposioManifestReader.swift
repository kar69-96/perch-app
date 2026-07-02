//
//  ComposioManifestReader.swift
//  Perch
//
//  Reads the Python sidecar's capability manifest (<repo>/support/composio-manifest.json)
//  to answer two questions the integration-offer coordinator needs without ever
//  spawning the sidecar:
//   • Is Composio available at all? (`composio_enabled` — false when COMPOSIO_DISABLED
//     is set or no API key is configured; the manifest may also be absent entirely.)
//   • Which toolkits are already connected? (`connected_toolkits`) — so a connect
//     offer never fires for a service the user has already linked.
//
//  The manifest is the shared contract between Swift and Python (see
//  browser-subagent/.../loop/planning/capabilities.py). The Python `--connect` flow
//  rewrites it on success, so this reader is also how the connect flow's completion
//  is observed. Results are cached and only re-read when the file's modification
//  date changes, so the 0.75s monitor tick is cheap.
//
//  Deliberately plain (not @MainActor) and file-URL injected so it round-trips
//  against a fixture in a standalone harness.
//

import Foundation

/// A snapshot of the manifest's integration-relevant fields.
struct ComposioManifestState: Equatable {
    /// Whether the manifest file exists yet (the sidecar has probed at least once).
    let manifestPresent: Bool
    /// `composio_enabled` from the manifest — Composio has a key and isn't disabled.
    let composioEnabled: Bool
    /// Lowercased slugs of the user's already-connected toolkits.
    let connectedToolkitSlugs: Set<String>
    /// Toolkit slug -> high quality logo URL (from Composio). Used by the
    /// integrations UI to show distinct, professional icons instead of
    /// generic favicons or monograms.
    let toolkitLogos: [String: String]

    /// Composio can actually run a connect flow right now.
    var composioAvailable: Bool { manifestPresent && composioEnabled }

    static let absent = ComposioManifestState(
        manifestPresent: false, composioEnabled: false, connectedToolkitSlugs: [], toolkitLogos: [:]
    )
}

final class ComposioManifestReader {

    private let manifestFileURL: URL

    /// Cached parse + the file modification date it was parsed from.
    private var cachedState: ComposioManifestState = .absent
    private var cachedModificationDate: Date?
    private var hasReadAtLeastOnce = false

    init(manifestFileURL: URL) {
        self.manifestFileURL = manifestFileURL
    }

    /// The app's real manifest at <repo>/support/composio-manifest.json.
    static func standard() -> ComposioManifestReader {
        return ComposioManifestReader(
            manifestFileURL: PerchSupportPaths.file("composio-manifest.json")
        )
    }

    /// Current manifest state, re-reading from disk only when the file's
    /// modification date has changed since the last read.
    func currentState() -> ComposioManifestState {
        let fileAttributes = try? FileManager.default.attributesOfItem(atPath: manifestFileURL.path)
        let modificationDate = fileAttributes?[.modificationDate] as? Date

        // File missing now (it may have existed before).
        guard let modificationDate else {
            cachedState = .absent
            cachedModificationDate = nil
            hasReadAtLeastOnce = true
            return cachedState
        }

        if hasReadAtLeastOnce, cachedModificationDate == modificationDate {
            return cachedState
        }

        cachedState = Self.parse(manifestFileURL)
        cachedModificationDate = modificationDate
        hasReadAtLeastOnce = true
        return cachedState
    }

    /// Whether `toolkitSlug` is already connected (case-insensitive).
    func isConnected(toolkitSlug: String) -> Bool {
        currentState().connectedToolkitSlugs.contains(toolkitSlug.lowercased())
    }

    // MARK: - Parsing

    private static func parse(_ fileURL: URL) -> ComposioManifestState {
        let manifestData: Data
        do {
            manifestData = try Data(contentsOf: fileURL)
        } catch {
            // currentState() already confirmed the file exists, so a read failure here
            // is a real error (a transient I/O issue, a permissions change) — not "file
            // missing". Log it so it isn't silently indistinguishable from absence,
            // which would suppress every connection offer with no signal.
            print("⚠️ ComposioManifestReader: composio-manifest.json present but "
                + "unreadable (read error): \(error)")
            return .absent
        }
        guard let parsedObject = try? JSONSerialization.jsonObject(with: manifestData),
              let manifestDictionary = parsedObject as? [String: Any]
        else {
            print("⚠️ ComposioManifestReader: composio-manifest.json present but unreadable")
            return .absent
        }

        let composioEnabled = (manifestDictionary["composio_enabled"] as? Bool) ?? false
        let rawConnectedToolkits = (manifestDictionary["connected_toolkits"] as? [String]) ?? []
        let connectedSlugs = Set(rawConnectedToolkits.map(extractSlug(from:)))

        var toolkitLogos: [String: String] = [:]
        if let rawLogos = manifestDictionary["toolkit_logos"] as? [String: String] {
            for (slug, url) in rawLogos {
                let normalized = extractSlug(from: slug)
                if !normalized.isEmpty, !url.isEmpty {
                    toolkitLogos[normalized] = url
                }
            }
        }

        return ComposioManifestState(
            manifestPresent: true,
            composioEnabled: composioEnabled,
            connectedToolkitSlugs: connectedSlugs,
            toolkitLogos: toolkitLogos
        )
    }

    /// The Python side usually writes clean lowercased slugs ("gmail"), but a
    /// toolkit object can serialize as its repr ("itemtoolkit(slug='gmail')").
    /// Pull the slug out of the repr form when present; otherwise lowercase the
    /// whole string.
    static func extractSlug(from rawToolkit: String) -> String {
        if let slugRange = rawToolkit.range(of: "slug='") {
            let afterMarker = rawToolkit[slugRange.upperBound...]
            if let closingQuoteRange = afterMarker.range(of: "'") {
                return String(afterMarker[..<closingQuoteRange.lowerBound]).lowercased()
            }
        }
        return rawToolkit.lowercased()
    }
}
