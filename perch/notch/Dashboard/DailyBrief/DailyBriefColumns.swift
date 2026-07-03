//
//  DailyBriefColumns.swift
//  notch
//
//  The two editable editorial columns: "Catch up:" (plain bullets) and "Today's
//  priorities:" (a checklist). Editing is keyboard-driven, just like Notion: type inline to
//  edit (full native text editing via `DailyBriefTextField`), press Return to start a new
//  item below, and press Backspace on an EMPTY item to delete it and jump to the previous
//  one. Priorities also click their box to check off. All edits flow through
//  `DailyBriefStore.shared` and persist across relaunches.
//

import SwiftUI

struct DailyBriefColumns: View {
    @ObservedObject private var store = DailyBriefStore.shared
    /// Drives the "Connect to Gmail" prompt shown when both lists are still blank (nothing
    /// synthesized, nothing typed) AND Gmail — the integration those lists are seeded from —
    /// isn't connected.
    @ObservedObject var connectCoordinator: DailyBriefConnectCoordinator
    /// Re-run the synthesis (which seeds the lists) once Gmail connects.
    var onConnected: () -> Void = {}
    /// Which row's text field currently has the keyboard — drives Return/Backspace focus moves.
    @State private var focusedItemID: String?

    /// The Composio toolkit whose priority email seeds the catch-up / priorities lists.
    private let emailToolkitSlug = "gmail"

    /// True when neither list has any typed content — only the honest blank seed rows. Both
    /// lists are filled together by the same email-driven synthesis, so when Gmail is missing
    /// they're empty in lockstep and a single prompt stands in for the whole block.
    private var bothListsBlank: Bool {
        (store.catchUp + store.priorities).allSatisfy {
            $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var body: some View {
        if bothListsBlank, connectCoordinator.canOfferConnect(emailToolkitSlug) {
            DailyBriefConnectPrompt(
                toolkitSlug: emailToolkitSlug,
                coordinator: connectCoordinator,
                onConnected: onConnected
            )
            .frame(maxWidth: .infinity)
        } else {
            HStack(alignment: .top, spacing: 40) {
                DailyBriefEditableColumn(
                    heading: "Catch up:",
                    kind: .catchUp,
                    items: store.catchUp,
                    showsCheckbox: false,
                    store: store,
                    focusedItemID: $focusedItemID
                )
                DailyBriefEditableColumn(
                    heading: "Today's priorities:",
                    kind: .priorities,
                    items: store.priorities,
                    showsCheckbox: true,
                    store: store,
                    focusedItemID: $focusedItemID
                )
            }
        }
    }
}

/// One editable column: a serif heading over its keyboard-editable rows.
private struct DailyBriefEditableColumn: View {
    let heading: String
    let kind: DailyBriefListKind
    let items: [DailyBriefItem]
    let showsCheckbox: Bool
    @ObservedObject var store: DailyBriefStore
    @Binding var focusedItemID: String?

    /// Fixed wrap width for the inline editors (the columns are a fixed width).
    private let rowTextWrapWidth: CGFloat = 400

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(heading)
                .font(DailyBriefStyle.heading(size: 24))
                .foregroundColor(DailyBriefStyle.headingInk)

            VStack(alignment: .leading, spacing: 9) {
                ForEach(items) { item in
                    DailyBriefEditableRow(
                        item: item,
                        kind: kind,
                        showsCheckbox: showsCheckbox,
                        siblings: items,
                        wrapWidth: rowTextWrapWidth,
                        store: store,
                        focusedItemID: $focusedItemID
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One editable row: a leading marker (checkbox or bullet) + a native inline text editor
/// with Notion-style Return/Backspace handling.
private struct DailyBriefEditableRow: View {
    let item: DailyBriefItem
    let kind: DailyBriefListKind
    let showsCheckbox: Bool
    /// The current list (for figuring out which row to focus after an insert/delete).
    let siblings: [DailyBriefItem]
    let wrapWidth: CGFloat
    @ObservedObject var store: DailyBriefStore
    @Binding var focusedItemID: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            marker

            DailyBriefTextField(
                itemID: item.id,
                text: textBinding,
                focusedItemID: $focusedItemID,
                font: NSFont.systemFont(ofSize: 17),
                textColor: NSColor(item.isChecked ? DailyBriefStyle.captionInk : DailyBriefStyle.bodyInk),
                wrapWidth: wrapWidth,
                onReturn: {
                    let newID = store.insertItem(kind, afterID: item.id)
                    focusedItemID = newID
                },
                onBackspaceWhenEmpty: handleBackspaceOnEmpty
            )
        }
    }

    @ViewBuilder
    private var marker: some View {
        if showsCheckbox {
            Button {
                store.toggleChecked(kind, id: item.id)
            } label: {
                Image(systemName: item.isChecked ? "checkmark.square.fill" : "square")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundColor(item.isChecked ? DailyBriefStyle.bodyInk : DailyBriefStyle.captionInk)
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        } else {
            Text("–")
                .font(DailyBriefStyle.body(size: 17))
                .foregroundColor(DailyBriefStyle.bodyInk)
        }
    }

    /// Delete this (empty) row and move focus up, keeping at least one row in the list so
    /// there's always somewhere to type — the same way Notion keeps an empty trailing line.
    private func handleBackspaceOnEmpty() {
        guard siblings.count > 1,
              let index = siblings.firstIndex(where: { $0.id == item.id }) else {
            return  // the only row — leave it so the list never becomes un-typeable.
        }
        // Focus the previous row if there is one, else the row that shifts up into its place.
        let focusTargetID = index > 0 ? siblings[index - 1].id : siblings[index + 1].id
        store.deleteItem(kind, id: item.id)
        focusedItemID = focusTargetID
    }

    /// Reads the live item text and routes edits back through the store (debounced save).
    private var textBinding: Binding<String> {
        Binding(
            get: { item.text },
            set: { store.updateText(kind, id: item.id, text: $0) }
        )
    }
}
