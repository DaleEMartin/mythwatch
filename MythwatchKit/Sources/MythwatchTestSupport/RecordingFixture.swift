import Foundation
import MythwatchDomain

extension Recording {
    /// Every field has a default, so a test names only the fields it cares about.
    public static func fixture(
        id: RecordingID = RecordingID(rawValue: 1),
        title: String = "Test Show",
        subtitle: String? = "Test Episode",
        synopsis: String? = "A synopsis.",
        kind: ProgramKind = .series,
        category: String? = "Drama",
        season: Int? = 1,
        episode: Int? = 1,
        originalAirDate: CalendarDay? = nil,
        seriesKey: String? = "SERIES-1",
        scheduledStart: Date = Date(timeIntervalSince1970: 1_700_000_000),
        scheduledEnd: Date = Date(timeIntervalSince1970: 1_700_003_600),
        recordingStart: Date = Date(timeIntervalSince1970: 1_700_000_000),
        recordingEnd: Date = Date(timeIntervalSince1970: 1_700_003_600),
        lastModified: Date = Date(timeIntervalSince1970: 1_700_003_700),
        fileSize: Int64 = 1_000_000_000,
        channel: ChannelSummary? = ChannelSummary(number: "5", callSign: "TEST", name: "Test Channel"),
        recordingGroup: String = "Default",
        flags: RecordingFlags = [],
        video: VideoTraits = VideoTraits(isHD: true, isWidescreen: true, verticalResolution: 1080),
        artwork: [ArtworkReference] = []
    ) -> Recording {
        Recording(
            id: id, title: title, subtitle: subtitle, synopsis: synopsis, kind: kind,
            category: category, season: season, episode: episode, originalAirDate: originalAirDate,
            seriesKey: seriesKey, scheduledStart: scheduledStart, scheduledEnd: scheduledEnd,
            recordingStart: recordingStart, recordingEnd: recordingEnd, lastModified: lastModified,
            fileSize: fileSize, channel: channel, recordingGroup: recordingGroup, flags: flags,
            video: video, artwork: artwork)
    }
}
