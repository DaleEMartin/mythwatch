import MythwatchDomain
import MythwatchFeatures
import SwiftUI

/// Where the Recordings tab can go.
enum LibraryRoute: Hashable {
    case show(Show)
    case episode(Recording)
}

/// The Recordings tab: the connection's state, then the library and its pages.
struct RecordingsTab: View {
    let app: AppModel

    var body: some View {
        switch app.session {
        case .idle, .loading:
            LoadingView(caption: Labels.connecting)
        case .failed(let message):
            MessageView(message: message, retry: { await app.connect() })
        case .loaded(let session):
            // A new session (another backend, or a reconnect) gets a fresh library and stack.
            LibraryStack(app: app).id(session.id)
        }
    }
}

/// The navigation stack of the Recordings tab. It owns the path, so a page that has to close
/// (deleted episode, emptied show) is removed with everything above it.
struct LibraryStack: View {
    let app: AppModel
    @State private var library: LibraryViewModel?
    @State private var path: [LibraryRoute] = []
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let library {
                    LibraryView(model: library, artwork: app.makeArtwork())
                } else {
                    Color.clear
                }
            }
            .navigationDestination(for: LibraryRoute.self) { route in
                switch route {
                case .show(let show):
                    ShowPage(app: app, show: show, close: { close(route) })
                case .episode(let recording):
                    EpisodePage(app: app, recording: recording, close: { close(route) })
                }
            }
        }
        .onAppear {
            if library == nil { library = app.makeLibraryModel() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, let library { Task { await library.refresh() } }
        }
    }

    private func close(_ route: LibraryRoute) {
        if let index = path.firstIndex(of: route) { path.removeSubrange(index...) }
    }
}
