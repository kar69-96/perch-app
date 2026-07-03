//
//  DailyBriefView.swift
//  notch
//
//  The redesigned Daily Brief: a fixed, scrolling editorial page (title card → summary →
//  catch-up / priorities → calendar → news + comic) on a clean light background. The title
//  card paints instantly from local facts; every other section fills in live as its source
//  resolves (see `DailyBriefViewModel`).
//
//  This is a brand-new surface that sits alongside the legacy pegboard dashboard — it does
//  not touch `DashboardView`/`DashboardCanvasView`. It's hosted by `DailyBriefWindowController`.
//

import SwiftUI

struct DailyBriefView: View {
    @StateObject private var viewModel = DailyBriefViewModel()
    /// Knows which integrations are connected and runs the connect flow for the "Connect
    /// to …" prompts a section shows when its integration is missing and it has nothing to
    /// display (calendar → Google Calendar, catch-up / priorities → Gmail).
    @StateObject private var connectCoordinator = DailyBriefConnectCoordinator()

    // When set, the comic is shown full-size in a dismissible lightbox over the whole page.
    // It's hosted here (not inside the news section) so the expanded view can cover the
    // entire brief rather than being clipped to the small comic card.
    @State private var expandedComic: DailyBriefComic?

    var body: some View {
        ScrollView {
            // Center a fixed-width reading column with greedy spacers — a plain
            // `.frame(maxWidth:)` doesn't reliably cap the greedy title card.
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                column
                    .frame(maxWidth: DailyBriefStyle.contentWidth)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DailyBriefStyle.pagePadding)
            .padding(.top, 28)
            .padding(.bottom, 56)
        }
        .background(DailyBriefStyle.pageBackground)
        .overlay {
            if let expandedComic {
                DailyBriefComicLightbox(comic: expandedComic) {
                    withAnimation(.easeOut(duration: 0.15)) { self.expandedComic = nil }
                }
                .transition(.opacity)
            }
        }
        .onAppear { viewModel.loadIfNeeded() }
    }

    private var column: some View {
        VStack(alignment: .leading, spacing: DailyBriefStyle.sectionSpacing) {
                DailyBriefTitleCard(
                    firstName: viewModel.firstName,
                    dateLine: viewModel.dateLine,
                    weekdayName: viewModel.weekdayName,
                    artwork: viewModel.artwork
                )

                DailyBriefSummaryRow(
                    summary: viewModel.synthesis?.summary ?? "",
                    isSynthesizing: viewModel.isSynthesizing,
                    caption: viewModel.artwork.caption
                )

                Rectangle()
                    .fill(DailyBriefStyle.hairline)
                    .frame(height: 1)

                DailyBriefColumns(
                    connectCoordinator: connectCoordinator,
                    onConnected: { viewModel.refreshDayContext() }
                )

                DailyBriefCalendarWidget(
                    entries: viewModel.calendarEntries,
                    isLoading: viewModel.isLoadingCalendar,
                    connectCoordinator: connectCoordinator,
                    onConnected: { viewModel.refreshDayContext() }
                )

                DailyBriefNewsSection(
                    headlines: viewModel.headlines,
                    isLoading: viewModel.isLoadingNews,
                    comic: viewModel.comic,
                    onExpandComic: { comic in
                        withAnimation(.easeOut(duration: 0.15)) { expandedComic = comic }
                    }
                )
        }
    }
}

// A full-page lightbox that shows the comic at a large, readable size. Clicking the dimmed
// backdrop or the close button dismisses it; the alt text is shown beneath the strip so the
// reader gets the joke without hunting for the tooltip.
private struct DailyBriefComicLightbox: View {
    let comic: DailyBriefComic
    let onDismiss: () -> Void

    @State private var isHoveringClose = false

    var body: some View {
        ZStack {
            // Dimmed backdrop — clicking anywhere outside the card closes the lightbox.
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }

            VStack(spacing: 16) {
                Text(comic.title)
                    .font(DailyBriefStyle.heading(size: 22))
                    .foregroundColor(DailyBriefStyle.headingInk)
                    .multilineTextAlignment(.center)

                Image(nsImage: comic.image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(24)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.white)
                    )

                if !comic.altText.isEmpty {
                    Text(comic.altText)
                        .font(DailyBriefStyle.body(size: 15))
                        .foregroundColor(DailyBriefStyle.captionInk)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 640)
                }
            }
            // Cap the expanded card so it never overruns the page on large displays, while
            // still being far bigger than the 280×300 thumbnail.
            .frame(maxWidth: 820, maxHeight: 760)
            .padding(40)
            // Tapping the card itself should NOT close the lightbox.
            .contentShape(Rectangle())
            .onTapGesture { }
            .overlay(alignment: .topTrailing) { closeButton }
        }
    }

    private var closeButton: some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 26))
                .foregroundColor(.white.opacity(isHoveringClose ? 1.0 : 0.8))
                .padding(20)
        }
        .buttonStyle(.plain)
        .help("Close")
        .onHover { hovering in
            isHoveringClose = hovering
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}
