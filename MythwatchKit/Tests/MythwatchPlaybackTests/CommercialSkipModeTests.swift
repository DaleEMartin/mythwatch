import Testing

@testable import MythwatchPlayback

@Suite struct CommercialSkipModeTests {
    @Test(arguments: [
        (CommercialSkipMode.auto, "auto"), (.prompt, "prompt"), (.off, "off"),
    ])
    func rawValues(mode: CommercialSkipMode, raw: String) {
        #expect(mode.rawValue == raw)
        #expect(CommercialSkipMode(rawValue: raw) == mode)
    }

    @Test func hasExactlyThreeCases() {
        #expect(CommercialSkipMode.allCases == [.auto, .prompt, .off])
    }
}
