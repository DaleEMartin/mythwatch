import Foundation
import MythwatchDomain
import MythwatchTestSupport
import Testing

@testable import MythwatchBackend

private func req(_ url: String, _ method: HTTPRequest.Method = .get) -> HTTPRequest {
    HTTPRequest(method: method, url: URL(string: url)!)
}

private func text(_ r: HTTPResponse) -> String { String(decoding: r.body, as: UTF8.self) }

@Suite struct FixtureTransportTests {
    @Test func matchesByMethodAndPath() async throws {
        let t = FixtureTransport()
        t.stub(.get, path: "/a/b", body: "get-ab")
        t.stub(.post, path: "/a/b", body: "post-ab")
        t.stub(.get, path: "/a/c", body: "get-ac")

        #expect(text(try await t.send(req("http://h:1/a/b"))) == "get-ab")
        #expect(text(try await t.send(req("http://h:1/a/b", .post))) == "post-ab")
        #expect(text(try await t.send(req("http://h:1/a/c"))) == "get-ac")
    }

    @Test func returnsStatusAndHeaders() async throws {
        let t = FixtureTransport()
        t.stub(.get, path: "/a/b", response: HTTPResponse(status: 404, headers: ["X": "y"], body: Data()))
        let r = try await t.send(req("http://h:1/a/b"))
        #expect(r.status == 404)
        #expect(r.headers["X"] == "y")
    }

    @Test func queryMatching() async throws {
        let t = FixtureTransport()
        t.stub(.get, path: "/a/b", body: "any")
        t.stub(.get, path: "/a/b", query: ["x": "1"], body: "x1")
        t.stub(.get, path: "/a/b", query: ["x": "1", "y": "2"], body: "x1y2")

        // no query: only the unconstrained route matches
        #expect(text(try await t.send(req("http://h:1/a/b"))) == "any")
        // extra items allowed, order ignored, most specific wins
        #expect(text(try await t.send(req("http://h:1/a/b?z=9&x=1"))) == "x1")
        #expect(text(try await t.send(req("http://h:1/a/b?y=2&x=1&z=3"))) == "x1y2")
        // value mismatch falls back
        #expect(text(try await t.send(req("http://h:1/a/b?x=2"))) == "any")
    }

    @Test func tieGoesToEarliestRegistered() async throws {
        let t = FixtureTransport()
        t.stub(.get, path: "/a/b", query: ["x": "1"], body: "first")
        t.stub(.get, path: "/a/b", query: ["x": "1"], body: "second")
        #expect(text(try await t.send(req("http://h:1/a/b?x=1"))) == "first")
    }

    @Test func unmatchedRequestReportsFullURL() async throws {
        let t = FixtureTransport()
        t.stub(.get, path: "/a/b", query: ["x": "1"], body: "x1")
        let url = "http://h:1/a/b?x=2"
        do {
            _ = try await t.send(req(url))
            Issue.record("expected a throw")
        } catch let BackendError.unreachable(message) {
            #expect(message.contains(url))
        } catch {
            Issue.record("wrong error \(error)")
        }
        #expect(t.unmatchedRequests.map(\.url.absoluteString) == [url])
    }

    @Test func recordsRequestsInOrderIncludingUnmatched() async throws {
        let t = FixtureTransport()
        t.stub(.get, path: "/a/b", body: "")
        t.stub(.post, path: "/a/c", body: "")
        _ = try await t.send(req("http://h:1/a/b?n=1"))
        _ = try await t.send(req("http://h:1/a/c", .post))
        _ = try? await t.send(req("http://h:1/nope"))
        _ = try await t.send(req("http://h:1/a/b?n=2"))
        #expect(
            t.requests.map(\.url.absoluteString) == [
                "http://h:1/a/b?n=1", "http://h:1/a/c", "http://h:1/nope", "http://h:1/a/b?n=2",
            ])
        #expect(t.requests.map(\.method) == [.get, .post, .get, .get])
    }

    @Test func canStubAnError() async throws {
        let t = FixtureTransport()
        t.stub(.get, path: "/a/b", failure: .timedOut)
        await #expect(throws: BackendError.timedOut) { try await t.send(req("http://h:1/a/b")) }
    }
}

@MainActor @Suite struct TestClockTests {
    @Test func advanceMovesNowByExactAmount() {
        let clock = TestClock()
        let start = clock.now()
        #expect(clock.now() == start)
        clock.advance(by: .seconds(90))
        #expect(clock.now() - start == .seconds(90))
        clock.advance(by: .milliseconds(250))
        #expect(clock.now() - start == .milliseconds(90_250))
    }
}

@Suite struct RecordingFixtureTests {
    @Test func defaultsBuild() {
        let r = Recording.fixture()
        #expect(!r.title.isEmpty)
        #expect(r.scheduledStart < r.scheduledEnd)
        #expect(Recording.fixture() == r)
    }

    @Test func overrideSticks() {
        let r = Recording.fixture(id: RecordingID(rawValue: 42), title: "Other", flags: .watched)
        #expect(r.id.rawValue == 42)
        #expect(r.title == "Other")
        #expect(r.flags == .watched)
        #expect(r.recordingGroup == Recording.fixture().recordingGroup)
    }
}

@Suite struct FixtureLoaderTests {
    @Test func loadsBundledFile() throws {
        let data = try FixtureLoader.data(named: "sample.json", in: .module, subdirectory: "Fixtures")
        #expect(String(decoding: data, as: UTF8.self).contains("hello"))
        let again = try FixtureLoader.data(named: "sample", in: .module, subdirectory: "Fixtures")
        #expect(again == data)
    }

    @Test func missingFileErrorNamesTheFile() {
        do {
            _ = try FixtureLoader.data(named: "nope.json", in: .module, subdirectory: "Fixtures")
            Issue.record("expected a throw")
        } catch {
            #expect("\(error)".contains("nope.json"))
        }
    }
}
