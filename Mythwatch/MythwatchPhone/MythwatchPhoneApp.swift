import AVFoundation
import MythwatchFeatures
import SwiftUI

/// The iPhone and iPad app (SPEC 11). Same composition root and models as the tvOS app; its own
/// touch views.
@main
struct MythwatchPhoneApp: App {
    @State private var app = Composition.makeAppModel()

    init() {
        // Recordings are video with sound: play it with the ring/silent switch on silent, as
        // video apps do (M6-2). A failure only means the system default (muted on silent).
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    }

    var body: some Scene {
        WindowGroup {
            PhoneRootView(app: app)
        }
    }
}
