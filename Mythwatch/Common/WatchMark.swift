import MythwatchDomain
import SwiftUI

/// Watched: a check. Part watched: a half circle. Otherwise nothing.
struct WatchMark: View {
    let recording: Recording

    var body: some View {
        if recording.flags.contains(.watched) {
            Image(systemName: "checkmark.circle.fill")
                .symbolRenderingMode(.palette).foregroundStyle(.white, .green)
                .font(.title3)
                .accessibilityLabel(Labels.watched)
        } else if recording.flags.contains(.hasResumePosition) {
            Image(systemName: "circle.lefthalf.filled")
                .foregroundStyle(.white).font(.title3)
                .accessibilityLabel(Labels.partWatched)
        }
    }
}
