import Foundation
import MythwatchDomain

/// Which image URLs a screen tries, in order, before it draws its titled placeholder (SPEC 6.4
/// "Artwork"). Pure: it only asks the session's `MediaLocator` for URLs and sends nothing.
public struct ArtworkURLs: Sendable {
    private let media: any MediaLocator

    public init(media: any MediaLocator) { self.media = media }

    /// A show's poster: its poster artwork, then the newest recording's preview image.
    public func poster(for show: Show, maxWidth: Int) -> [URL] {
        var urls: [URL] = []
        if let poster = show.poster, let url = media.artworkURL(for: poster, maxWidth: maxWidth) {
            urls.append(url)
        }
        if let newest = show.recordings.first {
            urls.append(media.previewImageURL(for: newest, maxWidth: maxWidth))
        }
        return urls
    }

    /// A recording's poster: its own poster artwork, then its preview image.
    public func poster(for recording: Recording, maxWidth: Int) -> [URL] {
        var urls: [URL] = []
        if let poster = recording.artwork.first(where: { $0.kind == .poster }),
            let url = media.artworkURL(for: poster, maxWidth: maxWidth)
        {
            urls.append(url)
        }
        urls.append(media.previewImageURL(for: recording, maxWidth: maxWidth))
        return urls
    }

    /// A show page's header: the first fanart of the newest recording that has one, else nil.
    public func fanart(for show: Show, maxWidth: Int) -> URL? {
        for recording in show.recordings {
            if let fanart = recording.artwork.first(where: { $0.kind == .fanart }) {
                return media.artworkURL(for: fanart, maxWidth: maxWidth)
            }
        }
        return nil
    }

    /// A landscape recording card: the recording's preview image.
    public func thumbnail(for recording: Recording, maxWidth: Int) -> [URL] {
        [media.previewImageURL(for: recording, maxWidth: maxWidth)]
    }
}
