import Foundation
import MythwatchBackend
import MythwatchDomain

/// The one place that builds v35 URLs, sends requests through the injected transport, and maps
/// HTTP statuses and decoding failures to `BackendError`. Every service goes through it, so every
/// service maps errors the same way (docs/BACKEND-V35.md, "General").
struct V35Client: Sendable {
    let baseURL: URL
    let transport: any HTTPTransport

    init(connection: BackendConnection, transport: any HTTPTransport) {
        self.baseURL = connection.baseURL
        self.transport = transport
    }

    // MARK: URLs

    /// `base + path`, without a doubled slash. `path` starts with "/".
    static func absoluteString(base: URL, path: String) -> String {
        var text = base.absoluteString
        while text.hasSuffix("/") { text.removeLast() }
        return text + path
    }

    /// Query values are percent-encoded once here; nothing is decoded.
    static func encode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+#?")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    func url(path: String, query: [(name: String, value: String)]) -> URL {
        var text = Self.absoluteString(base: baseURL, path: path)
        if !query.isEmpty {
            text += "?" + query.map { "\($0.name)=\(Self.encode($0.value))" }.joined(separator: "&")
        }
        return URL(string: text) ?? baseURL
    }

    // MARK: Requests

    /// GET with `Accept: application/json`; returns the body of a 2xx reply.
    func get(path: String, query: [(name: String, value: String)]) async throws -> Data {
        let request = HTTPRequest(
            method: .get, url: url(path: path, query: query),
            headers: ["Accept": "application/json"])
        let response = try await transport.send(request)
        switch response.status {
        case 200..<300:
            return response.body
        case 400:
            throw BackendError.rejected(Self.message(from: response.body) ?? "HTTP 400")
        default:
            throw BackendError.http(
                status: response.status, message: Self.message(from: response.body))
        }
    }

    func get<T: Decodable>(
        _ type: T.Type, path: String, query: [(name: String, value: String)]
    ) async throws -> T {
        let data = try await get(path: path, query: query)
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            // Nothing above the adapter may see a DecodingError.
            throw BackendError.malformedResponse("\(path): unexpected response shape")
        }
    }

    // MARK: Error text

    /// The readable text of an HTML (or plain) error body: the `<head>` and tags are dropped and
    /// whitespace collapsed. nil when nothing readable is left. Diagnostic only, never shown as is.
    static func message(from body: Data) -> String? {
        var text = String(decoding: body, as: UTF8.self)
        let patterns = [("<head[^>]*>.*?</head>", " "), ("<[^>]*>", " ")]
        for (pattern, template) in patterns {
            guard
                let regex = try? NSRegularExpression(
                    pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
            else { continue }
            text = regex.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
        }
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(200))
    }
}
