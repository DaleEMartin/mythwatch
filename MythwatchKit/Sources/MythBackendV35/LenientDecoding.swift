import Foundation

// Lenient decoding helpers. Every v35 DTO decodes every field with `try?`, so one odd value in one
// row can never fail a whole list (docs/BACKEND-V35.md, "Recordings"). Unknown keys are ignored by
// the keyed containers themselves.

extension KeyedDecodingContainer {
    /// A string, or nil when the key is absent, null or not a string.
    func lenientString(_ key: Key) -> String? {
        (try? decodeIfPresent(String.self, forKey: key)) ?? nil
    }

    /// A number, or a string holding one; nil otherwise.
    func lenientInt64(_ key: Key) -> Int64? {
        guard contains(key) else { return nil }
        return LenientNumber.int64(from: self, key: key)
    }

    /// A nested object, or nil when absent, null or of the wrong shape.
    func lenientObject<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }
}

enum LenientNumber {
    static func int64<K: CodingKey>(from container: KeyedDecodingContainer<K>, key: K) -> Int64? {
        if let value = try? container.decode(Int64.self, forKey: key) { return value }
        if let value = try? container.decode(Double.self, forKey: key),
            value == value.rounded(), abs(value) < 9.0e18
        {
            return Int64(value)
        }
        if let text = try? container.decode(String.self, forKey: key) {
            return Int64(text.trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    static func bool<K: CodingKey>(from container: KeyedDecodingContainer<K>, key: K) -> Bool? {
        if let value = try? container.decode(Bool.self, forKey: key) { return value }
        if let number = try? container.decode(Int64.self, forKey: key) {
            return number == 1 ? true : number == 0 ? false : nil
        }
        if let text = try? container.decode(String.self, forKey: key) {
            switch text.trimmingCharacters(in: .whitespaces).lowercased() {
            case "true", "1": return true
            case "false", "0": return false
            default: return nil
            }
        }
        return nil
    }
}

/// Decodes to nil instead of throwing, so an array of these never fails because of one element.
struct Lossy<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: any Decoder) throws { value = try? Value(from: decoder) }
}

extension KeyedDecodingContainer {
    /// An array whose undecodable elements are dropped; empty when absent, null or not an array.
    func lossyArray<T: Decodable>(_ type: T.Type, _ key: Key) -> [T] {
        let boxes = (try? decodeIfPresent([Lossy<T>].self, forKey: key)) ?? nil
        return (boxes ?? []).compactMap(\.value)
    }
}
