import MythwatchDomain
import MythwatchFeatures
import MythwatchPlayback
import SwiftUI

/// SPEC 7 "Episode detail" on a touch screen. Makes its model once, when first shown.
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
            let outcome = await app.finishPlayback(session)
            model?.playbackFinished(outcome)
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
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ArtworkImage(urls: artwork.thumbnail(for: recording, maxWidth: 1280), title: recording.title,
                             aspectRatio: 16.0 / 9.0)
                    .accessibilityHidden(true)
                    .frame(maxWidth: 640)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                Text(recording.title).font(.subheadline).foregroundStyle(.secondary)
                Text(Labels.episodeTitle(recording)).font(.title2).bold()
                    .accessibilityIdentifier("detail.title")
                Text(Labels.detailLine(recording)).font(.subheadline).foregroundStyle(.secondary)
                Text([Labels.channel(recording), Labels.recorded(recording)].compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline).foregroundStyle(.secondary)
                // Try Again only for a failed load (M5-3); a failed delete is retried with Delete.
                if let problem = model.problem {
                    MessageBanner(message: problem, retry: model.canRetryLoad ? { await model.load() } : nil)
                }
                buttons
                if let synopsis = recording.synopsis, !synopsis.isEmpty {
                    Text(synopsis)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail.screen")
        .task { await model.load() }
        .onChange(of: model.isDeleted) { _, deleted in if deleted { close() } }
        // An alert, not a confirmation dialog: on iPhone, iOS 26 draws a confirmation dialog as a
        // popover without its cancel button, and Keep must be visible (SPEC 11 "iPhone screens").
        .alert(
            model.offersDelete ? Labels.finishedQuestion(recording) : Labels.deleteQuestion(recording),
            isPresented: Binding(
                get: { confirmingDelete || model.offersDelete },
                set: { if !$0 { closeDialog() } })
        ) {
            DeleteChoices(cancelTitle: model.offersDelete ? Labels.keep : Labels.cancel) {
                closeDialog()
                model.delete(allowRerecord: $0)
            } cancel: {
                closeDialog()
            }
        } message: {
            Text(DeleteMessage.text(confirming: model.offersDelete || askBeforeDelete()))
        }
    }

    private func closeDialog() {
        confirmingDelete = false
        model.dismissDeleteOffer()
    }

    /// The start points, full width (the first prominent), then Delete.
    private var buttons: some View {
        VStack(spacing: 10) {
            ForEach(Array(model.startOptions.enumerated()), id: \.element.id) { index, option in
                Button { play(option.point) } label: {
                    Label(option.title, systemImage: index == 0 ? "play.fill" : "play")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(index == 0 ? .accentColor : .secondary)
                .controlSize(.large)
                .accessibilityIdentifier("detail.start.\(option.id)")
            }
            if model.isLoading { ProgressView() }
            Button(role: .destructive) {
                confirmingDelete = true  // always: the re-record choice is asked each time
            } label: {
                Text(model.isDeleting ? Labels.deleting : Labels.delete).frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(model.isDeleting)
            .accessibilityIdentifier("detail.delete")
        }
        .frame(maxWidth: 640)
        .padding(.vertical, 6)
    }
}
