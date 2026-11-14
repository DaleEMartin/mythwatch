import Foundation

/// Every adapter and transport maps its failures to this type.
public enum BackendError: Error, Sendable, Equatable {
    case unreachable(String)
    case timedOut
    case http(status: Int, message: String?)
    case malformedResponse(String)
    case notFound
    case rejected(String)
    case unsupportedVersion(String)
    case notAuthorized
}
