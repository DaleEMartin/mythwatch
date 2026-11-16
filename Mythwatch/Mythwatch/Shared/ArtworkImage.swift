import SwiftUI

/// An image that tries each URL in turn and falls back to a titled placeholder (SPEC 7, M2-7).
/// The URLs come from `ArtworkURLs`; this view only loads them.
struct ArtworkImage: View {
    let urls: [URL]
    let title: String
    var aspectRatio: CGFloat = 2.0 / 3.0

    @State private var attempt = 0

    var body: some View {
        Color.clear
            .aspectRatio(aspectRatio, contentMode: .fit)
            .overlay {
                ZStack {
                    TitledPlaceholder(title: title)
                    if attempt < urls.count {
                        AsyncImage(url: urls[attempt]) { phase in
                            switch phase {
                            case .success(let image):
                                image.resizable().scaledToFill()
                            case .failure:
                                Color.clear.onAppear { attempt += 1 }
                            default:
                                Color.clear
                            }
                        }
                        .id(attempt)
                    }
                }
            }
            .clipped()
            .onChange(of: urls) { attempt = 0 }
    }
}

/// The fallback when no image loads: the title on a quiet background.
struct TitledPlaceholder: View {
    let title: String

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(16)
        }
    }
}
