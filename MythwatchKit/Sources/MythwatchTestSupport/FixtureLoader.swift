import Foundation

public struct FixtureError: Error, CustomStringConvertible, Sendable {
    public let name: String
    public let reason: String
    public var description: String { "Fixture \"\(name)\": \(reason)" }
}

/// Reads fixtures from a bundle the caller supplies (each test target passes `.module`).
public enum FixtureLoader {
    /// `name` without an extension means `name.json`; a name with an extension
    /// (`not-found.html`, `sample.json`) is used as given.
    public static func data(named name: String, in bundle: Bundle, subdirectory: String? = nil)
        throws -> Data
    {
        let given = (name as NSString).pathExtension
        let ext = given.isEmpty ? "json" : given
        let base = given.isEmpty ? name : (name as NSString).deletingPathExtension
        let file = base + "." + ext
        guard let url = bundle.url(forResource: base, withExtension: ext, subdirectory: subdirectory)
        else {
            throw FixtureError(
                name: file,
                reason: "not found in bundle \(bundle.bundleURL.lastPathComponent)"
                    + (subdirectory.map { " (subdirectory \($0))" } ?? ""))
        }
        do { return try Data(contentsOf: url) } catch {
            throw FixtureError(name: file, reason: "could not be read: \(error)")
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
