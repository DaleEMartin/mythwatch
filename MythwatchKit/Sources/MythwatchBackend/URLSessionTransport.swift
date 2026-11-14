import Foundation
import MythwatchDomain

/// `HTTPTransport` over `URLSession`. Throws `BackendError` only; see SPEC section 4 for the mapping.
public struct URLSessionTransport: HTTPTransport {
    /// Per-request timeout in seconds.
    public static let requestTimeout: TimeInterval = 10

    private let session: URLSession
    private let authorizer: (any RequestAuthorizer)?

    /// `configuration` is copied; its request timeout is replaced by `requestTimeout`.
    public init(
        configuration: URLSessionConfiguration = .default,
        authorizer: (any RequestAuthorizer)? = nil
    ) {
        let copy = configuration.copy() as! URLSessionConfiguration
        copy.timeoutIntervalForRequest = Self.requestTimeout
        self.session = URLSession(configuration: copy)
        self.authorizer = authorizer
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var request = request
        if let authorizer {
            do {
                request = try await authorizer.authorize(request)
            } catch let error as BackendError {
                throw error
            } catch {
                throw Self.map(error, otherwise: .notAuthorized)
            }
        }

        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.timeoutInterval = Self.requestTimeout
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        urlRequest.httpBody = request.body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw Self.map(error, otherwise: nil)
        }
        guard let http = response as? HTTPURLResponse else {
            throw BackendError.malformedResponse("The reply was not an HTTP response.")
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key] = value }
        }
        return HTTPResponse(status: http.statusCode, headers: headers, body: data)
    }

    /// `otherwise` is used for a non-`URLError`; nil means `.unreachable`.
    private static func map(_ error: any Error, otherwise: BackendError?) -> BackendError {
        if let error = error as? BackendError { return error }
        guard let urlError = error as? URLError else {
            return otherwise ?? .unreachable(error.localizedDescription)
        }
        switch urlError.code {
        case .timedOut:
            return .timedOut
        case .badServerResponse, .cannotParseResponse, .cannotDecodeRawData,
            .cannotDecodeContentData, .zeroByteResource, .httpTooManyRedirects,
            .redirectToNonExistentLocation, .dataLengthExceedsMaximum:
            return .malformedResponse(urlError.localizedDescription)
        default:
            // Refused, DNS, no route, offline, TLS, cancelled, bad URL and anything else.
            return .unreachable(urlError.localizedDescription)
        }
    }
}
