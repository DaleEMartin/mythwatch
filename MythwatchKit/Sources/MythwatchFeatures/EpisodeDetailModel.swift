import Foundation
import MythwatchDomain
import MythwatchPlayback
import Observation

/// One way to start playback, ready to render: no logic needed in the view.
public struct StartOption: Identifiable, Sendable, Equatable {
    public var point: StartPoint
    /// Button text, for example "Resume from 12:34".
    public var title: String
    /// The position the option starts at; nil for Play from Beginning.
    public var position: Duration?
    public var id: String {
        switch point {
        case .resume: "resume"
        case .bookmark: "bookmark"
        case .beginning: "beginning"
        }
    }
}

/// The user-facing words of the episode detail screen, kept in one place.
enum EpisodeLabels {
    static let beginning = "Play from Beginning"
    static func resume(at position: Duration) -> String { "Resume from \(clock(position))" }
    static func bookmark(at position: Duration) -> String { "Play from Bookmark at \(clock(position))" }

    /// "12:34", or "1:02:03" from an hour up. Whole seconds, rounded down.
    static func clock(_ position: Duration) -> String {
        let total = max(0, Int(position.components.seconds))
        let hours = total / 3600, minutes = total % 3600 / 60, seconds = total % 60
        let tail = (minutes < 10 && hours > 0 ? "0" : "") + "\(minutes):" + (seconds < 10 ? "0" : "") + "\(seconds)"
        return hours > 0 ? "\(hours):" + tail : tail
    }
}

/// The episode detail screen's model (SPEC 6.4).
///
/// `startOptions`, in order: Resume (when there is a resume position), Play from Bookmark (when
/// there is a bookmark), Play from Beginning (always, even before `load()` and when a fetch
/// failed). A position of zero or less counts as none; there is no other threshold.
///
/// `load()` fetches both positions at the same time. If one fetch fails the other's result is
/// still used. A failure is shown, not hidden: `problem` holds the message (the first failure's
/// when both fail), since a missing Resume button with no explanation would look like there was
/// nothing to resume. It clears when the next load starts; a failed load keeps what an earlier
/// load found.
///
/// `delete()` sends `delete(id:allowRerecord: false)` and waits for the answer: the page closes
/// when `isDeleted` becomes true, so a failure must keep the page up to be seen. While it is in
/// flight `isDeleting` is true and another `delete()` sends nothing; a failure sets `problem`.
/// A successful delete calls `onChange` with `.deleted`. Confirming is the view's job.
///
/// A concurrent `load()` joins the one running. If every caller waiting is cancelled the load is
/// cancelled and publishes nothing: no message, `isLoading` back to false, the positions as they
/// were before it started (none, after a first load).
@MainActor @Observable public final class EpisodeDetailModel {
    public let recording: Recording
    public private(set) var resumePosition: Duration?
    public private(set) var bookmark: Duration?
    public private(set) var isLoading = false
    public private(set) var problem: UserMessage?
    public private(set) var isDeleting = false
    /// The backend accepted the delete: the view should close the page.
    public private(set) var isDeleted = false

    @ObservationIgnored private let state: any PlaybackStateService
    @ObservationIgnored private let recordings: any RecordingsService
    @ObservationIgnored private let onChange: (@MainActor (RecordingChange) -> Void)?
    @ObservationIgnored private var deleteTask: Task<Void, Never>?
    @ObservationIgnored private let shared = SharedLoad<Positions>()

    struct Positions: Sendable {
        var resume: Result<Duration?, any Error>
        var bookmark: Result<Duration?, any Error>
    }

    public init(
        recording: Recording, state: any PlaybackStateService, recordings: any RecordingsService,
        onChange: (@MainActor (RecordingChange) -> Void)? = nil
    ) {
        self.recording = recording
        self.state = state
        self.recordings = recordings
        self.onChange = onChange
    }

    /// Deletes the recording (no rerecord). The returned task ends when the backend has
    /// answered; the caller cannot cancel the delete.
    @discardableResult
    public func delete() -> Task<Void, Never> {
        if let deleteTask { return deleteTask }
        guard !isDeleted else { return Task {} }
        problem = nil
        isDeleting = true
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            let id = recording.id
            do {
                try await recordings.delete(id: id, allowRerecord: false)
                isDeleted = true
                onChange?(.deleted(id))
            } catch {
                problem = UserMessage.describing(error)
            }
            isDeleting = false
            deleteTask = nil
        }
        deleteTask = task
        return task
    }

    public var startOptions: [StartOption] {
        var options: [StartOption] = []
        if let resumePosition {
            options.append(
                StartOption(point: .resume, title: EpisodeLabels.resume(at: resumePosition), position: resumePosition))
        }
        if let bookmark {
            options.append(
                StartOption(point: .bookmark, title: EpisodeLabels.bookmark(at: bookmark), position: bookmark))
        }
        options.append(StartOption(point: .beginning, title: EpisodeLabels.beginning, position: nil))
        return options
    }

    public func load() async {
        if !shared.isRunning {
            isLoading = true
            problem = nil
        }
        let state = self.state
        let id = recording.id
        await shared.run(
            fetch: {
                async let resume = Self.result { try await state.resumePosition(for: id) }
                async let mark = Self.result { try await state.bookmark(for: id) }
                return Positions(resume: await resume, bookmark: await mark)
            },
            publish: { [weak self] positions in self?.publish(positions) },
            abandon: { [weak self] in
                self?.isLoading = false
                self?.problem = nil
            })
    }

    private nonisolated static func result(
        _ body: @Sendable () async throws -> Duration?
    ) async -> Result<Duration?, any Error> {
        do { return .success(try await body()) } catch { return .failure(error) }
    }

    private func publish(_ positions: Positions) {
        isLoading = false
        var firstFailure: (any Error)?
        switch positions.resume {
        case .success(let value): resumePosition = Self.usable(value)
        case .failure(let error): firstFailure = error
        }
        switch positions.bookmark {
        case .success(let value): bookmark = Self.usable(value)
        case .failure(let error): firstFailure = firstFailure ?? error
        }
        problem = firstFailure.map(UserMessage.describing)
    }

    private static func usable(_ position: Duration?) -> Duration? {
        guard let position, position > .zero else { return nil }
        return position
    }
}
