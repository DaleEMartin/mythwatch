import Foundation
import MythwatchBackend

/// Turns text typed by the user into a `BackendConnection`. Pure; makes no network request.
public enum BackendAddress {
    public static let defaultPort = 6544

    public static func parse(_ text: String) -> BackendConnection? {
        var rest = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        var scheme = "http"
        if let range = rest.range(of: "://") {
            scheme = rest[..<range.lowerBound].lowercased()
            guard scheme == "http" || scheme == "https" else { return nil }
            rest = rest[range.upperBound...]
        }
        if rest.hasSuffix("/") { rest = rest.dropLast() }  // a lone trailing slash is not a path
        guard !rest.isEmpty,
            !rest.contains(where: { "/?#@\\ ".contains($0) || $0.isWhitespace })
        else { return nil }

        let host: String
        var portText: Substring?
        if rest.hasPrefix("[") {
            guard let close = rest.firstIndex(of: "]") else { return nil }
            let inner = rest[rest.index(after: rest.startIndex)..<close]
            guard isIPv6Literal(inner) else { return nil }
            host = "[" + inner.lowercased() + "]"
            let tail = rest[rest.index(after: close)...]
            if !tail.isEmpty {
                guard tail.first == ":" else { return nil }
                portText = tail.dropFirst()
            }
        } else {
            let parts = rest.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count <= 2 else { return nil }
            guard isHostName(parts[0]) else { return nil }
            host = parts[0].lowercased()
            if parts.count == 2 { portText = parts[1] }
        }

        var port = defaultPort
        if let portText {
            guard !portText.isEmpty, portText.allSatisfy({ $0.isASCII && $0.isNumber }),
                portText.count <= 5, let value = Int(portText), (1...65535).contains(value)
            else { return nil }
            port = value
        }
        guard let url = URL(string: "\(scheme)://\(host):\(port)") else { return nil }
        return BackendConnection(baseURL: url)
    }

    private static func isHostName(_ s: Substring) -> Bool {
        guard !s.isEmpty else { return false }
        return s.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty
                && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        }
    }

    private static func isIPv6Literal(_ s: Substring) -> Bool {
        s.contains(":") && s.allSatisfy { $0.isASCII && ($0.isHexDigit || $0 == ":" || $0 == ".") }
    }
}
