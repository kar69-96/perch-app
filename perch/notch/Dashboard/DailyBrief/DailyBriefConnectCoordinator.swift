//
//  DailyBriefConnectCoordinator.swift
//  notch
//
//  The Daily Brief's self-contained bridge to the app's integration-connect machinery.
//  A brief section (calendar, catch-up / priorities) shows a "Connect to …" prompt only
//  when the integration that feeds it isn't connected AND the section is empty; tapping the
//  prompt runs the SAME OAuth flow as the notch Home tab's integrations row.
//
//  It reuses the real building blocks rather than reimplementing them:
//   • `ComposioManifestReader.standard()` — the canonical "is this toolkit connected?" +
//     "can Composio run a connect right now?" authority (reads <repo>/support/composio-
//     manifest.json, mod-date cached).
//   • `ServiceConnectManager` — spawns `run.sh --connect <slug>` and polls the manifest.
//   • `ServiceCatalog.loadFromBundle()` — maps a toolkit slug to its display name + offer.
//
//  Kept local to the brief (its own coordinator, its own reader) because the brief is a
//  standalone window built without the app's environment — mirroring how `ActiveIntegrations-
//  Store` is itself just a thin coordinator over these same pieces. The manifest is a single
//  file on disk, so a connection made here (or in the notch) is observed by both surfaces on
//  their next read; the only unshared state is the in-flight "connecting" spinner, which each
//  surface owns for itself.
//
//  @MainActor because it drives SwiftUI and the main-actor connect manager.
//

import Foundation

@MainActor
final class DailyBriefConnectCoordinator: ObservableObject {

    /// Lowercased slugs of the user's already-connected toolkits (manifest snapshot).
    @Published private(set) var connectedSlugs: Set<String> = []
    /// Whether Composio can actually run a connect right now (key present, not disabled).
    /// When false there's nothing to connect to, so no prompt is offered.
    @Published private(set) var composioAvailable = false
    /// Slugs whose OAuth flow is in flight, so the prompt can show a spinner and ignore
    /// repeat taps.
    @Published private(set) var connectingSlugs: Set<String> = []

    private let manifestReader: ComposioManifestReader
    private let catalog: ServiceCatalog
    private let connector: ServiceConnecting

    /// Injected for tests; the app path uses the standard manifest reader, the bundle
    /// catalog, and a real `ServiceConnectManager` bound to that same reader.
    init(
        manifestReader: ComposioManifestReader = .standard(),
        catalog: ServiceCatalog = .loadFromBundle(),
        connector: ServiceConnecting? = nil
    ) {
        self.manifestReader = manifestReader
        self.catalog = catalog
        self.connector = connector ?? ServiceConnectManager(manifestReader: manifestReader)
        refresh()
    }

    // MARK: - Reads

    /// Re-read the manifest snapshot (cheap — the reader only re-parses on a file change).
    /// Called on init and after each connect outcome so the prompt reflects reality.
    func refresh() {
        let state = manifestReader.currentState()
        connectedSlugs = state.connectedToolkitSlugs
        composioAvailable = state.composioAvailable
    }

    /// Whether `toolkitSlug` is already connected (case-insensitive).
    func isConnected(_ toolkitSlug: String) -> Bool {
        connectedSlugs.contains(toolkitSlug.lowercased())
    }

    /// Whether `toolkitSlug`'s connect is currently in flight.
    func isConnecting(_ toolkitSlug: String) -> Bool {
        connectingSlugs.contains(toolkitSlug.lowercased())
    }

    /// Whether a "Connect to …" prompt should be offered for `toolkitSlug`: Composio can
    /// run a connect right now and the toolkit isn't already connected. When this is false
    /// the caller keeps its existing quiet empty state (so nothing regresses in local dev,
    /// where Composio is disabled, or once the service is connected).
    func canOfferConnect(_ toolkitSlug: String) -> Bool {
        composioAvailable && !isConnected(toolkitSlug)
    }

    /// The human display name for a toolkit slug, from the curated catalog (falls back to a
    /// humanized slug for services not in the catalog) — so the prompt copy stays in sync
    /// with the single catalog source rather than hardcoding names.
    func displayName(forSlug toolkitSlug: String) -> String {
        catalog.composioEntry(forToolkitSlug: toolkitSlug).displayName
    }

    // MARK: - Connect

    /// Begin connecting `toolkitSlug`, reusing the app's real OAuth flow. No-ops if it's
    /// already connecting. On success, refreshes the snapshot (so the prompt disappears) and
    /// calls `onSuccess` so the brief can re-fetch the now-available data.
    func connect(slug toolkitSlug: String, onSuccess: @escaping () -> Void) {
        let slug = toolkitSlug.lowercased()
        guard !connectingSlugs.contains(slug) else { return }
        connectingSlugs.insert(slug)

        let offer = ServiceConnectionOffer(from: catalog.composioEntry(forToolkitSlug: slug))
        connector.connect(offer) { [weak self] didSucceed in
            guard let self else { return }
            self.connectingSlugs.remove(slug)
            self.refresh()
            if didSucceed { onSuccess() }
        }
    }
}
