import MythwatchDomain
import MythwatchFeatures
import SwiftUI

/// SPEC 7 "Recordings": Continue Watching and Recently Recorded shelves, then a poster grid.
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
            VStack(spacing: 24) {
                if let problem = model.refreshProblem { MessageBanner(message: problem) }
                Text(Labels.noRecordingsTitle).font(.title2).bold()
                Text(Labels.noRecordingsDetail).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library.empty")
        case .loaded(let library):
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 50) {
                    if let problem = model.refreshProblem { MessageBanner(message: problem) }
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
                .padding(.vertical, 40)
            }
            .accessibilityIdentifier("library.screen")
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
        VStack(alignment: .leading, spacing: 20) {
            Text(title).font(.title3).bold().padding(.horizontal, 80)
            ScrollView(.horizontal) {
                LazyHStack(spacing: 48) {
                    ForEach(recordings) { recording in
                        NavigationLink(value: LibraryRoute.episode(recording)) {
                            RecordingCard(recording: recording, artwork: artwork)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("card.\(id).\(recording.id.rawValue)")
                    }
                }
                .padding(.horizontal, 80)
                .padding(.vertical, 30)
            }
            .scrollClipDisabled()
        }
        .focusSection()
        .accessibilityIdentifier("shelf.\(id)")
    }
}

/// A landscape card: preview image with a watched or part-watched mark, title and episode.
struct RecordingCard: View {
    let recording: Recording
    let artwork: ArtworkURLs

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ArtworkImage(
                urls: artwork.thumbnail(for: recording, maxWidth: 640), title: recording.title,
                aspectRatio: 16.0 / 9.0
            )
            .overlay(alignment: .bottomTrailing) { WatchMark(recording: recording).padding(12) }
            .frame(width: 400)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .hoverEffect(.highlight)
            VStack(alignment: .leading, spacing: 4) {
                Text(recording.title).font(.callout).bold().lineLimit(1)
                Text(Labels.episodeTitle(recording) == recording.title
                     ? Labels.length(recording) : Labels.episodeTitle(recording))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: 400, alignment: .leading)
        }
    }
}

/// The shows as posters.
struct ShowsGrid: View {
    let shows: [Show]
    let artwork: ArtworkURLs

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 48, alignment: .top), count: 6)

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(Labels.shows).font(.title3).bold()
            LazyVGrid(columns: columns, alignment: .leading, spacing: 60) {
                ForEach(shows) { show in
                    NavigationLink(value: LibraryRoute.show(show)) {
                        VStack(alignment: .leading, spacing: 12) {
                            ArtworkImage(urls: artwork.poster(for: show, maxWidth: 320), title: show.title)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .hoverEffect(.highlight)
                            Text(show.title).font(.caption).bold().lineLimit(1)
                            Text(Labels.counts(show)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("show.\(show.id)")
                }
            }
        }
        .padding(.horizontal, 80)
        .focusSection()
        .accessibilityIdentifier("library.shows")
    }
}

/// Watched: a check. Part watched: a half circle. Otherwise nothing.
struct WatchMark: View {
    let recording: Recording

    var body: some View {
        if recording.flags.contains(.watched) {
            Image(systemName: "checkmark.circle.fill")
                .symbolRenderingMode(.palette).foregroundStyle(.white, .green)
                .font(.title3)
                .accessibilityLabel(Labels.watched)
        } else if recording.flags.contains(.hasResumePosition) {
            Image(systemName: "circle.lefthalf.filled")
                .foregroundStyle(.white).font(.title3)
                .accessibilityLabel(Labels.partWatched)
        }
    }
}
