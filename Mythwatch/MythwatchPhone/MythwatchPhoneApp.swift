import MythwatchFeatures
import SwiftUI

/// The iPhone and iPad app (SPEC 11). Same composition root and models as the tvOS app; its own
/// touch views.
@main
struct MythwatchPhoneApp: App {
    @State private var app = Composition.makeAppModel()

    var body: some Scene {
        WindowGroup {
            PhoneRootView(app: app)
        }
    }
}
