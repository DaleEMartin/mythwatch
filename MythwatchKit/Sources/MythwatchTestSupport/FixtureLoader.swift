import Foundation

public struct FixtureError: Error, CustomStringConvertible, Sendable {
    public let name: String
    public let reason: String
    public var description: String { "Fixture \"\(name)\": \(reason)" }
}

/// Reads JSON fixtures from a bundle the caller supplies (each test target passes `.module`).
public enum FixtureLoader {
    /// `name` may be given with or without the `.json` extension.
    public static func data(named name: String, in bundle: Bundle, subdirectory: String? = nil)
        throws -> Data
    {
        let base = name.hasSuffix(".json") ? String(name.dropLast(5)) : name
        guard let url = bundle.url(forResource: base, withExtension: "json", subdirectory: subdirectory)
        else {
            throw FixtureError(
                name: base + ".json",
                reason: "not found in bundle \(bundle.bundleURL.lastPathComponent)"
                    + (subdirectory.map { " (subdirectory \($0))" } ?? ""))
        }
        do { return try Data(contentsOf: url) } catch {
            throw FixtureError(name: base + ".json", reason: "could not be read: \(error)")
        }
    }

    public static func decode<T: Decodable>(
        _ type: T.Type, named name: String, in bundle: Bundle, subdirectory: String? = nil,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> T {
        let data = try data(named: name, in: bundle, subdirectory: subdirectory)
        do { return try decoder.decode(type, from: data) } catch {
            throw FixtureError(name: name, reason: "could not be decoded as \(T.self): \(error)")
        }
    }
}
