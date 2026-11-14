import Foundation
import MythwatchDomain

public struct BackendInfo: Sendable, Equatable {
    public var version: BackendVersion
    public var hostName: String?

    public init(version: BackendVersion, hostName: String?) {
        self.version = version
        self.hostName = hostName
    }
}

/// The only version-neutral wire code in the app (SPEC §4). The endpoint paths and the one
/// JSON key path read here must not appear anywhere else in this target.
public struct BackendProbe: Sendable {
    private static let infoPath = "/Myth/GetBackendInfo"
    private static let hostNamePath = "/Myth/GetHostName"

    private struct InfoEnvelope: Decodable {
        struct Info: Decodable {
            struct Build: Decodable { let Version: String? }
            let Build: Build?
        }
        let BackendInfo: Info?
    }

    private struct HostNameEnvelope: Decodable { let String: String? }

    private let transport: any HTTPTransport

    public init(transport: any HTTPTransport) { self.transport = transport }

    public func probe(_ connection: BackendConnection) async throws -> BackendInfo {
        let response = try await transport.send(request(Self.infoPath, connection))
        guard (200..<300).contains(response.status) else {
            throw BackendError.http(status: response.status, message: nil)
        }
        let envelope: InfoEnvelope
        do {
            envelope = try JSONDecoder().decode(InfoEnvelope.self, from: response.body)
        } catch {
            throw BackendError.malformedResponse("The backend's version reply was not understood.")
        }
        guard let raw = envelope.BackendInfo?.Build?.Version else {
            throw BackendError.malformedResponse("The backend's version reply had no version.")
        }
        guard let version = BackendVersion(parsing: raw) else {
            throw BackendError.malformedResponse("The backend's version \"\(raw)\" was not understood.")
        }
        return BackendInfo(version: version, hostName: await hostName(connection))
    }

    /// Optional: any failure (transport, status, shape) yields nil.
    private func hostName(_ connection: BackendConnection) async -> String? {
        guard let response = try? await transport.send(request(Self.hostNamePath, connection)),
            (200..<300).contains(response.status),
            let envelope = try? JSONDecoder().decode(HostNameEnvelope.self, from: response.body)
        else { return nil }
        return envelope.String
    }

    private func request(_ path: String, _ connection: BackendConnection) -> HTTPRequest {
        var components = URLComponents(url: connection.baseURL, resolvingAgainstBaseURL: false)
        components?.path = path
        let url = components?.url ?? connection.baseURL.appendingPathComponent(path)
        return HTTPRequest(method: .get, url: url, headers: ["Accept": "application/json"])
    }
}
