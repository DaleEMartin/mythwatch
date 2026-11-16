import Foundation
import MythwatchDomain

/// The state of something the screen loads (SPEC 6).
public enum Loadable<Value: Sendable>: Sendable {
    case idle
    case loading
    case loaded(Value)
    case failed(UserMessage)

    /// The loaded value, if there is one.
    public var value: Value? {
        if case .loaded(let value) = self { return value }
        return nil
    }

    /// The failure message, if loading failed.
    public var message: UserMessage? {
        if case .failed(let message) = self { return message }
        return nil
    }

    public var isIdle: Bool {
        if case .idle = self { return true }
        return false
    }

    public var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}

extension Loadable: Equatable where Value: Equatable {}

/// Text shown to the user when something goes wrong. Built only here (SPEC 6, CLAUDE.md rule 8);
/// the wording table is in SPEC §6.
public struct UserMessage: Sendable, Equatable {
    public var title: String
    public var detail: String
    /// Whether offering "Try Again" makes sense: trying the same thing again could succeed.
    public var canRetry: Bool

    public init(title: String, detail: String, canRetry: Bool) {
        self.title = title
        self.detail = detail
        self.canRetry = canRetry
    }
}

extension UserMessage {
    /// The one place a `BackendError` becomes user text. Associated strings are diagnostics and
    /// are never shown; the only exception is the version string of `.unsupportedVersion`.
    public init(_ error: BackendError) {
        switch error {
        case .unreachable:
            self.init(
                title: "Can't Reach Your MythTV Backend",
                detail: "Make sure the backend is turned on and connected to your home network, "
                    + "then try again. If that doesn't help, check the address in Settings.",
                canRetry: true)
        case .timedOut:
            self.init(
                title: "Your MythTV Backend Didn't Answer in Time",
                detail: "It may be busy or still starting up. Wait a moment, then try again.",
                canRetry: true)
        case .http:
            self.init(
                title: "Your MythTV Backend Had a Problem",
                detail: "It couldn't answer just now. Try again in a moment. If this keeps "
                    + "happening, check that the address in Settings is your MythTV backend.",
                canRetry: true)
        case .malformedResponse:
            self.init(
                title: "Mythwatch Didn't Understand the Reply",
                detail: "The address in Settings may not be a MythTV backend, or the backend sent "
                    + "something unexpected. Check the address, then try again.",
                canRetry: true)
        case .notFound:
            self.init(
                title: "This Recording Is No Longer Available",
                detail: "It may have been deleted. Go back and refresh to see what's on the "
                    + "backend now.",
                canRetry: false)
        case .rejected:
            self.init(
                title: "Your MythTV Backend Turned That Down",
                detail: "It wouldn't do what Mythwatch asked, so nothing was changed.",
                canRetry: false)
        case .unsupportedVersion(let raw):
            let version = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let running = version.isEmpty ? "a version of MythTV" : "MythTV \(version)"
            self.init(
                title: "This Version of MythTV Isn't Supported",
                detail: "Your backend is running \(running), which this version of Mythwatch "
                    + "can't work with.",
                canRetry: false)
        case .notAuthorized:
            self.init(
                title: "Your MythTV Backend Wants a Sign-In",
                detail: "Mythwatch can't sign in to a backend yet, so it can only use one that "
                    + "doesn't ask for a password.",
                canRetry: false)
        }
    }

    /// The player lost the video, or never got it (SPEC 7 "Player"). The engine's own reason is
    /// never shown. Try Again starts a new viewing from where this one stopped.
    public static let playbackFailed = UserMessage(
        title: "Can't Play This Recording",
        detail: "Mythwatch couldn't get the video from your MythTV backend. Make sure the backend is "
            + "turned on, then try again. Mythwatch will pick up where you left off.",
        canRetry: true)

    /// For a failure that is not a `BackendError` (which should not happen). Never shows the
    /// failure's own description.
    public static let unexpected = UserMessage(
        title: "Something Went Wrong",
        detail: "Mythwatch ran into a problem it didn't expect. Try again.",
        canRetry: true)
}
