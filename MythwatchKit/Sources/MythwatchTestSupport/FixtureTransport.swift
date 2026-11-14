import Foundation
import MythwatchBackend
import MythwatchDomain
import Synchronization

/// Canned-response `HTTPTransport` for tests. See SPEC §8 for the matching rules.
///
/// A final class guarding its state with `Mutex` (rather than an actor) so tests can register
/// stubs and read the request log synchronously; `Mutex` makes it `Sendable` without
/// `@unchecked`. `Mutex` is available on every platform the package declares.
public final class FixtureTransport: HTTPTransport {
    private struct Route {
        let method: HTTPRequest.Method
        let path: String
        let query: [String: String]
        let outcome: Result<HTTPResponse, BackendError>
    }

    private struct State {
        var routes: [Route] = []
        var requests: [HTTPRequest] = []
        var unmatched: [HTTPRequest] = []
    }

    private let state = Mutex(State())

    public init() {}

    /// Every request received, in order, matched or not.
    public var requests: [HTTPRequest] { state.withLock { $0.requests } }

    /// The requests that matched no route, in order.
    public var unmatchedRequests: [HTTPRequest] { state.withLock { $0.unmatched } }

    public func stub(
        _ method: HTTPRequest.Method, path: String, query: [String: String] = [:],
        response: HTTPResponse
    ) {
        add(Route(method: method, path: path, query: query, outcome: .success(response)))
    }

    public func stub(
        _ method: HTTPRequest.Method, path: String, query: [String: String] = [:],
        status: Int = 200, headers: [String: String] = [:], body: String
    ) {
        stub(
            method, path: path, query: query,
            response: HTTPResponse(status: status, headers: headers, body: Data(body.utf8)))
    }

    public func stub(
        _ method: HTTPRequest.Method, path: String, query: [String: String] = [:],
        status: Int = 200, headers: [String: String] = [:], body: Data
    ) {
        stub(
            method, path: path, query: query,
            response: HTTPResponse(status: status, headers: headers, body: body))
    }

    /// Makes matching requests throw `failure` instead of returning a response.
    public func stub(
        _ method: HTTPRequest.Method, path: String, query: [String: String] = [:],
        failure: BackendError
    ) {
        add(Route(method: method, path: path, query: query, outcome: .failure(failure)))
    }

    private func add(_ route: Route) {
        state.withLock { $0.routes.append(route) }
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let items = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?
            .queryItems ?? []
        let path = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.path ?? ""

        let outcome: Result<HTTPResponse, BackendError> = state.withLock { s in
            s.requests.append(request)
            var best: Route?
            for route in s.routes
            where route.method == request.method && route.path == path
                && route.query.allSatisfy({ key, value in
                    items.contains { $0.name == key && $0.value == value }
                })
            {
                // Strictly more specific replaces; a tie keeps the earlier registration.
                if best == nil || route.query.count > best!.query.count { best = route }
            }
            if let best { return best.outcome }
            s.unmatched.append(request)
            return .failure(
                .unreachable(
                    "FixtureTransport: no route for \(request.method.rawValue) "
                        + request.url.absoluteString))
        }
        return try outcome.get()
    }
}
