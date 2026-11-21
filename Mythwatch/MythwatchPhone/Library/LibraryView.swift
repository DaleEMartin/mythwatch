import MythwatchDomain
import MythwatchFeatures
import SwiftUI

/// SPEC 7 "Recordings" on a touch screen (SPEC 11): Continue Watching and Recently Recorded as
/// horizontal shelves, then the shows as an adaptive poster grid. Pull to refresh.
struct LibraryView: View {
    let model: LibraryViewModel
    let artwork: ArtworkURLs

    var body: some View {
        content
            .task { await model.load() }
    }

    @ViewBuilder private var content: some View {
        switch model.library {
        case .idle, .loading:
            LoadingView(caption: Labels.loadingRecordings)
        case .failed(let message):
            MessageView(message: message, retry: { await model.load() })
        case .loaded(let library) where library.shows.isEmpty:
            ScrollView {
                VStack(spacing: 12) {
                    refreshBanner
                    Text(Labels.noRecordingsTitle).font(.title3).bold()
                    Text(Labels.noRecordingsDetail).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding(32)
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("library.empty")
            }
            .refreshable { await model.refresh() }
        case .loaded(let library):
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 28) {
                    if model.refreshProblem != nil { refreshBanner.padding(.horizontal) }
                    if !library.continueWatching.isEmpty {
                        Shelf(title: Labels.continueWatching, id: "continueWatching",
                              recordings: library.continueWatching, artwork: artwork)
                    }
                    if !library.recentlyRecorded.isEmpty {
                        Shelf(title: Labels.recentlyRecorded, id: "recentlyRecorded",
                              recordings: library.recentlyRecorded, artwork: artwork)
                    }
                    ShowsGrid(shows: library.shows, artwork: artwork)
                }
                .padding(.vertical, 12)
            }
            .refreshable { await model.refresh() }
            .accessibilityIdentifier("library.screen")
        }
    }

    /// A failed refresh: the library stays, and Try Again fetches again (M5-3).
    @ViewBuilder private var refreshBanner: some View {
        if let problem = model.refreshProblem {
            MessageBanner(message: problem, retry: problem.canRetry ? { await model.refresh() } : nil)
        }
    }
}

/// A horizontal row of landscape recording cards.
struct Shelf: View {
    let title: String
    let id: String
    let recordings: [Recording]
    let artwork: ArtworkURLs

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title3).bold().padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(recordings) { recording in
                        NavigationLink(value: LibraryRoute.episode(recording)) {
                            RecordingCard(recording: recording, artwork: artwork)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Labels.spokenCard(recording))
                        .accessibilityIdentifier("card.\(id).\(recording.id.rawValue)")
                    }
                }
                .padding(.horizontal)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("shelf.\(id)")
    }
}

/// A landscape card: preview image with a watched or part-watched mark, title and episode.
struct RecordingCard: View {
    let recording: Recording
    let artwork: ArtworkURLs
    private let width: CGFloat = 240

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ArtworkImage(
                urls: artwork.thumbnail(for: recording, maxWidth: 640), title: recording.title,
                aspectRatio: 16.0 / 9.0
            )
            .accessibilityHidden(true)
            .overlay(alignment: .bottomTrailing) { WatchMark(recording: recording).padding(6) }
            .frame(width: width)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(recording.title).font(.subheadline).bold().lineLimit(1)
                Text(Labels.episodeTitle(recording) == recording.title
                     ? Labels.length(recording) : Labels.episodeTitle(recording))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: width, alignment: .leading)
        }
        .contentShape(Rectangle())
    }
}

/// The shows as posters, as many columns as fit.
struct ShowsGrid: View {
    let shows: [Show]
    let artwork: ArtworkURLs

    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 180), spacing: 14, alignment: .top)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(Labels.shows).font(.title3).bold()
            LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                ForEach(shows) { show in
                    NavigationLink(value: LibraryRoute.show(show)) {
                        VStack(alignment: .leading, spacing: 4) {
                            ArtworkImage(urls: artwork.poster(for: show, maxWidth: 320), title: show.title)
                                .accessibilityHidden(true)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            Text(show.title).font(.caption).bold().lineLimit(1)
                            Text(Labels.counts(show)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Labels.spokenShow(show))
                    .accessibilityIdentifier("show.\(show.id)")
                }
            }
        }
        .padding(.horizontal)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library.shows")
    }
}
