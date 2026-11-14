import Foundation
import MythwatchDomain
import Synchronization
import Testing

@testable import MythwatchBackend

// MARK: - Stub

/// What the stub saw on the wire.
private struct SeenRequest: Sendable {
    var method: String?
    var url: URL?
    var headers: [String: String]
    var body: Data?
    var timeout: TimeInterval
}

private enum StubOutcome: Sendable {
    case response(status: Int, headers: [String: String], body: Data)
    case redirect(to: URL)
    case failure(URLError.Code)
    case otherFailure
    case notHTTP
}

private struct StubOtherError: Error {}

/// Per-test state, keyed by a unique fake host so parallel tests never share an entry.
private struct StubEntry: Sendable {
    var respond: @Sendable (SeenRequest) -> StubOutcome
    var seen: [SeenRequest] = []
}

private let stubRegistry = Mutex<[String: StubEntry]>([:])

private final class StubProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return stubRegistry.withLock { $0[host] != nil }
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let seen = SeenRequest(
            method: request.httpMethod,
            url: request.url,
            headers: request.allHTTPHeaderFields ?? [:],
            body: Self.readBody(request),
            timeout: request.timeoutInterval)
        let host = request.url?.host ?? ""
        let respond = stubRegistry.withLock { registry -> (@Sendable (SeenRequest) -> StubOutcome)? in
            registry[host]?.seen.append(seen)
            return registry[host]?.respond
        }
        guard let url = request.url, let respond else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        switch respond(seen) {
        case .response(let status, let headers, let body):
            let http = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case .redirect(let target):
            let http = HTTPURLResponse(
                url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                headerFields: ["Location": target.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: http)
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .otherFailure:
            client?.urlProtocol(self, didFailWithError: StubOtherError())
        case .notHTTP:
            let plain = URLResponse(
                url: url, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)
            client?.urlProtocol(self, didReceive: plain, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    private static func readBody(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

/// One stubbed fake host plus a transport wired to it. Removes its registry entry on `finish()`.
private struct Rig {
    let host = "\(UUID().uuidString.lowercased()).backend.invalid"
    let transport: URLSessionTransport

    init(
        authorizer: (any RequestAuthorizer)? = nil,
        respond: @escaping @Sendable (SeenRequest) -> StubOutcome
    ) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        transport = URLSessionTransport(configuration: configuration, authorizer: authorizer)
        stubRegistry.withLock { $0[host] = StubEntry(respond: respond) }
    }

    func url(_ path: String = "/a/b") -> URL { URL(string: "http://\(host)\(path)")! }
    var seen: [SeenRequest] { stubRegistry.withLock { $0[host]?.seen ?? [] } }
    func finish() { stubRegistry.withLock { _ = $0.removeValue(forKey: host) } }
}

private func ok(_ body: String = "") -> StubOutcome {
    .response(status: 200, headers: [:], body: Data(body.utf8))
}

private struct AddHeader: RequestAuthorizer {
    func authorize(_ request: HTTPRequest) async throws -> HTTPRequest {
        var r = request
        r.headers["X-Added"] = "yes"
        return r
    }
}

private struct FailingAuthorizer: RequestAuthorizer {
    let error: any Error
    func authorize(_ request: HTTPRequest) async throws -> HTTPRequest { throw error }
}

// MARK: - Tests

@Suite("URLSessionTransport")
struct URLSessionTransportTests {
    @Test func getReachesTheWireUnchanged() async throws {
        let rig = Rig { _ in ok("hi") }
        defer { rig.finish() }
        let response = try await rig.transport.send(
            HTTPRequest(
                method: .get, url: rig.url("/a/b?x=1&y=two"),
                headers: ["Accept": "application/json", "X-Custom": "v"]))
        #expect(response.status == 200)
        #expect(response.body == Data("hi".utf8))
        let seen = try #require(rig.seen.first)
        #expect(rig.seen.count == 1)
        #expect(seen.method == "GET")
        #expect(seen.url == rig.url("/a/b?x=1&y=two"))
        #expect(seen.headers["Accept"] == "application/json")
        #expect(seen.headers["X-Custom"] == "v")
    }

    @Test func postBodyAndHeadersPassThrough() async throws {
        let rig = Rig { _ in ok() }
        defer { rig.finish() }
        let payload = Data("a=1&b=two".utf8)
        _ = try await rig.transport.send(
            HTTPRequest(
                method: .post, url: rig.url("/a/c"),
                headers: ["Content-Type": "application/x-www-form-urlencoded"], body: payload))
        let seen = try #require(rig.seen.first)
        #expect(seen.method == "POST")
        #expect(seen.body == payload)
        #expect(seen.headers["Content-Type"] == "application/x-www-form-urlencoded")
    }

    @Test func notFoundIsReturnedAsAValue() async throws {
        let rig = Rig { _ in
            .response(status: 404, headers: ["X-Why": "gone"], body: Data("missing".utf8))
        }
        defer { rig.finish() }
        let response = try await rig.transport.send(HTTPRequest(method: .get, url: rig.url()))
        #expect(response.status == 404)
        #expect(response.headers["X-Why"] == "gone")
        #expect(response.body == Data("missing".utf8))
    }

    @Test func serverErrorIsReturnedAsAValue() async throws {
        let rig = Rig { _ in .response(status: 500, headers: [:], body: Data("boom".utf8)) }
        defer { rig.finish() }
        let response = try await rig.transport.send(HTTPRequest(method: .get, url: rig.url()))
        #expect(response.status == 500)
        #expect(response.body == Data("boom".utf8))
    }

    @Test func responseHeadersComeBackAsStringDictionary() async throws {
        let rig = Rig { _ in
            .response(
                status: 200, headers: ["Content-Type": "application/json", "X-N": "7"], body: Data())
        }
        defer { rig.finish() }
        let response = try await rig.transport.send(HTTPRequest(method: .get, url: rig.url()))
        let headers: [String: String] = response.headers
        #expect(headers["Content-Type"] == "application/json")
        #expect(headers["X-N"] == "7")
    }

    @Test func requestTimeoutIsTenSeconds() async throws {
        let rig = Rig { _ in ok() }
        defer { rig.finish() }
        _ = try await rig.transport.send(HTTPRequest(method: .get, url: rig.url()))
        #expect(try #require(rig.seen.first).timeout == 10)
        #expect(URLSessionTransport.requestTimeout == 10)
    }

    @Test func redirectsAreFollowed() async throws {
        let rig = Rig { seen in
            if seen.url?.path == "/a/old" {
                return .redirect(to: URL(string: "http://\(seen.url!.host!)/a/new")!)
            }
            return ok("landed")
        }
        defer { rig.finish() }
        let response = try await rig.transport.send(HTTPRequest(method: .get, url: rig.url("/a/old")))
        #expect(response.status == 200)
        #expect(response.body == Data("landed".utf8))
        #expect(rig.seen.map { $0.url?.path } == ["/a/old", "/a/new"])
    }

    @Test func timedOutMapsToTimedOut() async {
        let rig = Rig { _ in .failure(.timedOut) }
        defer { rig.finish() }
        await #expect(throws: BackendError.timedOut) {
            try await rig.transport.send(HTTPRequest(method: .get, url: rig.url()))
        }
    }

    @Test(
        arguments: [
            URLError.Code.cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
            .notConnectedToInternet, .networkConnectionLost, .secureConnectionFailed,
            .internationalRoamingOff, .dataNotAllowed, .unknown,
        ])
    func connectionProblemsMapToUnreachable(code: URLError.Code) async {
        let rig = Rig { _ in .failure(code) }
        defer { rig.finish() }
        do {
            _ = try await rig.transport.send(HTTPRequest(method: .get, url: rig.url()))
            Issue.record("expected a throw")
        } catch let error as BackendError {
            guard case .unreachable(let message) = error else {
                Issue.record("expected .unreachable, got \(error)")
                return
            }
            #expect(!message.isEmpty)
        } catch {
            Issue.record("non-BackendError escaped: \(error)")
        }
    }

    @Test(
        arguments: [
            URLError.Code.badServerResponse, .cannotParseResponse, .zeroByteResource,
            .httpTooManyRedirects,
        ])
    func malformedReplyCodesMapToMalformedResponse(code: URLError.Code) async {
        let rig = Rig { _ in .failure(code) }
        defer { rig.finish() }
        do {
            _ = try await rig.transport.send(HTTPRequest(method: .get, url: rig.url()))
            Issue.record("expected a throw")
        } catch let error as BackendError {
            guard case .malformedResponse = error else {
                Issue.record("expected .malformedResponse, got \(error)")
                return
            }
        } catch {
            Issue.record("non-BackendError escaped: \(error)")
        }
    }

    @Test func nonURLErrorMapsToUnreachable() async {
        let rig = Rig { _ in .otherFailure }
        defer { rig.finish() }
        do {
            _ = try await rig.transport.send(HTTPRequest(method: .get, url: rig.url()))
            Issue.record("expected a throw")
        } catch let error as BackendError {
            guard case .unreachable = error else {
                Issue.record("expected .unreachable, got \(error)")
                return
            }
        } catch {
            Issue.record("non-BackendError escaped: \(error)")
        }
    }

    @Test func nonHTTPReplyMapsToMalformedResponse() async {
        let rig = Rig { _ in .notHTTP }
        defer { rig.finish() }
        do {
            _ = try await rig.transport.send(HTTPRequest(method: .get, url: rig.url()))
            Issue.record("expected a throw")
        } catch let error as BackendError {
            guard case .malformedResponse = error else {
                Issue.record("expected .malformedResponse, got \(error)")
                return
            }
        } catch {
            Issue.record("non-BackendError escaped: \(error)")
        }
    }

    @Test func authorizerIsAppliedWhenPresent() async throws {
        let rig = Rig(authorizer: AddHeader()) { _ in ok() }
        defer { rig.finish() }
        _ = try await rig.transport.send(
            HTTPRequest(method: .get, url: rig.url(), headers: ["Accept": "text/plain"]))
        let seen = try #require(rig.seen.first)
        #expect(seen.headers["X-Added"] == "yes")
        #expect(seen.headers["Accept"] == "text/plain")
    }

    @Test func requestIsUnchangedWithoutAuthorizer() async throws {
        let rig = Rig { _ in ok() }
        defer { rig.finish() }
        _ = try await rig.transport.send(
            HTTPRequest(method: .get, url: rig.url(), headers: ["Accept": "text/plain"]))
        let seen = try #require(rig.seen.first)
        #expect(seen.headers["X-Added"] == nil)
        #expect(seen.headers["Accept"] == "text/plain")
    }

    @Test func authorizerBackendErrorPassesThroughAndNothingIsSent() async {
        let rig = Rig(authorizer: FailingAuthorizer(error: BackendError.rejected("no"))) { _ in ok() }
        defer { rig.finish() }
        await #expect(throws: BackendError.rejected("no")) {
            try await rig.transport.send(HTTPRequest(method: .get, url: rig.url()))
        }
        #expect(rig.seen.isEmpty)
    }

    @Test func authorizerOtherErrorMapsToNotAuthorized() async {
        let rig = Rig(authorizer: FailingAuthorizer(error: StubOtherError())) { _ in ok() }
        defer { rig.finish() }
        await #expect(throws: BackendError.notAuthorized) {
            try await rig.transport.send(HTTPRequest(method: .get, url: rig.url()))
        }
        #expect(rig.seen.isEmpty)
    }

    @Test func authorizerURLErrorIsMappedLikeATransportError() async {
        let rig = Rig(authorizer: FailingAuthorizer(error: URLError(.timedOut))) { _ in ok() }
        defer { rig.finish() }
        await #expect(throws: BackendError.timedOut) {
            try await rig.transport.send(HTTPRequest(method: .get, url: rig.url()))
        }
    }
}
