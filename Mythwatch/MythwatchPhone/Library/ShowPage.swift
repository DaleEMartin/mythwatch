import MythwatchDomain
import MythwatchFeatures
import SwiftUI

/// SPEC 7 "Show" on a touch screen. Makes its model once, when first shown.
struct ShowPage: View {
    let app: AppModel
    let show: Show
    let close: () -> Void
    @State private var model: ShowViewModel?

    var body: some View {
        Group {
            if let model {
                ShowView(model: model, artwork: app.makeArtwork(),
                         askBeforeDelete: { app.savedSettings.askBeforeDelete }, close: close)
            } else {
                Color.clear  // something must be on screen for onAppear to run
            }
        }
        .onAppear { if model == nil { model = app.makeShowModel(show) } }
    }
}

struct ShowView: View {
    @Bindable var model: ShowViewModel
    let artwork: ArtworkURLs
    let askBeforeDelete: () -> Bool
    let close: () -> Void

    @State private var pendingDelete: Recording?

    var body: some View {
        List {
            Section {
                header
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                seasonPicker
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            if let season = model.selectedSeason {
                Section {
                    ForEach(season.episodes) { episode in
                        EpisodeRow(recording: episode, model: model, requestDelete: requestDelete)
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(model.show.title)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("show.screen")
        .onChange(of: model.isEmpty) { _, empty in if empty { close() } }
        .alert(
            model.problem?.title ?? "", isPresented: Binding(
                get: { model.problem != nil }, set: { if !$0 { model.dismissProblem() } }),
            presenting: model.problem
        ) { _ in
            Button(Labels.ok) { model.dismissProblem() }
        } message: { problem in
            Text(problem.detail)
        }
        .confirmationDialog(
            pendingDelete.map(Labels.deleteQuestion) ?? "", isPresented: Binding(
                get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible, presenting: pendingDelete
        ) { recording in
            DeleteChoices { model.delete(recording, allowRerecord: $0) }
        } message: { _ in
            Text(DeleteMessage.text(confirming: askBeforeDelete()))
        }
    }

    /// Always a dialog: the re-record choice is asked each time (owner, 2026-11-16).
    private func requestDelete(_ recording: Recording) {
        pendingDelete = recording
    }

    /// Fanart (when there is some) under the title and counts.
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let url = artwork.fanart(for: model.show, maxWidth: 1280) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: { Color.clear }
                .frame(height: 180)
                .frame(maxWidth: .infinity)
                .clipped()
                .accessibilityHidden(true)
            }
            Text(model.show.title).font(.title2).bold()
                .accessibilityIdentifier("show.title")
                .padding(.horizontal)
                .padding(.top, 8)
            Text(Labels.counts(model.show)).font(.subheadline).foregroundStyle(.secondary)
                .padding(.horizontal)
        }
    }

    /// Several seasons: a picker (segmented when they fit). One named season: its name. A film's
    /// season has no name: nothing.
    @ViewBuilder private var seasonPicker: some View {
        let seasons = model.seasons
        let selection = Binding(
            get: { model.selectedSeason?.id },
            set: { id in if let s = seasons.first(where: { $0.id == id }) { model.select(season: s) } })
        if seasons.count > 1 {
            Group {
                if seasons.count <= 3 {
                    Picker(Labels.shows, selection: selection) {
                        ForEach(seasons) { season in Text(season.title).tag(season.id) }
                    }
                    .pickerStyle(.segmented)
                } else {
                    Picker(Labels.shows, selection: selection) {
                        ForEach(seasons) { season in Text(season.title).tag(season.id) }
                    }
                    .pickerStyle(.menu)
                }
            }
            .accessibilityIdentifier("show.seasons")
        } else if let only = seasons.first, !only.title.isEmpty {
            Text(only.title).font(.headline)
        }
    }
}

/// One episode: opens its page. Swipe or press and hold to mark or delete it.
struct EpisodeRow: View {
    let recording: Recording
    let model: ShowViewModel
    let requestDelete: (Recording) -> Void

    private var watchTitle: String {
        recording.flags.contains(.watched) ? Labels.markUnwatched : Labels.markWatched
    }

    var body: some View {
        NavigationLink(value: LibraryRoute.episode(recording)) {
            HStack(spacing: 12) {
                Group {
                    if recording.flags.contains(.watched) || recording.flags.contains(.hasResumePosition) {
                        WatchMark(recording: recording)
                    } else {
                        Image(systemName: "circle").foregroundStyle(.secondary).font(.title3)
                    }
                }
                .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Labels.episodeTitle(recording)).font(.body).lineLimit(2)
                    Text(Labels.detailLine(recording)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.vertical, 2)
        }
        .accessibilityLabel(Labels.spokenEpisodeRow(recording))
        .accessibilityIdentifier("episode.\(recording.id.rawValue)")
        .swipeActions(edge: .trailing) {
            Button(Labels.delete, role: .destructive) { requestDelete(recording) }
        }
        .swipeActions(edge: .leading) {
            Button(watchTitle) { model.toggleWatched(recording) }.tint(.green)
        }
        .contextMenu {
            Button(watchTitle) { model.toggleWatched(recording) }
            Button(Labels.delete, role: .destructive) { requestDelete(recording) }
        }
    }
}
