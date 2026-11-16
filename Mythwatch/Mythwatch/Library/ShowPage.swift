import MythwatchDomain
import MythwatchFeatures
import SwiftUI

/// SPEC 7 "Show". Makes its model once, when first shown.
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
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 40) {
                header
                seasonPicker
                if let season = model.selectedSeason {
                    VStack(spacing: 16) {
                        ForEach(season.episodes) { episode in
                            EpisodeRow(recording: episode, model: model, requestDelete: requestDelete)
                        }
                    }
                    .focusSection()
                }
            }
            .padding(.horizontal, 80)
            .padding(.bottom, 60)
        }
        .background(alignment: .top) { fanart }
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
            Button(Labels.delete, role: .destructive) { model.delete(recording) }
            Button(Labels.cancel, role: .cancel) {}
        } message: { _ in
            Text(Labels.deleteDetail)
        }
    }

    private func requestDelete(_ recording: Recording) {
        if askBeforeDelete() { pendingDelete = recording } else { model.delete(recording) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.show.title).font(.largeTitle).bold()
                .accessibilityIdentifier("show.title")
            Text(Labels.counts(model.show)).foregroundStyle(.secondary)
        }
        .padding(.top, 120)
    }

    @ViewBuilder private var fanart: some View {
        if let url = artwork.fanart(for: model.show, maxWidth: 1280) {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
                    .frame(height: 500).clipped()
                    .overlay { LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom) }
                    .opacity(0.6)
            } placeholder: { EmptyView() }
            .ignoresSafeArea()
        }
    }

    /// Several seasons: a picker. One named season: its name. A film's season has no name: nothing.
    @ViewBuilder private var seasonPicker: some View {
        let seasons = model.seasons
        if seasons.count > 1 {
            Picker(
                Labels.shows,
                selection: Binding(
                    get: { model.selectedSeason?.id },
                    set: { id in if let s = seasons.first(where: { $0.id == id }) { model.select(season: s) } })
            ) {
                ForEach(seasons) { season in Text(season.title).tag(season.id) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .focusSection()
            .accessibilityIdentifier("show.seasons")
        } else if let only = seasons.first, !only.title.isEmpty {
            Text(only.title).font(.title3).bold()
        }
    }
}

/// One episode: opens its page; the context menu (press and hold) marks or deletes it.
struct EpisodeRow: View {
    let recording: Recording
    let model: ShowViewModel
    let requestDelete: (Recording) -> Void

    var body: some View {
        NavigationLink(value: LibraryRoute.episode(recording)) {
            HStack(spacing: 30) {
                Group {
                    if recording.flags.contains(.watched) || recording.flags.contains(.hasResumePosition) {
                        WatchMark(recording: recording)
                    } else {
                        Image(systemName: "circle").foregroundStyle(.secondary).font(.title3)
                    }
                }
                .frame(width: 44)
                VStack(alignment: .leading, spacing: 6) {
                    Text(Labels.episodeTitle(recording)).font(.headline).lineLimit(1)
                    Text(Labels.detailLine(recording)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            .padding(.vertical, 8)
        }
        .contextMenu {
            Button(recording.flags.contains(.watched) ? Labels.markUnwatched : Labels.markWatched) {
                model.toggleWatched(recording)
            }
            Button(Labels.delete, role: .destructive) { requestDelete(recording) }
        }
        .accessibilityIdentifier("episode.\(recording.id.rawValue)")
    }
}
