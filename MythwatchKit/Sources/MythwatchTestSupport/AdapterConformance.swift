import Foundation
import MythwatchBackend
import MythwatchDomain

/// The shared adapter conformance suite (SPEC §9): behaviour checks written only against
/// `BackendAdapter` and the domain ports. Every adapter must pass every check.
///
/// This target cannot import `Testing`, so a check does not assert. It returns the violations it
/// found as plain-English messages; an empty array is a pass. An adapter's test target runs every
/// case with one parameterised test:
///
/// ```swift
/// @Test(arguments: AdapterConformance.Check.allCases)
/// func passes(_ check: AdapterConformance.Check) async {
///     let violations = await check.violations(in: MyScenario())   // `try` if its init throws
///     #expect(violations.isEmpty, "\(violations.joined(separator: "\n"))")
/// }
/// ```
///
/// Because the test iterates `allCases`, a check added here runs for every adapter with no edit
/// in the adopting targets. No check calls a write method (`setWatched`, `delete`,
/// `setResumePosition`, `setBookmark`): write behaviour is outside the suite for now.
public enum AdapterConformance {
    /// One behaviour check. The raw value is the name shown in test reports.
    public enum Check: String, CaseIterable, Sendable, Codable {
        /// `allRecordings()` lists no id twice.
        case listIDsAreUnique
        /// Two `allRecordings()` calls on the same data list the same ids in the same order.
        case listOrderIsStable
        /// `recording(id:)` of every listed id is `==` to the listed value.
        case recordingByIDEqualsListedValue
        /// `recording(id: absentID)` throws `BackendError.notFound`, and `absentID` is not listed.
        case unknownIDThrowsNotFound
        /// For every listed recording and `idWithBreaks`: breaks are non-empty ranges, sorted by
        /// start, non-overlapping (touching is allowed); `idWithBreaks` has at least one.
        case commercialBreaksAreWellFormed
        /// Both position getters return nil for `idWithoutStoredPosition`, and a positive
        /// duration for `idWithResumePosition` / `idWithBookmark` when the scenario names them.
        case positionIsNilWhenNoneStored
        /// Stream, preview and artwork URLs of every listed recording are absolute and under the
        /// connection's base URL (`isURL(_:under:)`). A nil artwork URL is allowed.
        case mediaURLsAreUnderBaseURL
        /// `.liveTV` is in `capabilities` exactly when `liveTV` is non-nil; the same for
        /// `.videoLibrary` and `videoLibrary`.
        case capabilitiesMatchOptionalServices

        /// Runs the check against a fresh adapter from `scenario`. Empty means it passed.
        public func violations(in scenario: any ConformanceScenario) async -> [String] {
            let adapter: any BackendAdapter
            do {
                adapter = try await scenario.makeAdapter()
            } catch {
                return ["makeAdapter() threw \(error)"]
            }
            switch self {
            case .listIDsAreUnique: return await uniqueIDs(adapter)
            case .listOrderIsStable: return await stableOrder(adapter)
            case .recordingByIDEqualsListedValue: return await fetchedEqualsListed(adapter)
            case .unknownIDThrowsNotFound: return await unknownID(adapter, scenario)
            case .commercialBreaksAreWellFormed: return await breaks(adapter, scenario)
            case .positionIsNilWhenNoneStored: return await positions(adapter, scenario)
            case .mediaURLsAreUnderBaseURL: return await mediaURLs(adapter, scenario)
            case .capabilitiesMatchOptionalServices: return capabilities(adapter)
            }
        }
    }

    // MARK: Rules, public so they can be tested on values an adapter cannot produce

    /// True when the URL stands alone: it has a scheme and a host of its own, without needing a
    /// base URL to resolve against.
    public static func isAbsolute(_ url: URL) -> Bool {
        guard url.baseURL == nil,
            let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let scheme = parts.scheme, !scheme.isEmpty,
            let host = parts.host, !host.isEmpty
        else { return false }
        return true
    }

    /// True when `url` is absolute and lies under `base`: the same scheme and host (both compared
    /// case-insensitively), the same port (an absent port counts as 80 for http and 443 for
    /// https), and a path equal to the base's path or continuing it after a `/`. A base path of
    /// `""` or `/` admits every path. So `http://backendx:6544/` is not under `http://backend:6544`
    /// and `/mythtv/x` is not under `/myth`.
    public static func isURL(_ url: URL, under base: URL) -> Bool {
        guard isAbsolute(url), isAbsolute(base),
            let u = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let b = URLComponents(url: base, resolvingAgainstBaseURL: false),
            u.scheme?.lowercased() == b.scheme?.lowercased(),
            u.host?.lowercased() == b.host?.lowercased(),
            effectivePort(u) == effectivePort(b)
        else { return false }
        var basePath = b.percentEncodedPath
        while basePath.hasSuffix("/") { basePath.removeLast() }
        if basePath.isEmpty { return true }
        let path = u.percentEncodedPath
        return path == basePath || path.hasPrefix(basePath + "/")
    }

    /// The problems with a list of breaks given as raw spans: an empty or backwards span, a span
    /// starting before the previous one (unsorted), or a span starting before the previous one
    /// ends (overlapping). Spans that touch (`end == next.start`) are fine. Each message names the
    /// span's index.
    public static func breakViolations(_ spans: [(start: Duration, end: Duration)]) -> [String] {
        var found: [String] = []
        for (index, span) in spans.enumerated() {
            if !(span.start < span.end) {
                found.append("break \(index) (\(span.start) to \(span.end)) is empty")
            }
            guard index > 0 else { continue }
            let previous = spans[index - 1]
            if span.start < previous.start {
                found.append(
                    "break \(index) (starts \(span.start)) is not sorted: it starts before "
                        + "break \(index - 1) (starts \(previous.start))")
            } else if span.start < previous.end {
                found.append(
                    "break \(index) (\(span.start) to \(span.end)) overlaps break \(index - 1) "
                        + "(\(previous.start) to \(previous.end))")
            }
        }
        return found
    }

    // MARK: Helpers

    /// Widths the media check asks for: tiny, ordinary, and larger than any display.
    static let mediaWidths = [1, 320, 4096]

    private static func effectivePort(_ parts: URLComponents) -> Int? {
        if let port = parts.port { return port }
        switch parts.scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }

    /// The list, or the violations that stop a check: the call threw, or it listed fewer than
    /// two recordings (too few for the list checks to tell anything apart).
    fileprivate static func list(_ adapter: any BackendAdapter) async -> Result<[Recording], Stop> {
        let list: [Recording]
        do {
            list = try await adapter.recordings.allRecordings()
        } catch {
            return .failure(Stop(["allRecordings() threw \(error)"]))
        }
        guard list.count >= 2 else {
            return .failure(
                Stop([
                    "allRecordings() listed \(list.count) recording(s); a conformance scenario "
                        + "must list at least two"
                ]))
        }
        return .success(list)
    }

    fileprivate struct Stop: Error {
        let messages: [String]
        init(_ messages: [String]) { self.messages = messages }
    }

    /// Field-by-field differences between two recordings, naming each field.
    fileprivate static func differences(listed: Recording, fetched: Recording) -> [String] {
        let left = Mirror(reflecting: listed).children
        let right = Mirror(reflecting: fetched).children
        var found: [String] = []
        for (l, r) in zip(left, right) {
            let same =
                if let lh = l.value as? AnyHashable, let rh = r.value as? AnyHashable { lh == rh }
                else { String(describing: l.value) == String(describing: r.value) }
            if !same {
                found.append("\(l.label ?? "?"): listed \(describe(l.value)), fetched \(describe(r.value))")
            }
        }
        if found.isEmpty, listed != fetched { found.append("values differ") }
        return found
    }

    private static func describe(_ value: Any) -> String {
        if let date = value as? Date { return "\(date.timeIntervalSince1970)s since 1970" }
        return String(reflecting: value)
    }
}

// MARK: - The checks

extension AdapterConformance.Check {
    private func uniqueIDs(_ adapter: any BackendAdapter) async -> [String] {
        let list: [Recording]
        switch await AdapterConformance.list(adapter) {
        case .success(let value): list = value
        case .failure(let stop): return stop.messages
        }
        var seen = Set<RecordingID>()
        var repeated: [Int] = []
        for recording in list where !seen.insert(recording.id).inserted {
            repeated.append(recording.id.rawValue)
        }
        guard !repeated.isEmpty else { return [] }
        return ["allRecordings() lists these ids more than once: \(repeated)"]
    }

    private func stableOrder(_ adapter: any BackendAdapter) async -> [String] {
        let first: [Recording]
        switch await AdapterConformance.list(adapter) {
        case .success(let value): first = value
        case .failure(let stop): return stop.messages
        }
        let second: [Recording]
        do {
            second = try await adapter.recordings.allRecordings()
        } catch {
            return ["the second allRecordings() call threw \(error)"]
        }
        let a = first.map(\.id.rawValue)
        let b = second.map(\.id.rawValue)
        guard a != b else { return [] }
        if let index = zip(a, b).enumerated().first(where: { $0.element.0 != $0.element.1 })?.offset {
            return [
                "allRecordings() is not stable: the order differs between two calls at index "
                    + "\(index) (id \(a[index]) first, id \(b[index]) second)"
            ]
        }
        let longer = a.count > b.count ? a : b
        return [
            "allRecordings() is not stable: the first call listed \(a.count), the second "
                + "\(b.count); ids only in the longer list: \(Array(longer[min(a.count, b.count)...]))"
        ]
    }

    private func fetchedEqualsListed(_ adapter: any BackendAdapter) async -> [String] {
        let list: [Recording]
        switch await AdapterConformance.list(adapter) {
        case .success(let value): list = value
        case .failure(let stop): return stop.messages
        }
        var found: [String] = []
        for listed in list {
            do {
                let fetched = try await adapter.recordings.recording(id: listed.id)
                if fetched != listed {
                    let fields = AdapterConformance.differences(listed: listed, fetched: fetched)
                    found.append(
                        "recording(id: \(listed.id.rawValue)) differs from the listed value: "
                            + fields.joined(separator: "; "))
                }
            } catch {
                found.append("recording(id: \(listed.id.rawValue)) threw \(error) for a listed id")
            }
        }
        return found
    }

    private func unknownID(_ adapter: any BackendAdapter, _ scenario: any ConformanceScenario)
        async -> [String]
    {
        let id = scenario.absentID
        var found: [String] = []
        do {
            if try await adapter.recordings.allRecordings().contains(where: { $0.id == id }) {
                found.append("scenario error: absentID \(id.rawValue) is listed by allRecordings()")
            }
        } catch {
            found.append("allRecordings() threw \(error)")
        }
        do {
            let value = try await adapter.recordings.recording(id: id)
            found.append(
                "recording(id: \(id.rawValue)) returned a recording (id \(value.id.rawValue), "
                    + "\"\(value.title)\") instead of throwing BackendError.notFound")
        } catch let error as BackendError where error == .notFound {
            // Expected.
        } catch {
            found.append(
                "recording(id: \(id.rawValue)) threw \(error) instead of BackendError.notFound")
        }
        return found
    }

    private func breaks(_ adapter: any BackendAdapter, _ scenario: any ConformanceScenario)
        async -> [String]
    {
        let list: [Recording]
        switch await AdapterConformance.list(adapter) {
        case .success(let value): list = value
        case .failure(let stop): return stop.messages
        }
        var ids: [RecordingID] = []
        for id in list.map(\.id) + [scenario.idWithBreaks] where !ids.contains(id) { ids.append(id) }

        var found: [String] = []
        for id in ids {
            do {
                let breaks = try await adapter.markup.commercialBreaks(for: id)
                found += AdapterConformance.breakViolations(breaks.map { ($0.start, $0.end) })
                    .map { "commercialBreaks(for: \(id.rawValue)): \($0)" }
                if id == scenario.idWithBreaks, breaks.isEmpty {
                    found.append(
                        "commercialBreaks(for: \(id.rawValue)) is empty, but the scenario names it "
                            + "idWithBreaks")
                }
            } catch {
                found.append("commercialBreaks(for: \(id.rawValue)) threw \(error)")
            }
        }
        return found
    }

    private func positions(_ adapter: any BackendAdapter, _ scenario: any ConformanceScenario)
        async -> [String]
    {
        typealias Getter = @Sendable (RecordingID) async throws -> Duration?
        let state = adapter.playbackState
        let getters: [(name: String, get: Getter, storedID: RecordingID?)] = [
            ("resumePosition", { try await state.resumePosition(for: $0) }, scenario.idWithResumePosition),
            ("bookmark", { try await state.bookmark(for: $0) }, scenario.idWithBookmark),
        ]
        var found: [String] = []
        for getter in getters {
            let none = scenario.idWithoutStoredPosition
            do {
                if let value = try await getter.get(none) {
                    found.append(
                        "\(getter.name)(for: \(none.rawValue)) returned \(value), but the scenario "
                            + "names it idWithoutStoredPosition (expected nil)")
                }
            } catch {
                found.append("\(getter.name)(for: \(none.rawValue)) threw \(error)")
            }
            guard let stored = getter.storedID else { continue }
            do {
                let value = try await getter.get(stored)
                if value == nil || value! <= .zero {
                    found.append(
                        "\(getter.name)(for: \(stored.rawValue)) returned "
                            + "\(value.map { "\($0)" } ?? "nil"), but the scenario says one is stored")
                }
            } catch {
                found.append("\(getter.name)(for: \(stored.rawValue)) threw \(error)")
            }
        }
        return found
    }

    private func mediaURLs(_ adapter: any BackendAdapter, _ scenario: any ConformanceScenario)
        async -> [String]
    {
        let list: [Recording]
        switch await AdapterConformance.list(adapter) {
        case .success(let value): list = value
        case .failure(let stop): return stop.messages
        }
        let base = scenario.connection.baseURL
        let media = adapter.media
        var found: [String] = []
        func check(_ url: URL, _ what: String) {
            if !AdapterConformance.isAbsolute(url) {
                found.append("\(what) = \(url.absoluteString) is not absolute")
            } else if !AdapterConformance.isURL(url, under: base) {
                found.append("\(what) = \(url.absoluteString) is not under the base URL \(base.absoluteString)")
            }
        }
        for recording in list {
            let id = recording.id.rawValue
            check(media.streamURL(for: recording), "streamURL(for: \(id))")
            for width in AdapterConformance.mediaWidths {
                check(
                    media.previewImageURL(for: recording, maxWidth: width),
                    "previewImageURL(for: \(id), maxWidth: \(width))")
                for (index, reference) in recording.artwork.enumerated() {
                    if let url = media.artworkURL(for: reference, maxWidth: width) {
                        check(url, "artworkURL(for: artwork[\(index)] of \(id), maxWidth: \(width))")
                    }
                }
            }
        }
        return found
    }

    private func capabilities(_ adapter: any BackendAdapter) -> [String] {
        let pairs: [(capability: BackendCapabilities, name: String, present: Bool)] = [
            (.liveTV, "liveTV", adapter.liveTV != nil),
            (.videoLibrary, "videoLibrary", adapter.videoLibrary != nil),
        ]
        var found: [String] = []
        for pair in pairs {
            let claimed = adapter.capabilities.contains(pair.capability)
            if claimed && !pair.present {
                found.append("capabilities contain .\(pair.name) but \(pair.name) is nil")
            } else if !claimed && pair.present {
                found.append("\(pair.name) is non-nil but capabilities lack .\(pair.name)")
            }
        }
        return found
    }
}
