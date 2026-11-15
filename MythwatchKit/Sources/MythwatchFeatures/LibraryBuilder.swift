import Foundation
import MythwatchDomain

/// One programme (a series, or a film) as the shows grid and show page see it.
public struct Show: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var kind: ProgramKind
    public var poster: ArtworkReference?
    public var episodeCount: Int
    public var unwatchedCount: Int
    public var newest: Date
    public var recordings: [Recording]

    public init(
        id: String, title: String, kind: ProgramKind, poster: ArtworkReference?, episodeCount: Int,
        unwatchedCount: Int, newest: Date, recordings: [Recording]
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.poster = poster
        self.episodeCount = episodeCount
        self.unwatchedCount = unwatchedCount
        self.newest = newest
        self.recordings = recordings
    }
}

public struct Library: Sendable, Equatable {
    public var continueWatching: [Recording]
    public var recentlyRecorded: [Recording]
    public var shows: [Show]

    public init(continueWatching: [Recording], recentlyRecorded: [Recording], shows: [Show]) {
        self.continueWatching = continueWatching
        self.recentlyRecorded = recentlyRecorded
        self.shows = shows
    }
}

public struct Season: Identifiable, Hashable, Sendable {
    /// The season number; nil for "Other Episodes" and for a film's single season.
    public var id: Int?
    public var title: String
    public var episodes: [Recording]

    public init(id: Int?, title: String, episodes: [Recording]) {
        self.id = id
        self.title = title
        self.episodes = episodes
    }
}

/// The user-facing words this file produces, kept in one place. (`UserMessage` does not exist yet
/// and is about errors; these are labels.)
enum LibraryLabels {
    static let otherEpisodes = "Other Episodes"
    static let movieSeason = ""
    static func season(_ number: Int) -> String { "Season \(number)" }
}

/// Pure functions that turn a flat recording list into shelves, shows and seasons. No I/O, no
/// clock, no locale: all string comparison is Swift's `String <` (Unicode canonical order).
public enum LibraryBuilder {
    static let shelfLimit = 20

    public static func build(from recordings: [Recording]) -> Library {
        let live = recordings.filter { !$0.flags.contains(.deletePending) }

        let continueWatching = live
            .filter { $0.flags.contains(.hasResumePosition) && !$0.flags.contains(.watched) }
            .sorted { a, b in
                if a.lastModified != b.lastModified { return a.lastModified > b.lastModified }
                return newerFirst(a, b)
            }
        let recentlyRecorded = live.sorted(by: newerFirst)

        var groups: [String: [Recording]] = [:]
        for recording in live { groups[groupKey(of: recording), default: []].append(recording) }

        var entries: [(show: Show, sort: String)] = []
        entries.reserveCapacity(groups.count)
        for (id, members) in groups {
            let show = makeShow(id: id, members: members)
            entries.append((show, sortTitle(show.title)))
        }
        entries.sort { a, b in
            if a.sort != b.sort { return a.sort < b.sort }
            if a.show.title != b.show.title { return a.show.title < b.show.title }
            return a.show.id < b.show.id
        }

        return Library(
            continueWatching: Array(continueWatching.prefix(shelfLimit)),
            recentlyRecorded: Array(recentlyRecorded.prefix(shelfLimit)),
            shows: entries.map(\.show))
    }

    /// Seasons of `show`, ignoring any `deletePending` recording it holds.
    public static func seasons(of show: Show) -> [Season] {
        let live = show.recordings.filter { !$0.flags.contains(.deletePending) }
        guard !live.isEmpty else { return [] }

        if show.kind == .movie {
            return [Season(id: nil, title: LibraryLabels.movieSeason, episodes: live.sorted(by: earlierFirst))]
        }

        var bySeason: [Int?: [Recording]] = [:]
        for recording in live { bySeason[recording.season, default: []].append(recording) }

        let numbers = bySeason.keys.compactMap { $0 }.sorted()
        var result = numbers.map { number in
            Season(
                id: number, title: LibraryLabels.season(number),
                episodes: (bySeason[number] ?? []).sorted(by: episodeOrder))
        }
        if let others = bySeason[nil] {
            result.append(
                Season(id: nil, title: LibraryLabels.otherEpisodes, episodes: others.sorted(by: episodeOrder)))
        }
        return result
    }

    /// A locale-independent key for ordering titles: case, diacritics, surrounding and repeated
    /// whitespace and leading punctuation are ignored, and a leading "the ", "a " or "an " is
    /// dropped when more text follows it.
    public static func sortTitle(_ title: String) -> String {
        let normalised = normalise(title)
        let trimmed = String(normalised.drop { !($0.isLetter || $0.isNumber) })
        let base = trimmed.isEmpty ? normalised : trimmed
        for article in ["the ", "a ", "an "] where base.hasPrefix(article) {
            let rest = base.dropFirst(article.count)
            if !rest.isEmpty { return String(rest) }
        }
        return base
    }

    // MARK: - Internals

    /// Case- and diacritic-folded, with whitespace runs collapsed to one space and the ends trimmed.
    static func normalise(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// "series:<key>" when the recording has a non-blank `seriesKey`, else "title:<normalised title>".
    static func groupKey(of recording: Recording) -> String {
        if let key = recording.seriesKey, !key.allSatisfy(\.isWhitespace) { return "series:" + key }
        return "title:" + normalise(recording.title)
    }

    /// Newest `recordingStart` first; `id` descending breaks ties.
    private static func newerFirst(_ a: Recording, _ b: Recording) -> Bool {
        if a.recordingStart != b.recordingStart { return a.recordingStart > b.recordingStart }
        return a.id.rawValue > b.id.rawValue
    }

    private static func earlierFirst(_ a: Recording, _ b: Recording) -> Bool {
        if a.recordingStart != b.recordingStart { return a.recordingStart < b.recordingStart }
        return a.id.rawValue < b.id.rawValue
    }

    /// Episode number ascending (no number last), then `recordingStart`, then `id`.
    private static func episodeOrder(_ a: Recording, _ b: Recording) -> Bool {
        if a.episode != b.episode {
            switch (a.episode, b.episode) {
            case let (x?, y?): return x < y
            case (nil, _?): return false
            default: return true
            }
        }
        return earlierFirst(a, b)
    }

    private static func makeShow(id: String, members: [Recording]) -> Show {
        let ordered = members.sorted(by: newerFirst)  // never empty

        var titleCounts: [String: Int] = [:]
        for recording in ordered {
            titleCounts[recording.title.trimmingCharacters(in: .whitespacesAndNewlines), default: 0] += 1
        }
        let title = titleCounts.min { a, b in
            a.value != b.value ? a.value > b.value : a.key < b.key
        }?.key ?? ""

        let poster = ordered.lazy
            .compactMap { $0.artwork.first { $0.kind == .poster } }
            .first

        return Show(
            id: id, title: title, kind: ordered[0].kind, poster: poster,
            episodeCount: ordered.count,
            unwatchedCount: ordered.filter { !$0.flags.contains(.watched) }.count,
            newest: ordered[0].recordingStart, recordings: ordered)
    }
}
