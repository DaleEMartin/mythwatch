import Foundation

/// What the player is doing (SPEC 5).
public enum PlayerStatus: Sendable, Equatable {
    case idle, loading, playing, paused, buffering, ended
    case failed(String)
}

/// One reading of the player's state; engines emit one on every change.
public struct PlayerSnapshot: Sendable, Equatable {
    public var status: PlayerStatus
    public var position: Duration
    public var duration: Duration?
    public var rate: Double

    public init(status: PlayerStatus, position: Duration, duration: Duration?, rate: Double) {
        self.status = status
        self.position = position
        self.duration = duration
        self.rate = rate
    }
}

/// An audio or subtitle track offered by the media.
public struct MediaTrack: Identifiable, Sendable, Hashable {
    public var id: Int
    public var name: String
    public var language: String?

    public init(id: Int, name: String, language: String?) {
        self.id = id
        self.name = name
        self.language = language
    }
}

/// The video player behind the playback screen (SPEC 5). The app implements it over VLCKit;
/// tests use a fake (task M3-1).
@MainActor public protocol PlayerEngine: AnyObject {
    var snapshot: PlayerSnapshot { get }
    /// Emits on every change; position about every 250 ms while playing (SPEC §5 engine rules).
    var snapshots: AsyncStream<PlayerSnapshot> { get }
    func load(url: URL, startAt: Duration?)
    func play()
    func pause()
    func seek(to position: Duration)
    func stop()
    var audioTracks: [MediaTrack] { get }
    var subtitleTracks: [MediaTrack] { get }
    var selectedAudioTrack: MediaTrack.ID? { get set }
    /// nil = subtitles off.
    var selectedSubtitleTrack: MediaTrack.ID? { get set }
}
