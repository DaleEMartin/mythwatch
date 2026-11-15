import MythwatchDomain

extension UserMessage {
    /// The message for whatever a service call threw: the `BackendError` wording, or
    /// `.unexpected` for anything else. Never shows the error's own text.
    static func describing(_ error: any Error) -> UserMessage {
        (error as? BackendError).map(UserMessage.init) ?? .unexpected
    }
}
