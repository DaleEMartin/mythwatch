import MythwatchFeatures
import SwiftUI

/// A full-screen problem: the `UserMessage` title and detail, with Try Again when it can help.
struct MessageView: View {
    let message: UserMessage
    var retry: (() async -> Void)?
    /// Adds a Close button (the player's failure screen).
    var close: (() -> Void)?

    var body: some View {
        VStack(spacing: 30) {
            Text(message.title).font(.title2).bold()
            Text(message.detail)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 1000)
            if message.canRetry, let retry {
                Button(Labels.tryAgain) { Task { await retry() } }
                    .accessibilityIdentifier("message.retry")
            }
            if let close {
                Button(Labels.close, action: close)
                    .accessibilityIdentifier("message.close")
            }
        }
        .padding(60)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("message.screen")
    }
}

/// A message shown inside a screen that keeps its content: a banner line.
struct MessageBanner: View {
    let message: UserMessage

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 6) {
                Text(message.title).font(.headline)
                Text(message.detail).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("message.banner")
    }
}

/// A centred spinner with a caption.
struct LoadingView: View {
    let caption: String
    var body: some View {
        VStack(spacing: 24) {
            ProgressView()
            Text(caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
