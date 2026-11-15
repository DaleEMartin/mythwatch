import Testing

@testable import MythwatchFeatures

@Suite struct BackendAddressTests {
    @Test(arguments: [
        // Spec table
        ("host", "http://host:6544"),
        ("host:6544", "http://host:6544"),
        ("http://host", "http://host:6544"),
        ("http://host:6544", "http://host:6544"),
        ("https://host:1234", "https://host:1234"),
        ("https://host", "https://host:6544"),
        ("  host  ", "http://host:6544"),
        ("\n\thost:80\t ", "http://host:80"),
        ("192.168.1.20", "http://192.168.1.20:6544"),
        ("192.168.1.20:6544", "http://192.168.1.20:6544"),
        ("http://192.168.1.20:7000", "http://192.168.1.20:7000"),
        ("[::1]", "http://[::1]:6544"),
        ("[::1]:6544", "http://[::1]:6544"),
        ("[fe80::1]:1234", "http://[fe80::1]:1234"),
        ("http://[::1]:9", "http://[::1]:9"),
        // Decisions written into SPEC 6.2
        ("http://host/", "http://host:6544"),
        ("host/", "http://host:6544"),
        ("host:1", "http://host:1"),
        ("host:65535", "http://host:65535"),
        ("HTTP://Host", "http://host:6544"),
        ("MyBackend", "http://mybackend:6544"),
        ("MyBackend.LOCAL:6544", "http://mybackend.local:6544"),
        ("mythtv.local", "http://mythtv.local:6544"),
        ("http://mythtv.local:6544", "http://mythtv.local:6544"),
        ("my-host_1", "http://my-host_1:6544"),
    ])
    func accepted(input: String, expected: String) {
        let connection = BackendAddress.parse(input)
        #expect(connection?.baseURL.absoluteString == expected)
    }

    @Test func resultHasNoPathQueryOrFragment() throws {
        let url = try #require(BackendAddress.parse("host:1234/")).baseURL
        #expect(url.scheme == "http")
        #expect(url.host == "host")
        #expect(url.port == 1234)
        #expect(url.path.isEmpty)
        #expect(url.query == nil)
        #expect(url.fragment == nil)
    }

    @Test(arguments: [
        "",
        "   ",
        "\n",
        "host/path",
        "http://host/path",
        "host/path/more",
        "host//",
        "host:notaport",
        "host:",
        "host:-1",
        "host:+80",
        "host:80a",
        "host:6544:1",
        "http://",
        ":6544",
        "http://:6544",
        // Decisions written into SPEC 6.2
        "host?x=1",
        "http://host?x=1",
        "http://host/?x=1",
        "host#frag",
        "host:0",
        "host:70000",
        "host:65536",
        "host:99999999999999999999",
        "ftp://host",
        "https2://host",
        "://host",
        "user@host",
        "user:pw@host:6544",
        "http://user@host",
        "ho st",
        "host.",
        ".host",
        "a..b",
        "::1",
        "[::1",
        "[]",
        "[::1]x",
        "[::1]:",
        "[not an ip]",
        "http://http://host",
    ])
    func rejected(input: String) {
        #expect(BackendAddress.parse(input) == nil)
    }
}
