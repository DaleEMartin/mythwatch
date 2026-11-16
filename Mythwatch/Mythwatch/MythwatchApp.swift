import MythwatchFeatures
import SwiftUI

@main
struct MythwatchApp: App {
    @State private var app = Composition.makeAppModel()

    var body: some Scene {
        WindowGroup {
            RootView(app: app)
        }
    }
}
