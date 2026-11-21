import MythwatchFeatures
import SwiftUI

/// A full-screen problem: the `UserMessage` title and detail, with Try Again when it can help.
struct MessageView: View {
    let message: UserMessage
    var retry: (() async -> Void)?
    /// Adds a Close button (the player's failure screen).
    var close: (() -> Void)?

    var body: some View {
        VStack(spacing: 16) {
            Text(message.title).font(.title3).bold().multilineTextAlignment(.center)
            Text(message.detail)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            if message.canRetry, let retry {
                Button(Labels.tryAgain) { Task { await retry() } }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("message.retry")
            }
            if let close {
                Button(Labels.close, action: close)
                    .accessibilityIdentifier("message.close")
            }
        }
        .padding(32)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("message.screen")
    }
}

/// A message shown inside a screen that keeps its content, with Try Again when the caller passes
/// `retry` (M5-3).
struct MessageBanner: View {
    let message: UserMessage
    var retry: (() async -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(message.title).font(.subheadline).bold()
                    Text(message.detail).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            if let retry {
                Button(Labels.tryAgain) { Task { await retry() } }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("message.banner.retry")
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("message.banner")
    }
}

/// A centred spinner with a caption.
struct LoadingView: View {
    let caption: String
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
