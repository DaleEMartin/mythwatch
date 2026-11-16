import MythwatchDomain
import MythwatchFeatures
import MythwatchPlayback
import SwiftUI

/// SPEC 7 "Episode detail". Makes its model once, when first shown.
struct EpisodePage: View {
    let app: AppModel
    let recording: Recording
    let close: () -> Void
    @State private var model: EpisodeDetailModel?
    @State private var playing: PlayRequest?

    var body: some View {
        Group {
            if let model {
                EpisodeDetailView(
                    model: model, artwork: app.makeArtwork(),
                    askBeforeDelete: { app.savedSettings.askBeforeDelete }, close: close,
                    play: { playing = PlayRequest(start: $0) })
            } else {
                Color.clear  // something must be on screen for onAppear to run
            }
        }
        .onAppear { if model == nil { model = app.makeEpisodeDetailModel(recording) } }
        .fullScreenCover(item: $playing) { request in
            PlayerScreen(app: app, recording: recording, start: request.start, close: finished)
        }
    }

    /// The player closed: write the final state and refresh the library, then this page's start
    /// points (SPEC 7 "Player"; `AppModel.finishPlayback`).
    private func finished(_ session: PlaybackSession) {
        playing = nil
        let model = self.model
        Task {
            await app.finishPlayback(session)
            await model?.load()
        }
    }
}

/// One press of a start button: a fresh identity, so the same start point can be chosen again.
struct PlayRequest: Identifiable {
    let id = UUID()
    let start: StartPoint
}

struct EpisodeDetailView: View {
    let model: EpisodeDetailModel
    let artwork: ArtworkURLs
    let askBeforeDelete: () -> Bool
    let close: () -> Void
    let play: (StartPoint) -> Void

    @State private var confirmingDelete = false

    private var recording: Recording { model.recording }

    var body: some View {
        HStack(alignment: .top, spacing: 70) {
            ArtworkImage(urls: artwork.thumbnail(for: recording, maxWidth: 1280), title: recording.title,
                         aspectRatio: 16.0 / 9.0)
                .frame(width: 720)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            VStack(alignment: .leading, spacing: 20) {
                Text(recording.title).font(.title2).foregroundStyle(.secondary)
                Text(Labels.episodeTitle(recording)).font(.largeTitle).bold()
                    .accessibilityIdentifier("detail.title")
                Text(Labels.detailLine(recording)).foregroundStyle(.secondary)
                Text([Labels.channel(recording), Labels.recorded(recording)].compactMap { $0 }.joined(separator: " · "))
                    .foregroundStyle(.secondary)
                if let synopsis = recording.synopsis, !synopsis.isEmpty {
                    Text(synopsis).lineLimit(6)
                }
                if let problem = model.problem { MessageBanner(message: problem) }
                buttons.padding(.top, 20)
            }
        }
        .padding(80)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail.screen")
        .task { await model.load() }
        .onChange(of: model.isDeleted) { _, deleted in if deleted { close() } }
        .confirmationDialog(
            Labels.deleteQuestion(recording), isPresented: $confirmingDelete, titleVisibility: .visible
        ) {
            Button(Labels.delete, role: .destructive) { model.delete() }
            Button(Labels.cancel, role: .cancel) {}
        } message: {
            Text(Labels.deleteDetail)
        }
    }

    private var buttons: some View {
        HStack(spacing: 30) {
            ForEach(model.startOptions) { option in
                Button(option.title) { play(option.point) }
                    .accessibilityIdentifier("detail.start.\(option.id)")
            }
            if model.isLoading { ProgressView() }
            Button(role: .destructive) {
                if askBeforeDelete() { confirmingDelete = true } else { model.delete() }
            } label: {
                Text(model.isDeleting ? Labels.deleting : Labels.delete)
            }
            .disabled(model.isDeleting)
            .accessibilityIdentifier("detail.delete")
        }
        .focusSection()
    }
}
