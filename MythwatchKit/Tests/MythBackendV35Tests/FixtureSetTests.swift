import Foundation
import MythwatchTestSupport
import Testing

/// Guards the committed v35 fixture set (docs/BACKEND-V35.md, "Fixtures"; provenance in
/// Fixtures/README.md). No decoding into DTOs or domain types here: that is M1-6.
@Suite struct FixtureSetTests {
    /// Every file in Fixtures/. Adding or removing a fixture means updating this list and the README.
    static let expected: Set<String> = [
        "README.md",
        // Captured (sanitised).
        "backend-info.json",
        "hostname.json",
        "recorded-list-page1.json",
        "recorded-list-page2.json",
        "recorded-one.json",
        "recorded-missing.json",
        "commbreak.json",
        "commbreak-empty.json",
        "lastplaypos-zero.json",
        "lastplaypos-set.json",
        "not-found.html",
        // Hand-edited copies.
        "recorded-one-airdate-null.json",
        "recorded-one-artwork-null.json",
        "recorded-one-resume-watched-bookmark.json",
        "recorded-one-deletepending.json",
        "recorded-one-damaged.json",
        "commbreak-unbalanced.json",
        "bool-true.json",
        "bool-true-string.json",
    ]

    static var jsonNames: [String] { expected.filter { $0.hasSuffix(".json") }.sorted() }

    /// The real backend's host name, spelt backwards so the literal itself never appears in the
    /// repository. Fixtures must use `backend` instead.
    static let realHostName = String("tnemesab".reversed())

    private func load(_ name: String) throws -> Data {
        try FixtureLoader.data(named: name, in: .module, subdirectory: "Fixtures")
    }

    @Test func bundleHoldsExactlyTheListedFixtures() throws {
        let directory = try #require(
            Bundle.module.url(forResource: "Fixtures", withExtension: nil), "Fixtures not bundled")
        let bundled = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(Set(bundled) == Self.expected)
    }

    @Test(arguments: jsonNames) func parsesAsJSON(_ name: String) throws {
        let data = try load(name)
        #expect(throws: Never.self) { try JSONSerialization.jsonObject(with: data) }
    }

    @Test(arguments: expected.sorted()) func doesNotMentionTheRealHost(_ name: String) throws {
        let text = String(decoding: try load(name), as: UTF8.self)
        #expect(!text.localizedCaseInsensitiveContains(Self.realHostName))
    }

    @Test(arguments: jsonNames) func everyHostNameIsSanitised(_ name: String) throws {
        let object = try JSONSerialization.jsonObject(with: try load(name))
        var hostNames: [String] = []
        collect(object, into: &hostNames)
        for host in hostNames {
            #expect(host == "backend", "\(name): host name \"\(host)\"")
        }
    }

    /// Values of `HostName` keys, and the host in `myth://Group@host/...` artwork file names.
    private func collect(_ value: Any, into hosts: inout [String]) {
        if let dict = value as? [String: Any] {
            for (key, child) in dict {
                if key == "HostName", let host = child as? String { hosts.append(host) }
                collect(child, into: &hosts)
            }
        } else if let array = value as? [Any] {
            for child in array { collect(child, into: &hosts) }
        } else if let text = value as? String, text.hasPrefix("myth://"),
            let at = text.firstIndex(of: "@")
        {
            let rest = text[text.index(after: at)...]
            hosts.append(String(rest.prefix { $0 != "/" }))
        }
    }

    @Test func notFoundPageIsHTML() throws {
        let text = String(decoding: try load("not-found.html"), as: UTF8.self)
        #expect(text.contains("404 Not Found"))
    }
}
