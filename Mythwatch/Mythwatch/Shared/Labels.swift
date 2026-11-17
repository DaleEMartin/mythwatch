import Foundation
import MythwatchBackend
import MythwatchDomain
import MythwatchFeatures
import MythwatchPlayback

/// The screens' own words, in one place. Error wording is `UserMessage`'s (SPEC 6); the address
/// hint is `addressHint`'s; start-point buttons are `StartOption.title`.
enum Labels {
    static let recordings = "Recordings"
    static let settings = "Settings"
    static let continueWatching = "Continue Watching"
    static let recentlyRecorded = "Recently Recorded"
    static let shows = "Shows"
    static let connecting = "Connecting to Your MythTV Backend"
    static let loadingRecordings = "Loading Your Recordings"
    static let noRecordingsTitle = "No Recordings Yet"
    static let noRecordingsDetail = "When your MythTV backend records something, it will appear here."
    static let tryAgain = "Try Again"
    static let ok = "OK"
    static let refreshProblemPrefix = "Couldn't refresh."

    // Onboarding
    static let welcome = "Welcome to Mythwatch"
    static let welcomeDetail =
        "Mythwatch plays the recordings on your MythTV backend. Choose your backend, or type its address."
    static let onYourNetwork = "Backends on Your Network"
    static let addressPrompt = "Backend address"
    static let addressExample = "For example 192.168.1.20 or mybackend.local"
    static let testConnection = "Test Connection"
    static let connect = "Connect"
    static let connectingShort = "Connecting"
    static let testing = "Checking"

    // Show and episode pages
    static let markWatched = "Mark as Watched"
    static let markUnwatched = "Mark as Unwatched"
    static let delete = "Delete"
    static let deleting = "Deleting"
    static let cancel = "Cancel"
    static func deleteQuestion(_ recording: Recording) -> String {
        "Delete \u{201C}\(episodeTitle(recording))\u{201D}?"
    }
    static let deleteDetail = "The recording is removed from your MythTV backend. This can't be undone."
    static let deleteAndRerecord = "Delete and Let MythTV Record It Again"
    static let rerecordDetail = "If it's shown again, MythTV can record it again, or not."
    static let keep = "Keep"
    static func finishedQuestion(_ recording: Recording) -> String {
        "You've finished \u{201C}\(episodeTitle(recording))\u{201D}. Delete it?"
    }
    static let watched = "Watched"
    static let partWatched = "Part watched"

    // Player
    static let close = "Close"
    static let info = "Info"
    static func panelTab(_ tab: TransportModel.Panel) -> String {
        switch tab {
        case .info: "Info"
        case .audio: "Audio"
        case .subtitles: "Subtitles"
        }
    }
    static let setBookmark = "Set Bookmark Here"
    /// The banner after a commercial skip (M4-3): "Skipped commercials · 2:56".
    static func skippedCommercials(_ distance: Duration) -> String {
        "Skipped commercials \u{00B7} \(TransportModel.timeText(distance))"
    }
    static let goBack = "Go Back"
    /// Prompt mode's button while a break plays.
    static let skipCommercials = "Skip Commercials"
    static let subtitlesOff = "Off"
    static let noAudioTracks = "No audio tracks are available."
    static let noSubtitles = "This recording has no subtitles or captions."
    /// "English", or VLC's name ("Track 1") when it gives no language.
    static func trackName(_ track: MediaTrack) -> String { track.language ?? track.name }

    // Settings
    static let backend = "Backend"
    static let address = "Address"
    static let mythTVVersion = "MythTV Version"
    static let adapter = "Adapter"
    static let notConnected = "Not connected"
    static let savesOnLeaving = "Changes are saved when you leave Settings."
    static let reconnecting = "Connecting to the new backend"
    static let playback = "Playback"
    static let skipForward = "Skip Forward"
    static let skipBack = "Skip Back"
    static let deinterlace = "Smooth Interlaced Video"
    static let askBeforeDelete = "Ask Before Deleting"
    static let commercials = "Commercials"
    static let commercialBreaks = "Commercial Breaks"
    static func skipMode(_ mode: CommercialSkipMode) -> String {
        switch mode {
        case .auto: "Skip Automatically"
        case .prompt: "Offer a Skip Button"
        case .off: "Play Them"
        }
    }
    static let about = "About"
    static let version = "Version"
    static let licences = "Licences"
    static func seconds(_ n: Int) -> String { "\(n) seconds" }

    static func found(_ info: BackendInfo, adapter: String?) -> String {
        var text = "Found MythTV \(info.version.raw)"
        if let host = info.hostName, !host.isEmpty { text += " on \(host)" }
        return text + "."
    }

    // VoiceOver (M5-3): one spoken label per card, poster and row, in words rather than symbols.

    /// "Garden Tales, Autumn Harvest 1, Season 2, Episode 1, Part watched"; a film:
    /// "The Long Voyage, 2 hours, Part watched".
    static func spokenCard(_ r: Recording) -> String {
        let second = episodeTitle(r) == r.title ? spokenLength(r) : episodeTitle(r)
        return [r.title, second, spokenSeasonEpisode(r), watchState(r)].compactMap { $0 }.joined(separator: ", ")
    }

    /// "Garden Tales, 7 episodes, 3 unwatched".
    static func spokenShow(_ show: Show) -> String { "\(show.title), \(counts(show))" }

    /// "Autumn Harvest 1, Season 2, Episode 1, First aired 26 Oct 2025, 30 minutes, Part watched".
    static func spokenEpisodeRow(_ r: Recording) -> String {
        let date = r.originalAirDate.flatMap(aired) ?? recordedDay(r)
        return [episodeTitle(r), spokenSeasonEpisode(r), date, spokenLength(r), watchState(r)]
            .compactMap { $0 }.joined(separator: ", ")
    }

    /// "Season 2, Episode 1", "Episode 5", "Season 2", or nil.
    static func spokenSeasonEpisode(_ r: Recording) -> String? {
        let parts = [r.season.map { "Season \($0)" }, r.episode.map { "Episode \($0)" }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// "45 minutes", "1 hour 30 minutes", "2 hours".
    static func spokenLength(_ r: Recording) -> String {
        let minutes = max(0, Int((r.recordingEnd.timeIntervalSince(r.recordingStart) / 60).rounded()))
        let (h, m) = (minutes / 60, minutes % 60)
        func unit(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
        if h == 0 { return unit(m, "minute") }
        return m == 0 ? unit(h, "hour") : unit(h, "hour") + " " + unit(m, "minute")
    }

    /// "Watched", "Part watched", or nil.
    static func watchState(_ r: Recording) -> String? {
        if r.flags.contains(.watched) { return watched }
        if r.flags.contains(.hasResumePosition) { return partWatched }
        return nil
    }

    /// The player's progress bar.
    static let position = "Position"
    /// "12:34 of 45:00", or just "12:34" without a length.
    static func spokenPosition(_ elapsed: String, of duration: Duration?) -> String {
        guard let duration, duration > .zero else { return elapsed }
        return "\(elapsed) of \(TransportModel.timeText(duration))"
    }

    // Recording details

    /// The line a list shows for a recording: its episode title, else the programme title.
    static func episodeTitle(_ r: Recording) -> String {
        if let subtitle = r.subtitle?.trimmingCharacters(in: .whitespaces), !subtitle.isEmpty { return subtitle }
        return r.title
    }

    /// "S2 E5", "E5", "S2", or nil.
    static func seasonEpisode(_ r: Recording) -> String? {
        switch (r.season, r.episode) {
        case let (s?, e?): "S\(s) E\(e)"
        case let (nil, e?): "E\(e)"
        case let (s?, nil): "S\(s)"
        case (nil, nil): nil
        }
    }

    /// "45 min", "1 hr 30 min", "2 hr".
    static func length(_ r: Recording) -> String {
        let minutes = max(0, Int((r.recordingEnd.timeIntervalSince(r.recordingStart) / 60).rounded()))
        let (h, m) = (minutes / 60, minutes % 60)
        if h == 0 { return "\(m) min" }
        return m == 0 ? "\(h) hr" : "\(h) hr \(m) min"
    }

    /// "First aired 28 Oct 2025".
    static func aired(_ day: CalendarDay) -> String? {
        var parts = DateComponents()
        (parts.year, parts.month, parts.day) = (day.year, day.month, day.day)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        guard let date = calendar.date(from: parts) else { return nil }
        var style = Date.FormatStyle(date: .abbreviated, time: .omitted)
        style.timeZone = .gmt
        return "First aired " + date.formatted(style)
    }

    /// "Recorded 1 Nov 2025 at 8:00 PM", in the device's time zone.
    static func recorded(_ r: Recording) -> String {
        "Recorded " + r.recordingStart.formatted(date: .abbreviated, time: .omitted) + " at "
            + r.recordingStart.formatted(date: .omitted, time: .shortened)
    }

    /// "Channel 4 WDMO".
    static func channel(_ r: Recording) -> String? {
        guard let c = r.channel else { return nil }
        return ["Channel", c.number, c.callSign].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// "7 episodes, 3 unwatched" ("1 recording" for a film).
    static func counts(_ show: Show) -> String {
        let noun = show.kind == .movie ? "recording" : "episode"
        var text = "\(show.episodeCount) \(noun)\(show.episodeCount == 1 ? "" : "s")"
        if show.unwatchedCount > 0 && show.unwatchedCount < show.episodeCount {
            text += ", \(show.unwatchedCount) unwatched"
        } else if show.unwatchedCount == 0 && show.episodeCount > 0 {
            text += ", all watched"
        }
        return text
    }

    /// "S25 E32 · First aired Nov 2, 2026 · 1 hr 2 min". Without an air date (the listings often
    /// have none for a first run) the recording day stands in: "Recorded Nov 10, 2026" (owner, 2026-11-16).
    static func detailLine(_ r: Recording) -> String {
        let date = r.originalAirDate.flatMap(aired) ?? recordedDay(r)
        return [seasonEpisode(r), date, length(r)].compactMap { $0 }.joined(separator: " · ")
    }

    /// "Recorded Nov 10, 2026", in the device's time zone.
    static func recordedDay(_ r: Recording) -> String {
        "Recorded " + r.recordingStart.formatted(date: .abbreviated, time: .omitted)
    }
}
