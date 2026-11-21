import MythwatchBackend
import MythwatchFeatures
import SwiftUI

/// M6-1 placeholder: connects at launch and says how it went. M6-3 replaces it with the
/// onboarding and the tabs (SPEC 11).
struct PhoneRootView: View {
    let app: AppModel

    var body: some View {
        VStack(spacing: 16) {
            Text("Mythwatch").font(.largeTitle).bold()
            switch app.session {
            case .idle:
                Text("Not connected")
            case .loading:
                ProgressView()
            case .loaded(let session):
                Text("Connected to \(session.info.hostName ?? "the backend")")
                    .accessibilityIdentifier("phone.connected")
            case .failed(let message):
                Text(message.title)
            }
        }
        .padding()
        .task { await app.connect() }
    }
}
