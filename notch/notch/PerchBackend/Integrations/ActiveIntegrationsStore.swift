//
//  ActiveIntegrationsStore.swift
//  leanring-buddy
//
//  The view model behind the notch Home tab's "Active integrations" row. It is the
//  single source of truth for two lists the row renders:
//   • `connectedIntegrations` — services the user has already wired up: Composio
//     toolkits (from the capability manifest) and enabled native apps (Word/Excel/
//     Numbers, from EnabledIntegrationsStore).
//   • `connectableIntegrations` — everything in the curated catalog not yet
//     connected (and, for Composio, only when Composio can actually run a connect),
//     shown in the "+" dropdown.
//
//  Selecting a service from the dropdown runs the SAME connect side effect as the
//  proactive offer — it reuses the injected `ServiceConnecting` (ServiceConnectManager):
//  Composio services spawn the OAuth flow and poll the manifest; native apps enable
//  immediately. The chip morphs Connecting… → connected as the outcome lands.
//
//  @MainActor because its only consumers are SwiftUI views and the main-actor
//  connect manager; collaborators are injected so it round-trips in a harness.
//

import Foundation

@MainActor
final class ActiveIntegrationsStore: ObservableObject {

    /// Catalog entries the user has already connected (Composio) or enabled (native),
    /// shown as chips. Recomputed by `refresh()`.
    @Published private(set) var connectedIntegrations: [ServiceCatalogEntry] = []

    /// Toolkit slugs currently mid-connect, so their dropdown row / chip can show a
    /// spinner and ignore repeat taps.
    @Published private(set) var connectingToolkitSlugs: Set<String> = []

    /// The slug whose connect most recently FAILED, so the row can surface a brief
    /// "Couldn't connect" hint. Cleared on the next connect attempt or refresh.
    @Published private(set) var lastFailedToolkitSlug: String?

    private let manifestReader: ComposioManifestReader
    private let enabledStore: EnabledIntegrationsStore
    private let catalog: ServiceCatalog
    private let connector: ServiceConnecting

    init(
        manifestReader: ComposioManifestReader,
        enabledStore: EnabledIntegrationsStore,
        catalog: ServiceCatalog,
        connector: ServiceConnecting
    ) {
        self.manifestReader = manifestReader
        self.enabledStore = enabledStore
        self.catalog = catalog
        self.connector = connector
        refresh()
    }

    // MARK: - Derived lists

    /// Whether Composio can run a connect flow right now (key present, not disabled).
    var composioAvailable: Bool {
        manifestReader.currentState().composioAvailable
    }

    /// Catalog entries not yet connected, eligible to connect, sorted by display
    /// name for the dropdown. A Composio service is only offered when Composio can
    /// actually run a connect (has a key and isn't disabled).
    var connectableIntegrations: [ServiceCatalogEntry] {
        let manifestState = manifestReader.currentState()
        return catalog.entries
            .filter { entry in
                guard !isConnected(entry, manifestState: manifestState) else { return false }
                switch entry.kind {
                case .composio:
                    return manifestState.composioAvailable
                case .native:
                    // Native apps (Word/Excel/Numbers) are no longer surfaced in the
                    // integrations strip — it lists Composio services only.
                    return false
                }
            }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    // MARK: - Refresh

    /// Re-reads the manifest + enabled store and recomputes the connected list.
    /// Cheap (the manifest reader only re-parses on a file-modification change), so
    /// the Home tab can call it on appear and after each connect outcome.
    func refresh() {
        let manifestState = manifestReader.currentState()
        connectedIntegrations = catalog.entries.filter {
            // Composio services only — native apps are excluded from the strip.
            $0.kind == .composio && isConnected($0, manifestState: manifestState)
        }
    }

    // MARK: - Connect (from the "+" dropdown)

    /// Begin connecting `entry`, reusing the proactive offer's connect machinery.
    /// No-ops if the service is already connecting. On success, records native
    /// enablement (Composio reflects through the manifest) and refreshes.
    func connect(_ entry: ServiceCatalogEntry) {
        let slug = entry.toolkitSlug
        guard !connectingToolkitSlugs.contains(slug) else { return }
        lastFailedToolkitSlug = nil
        connectingToolkitSlugs.insert(slug)

        let offer = ServiceConnectionOffer(from: entry)
        connector.connect(offer) { [weak self] didSucceed in
            guard let self else { return }
            self.connectingToolkitSlugs.remove(slug)
            if didSucceed {
                self.enabledStore.recordEnabledIfNative(kind: entry.kind, toolkitSlug: slug)
                self.refresh()
            } else {
                self.lastFailedToolkitSlug = slug
            }
        }
    }

    func isConnecting(_ entry: ServiceCatalogEntry) -> Bool {
        connectingToolkitSlugs.contains(entry.toolkitSlug)
    }

    // MARK: - Helpers

    private func isConnected(
        _ entry: ServiceCatalogEntry, manifestState: ComposioManifestState
    ) -> Bool {
        switch entry.kind {
        case .composio:
            return manifestState.connectedToolkitSlugs.contains(entry.toolkitSlug.lowercased())
        case .native:
            return enabledStore.isEnabled(entry.toolkitSlug)
        }
    }
}
