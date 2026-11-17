import MythwatchDomain
import MythwatchFeatures
import MythwatchPlayback
import Observation
import SwiftUI

/// SPEC 7 "Player": full-screen video with our transport overlay. Makes its session when it
/// appears and starts it. Leaving hands the session to `close`, which must finish it
/// (`AppModel.finishPlayback`); Try Again replaces it with a new one that resumes.
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
                PlayerContent(transport: transport, nowPlaying: nowPlaying, leave: leave, retry: retry)
                    .id(ObjectIdentifier(transport))
            }
        }
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
    let leave: () -> Void
    let retry: () -> Void

    var body: some View {
        ZStack {
            VideoSurface(engine: transport.session.engine).ignoresSafeArea()
            if let failure = transport.failure {
                MessageView(message: failure, retry: { retry() }, close: leave)
                    .background(.black.opacity(0.7))
                    .onExitCommand(perform: leave)
            } else {
                if transport.panel == nil {
                    RemoteInputView(input: input).ignoresSafeArea()
                }
                if transport.isWaiting { ProgressView().controlSize(.large) }
                VStack {
                    if transport.panel != nil {
                        PlayerPanel(transport: transport)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    Spacer()
                    if let banner = transport.commercialBanner {
                        CommercialBannerView(banner: banner)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .padding(.horizontal, 80)
                            .padding(.bottom, transport.controlsVisible ? 0 : 60)
                            .transition(.opacity)
                    }
                    if transport.controlsVisible {
                        TransportBar(transport: transport)
                            .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.25), value: transport.controlsVisible)
                .animation(.easeInOut(duration: 0.25), value: transport.panel)
                .animation(.easeInOut(duration: 0.25), value: transport.commercialBanner)
            }
        }
        // Every snapshot change, from the one on screen at appear: `Observations` gives the latest
        // value once per transaction. `onChange` is not used: it drops changes when several land in
        // one frame (SwiftUI: "tried to update multiple times per frame"), and a missed `.playing`
        // left the controls up for good.
        .task {
            for await _ in Observations({ transport.session.snapshot }) {
                transport.tick()
                nowPlaying.update()
            }
        }
        .onChange(of: transport.hasEnded) { _, ended in if ended { leave() } }
        // The model has no timer: wake it when the controls are due to hide.
        .task(id: transport.hideAt) {
            guard let at = transport.hideAt else { return }
            try? await Task.sleep(until: at, clock: .continuous)
            if !Task.isCancelled { transport.tick() }
        }
        // Nor for the skipped banner: wake it when the undo window ends, even while paused.
        .task(id: transport.bannerHidesAt) {
            guard let at = transport.bannerHidesAt else { return }
            try? await Task.sleep(until: at, clock: .continuous)
            if !Task.isCancelled { transport.tick() }
        }
    }

    private var input: RemoteInput {
        RemoteInput(
            select: { transport.select() },
            playPause: { transport.playPause() },
            left: { transport.skipBackward() },
            right: { transport.skipForward() },
            menu: { if transport.back() == .leave { leave() } },
            swipe: { transport.scrub(by: $0) },
            swipeDown: { transport.openPanel() },
            touch: { transport.showControls() })
    }
}

/// Elapsed and remaining time, the scrubber, and the title, along the bottom.
private struct TransportBar: View {
    let transport: TransportModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let notice = transport.notice {
                Label(notice, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .padding(.horizontal, 20).padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .accessibilityIdentifier("player.notice")
            }
            Text(transport.recording.title).font(.headline)
            if Labels.episodeTitle(transport.recording) != transport.recording.title {
                Text(Labels.episodeTitle(transport.recording)).font(.callout).foregroundStyle(.secondary)
            }
            Scrubber(progress: transport.progress, breaks: transport.breakSegments, scrubbing: transport.scrubPosition != nil)
                .frame(height: 12)
            HStack {
                Text(transport.elapsedText).accessibilityIdentifier("player.elapsed")
                Spacer()
                if let remaining = transport.remainingText {
                    Text(remaining).accessibilityIdentifier("player.remaining")
                }
            }
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 80)
        .padding(.top, 120)
        .padding(.bottom, 50)
        // Dark enough to read over a busy picture or the programme's own captions.
        .background(
            LinearGradient(
                stops: [.init(color: .clear, location: 0), .init(color: .black.opacity(0.75), location: 0.35),
                        .init(color: .black.opacity(0.9), location: 1)],
                startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player.transport")
    }
}

/// The commercial banner (M4-3), drawn as a focused button: Select acts on it (SPEC 7 "Player
/// controls"). The remote's input view keeps the real focus, so this is not a `Button`.
private struct CommercialBannerView: View {
    let banner: TransportModel.CommercialBanner

    var body: some View {
        HStack(spacing: 24) {
            switch banner {
            case .skipped(let distance):
                Text(Labels.skippedCommercials(distance))
                    .font(.callout)
                    .padding(.horizontal, 24).padding(.vertical, 14)
                    .background(.regularMaterial, in: Capsule())
                    .accessibilityIdentifier("player.banner.skippedText")
                pill(Labels.goBack, systemImage: "gobackward")
                    .accessibilityIdentifier("player.banner.goBack")
            case .offer:
                pill(Labels.skipCommercials, systemImage: "forward.end.fill")
                    .accessibilityIdentifier("player.banner.skip")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player.banner")
    }

    private func pill(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.callout.weight(.semibold))
            .foregroundStyle(.black)
            .padding(.horizontal, 32).padding(.vertical, 14)
            .background(.white, in: Capsule())
            .shadow(color: .black.opacity(0.4), radius: 12, y: 6)
            .scaleEffect(1.05)
    }
}

/// The progress line, with commercial breaks marked and a playhead that grows while scrubbing.
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
                        .frame(width: max(4, geo.size.width * (segment.upperBound - segment.lowerBound)))
                        .offset(x: geo.size.width * segment.lowerBound)
                }
                if progress != nil {
                    Circle().fill(.white)
                        .frame(width: scrubbing ? 32 : 18, height: scrubbing ? 32 : 18)
                        .offset(x: x - (scrubbing ? 16 : 9))
                }
            }
            .frame(maxHeight: .infinity)
        }
    }
}

/// The panel a swipe down opens: Info, Audio, Subtitles.
private struct PlayerPanel: View {
    let transport: TransportModel

    @FocusState private var tabsFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            Picker(Labels.info, selection: Binding(get: { transport.panel ?? .info }, set: { transport.openPanel($0) })) {
                ForEach(TransportModel.Panel.allCases) { tab in Text(Labels.panelTab(tab)).tag(tab) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .focused($tabsFocused)
            .accessibilityIdentifier("player.panel.tabs")
            // Full width too, so a swipe up from a button at the far right reaches the tabs.
            .frame(maxWidth: .infinity, alignment: .leading)
            .focusSection()
            // A focus section across the panel's width, so a swipe down from the tabs reaches a
            // button anywhere in it (Set Bookmark Here sits at the far right), and back up.
            Group {
                switch transport.panel ?? .info {
                case .info: info
                case .audio: audio
                case .subtitles: subtitles
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .focusSection()
        }
        .padding(50)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The panel opens with the tabs focused, not the first button.
        .defaultFocus($tabsFocused, true)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
        .padding(.horizontal, 80)
        .padding(.top, 50)
        .focusSection()
        .onExitCommand { transport.closePanel() }
        .background(SwipeUpCatcher(armed: tabsFocused, swipedUp: { transport.closePanel() }))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player.panel")
    }

    private var recording: Recording { transport.recording }

    private var info: some View {
        HStack(alignment: .top, spacing: 50) {
            VStack(alignment: .leading, spacing: 10) {
                Text(Labels.episodeTitle(recording)).font(.title3).bold()
                Text(Labels.detailLine(recording)).foregroundStyle(.secondary)
                Text([Labels.channel(recording), Labels.recorded(recording)].compactMap { $0 }.joined(separator: " · "))
                    .foregroundStyle(.secondary)
                if let synopsis = recording.synopsis, !synopsis.isEmpty {
                    Text(synopsis).lineLimit(4)
                }
            }
            Spacer()
            Button(Labels.setBookmark) { Task { await transport.setBookmark() } }
                .accessibilityIdentifier("player.bookmark")
        }
    }

    private var audio: some View {
        TrackList(
            tracks: transport.audioTracks.map { ($0.id, Labels.trackName($0)) },
            selected: transport.selectedAudioTrack, offTitle: nil, empty: Labels.noAudioTracks,
            choose: { transport.selectAudioTrack($0) })
    }

    private var subtitles: some View {
        TrackList(
            tracks: transport.subtitleTracks.map { ($0.id, Labels.trackName($0)) },
            selected: transport.selectedSubtitleTrack, offTitle: Labels.subtitlesOff, empty: Labels.noSubtitles,
            choose: { transport.selectSubtitleTrack($0) })
    }
}

/// A row of track buttons with a check on the chosen one; `offTitle` adds an Off choice (nil).
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
            HStack(spacing: 30) {
                if let offTitle { button(offTitle, id: nil) }
                ForEach(tracks, id: \.id) { track in button(track.name, id: track.id) }
            }
        }
    }

    private func button(_ title: String, id: Int?) -> some View {
        Button { choose(id) } label: {
            HStack(spacing: 12) {
                Image(systemName: "checkmark").opacity(selected == id ? 1 : 0)
                Text(title)
            }
        }
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

/// Closes the panel on a swipe up that starts while the tabs are focused, as in Apple's TV app.
/// Focus alone cannot do it: nothing is above the tabs, so a swipe up there moves nothing and
/// SwiftUI reports nothing. This watches the touch surface itself, through a pan recognizer on
/// the window (indirect touches reach the window whatever is focused). It only watches; it never
/// takes touches from the focus engine. It exists only while the panel is open.
private struct SwipeUpCatcher: UIViewRepresentable {
    let armed: Bool
    let swipedUp: () -> Void

    func makeUIView(context: Context) -> SwipeUpCatcherView {
        let view = SwipeUpCatcherView()
        view.isUserInteractionEnabled = false
        updateUIView(view, context: context)
        return view
    }

    func updateUIView(_ view: SwipeUpCatcherView, context: Context) {
        view.armedNow = armed
        view.swipedUp = swipedUp
    }

    static func dismantleUIView(_ view: SwipeUpCatcherView, coordinator: ()) { view.detach() }
}

final class SwipeUpCatcherView: UIView, UIGestureRecognizerDelegate {
    /// Whether the tabs are focused now; read when a swipe starts.
    var armedNow = false
    var swipedUp: () -> Void = {}
    /// The swipe must go this share of the surface's height, mostly straight up.
    private let upShare: CGFloat = 0.25
    private var armed = false
    private var fired = false

    private lazy var pan: UIPanGestureRecognizer = {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        pan.cancelsTouchesInView = false
        pan.delaysTouchesBegan = false
        pan.delaysTouchesEnded = false
        pan.delegate = self
        return pan
    }()

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if let window { window.addGestureRecognizer(pan) } else { detach() }
    }

    func detach() { pan.view?.removeGestureRecognizer(pan) }

    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began:
            armed = armedNow
            fired = false
        case .changed:
            guard armed, !fired, let surface = pan.view else { return }
            let t = pan.translation(in: surface)
            if -t.y >= surface.bounds.height * upShare, -t.y > 2 * abs(t.x) {
                fired = true
                swipedUp()
            }
        default:
            armed = false
        }
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool { true }
}
