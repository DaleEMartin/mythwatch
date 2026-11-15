import Foundation
import MythwatchDomain
import MythwatchTestSupport
import Testing

@testable import MythwatchBackend

// MARK: - BackendVersion

@Suite struct BackendVersionTests {
    @Test(arguments: [
        ("v35.0", 35, 0),
        ("v35.0-12-gabcdef", 35, 0),
        ("v37-Pre-676-g5474cf09b0", 37, 0),
        ("v0.28.1", 0, 28),
        ("35", 35, 0),
    ])
    func parses(raw: String, major: Int, minor: Int) throws {
        let v = try #require(BackendVersion(parsing: raw))
        #expect(v.major == major)
        #expect(v.minor == minor)
        #expect(v.raw == raw)
    }

    @Test(arguments: ["", "garbage"])
    func rejects(raw: String) {
        #expect(BackendVersion(parsing: raw) == nil)
    }

    @Test func ordering() throws {
        let v = try ["v34.0", "v35.0", "v35.1", "v36.0"].map { try #require(BackendVersion(parsing: $0)) }
        #expect(v[0] < v[1])
        #expect(v[1] < v[2])
        #expect(v[2] < v[3])
        #expect(!(v[3] < v[0]))
    }

    @Test func sameMajorMinorWithDifferentRawAreEqualAndHashEqual() throws {
        let a = try #require(BackendVersion(parsing: "v35.0"))
        let b = try #require(BackendVersion(parsing: "v35.0-12-gabcdef"))
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
        #expect(Set([a, b]).count == 1)
        #expect(!(a < b) && !(b < a))
        #expect(a.raw != b.raw)
    }
}

// MARK: - Stubs

private struct StubAdapter: BackendAdapter {
    let version: BackendVersion
    let factoryName: String
    let connection: BackendConnection
    var capabilities: BackendCapabilities { .recordings }
    var recordings: any RecordingsService { fatalError("unused") }
    var playbackState: any PlaybackStateService { fatalError("unused") }
    var markup: any MarkupService { fatalError("unused") }
    var media: any MediaLocator { fatalError("unused") }
    var liveTV: (any LiveTVService)? { nil }
    var videoLibrary: (any VideoLibraryService)? { nil }
}

private struct StubFactory: BackendAdapterFactory {
    let name: String
    let majors: Set<Int>
    func supports(_ version: BackendVersion) -> Bool { majors.contains(version.major) }
    func makeAdapter(connection: BackendConnection, version: BackendVersion, transport: any HTTPTransport)
        -> any BackendAdapter
    {
        StubAdapter(version: version, factoryName: name, connection: connection)
    }
}

private let connection = BackendConnection(baseURL: URL(string: "http://backend.test:6544")!)

private func infoFixture() throws -> Data {
    try FixtureLoader.data(named: "backend-info.json", in: .module, subdirectory: "Fixtures")
}

// MARK: - Registry

@Suite struct AdapterRegistryTests {
    @Test func firstSupportingFactoryInRegistrationOrderWins() throws {
        var registry = AdapterRegistry()
        registry.register(StubFactory(name: "A", majors: [34]))
        registry.register(StubFactory(name: "B", majors: [35, 36]))
        registry.register(StubFactory(name: "C", majors: [35]))
        let v = try #require(BackendVersion(parsing: "v35.0"))
        #expect(try registry.factory(for: v).name == "B")
    }

    @Test func noSupportingFactoryThrowsUnsupportedVersionWithRaw() throws {
        var registry = AdapterRegistry()
        registry.register(StubFactory(name: "A", majors: [34]))
        let v = try #require(BackendVersion(parsing: "v37-Pre-676-g5474cf09b0"))
        #expect(throws: BackendError.unsupportedVersion("v37-Pre-676-g5474cf09b0")) {
            try registry.factory(for: v)
        }
    }

    @Test func emptyRegistryThrowsUnsupportedVersion() throws {
        let v = try #require(BackendVersion(parsing: "v35.0"))
        #expect(throws: BackendError.unsupportedVersion("v35.0")) {
            try AdapterRegistry().factory(for: v)
        }
    }
}

// MARK: - Probe

@Suite struct BackendProbeTests {
    private func transport(info: Data? = nil, host: String? = "{\"String\": \"backend\"}") throws
        -> FixtureTransport
    {
        let t = FixtureTransport()
        t.stub(.get, path: "/Myth/GetBackendInfo", body: try info ?? infoFixture())
        if let host { t.stub(.get, path: "/Myth/GetHostName", body: host) }
        return t
    }

    @Test func parsesFixture() async throws {
        let info = try await BackendProbe(transport: try transport()).probe(connection)
        #expect(info.version.major == 35)
        #expect(info.version.minor == 0)
        #expect(info.version.raw == "v35.0")
        #expect(info.hostName == "backend")
    }

    @Test func sendsAcceptJSON() async throws {
        let t = try transport()
        _ = try await BackendProbe(transport: t).probe(connection)
        let info = try #require(t.requests.first { $0.url.path == "/Myth/GetBackendInfo" })
        #expect(info.method == .get)
        #expect(info.headers["Accept"] == "application/json")
        #expect(info.url.host == "backend.test")
        #expect(info.url.port == 6544)
    }

    @Test func ignoresUnknownFields() async throws {
        let body = #"{"BackendInfo": {"Build": {"Version": "v35.0", "X": [1, {"y": null}]}, "Other": 5}, "Extra": "z"}"#
        let info = try await BackendProbe(transport: try transport(info: Data(body.utf8))).probe(connection)
        #expect(info.version.major == 35)
    }

    @Test func missingBuildVersionIsMalformed() async throws {
        let body = #"{"BackendInfo": {"Build": {"LibX264": true}}}"#
        let probe = BackendProbe(transport: try transport(info: Data(body.utf8)))
        await #expect {
            try await probe.probe(connection)
        } throws: { error in
            if case .malformedResponse = error as? BackendError { return true }
            return false
        }
    }

    @Test func unparseableVersionStringIsMalformed() async throws {
        let body = #"{"BackendInfo": {"Build": {"Version": "garbage"}}}"#
        let probe = BackendProbe(transport: try transport(info: Data(body.utf8)))
        await #expect {
            try await probe.probe(connection)
        } throws: { error in
            if case .malformedResponse = error as? BackendError { return true }
            return false
        }
    }

    @Test func htmlBodyIsMalformed() async throws {
        let probe = BackendProbe(
            transport: try transport(info: Data("<html><body>Hi</body></html>".utf8)))
        await #expect {
            try await probe.probe(connection)
        } throws: { error in
            if case .malformedResponse = error as? BackendError { return true }
            return false
        }
    }

    @Test func status500IsHTTPError() async throws {
        let t = FixtureTransport()
        t.stub(.get, path: "/Myth/GetBackendInfo", status: 500, body: "<html>oops</html>")
        await #expect {
            try await BackendProbe(transport: t).probe(connection)
        } throws: { error in
            if case .http(let status, _) = error as? BackendError { return status == 500 }
            return false
        }
    }

    @Test func transportErrorPassesThroughUnchanged() async throws {
        let t = FixtureTransport()
        t.stub(.get, path: "/Myth/GetBackendInfo", failure: .timedOut)
        await #expect(throws: BackendError.timedOut) {
            try await BackendProbe(transport: t).probe(connection)
        }
        let t2 = FixtureTransport()
        t2.stub(.get, path: "/Myth/GetBackendInfo", failure: .unreachable("no route"))
        await #expect(throws: BackendError.unreachable("no route")) {
            try await BackendProbe(transport: t2).probe(connection)
        }
    }

    @Test func hostNameTransportFailureStillSucceeds() async throws {
        let t = try transport(host: nil)
        t.stub(.get, path: "/Myth/GetHostName", failure: .timedOut)
        let info = try await BackendProbe(transport: t).probe(connection)
        #expect(info.version.major == 35)
        #expect(info.hostName == nil)
    }

    @Test(arguments: [
        (404, "<html>nope</html>"), (200, "<html>nope</html>"), (200, "{}"),
        (200, #"{"String": 5}"#),
    ])
    func hostNameBadResponseStillSucceeds(status: Int, body: String) async throws {
        let t = try transport(host: nil)
        t.stub(.get, path: "/Myth/GetHostName", status: status, body: body)
        let info = try await BackendProbe(transport: t).probe(connection)
        #expect(info.hostName == nil)
    }

    @Test func hostNameRequestAlsoSendsAcceptJSON() async throws {
        let t = try transport()
        _ = try await BackendProbe(transport: t).probe(connection)
        let h = try #require(t.requests.first { $0.url.path == "/Myth/GetHostName" })
        #expect(h.headers["Accept"] == "application/json")
    }
}

// MARK: - Connector

@Suite struct BackendConnectorTests {
    @Test func probesThenResolvesFactoryThenMakesAdapter() async throws {
        let t = FixtureTransport()
        t.stub(.get, path: "/Myth/GetBackendInfo", body: try infoFixture())
        t.stub(.get, path: "/Myth/GetHostName", body: #"{"String": "backend"}"#)
        var registry = AdapterRegistry()
        registry.register(StubFactory(name: "MythTV v35", majors: [35]))
        let connected = try await BackendConnector(registry: registry, transport: t).connect(connection)
        let stub = try #require(connected.adapter as? StubAdapter)
        #expect(stub.factoryName == "MythTV v35")
        #expect(stub.version.major == 35)
        #expect(stub.connection == connection)
        #expect(t.requests.first?.url.path == "/Myth/GetBackendInfo")
    }

    @Test func returnsTheProbedInfoWithoutProbingTwice() async throws {
        let t = FixtureTransport()
        t.stub(.get, path: "/Myth/GetBackendInfo", body: try infoFixture())
        t.stub(.get, path: "/Myth/GetHostName", body: #"{"String": "backend"}"#)
        var registry = AdapterRegistry()
        registry.register(StubFactory(name: "MythTV v35", majors: [35]))
        let connected = try await BackendConnector(registry: registry, transport: t).connect(connection)
        #expect(connected.info.version.raw == "v35.0")
        #expect(connected.info.hostName == "backend")
        #expect(connected.info.version == connected.adapter.version)
        #expect(t.requests.map(\.url.path) == ["/Myth/GetBackendInfo", "/Myth/GetHostName"])
    }

    @Test func reportsTheNameOfTheFactoryThatMadeTheAdapter() async throws {
        let t = FixtureTransport()
        t.stub(.get, path: "/Myth/GetBackendInfo", body: try infoFixture())
        var registry = AdapterRegistry()
        registry.register(StubFactory(name: "MythTV v34", majors: [34]))
        registry.register(StubFactory(name: "MythTV v35", majors: [35]))
        let connected = try await BackendConnector(registry: registry, transport: t).connect(connection)
        #expect(connected.adapterName == "MythTV v35")
    }

    @Test func connectedBackendCarriesTheNameItIsGiven() {
        let adapter = FakeBackendAdapter()
        let connected = ConnectedBackend(
            info: BackendInfo(version: adapter.version, hostName: nil), adapter: adapter,
            adapterName: "Some name")
        #expect(connected.adapterName == "Some name")
    }

    @Test func unsupportedVersionSurfacesUnchanged() async throws {
        let t = FixtureTransport()
        t.stub(.get, path: "/Myth/GetBackendInfo", body: try infoFixture())
        var registry = AdapterRegistry()
        registry.register(StubFactory(name: "MythTV v34", majors: [34]))
        await #expect(throws: BackendError.unsupportedVersion("v35.0")) {
            try await BackendConnector(registry: registry, transport: t).connect(connection)
        }
    }

    @Test func probeErrorSurfacesUnchanged() async throws {
        let t = FixtureTransport()
        t.stub(.get, path: "/Myth/GetBackendInfo", failure: .unreachable("down"))
        var registry = AdapterRegistry()
        registry.register(StubFactory(name: "MythTV v35", majors: [35]))
        await #expect(throws: BackendError.unreachable("down")) {
            try await BackendConnector(registry: registry, transport: t).connect(connection)
        }
    }
}
