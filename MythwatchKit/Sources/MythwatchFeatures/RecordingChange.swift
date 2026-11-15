import MythwatchDomain

/// A change to one recording that the backend has accepted. A `ShowViewModel` reports these so
/// the `LibraryViewModel` can apply the same change locally (SPEC 6.4, "Consistency").
public enum RecordingChange: Sendable, Equatable {
    case watched(RecordingID, Bool)
    case deleted(RecordingID)
}
