import Foundation

/// The decisions behind a real `PlayerEngine` (SPEC 5 "Engine rules"), as a pure state machine.
///
/// `VLCPlayerEngine` feeds it what it was asked to do and what the player reported, emits
/// `snapshot` whenever `handle` says so, and carries out the commands (measure the file size,
/// reopen). It holds no player, does no I/O and knows nothing of VLC beyond the shape of its
/// events, so every rule is unit-tested here (M3-3).
public struct PlayerEventMachine: Sendable {
    public enum Input: Sendable, Equatable {
        /// The engine was asked to load new media.
        case load(startAt: Duration?)
        case seekRequested(Duration)
        case stopRequested
        /// The player's own events.
        case playerPlaying
        case playerPaused
        /// `isPlaying` is the player's own flag at that moment; VLC sends hundreds of these while
        /// playing normally, and only one with `isPlaying == false` means a stall.
        case playerBuffering(isPlaying: Bool)
        /// A position callback. A duration of zero or nil means unknown.
        case playerPosition(Duration, duration: Duration?)
        case playerEnded
        case playerError
        case playerStopped
        /// The answers to `measureOpenedSize` and `checkCurrentSize`: the file's total size in
        /// bytes, or nil when it could not be found.
        case openedSize(Int64?)
        case currentSize(Int64?)
    }

    public enum Command: Sendable, Equatable {
        /// Find the file's size now (a 1-byte range GET) and report it as `.openedSize`.
        case measureOpenedSize
        /// Find the file's size now and report it as `.currentSize`.
        case checkCurrentSize
        /// Open the same media again, starting at this position, and play.
        case reopen(at: Duration)
    }

    public struct Output: Sendable, Equatable {
        /// True when `snapshot` changed in a way the engine must deliver.
        public var emit: Bool
        public var commands: [Command]
    }

    private enum Phase: Sendable {
        case idle, opening, running, checkingGrowth, reopening, finished, stopped
    }

    public private(set) var snapshot = PlayerSnapshot(status: .idle, position: .zero, duration: nil, rate: 0)
    private var phase = Phase.idle
    /// A position has been reported since the last `load` (the 404 rule only applies before one).
    private var hadPosition = false
    private var openedSize: Int64?

    public init() {}

    static let failedToPlay = "The player could not open or play the recording."
    static let endedBeforePlaying = "The player reached the end before playing anything."
    static let sizeUnknown = "The player could not check whether the recording is still growing."

    public mutating func handle(_ input: Input) -> Output {
        switch input {
        case .load(let startAt):
            phase = .opening
            hadPosition = false
            openedSize = nil
            snapshot = PlayerSnapshot(status: .loading, position: startAt ?? .zero, duration: nil, rate: 0)
            return Output(emit: true, commands: [.measureOpenedSize])

        case .openedSize(let size):
            openedSize = size
            return .nothing

        case .seekRequested(let target):
            guard [.opening, .running, .reopening].contains(phase) else { return .nothing }
            snapshot.position = target
            return .emitted

        case .stopRequested:
            guard phase != .idle else { return .nothing }
            phase = .stopped
            snapshot = PlayerSnapshot(status: .idle, position: .zero, duration: snapshot.duration, rate: 0)
            return .emitted

        case .playerPlaying:
            guard phase == .running, snapshot.status == .paused || snapshot.status == .buffering else {
                return .nothing
            }
            return set(.playing, rate: 1)

        case .playerPaused:
            guard [.opening, .running, .reopening].contains(phase), snapshot.status != .paused else {
                return .nothing
            }
            return set(.paused, rate: 0)

        case .playerBuffering(let isPlaying):
            guard !isPlaying, phase == .running, snapshot.status == .playing else { return .nothing }
            return set(.buffering, rate: 0)

        case .playerPosition(let position, let duration):
            guard [.opening, .running, .reopening].contains(phase) else { return .nothing }
            phase = .running
            hadPosition = true
            snapshot.position = position
            if let duration, duration > .zero { snapshot.duration = duration }
            if snapshot.status != .paused {
                snapshot.status = .playing
                snapshot.rate = 1
            }
            return .emitted

        case .playerEnded:
            switch phase {
            case .opening where !hadPosition:
                return fail(Self.endedBeforePlaying)
            case .opening, .running, .reopening:
                phase = .checkingGrowth
                // Nothing is shown until the size is known: either it ends, or it reopens.
                return Output(emit: false, commands: [.checkCurrentSize])
            default:
                return .nothing
            }

        case .currentSize(let size):
            guard phase == .checkingGrowth else { return .nothing }
            guard let size else { return fail(Self.sizeUnknown) }
            if let opened = openedSize, size > opened {
                openedSize = size
                phase = .reopening
                let changed = snapshot.status != .buffering
                snapshot.status = .buffering
                snapshot.rate = 0
                return Output(emit: changed, commands: [.reopen(at: snapshot.position)])
            }
            phase = .finished
            snapshot.status = .ended
            snapshot.rate = 0
            if let duration = snapshot.duration { snapshot.position = duration }
            return .emitted

        case .playerError:
            guard [.opening, .running, .reopening, .checkingGrowth].contains(phase) else { return .nothing }
            return fail(Self.failedToPlay)

        case .playerStopped:
            // VLC sends Stopped after Ended, after Error, after stop() and when media is replaced.
            return .nothing
        }
    }

    private mutating func set(_ status: PlayerStatus, rate: Double) -> Output {
        snapshot.status = status
        snapshot.rate = rate
        return .emitted
    }

    private mutating func fail(_ message: String) -> Output {
        phase = .finished
        snapshot.status = .failed(message)
        snapshot.rate = 0
        return .emitted
    }

    // MARK: Tracks

    /// A player's track list as `MediaTrack`s: entries with a negative id ("Disable") dropped,
    /// and a bracketed language ("Track 1 - [English]") used as both name and language.
    public static func tracks(names: [String], ids: [Int]) -> [MediaTrack] {
        zip(names, ids).compactMap { name, id in
            guard id >= 0 else { return nil }
            if let open = name.lastIndex(of: "["), let close = name.lastIndex(of: "]"), open < close {
                let language = String(name[name.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
                if !language.isEmpty { return MediaTrack(id: id, name: language, language: language) }
            }
            return MediaTrack(id: id, name: name, language: nil)
        }
    }
}

extension PlayerEventMachine.Output {
    static let nothing = Self(emit: false, commands: [])
    static let emitted = Self(emit: true, commands: [])
}
