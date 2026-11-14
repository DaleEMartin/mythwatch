import Foundation
import MythwatchDomain
import MythwatchTestSupport
import Testing

@testable import MythBackendV35

// MARK: - Helpers

/// Values read from `recorded-one.json` (the first row of `recorded-list-page1.json`). When the
/// fixture's real titles are replaced, this is the one place to edit.
private enum One {
    static let title = "Amber Street Sessions"
    static let subtitle = "The Harbor Lights"
    static let synopsis =
        "A hometown set from The Harbor Lights, with songs from their new album \"Low Tide.\""
    static let category = "Music"
    static let seriesKey = "ttvdb4.py_900101"
    static let season = 50
    static let episode = 10
    static let recordedID = 33
    static let fileSize: Int64 = 3_728_761_544
    static let channelNumber = "7_1"
    static let callSign = "KMWA-HD"
    static let channelName = "KMWA-HD"
    static let locator =
        "/Content/GetImageFile?StorageGroup=Coverart&FileName=%2FAmber%20Street%20Sessions%20Season%2050_coverart.jpg"
    // 2025-01-19T04:00:00Z and neighbours, as seconds since 1970.
    static let start = Date(timeIntervalSince1970: 1_737_259_200)
    static let end = Date(timeIntervalSince1970: 1_737_262_800)
    static let lastModified = Date(timeIntervalSince1970: 1_737_262_810)
    static let recEnd = Date(timeIntervalSince1970: 1_737_262_801)
}

private func data(_ name: String) throws -> Data {
    try FixtureLoader.data(named: name, in: Bundle.module, subdirectory: "Fixtures")
}

private func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
    try JSONDecoder().decode(type, from: data(name))
}

private func program(fixture name: String = "recorded-one") throws -> ProgramDTO {
    try decode(ProgramEnvelopeDTO.self, name).program
}

private func mapped(fixture name: String = "recorded-one") throws -> Recording {
    try #require(RecordingMapper.recording(from: program(fixture: name)))
}

private func rowObject(_ name: String = "recorded-one") throws -> [String: Any] {
    let root = try #require(JSONSerialization.jsonObject(with: data(name)) as? [String: Any])
    return try #require(root["Program"] as? [String: Any])
}

private func json(_ object: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: object)
}

/// A programme derived from the real `recorded-one.json` row with `edit` applied.
private func edited(_ edit: (inout [String: Any]) -> Void) throws -> ProgramDTO {
    var row = try rowObject()
    edit(&row)
    return try JSONDecoder().decode(ProgramDTO.self, from: json(row))
}

private func mappedEdited(_ edit: (inout [String: Any]) -> Void) throws -> Recording {
    try #require(RecordingMapper.recording(from: edited(edit)))
}

private func listPage(rows: [Any]) throws -> ProgramListDTO {
    let body: [String: Any] = [
        "ProgramList": [
            "StartIndex": 0, "Count": rows.count, "TotalAvailable": rows.count,
            "AsOf": "2026-11-14T22:14:40Z", "Version": "35.20220913-1", "ProtoVer": "91",
            "Programs": rows,
        ] as [String: Any]
    ]
    return try JSONDecoder().decode(ProgramListEnvelopeDTO.self, from: json(body)).programList
}

// MARK: - Programme table

@Suite struct ProgramMappingTests {
    @Test func titleMapsToTitle() throws { #expect(try mapped().title == One.title) }
    @Test func subTitleMapsToSubtitle() throws { #expect(try mapped().subtitle == One.subtitle) }
    @Test func descriptionMapsToSynopsis() throws { #expect(try mapped().synopsis == One.synopsis) }
    @Test func categoryMapsToCategory() throws { #expect(try mapped().category == One.category) }
    @Test func catTypeMapsToKind() throws { #expect(try mapped().kind == .series) }
    @Test func seasonMapsToSeason() throws { #expect(try mapped().season == One.season) }
    @Test func episodeMapsToEpisode() throws { #expect(try mapped().episode == One.episode) }
    @Test func airdateMapsToOriginalAirDate() throws {
        #expect(try mapped().originalAirDate == CalendarDay(year: 2025, month: 1, day: 18))
    }
    @Test func inetrefMapsToSeriesKey() throws { #expect(try mapped().seriesKey == One.seriesKey) }
    @Test func startAndEndTimeMapToScheduledTimes() throws {
        let r = try mapped()
        #expect(r.scheduledStart == One.start)
        #expect(r.scheduledEnd == One.end)
    }
    @Test func lastModifiedMapsToLastModified() throws {
        #expect(try mapped().lastModified == One.lastModified)
    }
    @Test func fileSizeMapsToInt64() throws {
        #expect(try mapped().fileSize == One.fileSize)
        #expect(One.fileSize > Int64(Int32.max))
    }
    @Test func programFlagNamesMapToFlags() throws { #expect(try mapped().flags == [.commercialsFlagged]) }
    @Test func videoPropNamesMapToVideo() throws {
        #expect(
            try mapped().video
                == VideoTraits(isHD: true, isWidescreen: true, verticalResolution: 1080))
    }
    @Test func channelMapsToChannelSummary() throws {
        #expect(
            try mapped().channel
                == ChannelSummary(
                    number: One.channelNumber, callSign: One.callSign, name: One.channelName))
    }
    @Test func artworkMapsToArtworkReferences() throws {
        #expect(try mapped().artwork == [ArtworkReference(kind: .poster, locator: One.locator)])
    }
    @Test func castIsIgnored() throws {
        let withCast = try mappedEdited { $0["Cast"] = ["CastMembers": [["Name": "x"]]] }
        #expect(withCast == (try mapped()))
    }
    @Test func unknownKeysAreIgnoredEverywhere() throws {
        let r = try mappedEdited { row in
            row["BrandNewKey"] = ["a": 1]
            var rec = row["Recording"] as? [String: Any] ?? [:]
            rec["BrandNewKey"] = "x"
            row["Recording"] = rec
            var ch = row["Channel"] as? [String: Any] ?? [:]
            ch["BrandNewKey"] = [1, 2]
            row["Channel"] = ch
        }
        #expect(r == (try mapped()))
    }
}

// MARK: - Recording object table

@Suite struct RecordingObjectMappingTests {
    @Test func recordedIdMapsToId() throws { #expect(try mapped().id == RecordingID(rawValue: One.recordedID)) }
    @Test func startTsAndEndTsMapToRecordingTimes() throws {
        let r = try mapped()
        #expect(r.recordingStart == One.start)
        #expect(r.recordingEnd == One.recEnd)
    }
    @Test func recGroupMapsToRecordingGroup() throws { #expect(try mapped().recordingGroup == "Default") }
    @Test func missingRecGroupIsEmptyString() throws {
        let r = try mappedEdited { row in
            var rec = row["Recording"] as? [String: Any] ?? [:]
            rec.removeValue(forKey: "RecGroup")
            row["Recording"] = rec
        }
        #expect(r.recordingGroup == "")
    }
}

// MARK: - Nil, zero and missing handling

@Suite struct OptionalFieldTests {
    @Test(arguments: ["SubTitle", "Description", "Category", "Inetref"])
    func emptyStringBecomesNil(key: String) throws {
        let r = try mappedEdited { $0[key] = "" }
        #expect(r.subtitle == (key == "SubTitle" ? nil : One.subtitle))
        #expect(r.synopsis == (key == "Description" ? nil : One.synopsis))
        #expect(r.category == (key == "Category" ? nil : One.category))
        #expect(r.seriesKey == (key == "Inetref" ? nil : One.seriesKey))
    }

    @Test func nullStringBecomesNil() throws {
        let r = try mappedEdited { row in
            for k in ["SubTitle", "Description", "Category", "Inetref"] { row[k] = NSNull() }
        }
        #expect(r.subtitle == nil && r.synopsis == nil && r.category == nil && r.seriesKey == nil)
    }

    @Test func seasonAndEpisodeZeroBecomeNil() throws {
        let r = try mappedEdited { $0["Season"] = 0; $0["Episode"] = 0 }
        #expect(r.season == nil)
        #expect(r.episode == nil)
    }

    @Test func seasonAndEpisodeMayArriveAsStrings() throws {
        let r = try mappedEdited { $0["Season"] = "7"; $0["Episode"] = "3" }
        #expect(r.season == 7)
        #expect(r.episode == 3)
    }

    @Test func nullAirdateFixture() throws {
        let r = try mapped(fixture: "recorded-one-airdate-null")
        #expect(r.originalAirDate == nil)
        #expect(r.title == One.title)
    }

    @Test func emptyAirdateBecomesNil() throws {
        #expect(try mappedEdited { $0["Airdate"] = "" }.originalAirDate == nil)
    }

    @Test func malformedAirdateBecomesNil() throws {
        #expect(try mappedEdited { $0["Airdate"] = "18/01/2025" }.originalAirDate == nil)
    }

    @Test func movieAirdateOfJanuaryFirstIsKept() throws {
        let page: ProgramListEnvelopeDTO = try decode(ProgramListEnvelopeDTO.self, "recorded-list-page1")
        let movie = try #require(RecordingMapper.recordings(from: page.programList).first { $0.kind == .movie })
        #expect(movie.originalAirDate?.month == 1 && movie.originalAirDate?.day == 1)
        #expect(movie.subtitle == nil)
        #expect(movie.season == nil && movie.episode == nil)
        #expect(movie.artwork.isEmpty)
    }

    @Test func nullArtworkFixture() throws {
        #expect(try mapped(fixture: "recorded-one-artwork-null").artwork.isEmpty)
    }

    @Test func emptyArtworkInfosIsEmpty() throws {
        #expect(try mappedEdited { $0["Artwork"] = ["ArtworkInfos": [Any]()] }.artwork.isEmpty)
    }

    @Test func channelNullIsNil() throws {
        #expect(try mappedEdited { $0["Channel"] = NSNull() }.channel == nil)
    }

    @Test func recordingNullHasNoRecordedId() throws {
        let dto = try edited { $0["Recording"] = NSNull() }
        #expect(RecordingMapper.recording(from: dto) == nil)
    }

    @Test func castNullIsFine() throws {
        #expect(try mappedEdited { $0["Cast"] = NSNull() } == (try mapped()))
    }

    @Test func artworkNullIsFine() throws {
        #expect(try mappedEdited { $0["Artwork"] = NSNull() }.artwork.isEmpty)
    }

    @Test(arguments: ["series", "movie", "tvshow", "sports", "", "documentary", "SERIES"])
    func catTypeMapping(raw: String) throws {
        let expected: ProgramKind
        switch raw {
        case "series", "SERIES": expected = .series
        case "movie": expected = .movie
        case "tvshow": expected = .tvShow
        case "sports": expected = .sports
        default: expected = .unknown
        }
        #expect(try mappedEdited { $0["CatType"] = raw }.kind == expected)
    }

    @Test func missingCatTypeIsUnknown() throws {
        #expect(try mappedEdited { $0.removeValue(forKey: "CatType") }.kind == .unknown)
    }

    @Test func missingFileSizeIsZero() throws {
        #expect(try mappedEdited { $0.removeValue(forKey: "FileSize") }.fileSize == 0)
    }

    @Test func fileSizeMayArriveAsString() throws {
        #expect(try mappedEdited { $0["FileSize"] = "3728761544" }.fileSize == One.fileSize)
    }

    @Test func emptyChannelObjectIsNilChannel() throws {
        let r = try mappedEdited {
            $0["Channel"] = ["ChanId": 5, "ChanNum": NSNull(), "CallSign": "", "ChannelName": NSNull()]
        }
        #expect(r.channel == nil)
    }

    @Test func partialChannelFillsMissingPartsWithEmptyStrings() throws {
        let r = try mappedEdited { $0["Channel"] = ["CallSign": "XYZ"] }
        #expect(r.channel == ChannelSummary(number: "", callSign: "XYZ", name: ""))
    }
}

// MARK: - Rows that must decode but cannot map, and timestamps

@Suite struct RowValidityTests {
    @Test func rowWithEveryOptionalFieldMissingDecodes() throws {
        let dto = try JSONDecoder().decode(ProgramDTO.self, from: Data("{}".utf8))
        #expect(dto.title == nil)
        #expect(dto.recording == nil)
        #expect(dto.channel == nil)
        #expect(dto.artwork == nil)
        #expect(dto.fileSize == 0)
        #expect(RecordingMapper.recording(from: dto) == nil)
    }

    @Test func listWithEveryFieldMissingDecodes() throws {
        let env = try JSONDecoder().decode(
            ProgramListEnvelopeDTO.self, from: Data(#"{"ProgramList": {"Programs": [{}]}}"#.utf8))
        #expect(env.programList.programs.count == 1)
        #expect(env.programList.totalAvailable == 0)
        #expect(RecordingMapper.recordings(from: env.programList).isEmpty)
    }

    @Test func missingOrZeroOrNegativeRecordedIdSkipsRow() throws {
        let missing = try edited { row in
            var rec = row["Recording"] as? [String: Any] ?? [:]
            rec.removeValue(forKey: "RecordedId")
            row["Recording"] = rec
        }
        #expect(RecordingMapper.recording(from: missing) == nil)
        for bad in [0, -4] {
            let dto = try edited { row in
                var rec = row["Recording"] as? [String: Any] ?? [:]
                rec["RecordedId"] = bad
                row["Recording"] = rec
            }
            #expect(RecordingMapper.recording(from: dto) == nil)
        }
    }

    @Test func recordedIdMayArriveAsString() throws {
        let r = try mappedEdited { row in
            var rec = row["Recording"] as? [String: Any] ?? [:]
            rec["RecordedId"] = "33"
            row["Recording"] = rec
        }
        #expect(r.id == RecordingID(rawValue: 33))
    }

    @Test func badRowIsSkippedWhileNeighboursSurvive() throws {
        let good1 = try rowObject()
        var noRecording = try rowObject()
        noRecording["Recording"] = NSNull()
        var zeroId = try rowObject()
        zeroId["Recording"] = ["RecordedId": 0]
        var good2 = try rowObject()
        good2["Recording"] = ["RecordedId": 99, "StartTs": "2025-01-19T04:00:00Z", "EndTs": "2025-01-19T05:00:00Z", "RecGroup": "Default"]
        let page = try listPage(rows: [good1, noRecording, "not an object", zeroId, good2])
        let recs = RecordingMapper.recordings(from: page)
        #expect(recs.map(\.id.rawValue) == [One.recordedID, 99])
    }

    @Test func missingTitleSkipsRow() throws {
        #expect(RecordingMapper.recording(from: try edited { $0["Title"] = NSNull() }) == nil)
        #expect(RecordingMapper.recording(from: try edited { $0["Title"] = "" }) == nil)
    }

    @Test(arguments: ["StartTime", "EndTime", "LastModified"])
    func missingOrBadProgrammeTimestampSkipsRow(key: String) throws {
        #expect(RecordingMapper.recording(from: try edited { $0.removeValue(forKey: key) }) == nil)
        #expect(RecordingMapper.recording(from: try edited { $0[key] = "yesterday" }) == nil)
        #expect(RecordingMapper.recording(from: try edited { $0[key] = NSNull() }) == nil)
    }

    @Test(arguments: ["StartTs", "EndTs"])
    func missingOrBadRecordingTimestampSkipsRow(key: String) throws {
        let dto = try edited { row in
            var rec = row["Recording"] as? [String: Any] ?? [:]
            rec[key] = "2025-13-45T99:00:00Z"
            row["Recording"] = rec
        }
        #expect(RecordingMapper.recording(from: dto) == nil)
    }

    @Test func timestampFormat() {
        #expect(RecordingMapper.timestamp("2025-01-19T04:00:00Z") == One.start)
        #expect(RecordingMapper.timestamp("1970-01-01T00:00:00Z") == Date(timeIntervalSince1970: 0))
        #expect(RecordingMapper.timestamp(nil) == nil)
        #expect(RecordingMapper.timestamp("") == nil)
        #expect(RecordingMapper.timestamp("2025-01-19") == nil)
        #expect(RecordingMapper.timestamp("not a date") == nil)
    }

    @Test func listPagingFieldsDecode() throws {
        let env = try decode(ProgramListEnvelopeDTO.self, "recorded-list-page1")
        #expect(env.programList.startIndex == 0)
        #expect(env.programList.count == 4)
        #expect(env.programList.totalAvailable == 307)
        #expect(env.programList.version == "35.20220913-1")
        #expect(env.programList.protoVer == "91")
        #expect(env.programList.asOf == "2026-11-14T22:55:34Z")
        #expect(env.programList.programs.count == 4)
        let page2 = try decode(ProgramListEnvelopeDTO.self, "recorded-list-page2")
        #expect(page2.programList.startIndex == 4)
        #expect(RecordingMapper.recordings(from: page2.programList).count == 4)
    }

    @Test func pagingNumbersMayArriveAsStrings() throws {
        let env = try JSONDecoder().decode(
            ProgramListEnvelopeDTO.self,
            from: Data(#"{"ProgramList": {"StartIndex": "200", "Count": "3", "TotalAvailable": "307", "Programs": []}}"#.utf8))
        #expect(env.programList.startIndex == 200)
        #expect(env.programList.count == 3)
        #expect(env.programList.totalAvailable == 307)
    }

    @Test func listPageRowsWithNullCastAndNoMissingChannelsAllMap() throws {
        let env = try decode(ProgramListEnvelopeDTO.self, "recorded-list-page1")
        let recs = RecordingMapper.recordings(from: env.programList)
        #expect(recs.count == 4)
        #expect(recs.allSatisfy { $0.channel != nil })
    }
}

// MARK: - Not found

@Suite struct NotFoundTests {
    @Test func blankProgrammeFixtureIsNotFound() throws {
        let dto = try program(fixture: "recorded-missing")
        #expect(RecordingMapper.isNotFound(dto))
        #expect(dto.title == nil)
        #expect(dto.recording == nil)
        #expect(RecordingMapper.recording(from: dto) == nil)
    }

    @Test func realRecordingIsNotNotFound() throws {
        #expect(!RecordingMapper.isNotFound(try program()))
    }

    @Test func nullTitleAloneIsNotFound() throws {
        #expect(RecordingMapper.isNotFound(try edited { $0["Title"] = NSNull() }))
    }

    @Test func nullRecordingAloneIsNotFound() throws {
        #expect(RecordingMapper.isNotFound(try edited { $0["Recording"] = NSNull() }))
    }

    @Test func zeroRecordedIdAloneIsNotFound() throws {
        let dto = try edited { row in
            var rec = row["Recording"] as? [String: Any] ?? [:]
            rec["RecordedId"] = 0
            row["Recording"] = rec
        }
        #expect(RecordingMapper.isNotFound(dto))
    }

    @Test func missingRecordedIdAloneIsNotFound() throws {
        let dto = try edited { row in
            var rec = row["Recording"] as? [String: Any] ?? [:]
            rec.removeValue(forKey: "RecordedId")
            row["Recording"] = rec
        }
        #expect(RecordingMapper.isNotFound(dto))
    }
}

// MARK: - Flags

@Suite struct FlagParsingTests {
    @Test(arguments: [
        ("WATCHED", RecordingFlags.watched),
        ("BOOKMARK", .hasBookmark),
        ("LASTPLAYPOS", .hasResumePosition),
        ("COMMFLAG", .commercialsFlagged),
        ("CUTLIST", .hasCutList),
        ("INUSERECORDING", .recordingInProgress),
        ("DELETEPENDING", .deletePending),
    ])
    func eachNameMapsToItsFlag(name: String, flag: RecordingFlags) {
        #expect(RecordingMapper.flags(fromNames: name) == flag)
    }

    @Test func noneIsEmpty() { #expect(RecordingMapper.flags(fromNames: "NONE") == []) }
    @Test func nilAndEmptyAreEmpty() {
        #expect(RecordingMapper.flags(fromNames: nil) == [])
        #expect(RecordingMapper.flags(fromNames: "") == [])
    }
    @Test func unknownNamesAreIgnored() {
        #expect(RecordingMapper.flags(fromNames: "AUTOEXP|REPEAT|TRANSCODED") == [])
        #expect(RecordingMapper.flags(fromNames: "REPEAT|COMMFLAG|FUTURE") == [.commercialsFlagged])
    }
    @Test func hexNameCountsAsUnknown() {
        #expect(RecordingMapper.flags(fromNames: "0x00100000") == [])
        #expect(RecordingMapper.flags(fromNames: "COMMFLAG|0x00100000") == [.commercialsFlagged])
        // A hex spelling of a known bit is still unknown: only names are parsed.
        #expect(RecordingMapper.flags(fromNames: "0x00000001") == [])
    }
    @Test func namesAreMatchedExactly() {
        #expect(RecordingMapper.flags(fromNames: "watched") == [])
        #expect(RecordingMapper.flags(fromNames: " WATCHED ") == [])
    }
    @Test func numericProgramFlagsAreNotConsulted() throws {
        let r = try mappedEdited { $0["ProgramFlags"] = 0; $0["ProgramFlagNames"] = "WATCHED" }
        #expect(r.flags == [.watched])
    }
    @Test func resumeWatchedBookmarkFixture() throws {
        #expect(
            try mapped(fixture: "recorded-one-resume-watched-bookmark").flags
                == [.commercialsFlagged, .hasBookmark, .watched, .hasResumePosition])
    }
    @Test func deletePendingFixture() throws {
        #expect(try mapped(fixture: "recorded-one-deletepending").flags == [.commercialsFlagged, .deletePending])
    }
    @Test func listRowWithLastPlayPos() throws {
        let page = try decode(ProgramListEnvelopeDTO.self, "recorded-list-page2")
        let recs = RecordingMapper.recordings(from: page.programList)
        #expect(recs.contains { $0.flags.contains(.hasResumePosition) })
        #expect(recs.allSatisfy { $0.flags.contains(.commercialsFlagged) })
    }
}

// MARK: - Video props

@Suite struct VideoPropTests {
    @Test func hdWidescreen1080() {
        #expect(
            RecordingMapper.video(fromNames: "WIDESCREEN|HDTV|MPEG2|1080")
                == VideoTraits(isHD: true, isWidescreen: true, verticalResolution: 1080))
    }
    @Test func widescreenSDHasNoResolution() {
        #expect(
            RecordingMapper.video(fromNames: "WIDESCREEN|MPEG2")
                == VideoTraits(isHD: false, isWidescreen: true, verticalResolution: nil))
    }
    @Test func hd720() {
        #expect(RecordingMapper.video(fromNames: "HDTV|720").verticalResolution == 720)
    }
    @Test func unknownAndNilAreSD() {
        let sd = VideoTraits(isHD: false, isWidescreen: false, verticalResolution: nil)
        #expect(RecordingMapper.video(fromNames: "UNKNOWN") == sd)
        #expect(RecordingMapper.video(fromNames: nil) == sd)
        #expect(RecordingMapper.video(fromNames: "") == sd)
    }
    @Test func damagedIsDetectedAndDoesNotAffectTraits() {
        #expect(RecordingMapper.isDamaged(videoPropNames: "WIDESCREEN|HDTV|DAMAGED"))
        #expect(!RecordingMapper.isDamaged(videoPropNames: "WIDESCREEN|HDTV"))
        #expect(!RecordingMapper.isDamaged(videoPropNames: nil))
        #expect(RecordingMapper.video(fromNames: "HDTV|DAMAGED").isHD)
    }
    @Test func damagedFixtureSetsDamagedFlag() throws {
        let r = try mapped(fixture: "recorded-one-damaged")
        #expect(r.flags == [.commercialsFlagged, .damaged])
        #expect(r.video == VideoTraits(isHD: true, isWidescreen: true, verticalResolution: 1080))
    }
    @Test func damagedCombinesWithProgramFlags() throws {
        let r = try mappedEdited { $0["VideoPropNames"] = "DAMAGED"; $0["ProgramFlagNames"] = "WATCHED" }
        #expect(r.flags == [.watched, .damaged])
    }
}

// MARK: - Artwork and channel

@Suite struct ArtworkAndChannelTests {
    private func dto(_ infos: [[String: Any]]) throws -> ArtworkDTO {
        try JSONDecoder().decode(ArtworkDTO.self, from: json(["ArtworkInfos": infos]))
    }

    @Test func typesMapToKinds() throws {
        let art = try dto([
            ["URL": "/a", "Type": "coverart"], ["URL": "/b", "Type": "fanart"],
            ["URL": "/c", "Type": "banner"], ["URL": "/d", "Type": "screenshot"],
            ["URL": "/e", "Type": ""], ["URL": "/f"],
        ])
        #expect(
            RecordingMapper.artwork(art)
                == [
                    ArtworkReference(kind: .poster, locator: "/a"),
                    ArtworkReference(kind: .fanart, locator: "/b"),
                    ArtworkReference(kind: .banner, locator: "/c"),
                ])
    }

    @Test func locatorIsPreservedVerbatim() throws {
        let odd = "/Content/GetImageFile?StorageGroup=Coverart&FileName=%2FA%20b%2B%C3%A9 c.jpg"
        let art = try dto([["URL": odd, "Type": "coverart"]])
        #expect(RecordingMapper.artwork(art).first?.locator == odd)
    }

    @Test func missingOrEmptyURLIsDropped() throws {
        let art = try dto([["Type": "coverart"], ["URL": "", "Type": "coverart"]])
        #expect(RecordingMapper.artwork(art).isEmpty)
    }

    @Test func nilArtworkIsEmpty() { #expect(RecordingMapper.artwork(nil).isEmpty) }

    @Test func nullArtworkInfosIsEmpty() throws {
        let art = try JSONDecoder().decode(ArtworkDTO.self, from: Data(#"{"ArtworkInfos": null}"#.utf8))
        #expect(RecordingMapper.artwork(art).isEmpty)
    }

    @Test func channelDTOFieldsDecode() throws {
        let dto = try program().channel
        #expect(dto?.chanNum == One.channelNumber)
        #expect(dto?.callSign == One.callSign)
        #expect(dto?.channelName == One.channelName)
    }

    @Test func blankChannelOfMissingProgrammeIsNil() throws {
        #expect(RecordingMapper.channel(try program(fixture: "recorded-missing").channel) == nil)
    }
}

// MARK: - Cut list

@Suite struct CutListDTOTests {
    @Test func commBreakFixtureDecodes() throws {
        let env = try decode(CutListEnvelopeDTO.self, "commbreak")
        let marks = env.cutList.cuttings
        #expect(marks.map(\.mark) == [4, 5, 4, 5])
        #expect(marks.map(\.offset) == [0, 156_990, 3_183_681, 3_526_990])
    }
    @Test func emptyFixtureDecodes() throws {
        #expect(try decode(CutListEnvelopeDTO.self, "commbreak-empty").cutList.cuttings.isEmpty)
    }
    @Test func unbalancedFixtureDecodesInOrder() throws {
        let marks = try decode(CutListEnvelopeDTO.self, "commbreak-unbalanced").cutList.cuttings
        #expect(marks.map(\.mark) == [5, 5, 4, 4, 5, 4])
        #expect(marks.map(\.offset) == [156_990, 1_000_000, 3_183_681, 3_300_000, 3_526_990, 3_600_000])
    }
    @Test func offsetAsStringAndOtherMarksDecode() throws {
        let body = #"{"CutList": {"Cuttings": [{"Mark": 32, "Offset": "29970"}, {"Mark": "4", "Offset": 5}, {"Offset": 7}, 3]}}"#
        let marks = try JSONDecoder().decode(CutListEnvelopeDTO.self, from: Data(body.utf8)).cutList.cuttings
        #expect(marks.count == 3)
        #expect(marks[0].mark == 32 && marks[0].offset == 29_970)
        #expect(marks[1].mark == 4 && marks[1].offset == 5)
        #expect(marks[2].mark == nil && marks[2].offset == 7)
    }
    @Test func missingCuttingsIsEmpty() throws {
        let env = try JSONDecoder().decode(CutListEnvelopeDTO.self, from: Data(#"{"CutList": {}}"#.utf8))
        #expect(env.cutList.cuttings.isEmpty)
    }
}

// MARK: - Scalars

@Suite struct ScalarEnvelopeTests {
    private func long(_ text: String) throws -> Int64 {
        try JSONDecoder().decode(LongEnvelopeDTO.self, from: Data(text.utf8)).value
    }
    private func bool(_ text: String) throws -> Bool {
        try JSONDecoder().decode(BoolEnvelopeDTO.self, from: Data(text.utf8)).value
    }

    @Test func longFromStringFixtures() throws {
        #expect(try decode(LongEnvelopeDTO.self, "lastplaypos-set").value == 581_614)
        #expect(try decode(LongEnvelopeDTO.self, "lastplaypos-zero").value == 0)
    }
    @Test func longFromNumber() throws {
        #expect(try long(#"{"long": 700266}"#) == 700_266)
        #expect(try long(#"{"long": 5000000000}"#) == 5_000_000_000)
    }
    @Test func longNegativeAndStringForms() throws {
        #expect(try long(#"{"long": "-1"}"#) == -1)
        #expect(try long(#"{"long": -1}"#) == -1)
    }
    @Test func longGarbageThrows() {
        #expect(throws: DecodingError.self) { try long(#"{"long": "abc"}"#) }
        #expect(throws: DecodingError.self) { try long(#"{"long": null}"#) }
        #expect(throws: DecodingError.self) { try long(#"{}"#) }
        #expect(throws: DecodingError.self) { try long(#"{"long": true}"#) }
    }
    @Test func boolFromFixtures() throws {
        #expect(try decode(BoolEnvelopeDTO.self, "bool-true").value == true)
        #expect(try decode(BoolEnvelopeDTO.self, "bool-true-string").value == true)
    }
    @Test func boolFalseForms() throws {
        #expect(try bool(#"{"bool": false}"#) == false)
        #expect(try bool(#"{"bool": "false"}"#) == false)
        #expect(try bool(#"{"bool": 0}"#) == false)
        #expect(try bool(#"{"bool": "0"}"#) == false)
    }
    @Test func boolNumberAndOtherTrueForms() throws {
        #expect(try bool(#"{"bool": 1}"#) == true)
        #expect(try bool(#"{"bool": "1"}"#) == true)
        #expect(try bool(#"{"bool": "TRUE"}"#) == true)
    }
    @Test func boolGarbageThrows() {
        #expect(throws: DecodingError.self) { try bool(#"{"bool": "maybe"}"#) }
        #expect(throws: DecodingError.self) { try bool(#"{"bool": 2}"#) }
        #expect(throws: DecodingError.self) { try bool(#"{}"#) }
    }
    @Test func stringEnvelope() throws {
        #expect(try decode(StringEnvelopeDTO.self, "hostname").value == "backend")
    }
    @Test func stringEnvelopeMissingThrows() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(StringEnvelopeDTO.self, from: Data("{}".utf8))
        }
    }
}
