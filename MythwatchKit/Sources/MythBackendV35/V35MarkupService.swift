import Foundation
import MythwatchBackend
import MythwatchDomain

/// `GetRecordedCommBreak`, with the pairing rules of docs/BACKEND-V35.md, "Commercial breaks".
struct V35MarkupService: MarkupService {
    private static let commercialStart: Int64 = 4
    private static let commercialEnd: Int64 = 5
    private static let minimumBreak: Duration = .seconds(5)

    private let client: V35Client

    init(connection: BackendConnection, transport: any HTTPTransport) {
        self.client = V35Client(connection: connection, transport: transport)
    }

    func commercialBreaks(for id: RecordingID) async throws -> [CommercialBreak] {
        let cutList = try await client.get(
            CutListEnvelopeDTO.self, path: "/Dvr/GetRecordedCommBreak",
            query: [("RecordedId", String(id.rawValue)), ("OffsetType", "Duration")]
        ).cutList
        return Self.breaks(from: cutList.cuttings)
    }

    /// Pure, so the rules can be tested without a transport.
    static func breaks(from cuttings: [CutMarkDTO]) -> [CommercialBreak] {
        // Only marks 4 and 5 count (mark 32 is the frame rate); entries without offset are ignored.
        let marks: [(isStart: Bool, offset: Int64)] = cuttings.compactMap { cut in
            guard let mark = cut.mark, let offset = cut.offset, offset >= 0,
                mark == commercialStart || mark == commercialEnd
            else { return nil }
            return (mark == commercialStart, offset)
        }
        // Sort by offset; at equal offsets an end sorts before a start, so back-to-back breaks
        // close before the next one opens.
        let sorted = marks.enumerated().sorted { a, b in
            if a.element.offset != b.element.offset { return a.element.offset < b.element.offset }
            if a.element.isStart != b.element.isStart { return !a.element.isStart }
            return a.offset < b.offset
        }.map(\.element)

        var ranges: [CommercialBreak] = []
        var open: Int64?
        for (index, mark) in sorted.enumerated() {
            if mark.isStart {
                if open == nil { open = mark.offset }  // a second start is dropped
            } else if let start = open {
                append(start, mark.offset, to: &ranges)
                open = nil
            } else if index == 0 {
                append(0, mark.offset, to: &ranges)  // a leading end opens at the very start
            }  // any other end with no open start is dropped
        }
        // A trailing start with no end is dropped (`open` is simply not used).
        return normalise(ranges)
    }

    private static func append(_ start: Int64, _ end: Int64, to ranges: inout [CommercialBreak]) {
        guard let range = CommercialBreak(start: .milliseconds(start), end: .milliseconds(end)),
            range.end - range.start >= minimumBreak
        else { return }
        ranges.append(range)
    }

    /// Sort, drop empty, merge overlapping or touching ranges. The same contract as
    /// `CommercialSkipper.normalise` (SPEC §5.1), which this target may not import.
    static func normalise(_ breaks: [CommercialBreak]) -> [CommercialBreak] {
        var result: [CommercialBreak] = []
        for next in breaks.sorted(by: { ($0.start, $0.end) < ($1.start, $1.end) }) {
            if let last = result.last, next.start <= last.end {
                if next.end > last.end, let merged = CommercialBreak(start: last.start, end: next.end) {
                    result[result.count - 1] = merged
                }
            } else {
                result.append(next)
            }
        }
        return result
    }
}
