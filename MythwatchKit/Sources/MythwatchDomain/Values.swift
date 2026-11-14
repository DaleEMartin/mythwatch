import Foundation

public struct RecordingID: Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
}

public enum ProgramKind: Hashable, Sendable { case series, movie, tvShow, sports, unknown }

public struct RecordingFlags: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let watched = RecordingFlags(rawValue: 1 << 0)
    public static let hasBookmark = RecordingFlags(rawValue: 1 << 1)
    public static let hasResumePosition = RecordingFlags(rawValue: 1 << 2)
    public static let commercialsFlagged = RecordingFlags(rawValue: 1 << 3)
    public static let hasCutList = RecordingFlags(rawValue: 1 << 4)
    public static let recordingInProgress = RecordingFlags(rawValue: 1 << 5)
    public static let deletePending = RecordingFlags(rawValue: 1 << 6)
    public static let damaged = RecordingFlags(rawValue: 1 << 7)
}

/// A proleptic Gregorian calendar date with no time or zone (an original air date).
public struct CalendarDay: Hashable, Sendable, Comparable {
    public let year: Int
    public let month: Int
    public let day: Int

    /// Returns nil unless the date exists (year 1...9999, month 1...12, day valid for the month).
    public init?(year: Int, month: Int, day: Int) {
        guard (1...9999).contains(year), (1...12).contains(month), day >= 1,
              day <= CalendarDay.daysIn(month: month, year: year)
        else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    /// Parses exactly `yyyy-MM-dd` (ASCII digits only). Returns nil for anything else, including
    /// well-formed but impossible dates such as `2025-02-30`.
    public init?(parsing text: String) {
        let bytes = Array(text.utf8)
        guard bytes.count == 10, bytes[4] == 0x2D, bytes[7] == 0x2D else { return nil }
        func number(_ range: Range<Int>) -> Int? {
            var value = 0
            for byte in bytes[range] {
                guard byte >= 0x30, byte <= 0x39 else { return nil }
                value = value * 10 + Int(byte - 0x30)
            }
            return value
        }
        guard let y = number(0..<4), let m = number(5..<7), let d = number(8..<10) else { return nil }
        self.init(year: y, month: m, day: d)
    }

    public static func < (lhs: CalendarDay, rhs: CalendarDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    private static func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 2:
            let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
            return leap ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }
}

public struct ChannelSummary: Hashable, Sendable {
    public var number: String
    public var callSign: String
    public var name: String

    public init(number: String, callSign: String, name: String) {
        self.number = number
        self.callSign = callSign
        self.name = name
    }
}

public enum ArtworkKind: Hashable, Sendable { case poster, fanart, banner }

/// `locator` is opaque to everyone but the adapter that produced it.
public struct ArtworkReference: Hashable, Sendable {
    public var kind: ArtworkKind
    public var locator: String

    public init(kind: ArtworkKind, locator: String) {
        self.kind = kind
        self.locator = locator
    }
}

public struct VideoTraits: Hashable, Sendable {
    public var isHD: Bool
    public var isWidescreen: Bool
    public var verticalResolution: Int?

    public init(isHD: Bool, isWidescreen: Bool, verticalResolution: Int?) {
        self.isHD = isHD
        self.isWidescreen = isWidescreen
        self.verticalResolution = verticalResolution
    }
}

public struct Recording: Identifiable, Hashable, Sendable {
    public var id: RecordingID
    public var title: String
    public var subtitle: String?
    public var synopsis: String?
    public var kind: ProgramKind
    public var category: String?
    public var season: Int?
    public var episode: Int?
    public var originalAirDate: CalendarDay?
    public var seriesKey: String?
    public var scheduledStart: Date
    public var scheduledEnd: Date
    public var recordingStart: Date
    public var recordingEnd: Date
    public var lastModified: Date
    public var fileSize: Int64
    public var channel: ChannelSummary?
    public var recordingGroup: String
    public var flags: RecordingFlags
    public var video: VideoTraits
    public var artwork: [ArtworkReference]

    public init(
        id: RecordingID, title: String, subtitle: String?, synopsis: String?, kind: ProgramKind,
        category: String?, season: Int?, episode: Int?, originalAirDate: CalendarDay?,
        seriesKey: String?, scheduledStart: Date, scheduledEnd: Date, recordingStart: Date,
        recordingEnd: Date, lastModified: Date, fileSize: Int64, channel: ChannelSummary?,
        recordingGroup: String, flags: RecordingFlags, video: VideoTraits,
        artwork: [ArtworkReference]
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.synopsis = synopsis
        self.kind = kind
        self.category = category
        self.season = season
        self.episode = episode
        self.originalAirDate = originalAirDate
        self.seriesKey = seriesKey
        self.scheduledStart = scheduledStart
        self.scheduledEnd = scheduledEnd
        self.recordingStart = recordingStart
        self.recordingEnd = recordingEnd
        self.lastModified = lastModified
        self.fileSize = fileSize
        self.channel = channel
        self.recordingGroup = recordingGroup
        self.flags = flags
        self.video = video
        self.artwork = artwork
    }
}

/// A span within a recording. Invariant: `start < end`.
public struct TimeRange: Hashable, Sendable {
    public let start: Duration
    public let end: Duration

    /// Returns nil unless `start < end`.
    public init?(start: Duration, end: Duration) {
        guard start < end else { return nil }
        self.start = start
        self.end = end
    }
}

public typealias CommercialBreak = TimeRange
