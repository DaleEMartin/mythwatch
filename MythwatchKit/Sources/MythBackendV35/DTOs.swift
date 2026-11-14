import Foundation

// Wire shapes of the v35 services API (docs/BACKEND-V35.md). Internal to this target. Nothing here
// knows about the domain; `RecordingMapper` does the translation.

// MARK: - Scalar envelopes

/// `{"long": "581614"}` (a string on the wire; a JSON number is accepted too).
struct LongEnvelopeDTO: Decodable, Equatable {
    let value: Int64
    private enum CodingKeys: String, CodingKey { case long }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let v = c.lenientInt64(.long) else {
            throw DecodingError.dataCorruptedError(
                forKey: .long, in: c, debugDescription: "not an integer")
        }
        value = v
    }
}

/// `{"bool": true}` (a string or 0/1 is accepted too).
struct BoolEnvelopeDTO: Decodable, Equatable {
    let value: Bool
    private enum CodingKeys: String, CodingKey { case bool }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let v = LenientNumber.bool(from: c, key: .bool) else {
            throw DecodingError.dataCorruptedError(
                forKey: .bool, in: c, debugDescription: "not a boolean")
        }
        value = v
    }
}

/// `{"String": "x"}`.
struct StringEnvelopeDTO: Decodable, Equatable {
    let value: String
    private enum CodingKeys: String, CodingKey { case string = "String" }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        value = try c.decode(String.self, forKey: .string)
    }
}

// MARK: - Programme

struct ChannelDTO: Decodable, Equatable {
    let chanId: Int64
    let chanNum: String?
    let callSign: String?
    let channelName: String?

    private enum CodingKeys: String, CodingKey {
        case chanId = "ChanId", chanNum = "ChanNum", callSign = "CallSign", channelName = "ChannelName"
    }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        chanId = c.lenientInt64(.chanId) ?? 0
        chanNum = c.lenientString(.chanNum)
        callSign = c.lenientString(.callSign)
        channelName = c.lenientString(.channelName)
    }
}

struct RecordingDTO: Decodable, Equatable {
    let recordedId: Int64?
    let startTs: String?
    let endTs: String?
    let recGroup: String?

    private enum CodingKeys: String, CodingKey {
        case recordedId = "RecordedId", startTs = "StartTs", endTs = "EndTs", recGroup = "RecGroup"
    }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        recordedId = c.lenientInt64(.recordedId)
        startTs = c.lenientString(.startTs)
        endTs = c.lenientString(.endTs)
        recGroup = c.lenientString(.recGroup)
    }
}

struct ArtworkInfoDTO: Decodable, Equatable {
    let url: String?
    let type: String?

    private enum CodingKeys: String, CodingKey { case url = "URL", type = "Type" }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = c.lenientString(.url)
        type = c.lenientString(.type)
    }
}

/// `{"ArtworkInfos": [...]}`; the key can be absent or null.
struct ArtworkDTO: Decodable, Equatable {
    let artworkInfos: [ArtworkInfoDTO]

    private enum CodingKeys: String, CodingKey { case artworkInfos = "ArtworkInfos" }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        artworkInfos = c.lossyArray(ArtworkInfoDTO.self, .artworkInfos)
    }
}

struct ProgramDTO: Decodable, Equatable {
    let title: String?
    let subtitle: String?
    let descriptionText: String?
    let category: String?
    let catType: String?
    let season: Int64
    let episode: Int64
    let airdate: String?
    let inetref: String?
    let startTime: String?
    let endTime: String?
    let lastModified: String?
    let fileSize: Int64
    let programFlagNames: String?
    let videoPropNames: String?
    let channel: ChannelDTO?
    let recording: RecordingDTO?
    let artwork: ArtworkDTO?
    // `Cast` is deliberately not decoded: it is ignored in v1.

    private enum CodingKeys: String, CodingKey {
        case title = "Title", subtitle = "SubTitle", descriptionText = "Description"
        case category = "Category", catType = "CatType", season = "Season", episode = "Episode"
        case airdate = "Airdate", inetref = "Inetref", startTime = "StartTime", endTime = "EndTime"
        case lastModified = "LastModified", fileSize = "FileSize"
        case programFlagNames = "ProgramFlagNames", videoPropNames = "VideoPropNames"
        case channel = "Channel", recording = "Recording", artwork = "Artwork"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = c.lenientString(.title)
        subtitle = c.lenientString(.subtitle)
        descriptionText = c.lenientString(.descriptionText)
        category = c.lenientString(.category)
        catType = c.lenientString(.catType)
        season = c.lenientInt64(.season) ?? 0
        episode = c.lenientInt64(.episode) ?? 0
        airdate = c.lenientString(.airdate)
        inetref = c.lenientString(.inetref)
        startTime = c.lenientString(.startTime)
        endTime = c.lenientString(.endTime)
        lastModified = c.lenientString(.lastModified)
        fileSize = c.lenientInt64(.fileSize) ?? 0
        programFlagNames = c.lenientString(.programFlagNames)
        videoPropNames = c.lenientString(.videoPropNames)
        channel = c.lenientObject(ChannelDTO.self, .channel)
        recording = c.lenientObject(RecordingDTO.self, .recording)
        artwork = c.lenientObject(ArtworkDTO.self, .artwork)
    }
}

// MARK: - Envelopes

/// `{"Program": {...}}` from `GetRecorded`.
struct ProgramEnvelopeDTO: Decodable, Equatable {
    let program: ProgramDTO
    private enum CodingKeys: String, CodingKey { case program = "Program" }
}

/// The `ProgramList` object from `GetRecordedList`. Undecodable rows are dropped here.
struct ProgramListDTO: Decodable, Equatable {
    let startIndex: Int64
    let count: Int64
    let totalAvailable: Int64
    let asOf: String?
    let version: String?
    let protoVer: String?
    let programs: [ProgramDTO]

    private enum CodingKeys: String, CodingKey {
        case startIndex = "StartIndex", count = "Count", totalAvailable = "TotalAvailable"
        case asOf = "AsOf", version = "Version", protoVer = "ProtoVer", programs = "Programs"
    }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        startIndex = c.lenientInt64(.startIndex) ?? 0
        count = c.lenientInt64(.count) ?? 0
        totalAvailable = c.lenientInt64(.totalAvailable) ?? 0
        asOf = c.lenientString(.asOf)
        version = c.lenientString(.version)
        protoVer = c.lenientString(.protoVer)
        programs = c.lossyArray(ProgramDTO.self, .programs)
    }
}

struct ProgramListEnvelopeDTO: Decodable, Equatable {
    let programList: ProgramListDTO
    private enum CodingKeys: String, CodingKey { case programList = "ProgramList" }
}

// MARK: - Commercial breaks

/// One entry of the cut list. `Mark` 4 = commercial start, 5 = end; `Offset` is in milliseconds.
/// Pairing marks into ranges is the adapter's job (M1-7), not the DTO's.
struct CutMarkDTO: Decodable, Equatable {
    let mark: Int64?
    let offset: Int64?

    private enum CodingKeys: String, CodingKey { case mark = "Mark", offset = "Offset" }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mark = c.lenientInt64(.mark)
        offset = c.lenientInt64(.offset)
    }
}

struct CutListDTO: Decodable, Equatable {
    let cuttings: [CutMarkDTO]
    private enum CodingKeys: String, CodingKey { case cuttings = "Cuttings" }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cuttings = c.lossyArray(CutMarkDTO.self, .cuttings)
    }
}

struct CutListEnvelopeDTO: Decodable, Equatable {
    let cutList: CutListDTO
    private enum CodingKeys: String, CodingKey { case cutList = "CutList" }
}
