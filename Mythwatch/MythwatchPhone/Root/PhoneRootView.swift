import MythwatchFeatures
import SwiftUI

/// SPEC 7 "Root", for iPhone and iPad (SPEC 11): Onboarding when no backend is saved, otherwise
/// the tabs. Same rules as the tvOS root: the decision comes from the saved settings, and
/// Onboarding stays until its connect has succeeded.
struct PhoneRootView: View {
    let app: AppModel
    @State private var onboarding: OnboardingViewModel?
    @Environment(\.scenePhase) private var scenePhase

    private var needsSetup: Bool { app.session.isIdle && app.savedSettings.backend == nil }

    var body: some View {
        Group {
            if let onboarding {
                OnboardingView(model: onboarding)
            } else if needsSetup {
                Color.clear
            } else {
                MainTabs(app: app)
            }
        }
        .onChange(of: needsSetup, initial: true) { _, needs in
            if needs && onboarding == nil { onboarding = app.makeOnboardingModel() }
        }
        .onChange(of: onboarding?.connectState.value != nil) { _, connected in
            if connected { onboarding = nil }
        }
        .task { await app.connect() }
        // Back from the background: a failed connection is tried again (M5-3).
        .onChange(of: scenePhase) { old, new in
            if old == .background && new == .active { Task { await app.returnedToForeground() } }
        }
    }
}

/// The tabs. Live TV and Videos join them when an adapter offers them (SPEC 10).
struct MainTabs: View {
    let app: AppModel

    var body: some View {
        TabView {
            Tab(Labels.recordings, systemImage: "film.stack") { RecordingsTab(app: app) }
            Tab(Labels.settings, systemImage: "gearshape") { SettingsTab(app: app) }
        }
    }
}
