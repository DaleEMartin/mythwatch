import MythwatchDomain
import MythwatchFeatures
import MythwatchPlayback
import Observation
import SwiftUI

/// SPEC 7 "Player" for touch (SPEC 11, M6-4): full-screen video with our controls over it. Makes
/// its session when it appears and starts it. Leaving hands the session to `close`, which must
/// finish it (`AppModel.finishPlayback`); Try Again replaces it with a new one that resumes.
struct PlayerScreen: View {
    let app: AppModel
    let recording: Recording
    let start: StartPoint
    let close: (PlaybackSession) -> Void

    @State private var transport: TransportModel?
    @State private var nowPlaying = NowPlaying()
    @State private var closed = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let transport {
                let settings = app.savedSettings
                PlayerContent(
                    transport: transport, nowPlaying: nowPlaying,
                    skipForwardSeconds: settings.skipForwardSeconds,
                    skipBackwardSeconds: settings.skipBackwardSeconds,
                    leave: leave, retry: retry)
                    .id(ObjectIdentifier(transport))
            }
        }
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player.screen")
        .onAppear {
            guard transport == nil else { return }
            begin(app.makePlaybackSession(recording, start: start))
        }
        // However the screen goes, the session is finished (leave() runs once).
        .onDisappear { leave() }
    }

    private func begin(_ session: PlaybackSession) {
        let model = TransportModel(session: session, recording: recording, now: { ContinuousClock.now })
        transport = model
        let settings = app.savedSettings
        nowPlaying.attach(model, skipForward: settings.skipForwardSeconds, skipBackward: settings.skipBackwardSeconds)
        Task { await session.start() }
    }

    private func leave() {
        guard !closed, let transport else { return }
        closed = true
        nowPlaying.detach()
        close(transport.session)
    }

    private func retry() {
        guard let failed = transport?.session else { return }
        Task { begin(await app.retryPlayback(failed, recording: recording)) }
    }
}

/// One session's picture and controls.
private struct PlayerContent: View {
    let transport: TransportModel
    let nowPlaying: NowPlaying
    let skipForwardSeconds: Int
    let skipBackwardSeconds: Int
    let leave: () -> Void
    let retry: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            VideoSurface(engine: transport.session.engine).ignoresSafeArea().accessibilityHidden(true)
            // The picture takes the taps: show or hide the controls (SPEC 6.4 "Touch").
            Rectangle().fill(.clear)
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture { transport.toggleControls() }
                .accessibilityElement()
                .accessibilityLabel(Labels.video)
                .accessibilityIdentifier("player.surface")
            if let failure = transport.failure {
                MessageView(message: failure, retry: failure.canRetry ? { retry() } : nil, close: leave)
                    .background(.black)
            } else {
                if transport.isWaiting { ProgressView().controlSize(.large).tint(.white) }
                if transport.controlsVisible { controls.transition(.opacity) }
                VStack {
                    Spacer()
                    if let banner = transport.commercialBanner {
                        CommercialBannerView(banner: banner, transport: transport)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .padding(.horizontal)
                            .padding(.bottom, transport.controlsVisible ? 110 : 24)
                            .transition(.opacity)
                    }
                }
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: transport.controlsVisible)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: transport.commercialBanner)
        .statusBarHidden(!transport.controlsVisible)
        .persistentSystemOverlays(transport.controlsVisible ? .automatic : .hidden)
        .sheet(isPresented: Binding(
            get: { transport.panel != nil }, set: { if !$0 { transport.closePanel() } })
        ) {
            PlayerSheet(transport: transport)
                .presentationDetents([.medium, .large])
        }
        // Every snapshot change, as on tvOS (`onChange` drops changes that land in one frame).
        .task {
            for await _ in Observations({ transport.session.snapshot }) {
                transport.tick()
                nowPlaying.update()
            }
        }
        .onChange(of: transport.hasEnded) { _, ended in if ended { leave() } }
        // Locked or sent to the background: pause, which saves the place (SPEC 6.4).
        .onChange(of: scenePhase) { _, phase in if phase == .background { transport.leftForeground() } }
        // The model has no timer: wake it when the controls are due to hide, ...
        .task(id: transport.hideAt) {
            guard let at = transport.hideAt else { return }
            try? await Task.sleep(until: at, clock: .continuous)
            if !Task.isCancelled { transport.tick() }
        }
        // ... when a paused scrub has rested long enough, ...
        .task(id: transport.scrubPreviewAt) {
            guard let at = transport.scrubPreviewAt else { return }
            try? await Task.sleep(until: at, clock: .continuous)
            if !Task.isCancelled { transport.tick() }
        }
        // ... and when the skipped banner's undo window ends, even while paused.
        .task(id: transport.bannerHidesAt) {
            guard let at = transport.bannerHidesAt else { return }
            try? await Task.sleep(until: at, clock: .continuous)
            if !Task.isCancelled { transport.tick() }
        }
    }

    /// Close and the title at the top, play / pause and the skips in the middle, the scrubber
    /// and times at the bottom, over a dimmed picture.
    private var controls: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea().allowsHitTesting(false)
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 12) {
                    iconButton("xmark", label: Labels.close, id: "player.close", action: leave)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(transport.recording.title).font(.headline).lineLimit(1)
                        if Labels.episodeTitle(transport.recording) != transport.recording.title {
                            Text(Labels.episodeTitle(transport.recording))
                                .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer()
                    iconButton("ellipsis", label: Labels.infoAndTracks, id: "player.more") { transport.openPanel() }
                }
                .padding(.horizontal)
                .padding(.top, 8)
                if let notice = transport.notice {
                    Label(notice, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.top, 8)
                        .accessibilityIdentifier("player.notice")
                }
                Spacer()
                HStack(spacing: 48) {
                    iconButton(skipSymbol("gobackward", skipBackwardSeconds), label: Labels.skipBack(seconds: skipBackwardSeconds),
                               id: "player.skipBackward", size: 30) { transport.skipBackward() }
                    iconButton(transport.isPlaying ? "pause.fill" : "play.fill",
                               label: transport.isPlaying ? Labels.pause : Labels.play,
                               id: "player.playPause", size: 44) { transport.playPause() }
                    iconButton(skipSymbol("goforward", skipForwardSeconds), label: Labels.skipForward(seconds: skipForwardSeconds),
                               id: "player.skipForward", size: 30) { transport.skipForward() }
                }
                Spacer()
                TimeBar(transport: transport)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }
        }
        .foregroundStyle(.white)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player.transport")
    }

    /// SF Symbols has numbered skip arrows for the common steps only.
    private func skipSymbol(_ base: String, _ seconds: Int) -> String {
        [5, 10, 15, 30, 45, 60, 75, 90].contains(seconds) ? "\(base).\(seconds)" : base
    }

    private func iconButton(
        _ symbol: String, label: String, id: String, size: CGFloat = 20, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }
}

/// The scrubber with elapsed and remaining time. Dragging scrubs to the finger's place on the
/// line (`scrub(to:)`); lifting the finger commits.
private struct TimeBar: View {
    let transport: TransportModel

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                Scrubber(progress: transport.progress, breaks: transport.breakSegments,
                         scrubbing: transport.scrubPosition != nil)
                    .frame(height: 6)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard let duration = transport.duration, geo.size.width > 0 else { return }
                                let share = min(max(value.location.x / geo.size.width, 0), 1)
                                transport.scrub(to: duration * share)
                            }
                            .onEnded { _ in transport.commitScrub() })
            }
            .frame(height: 32)
            .accessibilityElement()
            .accessibilityLabel(Labels.position)
            .accessibilityValue(Labels.spokenPosition(transport.elapsedText, of: transport.duration))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: transport.skipForward()
                case .decrement: transport.skipBackward()
                @unknown default: break
                }
            }
            .accessibilityIdentifier("player.scrubber")
            HStack {
                Text(transport.elapsedText).accessibilityIdentifier("player.elapsed")
                Spacer()
                if let remaining = transport.remainingText {
                    Text(remaining).accessibilityIdentifier("player.remaining")
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.8))
        }
    }
}

/// The progress line, with commercial breaks marked and a thumb that grows while scrubbing.
private struct Scrubber: View {
    let progress: Double?
    let breaks: [ClosedRange<Double>]
    let scrubbing: Bool

    var body: some View {
        GeometryReader { geo in
            let x = geo.size.width * (progress ?? 0)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.3))
                Capsule().fill(.white).frame(width: max(0, x))
                ForEach(Array(breaks.enumerated()), id: \.offset) { _, segment in
                    Rectangle().fill(.yellow.opacity(0.85))
                        .frame(width: max(3, geo.size.width * (segment.upperBound - segment.lowerBound)))
                        .offset(x: geo.size.width * segment.lowerBound)
                }
                if progress != nil {
                    let d: CGFloat = scrubbing ? 24 : 14
                    Circle().fill(.white)
                        .frame(width: d, height: d)
                        .offset(x: x - d / 2)
                }
            }
            .frame(maxHeight: .infinity)
        }
    }
}

/// The commercial banner (M4-3) as real buttons: Go Back after a skip, Skip Commercials when one
/// is offered.
private struct CommercialBannerView: View {
    let banner: TransportModel.CommercialBanner
    let transport: TransportModel

    var body: some View {
        HStack(spacing: 10) {
            switch banner {
            case .skipped(let distance):
                Text(Labels.skippedCommercials(distance))
                    .font(.footnote)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .accessibilityIdentifier("player.banner.skippedText")
                pill(Labels.goBack, systemImage: "gobackward", id: "player.banner.goBack") { transport.goBack() }
            case .offer:
                pill(Labels.skipCommercials, systemImage: "forward.end.fill", id: "player.banner.skip") {
                    transport.skipCommercials()
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player.banner")
    }

    private func pill(_ title: String, systemImage: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.black)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(.white, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }
}

/// The tvOS panel as a sheet: Info (with Set Bookmark Here), Audio, Subtitles.
private struct PlayerSheet: View {
    let transport: TransportModel

    private var recording: Recording { transport.recording }

    var body: some View {
        NavigationStack {
            List {
                Picker(Labels.info, selection: Binding(get: { transport.panel ?? .info }, set: { transport.openPanel($0) })) {
                    ForEach(TransportModel.Panel.allCases) { tab in Text(Labels.panelTab(tab)).tag(tab) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .accessibilityIdentifier("player.panel.tabs")
                switch transport.panel ?? .info {
                case .info: info
                case .audio:
                    TrackList(
                        tracks: transport.audioTracks.map { ($0.id, Labels.trackName($0)) },
                        selected: transport.selectedAudioTrack, offTitle: nil, empty: Labels.noAudioTracks,
                        choose: { transport.selectAudioTrack($0) })
                case .subtitles:
                    TrackList(
                        tracks: transport.subtitleTracks.map { ($0.id, Labels.trackName($0)) },
                        selected: transport.selectedSubtitleTrack, offTitle: Labels.subtitlesOff,
                        empty: Labels.noSubtitles, choose: { transport.selectSubtitleTrack($0) })
                }
            }
            .navigationTitle(Labels.episodeTitle(recording))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(Labels.done) { transport.closePanel() }
                        .accessibilityIdentifier("player.panel.done")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player.panel")
    }

    @ViewBuilder private var info: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(Labels.detailLine(recording)).foregroundStyle(.secondary)
                Text([Labels.channel(recording), Labels.recorded(recording)].compactMap { $0 }.joined(separator: " · "))
                    .foregroundStyle(.secondary)
                if let synopsis = recording.synopsis, !synopsis.isEmpty { Text(synopsis) }
            }
            .font(.subheadline)
        }
        Section {
            Button(Labels.setBookmark) { Task { await transport.setBookmark() } }
                .accessibilityIdentifier("player.bookmark")
        }
    }
}

/// Track rows with a check on the chosen one; `offTitle` adds an Off choice (nil).
private struct TrackList: View {
    let tracks: [(id: Int, name: String)]
    let selected: Int?
    let offTitle: String?
    let empty: String
    let choose: (Int?) -> Void

    var body: some View {
        if tracks.isEmpty {
            Text(empty).foregroundStyle(.secondary)
        } else {
            Section {
                if let offTitle { row(offTitle, id: nil) }
                ForEach(tracks, id: \.id) { track in row(track.name, id: track.id) }
            }
        }
    }

    private func row(_ title: String, id: Int?) -> some View {
        Button { choose(id) } label: {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                if selected == id { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
        }
        .accessibilityAddTraits(selected == id ? .isSelected : [])
        .accessibilityIdentifier("player.track.\(id.map(String.init) ?? "off")")
    }
}

/// Hosts the engine's picture. Only `VLCPlayerEngine` has one; with the fakes the screen is black.
private struct VideoSurface: UIViewRepresentable {
    let engine: any PlayerEngine

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        container.isUserInteractionEnabled = false
        if let video = (engine as? VLCPlayerEngine)?.videoView {
            video.frame = container.bounds
            video.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            container.addSubview(video)
        }
        return container
    }

    func updateUIView(_ view: UIView, context: Context) {}
}
