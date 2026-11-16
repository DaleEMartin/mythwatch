import Foundation
import MythwatchDomain
import MythwatchFeatures
import MythwatchTestSupport
import Testing

/// SPEC 6.4 "Artwork": which image URLs a screen tries, in order, before its titled placeholder.
@MainActor
@Suite("ArtworkURLs")
struct ArtworkURLsTests {
    let media = FakeMediaLocator()
    var artwork: ArtworkURLs { ArtworkURLs(media: media) }

    let poster = ArtworkReference(kind: .poster, locator: "p.jpg")
    let fanart = ArtworkReference(kind: .fanart, locator: "f.jpg")

    func show(_ recordings: [Recording]) -> Show {
        LibraryBuilder.build(from: recordings).shows[0]
    }

    @Test func aShowWithAPosterTriesThePosterThenTheNewestRecordingsPreview() {
        let s = show([episode(1, day: 0), .fixture(
            id: rid(2), title: "Garden Tales", seriesKey: "KEY-GARDEN",
            recordingStart: Date(timeIntervalSince1970: 1_800_000_000), artwork: [poster])])
        #expect(artwork.poster(for: s, maxWidth: 320) == [
            media.artworkURL(for: poster, maxWidth: 320)!,
            media.previewImageURL(for: s.recordings[0], maxWidth: 320),
        ])
        #expect(s.recordings[0].id == rid(2))
    }

    @Test func aShowWithoutAPosterTriesOnlyTheNewestRecordingsPreview() {
        let s = show([episode(1), episode(2)])
        #expect(artwork.poster(for: s, maxWidth: 640) == [media.previewImageURL(for: s.recordings[0], maxWidth: 640)])
    }

    @Test func aShowWithNoRecordingsHasNothingToTry() {
        var s = show([episode(1)])
        s.recordings = []
        s.poster = nil
        #expect(artwork.poster(for: s, maxWidth: 320).isEmpty)
    }

    @Test func fanartComesFromTheNewestRecordingThatHasOne() {
        let older = Recording.fixture(
            id: rid(1), title: "Garden Tales", seriesKey: "K",
            recordingStart: Date(timeIntervalSince1970: 1_700_000_000), artwork: [fanart])
        let newer = Recording.fixture(
            id: rid(2), title: "Garden Tales", seriesKey: "K",
            recordingStart: Date(timeIntervalSince1970: 1_800_000_000), artwork: [poster])
        #expect(artwork.fanart(for: show([older, newer]), maxWidth: 1280) == media.artworkURL(for: fanart, maxWidth: 1280))
        #expect(artwork.fanart(for: show([episode(1)]), maxWidth: 1280) == nil)
    }

    @Test func aRecordingCardTriesItsPreviewImage() {
        let r = episode(3)
        #expect(artwork.thumbnail(for: r, maxWidth: 640) == [media.previewImageURL(for: r, maxWidth: 640)])
    }

    @Test func aRecordingsPosterIsItsOwnPosterThenItsPreview() {
        let r = Recording.fixture(id: rid(4), artwork: [fanart, poster])
        #expect(artwork.poster(for: r, maxWidth: 320) == [
            media.artworkURL(for: poster, maxWidth: 320)!, media.previewImageURL(for: r, maxWidth: 320),
        ])
    }
}
