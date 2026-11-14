import Foundation
import MythwatchDomain

/// Pure functions from v35 DTOs to domain values. No I/O, no clock, no shared state.
///
/// Rows that cannot be turned into a faithful `Recording` are skipped, never patched up with
/// invented data: see `recording(from:)`.
enum RecordingMapper {
    // MARK: Rows

    /// Returns nil (the row is skipped) when the row has no `Recording.RecordedId > 0`, no title,
    /// or any of `StartTime`, `EndTime`, `LastModified`, `Recording.StartTs`, `Recording.EndTs`
    /// is missing or not `yyyy-MM-ddTHH:mm:ssZ`. Everything else has a default: absent strings
    /// are nil (or "" for `recordingGroup`), absent numbers are 0 (and season/episode 0 are nil).
    static func recording(from dto: ProgramDTO) -> Recording? {
        guard let rec = dto.recording, let rawId = rec.recordedId, rawId > 0,
            let id = Int(exactly: rawId),
            let title = emptyToNil(dto.title),
            let scheduledStart = timestamp(dto.startTime),
            let scheduledEnd = timestamp(dto.endTime),
            let lastModified = timestamp(dto.lastModified),
            let recordingStart = timestamp(rec.startTs),
            let recordingEnd = timestamp(rec.endTs)
        else { return nil }

        var flags = flags(fromNames: dto.programFlagNames)
        if isDamaged(videoPropNames: dto.videoPropNames) { flags.insert(.damaged) }

        return Recording(
            id: RecordingID(rawValue: id),
            title: title,
            subtitle: emptyToNil(dto.subtitle),
            synopsis: emptyToNil(dto.descriptionText),
            kind: kind(fromCatType: dto.catType),
            category: emptyToNil(dto.category),
            season: positive(dto.season),
            episode: positive(dto.episode),
            originalAirDate: emptyToNil(dto.airdate).flatMap { CalendarDay(parsing: $0) },
            seriesKey: emptyToNil(dto.inetref),
            scheduledStart: scheduledStart,
            scheduledEnd: scheduledEnd,
            recordingStart: recordingStart,
            recordingEnd: recordingEnd,
            lastModified: lastModified,
            fileSize: dto.fileSize,
            channel: channel(dto.channel),
            recordingGroup: rec.recGroup ?? "",
            flags: flags,
            video: video(fromNames: dto.videoPropNames),
            artwork: artwork(dto.artwork))
    }

    /// Maps every mappable row, in order, dropping the rest.
    static func recordings(from list: ProgramListDTO) -> [Recording] {
        list.programs.compactMap(recording(from:))
    }

    /// The "not found" reply of `GetRecorded` is a blank programme with HTTP 200: `Title` null,
    /// `Recording` null, or a missing/zero `RecordedId` (BACKEND-V35, "GetRecorded").
    static func isNotFound(_ dto: ProgramDTO) -> Bool {
        dto.title == nil || dto.recording == nil || (dto.recording?.recordedId ?? 0) <= 0
    }

    // MARK: Fields

    static func kind(fromCatType raw: String?) -> ProgramKind {
        switch raw?.lowercased() {
        case "series": .series
        case "movie": .movie
        case "tvshow": .tvShow
        case "sports": .sports
        default: .unknown
        }
    }

    /// Parses `ProgramFlagNames` (`|`-separated, or `NONE`). Only exact, known names count; hex
    /// spellings (`0x00100000`) and unknown names are ignored. `DAMAGED` comes from
    /// `VideoPropNames`, see `isDamaged`.
    static func flags(fromNames names: String?) -> RecordingFlags {
        var result: RecordingFlags = []
        for name in names?.split(separator: "|") ?? [] {
            switch name {
            case "WATCHED": result.insert(.watched)
            case "BOOKMARK": result.insert(.hasBookmark)
            case "LASTPLAYPOS": result.insert(.hasResumePosition)
            case "COMMFLAG": result.insert(.commercialsFlagged)
            case "CUTLIST": result.insert(.hasCutList)
            case "INUSERECORDING": result.insert(.recordingInProgress)
            case "DELETEPENDING": result.insert(.deletePending)
            default: break
            }
        }
        return result
    }

    private static func videoNames(_ names: String?) -> Set<Substring> {
        Set(names?.split(separator: "|") ?? [])
    }

    static func video(fromNames names: String?) -> VideoTraits {
        let set = videoNames(names)
        return VideoTraits(
            isHD: set.contains("HDTV"),
            isWidescreen: set.contains("WIDESCREEN"),
            verticalResolution: set.contains("1080") ? 1080 : set.contains("720") ? 720 : nil)
    }

    static func isDamaged(videoPropNames names: String?) -> Bool {
        videoNames(names).contains("DAMAGED")
    }

    /// `coverart` → poster, `fanart` → fanart, `banner` → banner; other types and entries
    /// without a URL are dropped. The URL is kept verbatim as the locator.
    static func artwork(_ dto: ArtworkDTO?) -> [ArtworkReference] {
        (dto?.artworkInfos ?? []).compactMap { info in
            guard let url = emptyToNil(info.url) else { return nil }
            let kind: ArtworkKind
            switch info.type {
            case "coverart": kind = .poster
            case "fanart": kind = .fanart
            case "banner": kind = .banner
            default: return nil
            }
            return ArtworkReference(kind: kind, locator: url)
        }
    }

    /// nil when the channel object is absent or carries no number, call sign or name (the
    /// channel no longer exists); otherwise missing parts become "".
    static func channel(_ dto: ChannelDTO?) -> ChannelSummary? {
        guard let dto else { return nil }
        let number = emptyToNil(dto.chanNum)
        let callSign = emptyToNil(dto.callSign)
        let name = emptyToNil(dto.channelName)
        if number == nil && callSign == nil && name == nil { return nil }
        return ChannelSummary(number: number ?? "", callSign: callSign ?? "", name: name ?? "")
    }

    /// `yyyy-MM-ddTHH:mm:ssZ`, UTC. nil for anything else.
    static func timestamp(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        return try? Date(text, strategy: .iso8601)
    }

    // MARK: Small helpers

    private static func emptyToNil(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }

    private static func positive(_ value: Int64) -> Int? {
        value > 0 ? Int(exactly: value) : nil
    }
}
