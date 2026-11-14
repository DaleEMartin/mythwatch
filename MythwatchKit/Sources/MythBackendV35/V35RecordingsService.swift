import Foundation
import MythwatchBackend
import MythwatchDomain

/// `GetRecordedList` (paged) and `GetRecorded`. Write methods are not implemented until
/// M3-5 / M5-1 and send no request.
struct V35RecordingsService: RecordingsService {
    /// Page size from docs/BACKEND-V35.md, "Recordings".
    static let defaultPageSize = 200

    private let client: V35Client
    private let pageSize: Int

    init(
        connection: BackendConnection, transport: any HTTPTransport,
        pageSize: Int = V35RecordingsService.defaultPageSize
    ) {
        self.client = V35Client(connection: connection, transport: transport)
        self.pageSize = max(1, pageSize)
    }

    func allRecordings() async throws -> [Recording] {
        var result: [Recording] = []
        var seen = Set<RecordingID>()
        var startIndex = 0
        while true {
            let list = try await client.get(
                ProgramListEnvelopeDTO.self, path: "/Dvr/GetRecordedList",
                query: [
                    ("Descending", "true"), ("StartIndex", String(startIndex)),
                    ("Count", String(pageSize)), ("IgnoreLiveTV", "true"),
                    ("IgnoreDeleted", "true"), ("IncCast", "false"), ("IncChannel", "true"),
                    ("IncArtWork", "true"), ("IncRecording", "true"),
                ]
            ).programList
            for recording in RecordingMapper.recordings(from: list) where seen.insert(recording.id).inserted {
                result.append(recording)
            }
            let received = max(Int(clamping: list.count), list.programs.count)
            startIndex += received
            if received == 0 || Int64(startIndex) >= list.totalAvailable { break }
        }
        return result
    }

    func recording(id: RecordingID) async throws -> Recording {
        let program = try await client.get(
            ProgramEnvelopeDTO.self, path: "/Dvr/GetRecorded",
            query: [("RecordedId", String(id.rawValue))]
        ).program
        if RecordingMapper.isNotFound(program) { throw BackendError.notFound }
        guard let recording = RecordingMapper.recording(from: program) else {
            throw BackendError.malformedResponse("/Dvr/GetRecorded: programme is incomplete")
        }
        return recording
    }

    func setWatched(_ watched: Bool, id: RecordingID) async throws {
        throw V35NotImplemented.error
    }

    func delete(id: RecordingID, allowRerecord: Bool) async throws {
        throw V35NotImplemented.error
    }
}

/// What every write stub throws, before any request is built.
enum V35NotImplemented {
    static let error = BackendError.rejected("not implemented until M3-5 / M5-1")
}
