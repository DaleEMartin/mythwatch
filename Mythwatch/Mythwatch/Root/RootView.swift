import MythwatchFeatures
import SwiftUI

/// SPEC 7 "Root". Onboarding when no backend is saved, otherwise the tabs.
///
/// The decision comes from the saved settings, not from `session == .idle` (which only means
/// "not connected and not connecting"). Once Onboarding is up, it and its model stay until the
/// connect has succeeded: a failed connect has already saved the address (SPEC 6.4 "Onboarding
/// rules"), and the screen must not be rebuilt when settings change.
struct RootView: View {
    let app: AppModel
    @State private var onboarding: OnboardingViewModel?

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
    }
}

/// The tabs. Live TV and Videos join them when an adapter offers them (SPEC 10); none does yet.
struct MainTabs: View {
    let app: AppModel

    var body: some View {
        TabView {
            Tab(Labels.recordings, systemImage: "film.stack") { RecordingsTab(app: app) }
            Tab(Labels.settings, systemImage: "gearshape") { SettingsTab(app: app) }
        }
    }
}
