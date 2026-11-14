import Foundation
import MythwatchBackend
import MythwatchDomain

/// Builds media URLs under the connection's base URL. Never fetches anything.
struct V35MediaLocator: MediaLocator {
    /// Image widths the backend is asked for. Each distinct width makes the backend write a cached
    /// copy next to the original, so requests are rounded up to one of these; anything larger than
    /// the last gets the last (docs/BACKEND-V35.md, "Media URLs").
    static let widths = [160, 320, 640, 1280]

    private let baseURL: URL

    init(connection: BackendConnection) {
        self.baseURL = connection.baseURL
    }

    static func roundedWidth(_ requested: Int) -> Int {
        widths.first { $0 >= requested } ?? widths[widths.count - 1]
    }

    func streamURL(for recording: Recording) -> URL {
        url(path: "/Content/GetRecording", id: recording.id)
    }

    func previewImageURL(for recording: Recording, maxWidth: Int) -> URL {
        url(
            path: "/Content/GetPreviewImage", id: recording.id,
            extra: "&Width=\(Self.roundedWidth(maxWidth))")
    }

    /// The locator is a server-relative path that may already carry percent-escapes (`%2F`,
    /// `%20`); it is used verbatim, never re-encoded. nil when it is not such a path.
    func artworkURL(for reference: ArtworkReference, maxWidth: Int) -> URL? {
        let locator = reference.locator
        guard locator.hasPrefix("/"), !locator.hasPrefix("//"),
            locator.allSatisfy({ $0.isASCII && !$0.isWhitespace })
        else { return nil }
        let separator = locator.contains("?") ? "&" : "?"
        let text =
            V35Client.absoluteString(base: baseURL, path: locator) + separator
            + "Width=\(Self.roundedWidth(maxWidth))"
        return URL(string: text)
    }

    private func url(path: String, id: RecordingID, extra: String = "") -> URL {
        let text =
            V35Client.absoluteString(base: baseURL, path: path) + "?RecordedId=\(id.rawValue)" + extra
        return URL(string: text) ?? baseURL
    }
}
