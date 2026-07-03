//
//  DailyBriefCalendarWidget.swift
//  notch
//
//  Today's agenda as a simple timeline inside a soft panel (the mockup's "calendar widget"
//  block, made real). Each row is a time label + the event title; it shows a quiet state
//  while the fetch is in flight and an explicit "Nothing scheduled today." when the day is
//  clear. When the day is empty AND Google Calendar isn't connected (no local macOS events
//  either), it swaps that line for a tappable "Connect to Google Calendar" prompt.
//

import SwiftUI

struct DailyBriefCalendarWidget: View {
    let entries: [DailyBriefCalendarEntry]
    let isLoading: Bool
    /// Drives the "Connect to Google Calendar" prompt shown when the day's agenda is empty
    /// AND Google Calendar isn't connected (and there are no local macOS events to fall back
    /// on, since those already fill `entries`).
    @ObservedObject var connectCoordinator: DailyBriefConnectCoordinator
    /// Re-fetch the agenda once Google Calendar connects.
    var onConnected: () -> Void = {}

    /// The Composio toolkit that feeds this widget's cloud calendar events.
    private let calendarToolkitSlug = "googlecalendar"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(DailyBriefStyle.panelFill)
        )
    }

    @ViewBuilder
    private var content: some View {
        if entries.isEmpty {
            if isLoading {
                emptyText("Loading today's calendar…")
            } else if connectCoordinator.canOfferConnect(calendarToolkitSlug) {
                // Nothing on the cloud OR local calendar and Google Calendar isn't linked —
                // offer to connect it right here instead of a dead "Nothing scheduled" line.
                DailyBriefConnectPrompt(
                    toolkitSlug: calendarToolkitSlug,
                    coordinator: connectCoordinator,
                    onConnected: onConnected
                )
            } else {
                emptyText("Nothing scheduled today.")
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 {
                        Rectangle()
                            .fill(DailyBriefStyle.hairline)
                            .frame(height: 1)
                            .padding(.vertical, 10)
                    }
                    DailyBriefCalendarRow(entry: entry)
                }
            }
        }
    }

    /// A quiet, centered placeholder line — the shared look for the widget's empty states.
    private func emptyText(_ message: String) -> some View {
        Text(message)
            .font(DailyBriefStyle.body(size: 17))
            .foregroundColor(DailyBriefStyle.captionInk)
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
    }
}

private struct DailyBriefCalendarRow: View {
    let entry: DailyBriefCalendarEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(entry.timeLabel)
                .font(DailyBriefStyle.body(size: 16))
                .foregroundColor(DailyBriefStyle.captionInk)
                .frame(width: 84, alignment: .leading)
            Text(entry.title)
                .font(DailyBriefStyle.body(size: 17))
                .foregroundColor(DailyBriefStyle.bodyInk)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
