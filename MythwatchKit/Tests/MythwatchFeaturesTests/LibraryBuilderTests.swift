import Foundation
import MythwatchDomain
import MythwatchTestSupport
import Testing

@testable import MythwatchFeatures

private func at(_ seconds: Double) -> Date { Date(timeIntervalSince1970: 1_700_000_000 + seconds) }

private func rec(
    _ id: Int, _ title: String = "Alpha", key: String? = "K-alpha", kind: ProgramKind = .series,
    season: Int? = 1, episode: Int? = 1, start: Double = 0, modified: Double = 0,
    flags: RecordingFlags = [], artwork: [ArtworkReference] = []
) -> Recording {
    .fixture(
        id: RecordingID(rawValue: id), title: title, kind: kind, season: season, episode: episode,
        seriesKey: key, recordingStart: at(start), lastModified: at(modified), flags: flags,
        artwork: artwork)
}

private func ids(_ recordings: [Recording]) -> [Int] { recordings.map(\.id.rawValue) }

private func poster(_ name: String) -> ArtworkReference {
    ArtworkReference(kind: .poster, locator: name)
}

@Suite("LibraryBuilder grouping") struct LibraryGroupingTests {
    @Test func groupsBySeriesKeyEvenWithDifferentTitles() {
        let lib = LibraryBuilder.build(from: [
            rec(1, "Alpha"), rec(2, "Alpha Reruns"), rec(3, "Beta", key: "K-beta"),
        ])
        #expect(lib.shows.count == 2)
        #expect(lib.shows.first { $0.id == "series:K-alpha" }?.recordings.count == 2)
    }

    @Test func fallsBackToNormalisedTitleWhenKeyIsNil() {
        let lib = LibraryBuilder.build(from: [
            rec(1, "Café  Show", key: nil), rec(2, "  cafe show ", key: nil),
            rec(3, "CAFE\tSHOW", key: nil),
        ])
        #expect(lib.shows.count == 1)
        #expect(lib.shows[0].episodeCount == 3)
    }

    @Test func emptySeriesKeyCountsAsNil() {
        let lib = LibraryBuilder.build(from: [rec(1, "Alpha", key: ""), rec(2, "alpha", key: nil)])
        #expect(lib.shows.count == 1)
    }

    @Test func sameTitleWithDifferentKeysStaysSeparate() {
        let lib = LibraryBuilder.build(from: [
            rec(1, "Alpha", key: "K1"), rec(2, "Alpha", key: "K2"),
        ])
        #expect(lib.shows.count == 2)
        #expect(Set(lib.shows.map(\.id)).count == 2)
    }

    @Test func keylessRecordingNeverJoinsAKeyedGroupOfTheSameTitle() {
        let lib = LibraryBuilder.build(from: [rec(1, "Alpha", key: "K1"), rec(2, "Alpha", key: nil)])
        #expect(lib.shows.count == 2)
    }

    @Test func keyedIdCannotCollideWithTitleFallbackId() {
        // A series key that looks like a title-fallback id still gets its own prefix.
        let lib = LibraryBuilder.build(from: [
            rec(1, "x", key: "title:x"), rec(2, "x", key: nil),
        ])
        #expect(lib.shows.count == 2)
        #expect(Set(lib.shows.map(\.id)) == ["series:title:x", "title:x"])
    }

    @Test func showIdIsStableAcrossRefreshes() {
        let a = LibraryBuilder.build(from: [rec(1, "Alpha")]).shows[0].id
        let b = LibraryBuilder.build(from: [rec(1, "Alpha"), rec(2, "Alpha", start: 50)]).shows[0].id
        #expect(a == b)
    }

    @Test func showTitleIsTheMostCommonTitle() {
        let lib = LibraryBuilder.build(from: [
            rec(1, "Alpha Special", start: 30), rec(2, "Alpha"), rec(3, "Alpha", start: 10),
        ])
        #expect(lib.shows[0].title == "Alpha")
    }

    @Test func titleTieGoesToTheSmallerTitle() {
        let lib = LibraryBuilder.build(from: [rec(1, "Beta"), rec(2, "Alpha", start: 99)])
        #expect(lib.shows[0].title == "Alpha")
    }

    @Test func showTitleIgnoresSurroundingWhitespace() {
        let lib = LibraryBuilder.build(from: [rec(1, " Alpha "), rec(2, "Alpha")])
        #expect(lib.shows[0].title == "Alpha")
    }

    @Test func emptyInputGivesEmptyLibrary() {
        let lib = LibraryBuilder.build(from: [])
        #expect(lib == Library(continueWatching: [], recentlyRecorded: [], shows: []))
    }
}

@Suite("LibraryBuilder show fields") struct LibraryShowFieldTests {
    @Test func posterIsTheNewestRecordingsPoster() {
        let lib = LibraryBuilder.build(from: [
            rec(1, start: 0, artwork: [poster("old")]), rec(2, start: 10, artwork: [poster("new")]),
        ])
        #expect(lib.shows[0].poster == poster("new"))
    }

    @Test func posterFallsBackToNewestRecordingThatHasOne() {
        let fanart = ArtworkReference(kind: .fanart, locator: "f")
        let lib = LibraryBuilder.build(from: [
            rec(1, start: 0, artwork: [poster("old")]), rec(2, start: 5, artwork: [poster("mid")]),
            rec(3, start: 10, artwork: [fanart]),
        ])
        #expect(lib.shows[0].poster == poster("mid"))
    }

    @Test func posterIsNilWhenNoRecordingHasOne() {
        let fanart = ArtworkReference(kind: .fanart, locator: "f")
        #expect(LibraryBuilder.build(from: [rec(1, artwork: [fanart])]).shows[0].poster == nil)
    }

    @Test func newestIsTheLatestRecordingStart() {
        let lib = LibraryBuilder.build(from: [
            rec(1, start: 10, modified: 900), rec(2, start: 40, modified: 1), rec(3, start: 20),
        ])
        #expect(lib.shows[0].newest == at(40))
    }

    @Test func kindIsTheNewestRecordingsKind() {
        let lib = LibraryBuilder.build(from: [
            rec(1, kind: .movie, start: 0), rec(2, kind: .series, start: 10),
        ])
        #expect(lib.shows[0].kind == .series)
    }

    @Test func showRecordingsAreNewestFirstWithIdTieBreak() {
        let lib = LibraryBuilder.build(from: [
            rec(1, start: 10), rec(2, start: 30), rec(3, start: 30), rec(4, start: 20),
        ])
        #expect(ids(lib.shows[0].recordings) == [3, 2, 4, 1])
    }

    @Test func countsRecordingsAndUnwatched() {
        let lib = LibraryBuilder.build(from: [
            rec(1, episode: 1, flags: .watched), rec(2, episode: 2), rec(3, episode: 3),
        ])
        #expect(lib.shows[0].episodeCount == 3)
        #expect(lib.shows[0].unwatchedCount == 2)
    }

    @Test func sameEpisodeRecordedTwiceCountsTwice() {
        let lib = LibraryBuilder.build(from: [rec(1, episode: 4), rec(2, episode: 4, start: 5)])
        #expect(lib.shows[0].episodeCount == 2)
        #expect(lib.shows[0].unwatchedCount == 2)
    }
}

@Suite("LibraryBuilder sortTitle") struct SortTitleTests {
    @Test(arguments: [
        ("The Alpha", "alpha"), ("A Alpha", "alpha"), ("An Alpha", "alpha"),
        ("the alpha", "alpha"), ("THE ALPHA", "alpha"), ("tHe  Alpha", "alpha"),
        ("  The Alpha", "alpha"), ("\"The Alpha\"", "alpha\""), ("...A Alpha", "alpha"),
        ("Alpha", "alpha"), ("Theory", "theory"), ("Another", "another"), ("Anthem", "anthem"),
        ("The", "the"), ("A", "a"), ("An", "an"), ("The ", "the"), ("The: Alpha", "the: alpha"),
        ("The The", "the"), ("Café", "cafe"),
    ])
    func sortTitle(input: String, expected: String) {
        #expect(LibraryBuilder.sortTitle(input) == expected)
    }

    @Test func titleOfOnlyPunctuationIsKept() {
        #expect(LibraryBuilder.sortTitle("!!!") == "!!!")
    }

    @Test func emptyTitleGivesEmpty() {
        #expect(LibraryBuilder.sortTitle("   ") == "")
    }
}

@Suite("LibraryBuilder shows order") struct ShowsOrderTests {
    @Test func ordersBySortTitleIgnoringArticlesAndCase() {
        let lib = LibraryBuilder.build(from: [
            rec(1, "The Zebra", key: "z"), rec(2, "apple", key: "a"), rec(3, "A Mango", key: "m"),
            rec(4, "Banana", key: "b"),
        ])
        #expect(lib.shows.map(\.title) == ["apple", "Banana", "A Mango", "The Zebra"])
    }

    @Test func equalSortTitlesBreakByTitleThenId() {
        let lib = LibraryBuilder.build(from: [
            rec(1, "The Alpha", key: "k2"), rec(2, "Alpha", key: "k3"), rec(3, "Alpha", key: "k1"),
        ])
        #expect(lib.shows.map(\.id) == ["series:k1", "series:k3", "series:k2"])
    }
}

@Suite("LibraryBuilder shelves") struct ShelfTests {
    @Test func continueWatchingFiltersAndOrdersByLastModifiedNewestFirst() {
        let lib = LibraryBuilder.build(from: [
            rec(1, modified: 10, flags: .hasResumePosition),
            rec(2, modified: 30, flags: .hasResumePosition),
            rec(3, modified: 50),  // no resume position
            rec(4, modified: 40, flags: [.hasResumePosition, .watched]),  // watched
            rec(5, modified: 20, flags: [.hasResumePosition, .hasBookmark]),
            rec(6, modified: 60, flags: .hasBookmark),  // bookmark alone is not a resume position
        ])
        #expect(ids(lib.continueWatching) == [2, 5, 1])
    }

    @Test func continueWatchingTiesBreakByRecordingStartThenId() {
        let lib = LibraryBuilder.build(from: [
            rec(1, start: 5, modified: 10, flags: .hasResumePosition),
            rec(2, start: 9, modified: 10, flags: .hasResumePosition),
            rec(3, start: 9, modified: 10, flags: .hasResumePosition),
        ])
        #expect(ids(lib.continueWatching) == [3, 2, 1])
    }

    @Test func continueWatchingIncludesRecordingInProgress() {
        let lib = LibraryBuilder.build(from: [
            rec(1, flags: [.hasResumePosition, .recordingInProgress])
        ])
        #expect(ids(lib.continueWatching) == [1])
    }

    @Test func continueWatchingIsCappedAtTwentyAfterSorting() {
        let input = (1...25).map { rec($0, modified: Double($0), flags: .hasResumePosition) }
        let lib = LibraryBuilder.build(from: input)
        #expect(lib.continueWatching.count == 20)
        #expect(ids(lib.continueWatching) == Array((6...25).reversed()))
    }

    @Test func continueWatchingCapIsAppliedAfterFiltering() {
        var input = (1...25).map { rec($0, modified: Double($0), flags: .hasResumePosition) }
        input += (100...110).map { rec($0, modified: 1000 + Double($0), flags: .watched) }
        #expect(LibraryBuilder.build(from: input).continueWatching.count == 20)
    }

    @Test func recentlyRecordedOrdersByRecordingStartNewestFirst() {
        let lib = LibraryBuilder.build(from: [
            rec(1, start: 10), rec(2, start: 30), rec(3, start: 20), rec(4, start: 30),
        ])
        #expect(ids(lib.recentlyRecorded) == [4, 2, 3, 1])
    }

    @Test func recentlyRecordedIncludesWatchedAndInProgress() {
        let lib = LibraryBuilder.build(from: [
            rec(1, start: 1, flags: .watched), rec(2, start: 2, flags: .recordingInProgress),
        ])
        #expect(ids(lib.recentlyRecorded) == [2, 1])
    }

    @Test func recentlyRecordedIsCappedAtTwenty() {
        let input = (1...30).map { rec($0, start: Double($0)) }
        let lib = LibraryBuilder.build(from: input)
        #expect(ids(lib.recentlyRecorded) == Array((11...30).reversed()))
    }
}

@Suite("LibraryBuilder deletePending") struct DeletePendingTests {
    @Test func excludedFromEverything() {
        let lib = LibraryBuilder.build(from: [
            rec(1, episode: 1, start: 1, modified: 1, flags: .hasResumePosition),
            rec(2, episode: 2, start: 2, modified: 2, flags: [.hasResumePosition, .deletePending]),
            rec(3, episode: 3, start: 3, modified: 3, flags: .deletePending),
        ])
        #expect(ids(lib.continueWatching) == [1])
        #expect(ids(lib.recentlyRecorded) == [1])
        let show = lib.shows[0]
        #expect(ids(show.recordings) == [1])
        #expect(show.episodeCount == 1)
        #expect(show.unwatchedCount == 1)
        #expect(show.newest == at(1))
        #expect(LibraryBuilder.seasons(of: show).flatMap(\.episodes).map(\.id.rawValue) == [1])
    }

    @Test func showWithOnlyDeletePendingRecordingsDisappears() {
        let lib = LibraryBuilder.build(from: [
            rec(1, flags: .deletePending), rec(2, "Beta", key: "b"),
        ])
        #expect(lib.shows.map(\.title) == ["Beta"])
    }

    @Test func deletePendingDoesNotInfluenceTitleOrPoster() {
        let lib = LibraryBuilder.build(from: [
            rec(1, "Alpha", start: 0, artwork: [poster("kept")]),
            rec(2, "Zed", start: 50, flags: .deletePending, artwork: [poster("gone")]),
            rec(3, "Zed", start: 60, flags: .deletePending),
        ])
        #expect(lib.shows[0].title == "Alpha")
        #expect(lib.shows[0].poster == poster("kept"))
    }
}

@Suite("LibraryBuilder seasons") struct SeasonsTests {
    private func seasons(_ recordings: [Recording]) -> [Season] {
        LibraryBuilder.seasons(of: LibraryBuilder.build(from: recordings).shows[0])
    }

    @Test func numberedSeasonsAscendingWithOtherEpisodesLast() {
        let s = seasons([
            rec(1, season: nil), rec(2, season: 10), rec(3, season: 2), rec(4, season: 1),
        ])
        #expect(s.map(\.id) == [1, 2, 10, nil])
        #expect(s.map(\.title) == ["Season 1", "Season 2", "Season 10", "Other Episodes"])
    }

    @Test func showWithOnlyUnnumberedEpisodesHasOneOtherEpisodesSeason() {
        let s = seasons([rec(1, season: nil), rec(2, season: nil, episode: 2)])
        #expect(s.count == 1)
        #expect(s[0].id == nil)
        #expect(s[0].title == "Other Episodes")
        #expect(s[0].episodes.count == 2)
    }

    @Test func episodesOrderedByEpisodeNumber() {
        let s = seasons([rec(1, episode: 3), rec(2, episode: 1), rec(3, episode: 2)])
        #expect(ids(s[0].episodes) == [2, 3, 1])
    }

    @Test func episodeTiesBreakByRecordingStartThenId() {
        let s = seasons([
            rec(1, episode: 2, start: 30), rec(2, episode: 2, start: 10),
            rec(4, episode: 2, start: 20), rec(3, episode: 2, start: 20),
        ])
        #expect(ids(s[0].episodes) == [2, 3, 4, 1])
    }

    @Test func episodeWithoutNumberSortsAfterNumberedEpisodesInItsSeason() {
        let s = seasons([
            rec(1, episode: nil, start: 0), rec(2, episode: 5, start: 100), rec(3, episode: 1),
        ])
        #expect(ids(s[0].episodes) == [3, 2, 1])
    }

    @Test func movieHasOneUnnamedSeason() {
        let s = seasons([rec(1, "Film", key: "m", kind: .movie, season: nil, episode: nil)])
        #expect(s.count == 1)
        #expect(s[0].id == nil)
        #expect(s[0].title == "")
        #expect(ids(s[0].episodes) == [1])
    }

    @Test func movieWithSeveralAiringsKeepsOneSeasonOrderedByRecordingStart() {
        let s = seasons([
            rec(1, "Film", key: "m", kind: .movie, season: 2, episode: 9, start: 50),
            rec(2, "Film", key: "m", kind: .movie, season: nil, episode: nil, start: 10),
        ])
        #expect(s.count == 1)
        #expect(ids(s[0].episodes) == [2, 1])
    }

    @Test func showWithNoRecordingsHasNoSeasons() {
        let show = Show(
            id: "x", title: "x", kind: .series, poster: nil, episodeCount: 0, unwatchedCount: 0,
            newest: at(0), recordings: [])
        #expect(LibraryBuilder.seasons(of: show).isEmpty)
    }
}

@Suite("LibraryBuilder determinism") struct DeterminismTests {
    @Test func inputOrderDoesNotChangeTheLibrary() {
        let input: [Recording] = [
            rec(1, "Alpha", start: 10, modified: 5, flags: .hasResumePosition, artwork: [poster("a")]),
            rec(2, "Alpha Two", start: 10, modified: 5, flags: .hasResumePosition),
            rec(3, "Beta", key: nil, season: nil, start: 10, modified: 5),
            rec(4, "beta", key: nil, season: nil, start: 10, modified: 5),
            rec(5, "Alpha", episode: 1, start: 10),
            rec(6, "Film", key: "f", kind: .movie, start: 20, artwork: [poster("f1")]),
            rec(7, "Film", key: "f", kind: .series, start: 20, artwork: [poster("f2")]),
            rec(8, "Gamma", key: "g", start: 3, flags: .deletePending),
        ]
        let permutations: [[Int]] = [
            [7, 6, 5, 4, 3, 2, 1, 0], [3, 0, 6, 1, 7, 2, 5, 4], [4, 5, 0, 7, 2, 6, 1, 3],
        ]
        let expected = LibraryBuilder.build(from: input)
        for p in permutations {
            let lib = LibraryBuilder.build(from: p.map { input[$0] })
            #expect(lib == expected)
            for (a, b) in zip(lib.shows, expected.shows) {
                #expect(LibraryBuilder.seasons(of: a) == LibraryBuilder.seasons(of: b))
            }
        }
    }

    @Test func largeInputBuildsQuickly() {
        let input = (0..<5000).map { rec($0, "Show \($0 % 400)", key: "k\($0 % 400)", episode: $0) }
        #expect(LibraryBuilder.build(from: input).shows.count == 400)
    }
}
