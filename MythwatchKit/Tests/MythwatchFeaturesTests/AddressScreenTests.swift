import Foundation
import MythwatchBackend
import MythwatchDomain
import MythwatchFeatures
import MythwatchTestSupport
import Testing

// The rules Settings and Onboarding share: testing the address being edited, the adapter name,
// enabling the test button, and discovered backends. Each test runs against both models.

private let validAddresses = [
    "backend.invalid", "backend.invalid:6544", "http://backend.invalid", "HTTP://Backend.Invalid:9",
    "  backend.invalid  ", "https://backend.invalid", "192.168.1.20", "[::1]", "my_box-2.local:80",
]
private let invalidAddresses = [
    "ftp://backend.invalid", "backend.invalid:0", "backend.invalid:70000", "backend.invalid:", "backend.invalid/path",
    "user@backend.invalid", "a b", "::1", ".invalid", "back..end", "http://", "backend.invalid:abc",
]

@MainActor
@Suite("Address screens: test connection")
struct AddressScreenTestConnectionTests {
    @Test(arguments: ScreenKind.allCases)
    func startsIdle(_ kind: ScreenKind) {
        let screen = kind.make(SetupRig(saved: AppSettings(backend: savedBackend)))
        #expect(screen.connectionTest.isIdle)
        #expect(screen.adapterName == nil)
    }

    @Test(arguments: ScreenKind.allCases)
    func goesFromIdleToLoadingToLoaded(_ kind: ScreenKind) async {
        let rig = SetupRig(saved: AppSettings(backend: savedBackend))
        let screen = kind.make(rig)
        rig.transport.parkNext("backend.invalid")
        let running = Task { await screen.testConnection() }
        await rig.transport.waitForParked()
        #expect(screen.connectionTest.isLoading)
        #expect(screen.adapterName == nil)
        rig.transport.releaseNext("backend.invalid")
        await running.value
        #expect(screen.connectionTest == .loaded(hostInfo))
    }

    @Test(arguments: ScreenKind.allCases)
    func anUnreachableBackendFailsWithAPlainMessage(_ kind: ScreenKind) async {
        let rig = SetupRig()
        let screen = kind.make(rig)
        screen.addressText = "nowhere.invalid"
        await screen.testConnection()
        #expect(screen.connectionTest == .failed(UserMessage(.unreachable("anything"))))
        #expect(screen.connectionTest.message?.canRetry == true)
        #expect(screen.adapterName == nil)
        let shown = screen.connectionTest.message.map { $0.title + $0.detail } ?? ""
        #expect(!shown.contains("nowhere.invalid"))
        #expect(!shown.contains("no fixture"))
    }

    @Test(arguments: ScreenKind.allCases)
    func anUnsupportedVersionShowsTheMessageThatNamesIt(_ kind: ScreenKind) async {
        let rig = SetupRig()
        let screen = kind.make(rig)
        screen.addressText = "old.invalid"
        await screen.testConnection()
        let message = UserMessage(.unsupportedVersion("v30.0"))
        #expect(screen.connectionTest == .failed(message))
        #expect(message.detail.contains("v30.0"))
        #expect(screen.adapterName == nil)
    }

    @Test(arguments: ScreenKind.allCases)
    func aFailedTestCanBeRunAgain(_ kind: ScreenKind) async {
        let rig = SetupRig()
        let screen = kind.make(rig)
        screen.addressText = "nowhere.invalid"
        await screen.testConnection()
        #expect(screen.connectionTest.message != nil)
        screen.addressText = "backend.invalid"
        #expect(screen.connectionTest.isIdle)
        await screen.testConnection()
        #expect(screen.connectionTest == .loaded(hostInfo))
    }

    @Test(arguments: ScreenKind.allCases)
    func showsTheAdapterNameAfterASuccessfulTest(_ kind: ScreenKind) async {
        let rig = SetupRig(saved: AppSettings(backend: savedBackend))
        let screen = kind.make(rig)
        await screen.testConnection()
        #expect(screen.adapterName == adapterLabel)
        #expect(rig.factory.makeRequests.map(\.connection) == [savedBackend])
    }

    @Test(arguments: ScreenKind.allCases)
    func testsTheEditedAddressAndChangesNothingElse(_ kind: ScreenKind) async {
        let rig = SetupRig(saved: AppSettings(backend: savedBackend))
        let screen = kind.make(rig)
        screen.addressText = "other.invalid"
        await screen.testConnection()
        #expect(screen.connectionTest.value?.hostName == "other-host")
        #expect(Set(rig.transport.requests.compactMap(\.url.host)) == ["other.invalid"])
        #expect(rig.store.saveCount == 0)
        #expect(rig.store.load().backend == savedBackend)
        #expect(rig.reconnectCount == 0)
        #expect(rig.session.isIdle)
    }

    @Test(arguments: ScreenKind.allCases)
    func aTestMadeWhileOneRunsForTheSameAddressJoinsIt(_ kind: ScreenKind) async {
        let rig = SetupRig(saved: AppSettings(backend: savedBackend))
        let screen = kind.make(rig)
        rig.transport.parkNext("backend.invalid")
        let first = Task { await screen.testConnection() }
        await rig.transport.waitForParked()
        let second = Task { await screen.testConnection() }
        rig.transport.releaseNext("backend.invalid")
        await first.value
        await second.value
        #expect(rig.transport.probeCount == 1)
        #expect(screen.connectionTest == .loaded(hostInfo))
    }

    @Test(arguments: ScreenKind.allCases)
    func aTestForAnotherAddressReplacesOneInFlightAndOnlyTheNewestShows(_ kind: ScreenKind) async {
        let rig = SetupRig(saved: AppSettings(backend: savedBackend))
        let screen = kind.make(rig)
        // The first answer is held open and ignores cancellation, so it arrives after the newer one.
        rig.transport.parkNext("backend.invalid", onCancel: .keepParked)
        let stale = Task { await screen.testConnection() }
        await rig.transport.waitForParked()
        screen.addressText = "other.invalid"
        #expect(screen.connectionTest.isIdle)
        await screen.testConnection()
        #expect(screen.connectionTest.value?.hostName == "other-host")
        rig.transport.releaseNext("backend.invalid")
        await stale.value
        #expect(screen.connectionTest.value?.hostName == "other-host")
        #expect(screen.adapterName == adapterLabel)
    }

    @Test(arguments: ScreenKind.allCases)
    func aSecondTestAfterTheFirstFinishedProbesAgain(_ kind: ScreenKind) async {
        let rig = SetupRig(saved: AppSettings(backend: savedBackend))
        let screen = kind.make(rig)
        await screen.testConnection()
        await screen.testConnection()
        #expect(rig.transport.probeCount == 2)
    }

    @Test(arguments: ScreenKind.allCases)
    func editingTheAddressMidTestCancelsItWithoutShowingAnError(_ kind: ScreenKind) async {
        let rig = SetupRig(saved: AppSettings(backend: savedBackend))
        let screen = kind.make(rig)
        rig.transport.parkNext("backend.invalid")  // cancelling it throws .unreachable, like URLSession
        let running = Task { await screen.testConnection() }
        await rig.transport.waitForParked()
        screen.addressText = "other.invalid"
        await running.value
        #expect(rig.transport.cancelledCount == 1)
        #expect(screen.connectionTest.isIdle)
        #expect(screen.adapterName == nil)
    }

    @Test(arguments: ScreenKind.allCases)
    func cancellingTheCallerDoesNotShowAnError(_ kind: ScreenKind) async {
        let rig = SetupRig(saved: AppSettings(backend: savedBackend))
        let screen = kind.make(rig)
        rig.transport.parkNext("backend.invalid")
        let running = Task { await screen.testConnection() }
        await rig.transport.waitForParked()
        running.cancel()
        // The test belongs to the model: it is still running and still ends in a result.
        #expect(screen.connectionTest.isLoading)
        rig.transport.releaseNext("backend.invalid")
        await running.value
        #expect(screen.connectionTest == .loaded(hostInfo))
    }
}

@MainActor
@Suite("Address screens: editing the address")
struct AddressScreenEditingTests {
    @Test(arguments: ScreenKind.allCases)
    func editingTheAddressClearsAnEarlierResult(_ kind: ScreenKind) async {
        let rig = SetupRig(saved: AppSettings(backend: savedBackend))
        let screen = kind.make(rig)
        await screen.testConnection()
        #expect(screen.connectionTest.value != nil)
        screen.addressText = "other.invalid"
        #expect(screen.connectionTest.isIdle)
        #expect(screen.adapterName == nil)
    }

    @Test(arguments: ScreenKind.allCases)
    func aFailedResultIsClearedByEditingToo(_ kind: ScreenKind) async {
        let rig = SetupRig()
        let screen = kind.make(rig)
        screen.addressText = "nowhere.invalid"
        await screen.testConnection()
        #expect(screen.connectionTest.message != nil)
        screen.addressText = "nowhere.invalid2"
        #expect(screen.connectionTest.isIdle)
    }

    @Test(arguments: ScreenKind.allCases)
    func anotherSpellingOfTheSameBackendKeepsTheResult(_ kind: ScreenKind) async {
        let rig = SetupRig(saved: AppSettings(backend: savedBackend))
        let screen = kind.make(rig)
        await screen.testConnection()
        screen.addressText = "http://Backend.Invalid"
        #expect(screen.connectionTest == .loaded(hostInfo))
        #expect(screen.adapterName == adapterLabel)
        screen.addressText = "backend.invalid:6544  "
        #expect(screen.connectionTest == .loaded(hostInfo))
    }

    @Test(arguments: ScreenKind.allCases)
    func editingToTextThatIsNotAnAddressClearsTheResult(_ kind: ScreenKind) async {
        let rig = SetupRig(saved: AppSettings(backend: savedBackend))
        let screen = kind.make(rig)
        await screen.testConnection()
        screen.addressText = "backend.invalid:"
        #expect(screen.connectionTest.isIdle)
        #expect(screen.adapterName == nil)
    }

    @Test(arguments: ScreenKind.allCases, validAddresses)
    func aValidAddressEnablesTestingAndHasNoHint(_ kind: ScreenKind, _ text: String) {
        let screen = kind.make(SetupRig())
        screen.addressText = text
        #expect(screen.canTestConnection)
        #expect(screen.addressHint == nil)
    }

    @Test(arguments: ScreenKind.allCases, invalidAddresses)
    func anInvalidAddressDisablesTestingAndSaysWhy(_ kind: ScreenKind, _ text: String) async {
        let rig = SetupRig()
        let screen = kind.make(rig)
        screen.addressText = text
        #expect(!screen.canTestConnection)
        #expect(screen.addressHint == "That doesn't look like an address. Try something like 192.168.1.20 or mybackend.local.")
        await screen.testConnection()
        #expect(screen.connectionTest.isIdle)
        #expect(rig.transport.requests.isEmpty)
    }

    /// M2-7, settled on the owner's Apple TV: tvOS does not resolve a bare host name such as
    /// `basement` (neither `URLSession` nor VLC), while `basement.local` works. A bare name is
    /// still a valid address (some networks resolve it) but gets a hint.
    @Test(arguments: ScreenKind.allCases, [
        ("basement", "basement"), ("basement:6544", "basement"), ("HTTP://MythBox:80", "mythbox"),
        ("https://my_box-2", "my_box-2"), ("  basement  ", "basement"),
    ])
    func aBareNameCanBeTestedButSuggestsADotLocalNameOrAnIPAddress(_ kind: ScreenKind, _ example: (String, String)) {
        let (text, host) = example
        let screen = kind.make(SetupRig())
        screen.addressText = text
        #expect(screen.canTestConnection)
        #expect(screen.addressHint
            == "Apple TV usually can't find a backend by its name alone. Try \(host).local, or the backend's IP address.")
    }

    @Test(arguments: ScreenKind.allCases, ["localhost", "localhost:6544"])
    func localhostGetsNoBareNameHint(_ kind: ScreenKind, _ text: String) {
        let screen = kind.make(SetupRig())
        screen.addressText = text
        #expect(screen.addressHint == nil)
    }

    @Test(arguments: ScreenKind.allCases, ["", "   ", "\n"])
    func anEmptyAddressCannotBeTestedButIsNotAnError(_ kind: ScreenKind, _ text: String) async {
        let rig = SetupRig()
        let screen = kind.make(rig)
        screen.addressText = text
        #expect(!screen.canTestConnection)
        #expect(screen.addressHint == nil)
        await screen.testConnection()
        #expect(rig.transport.requests.isEmpty)
    }
}

private let foundBackends: [(String, BackendConnection)] = [
    ("http://backend.invalid:6544", savedBackend),
    ("http://other.invalid:6544", otherBackend),
    ("http://backend.invalid:9000", BackendConnection(baseURL: URL(string: "http://backend.invalid:9000")!)),
    ("https://backend.invalid:6544", BackendConnection(baseURL: URL(string: "https://backend.invalid:6544")!)),
    ("http://192.168.1.20:6544", BackendConnection(baseURL: URL(string: "http://192.168.1.20:6544")!)),
    ("http://[fe80::1]:6544", BackendConnection(baseURL: URL(string: "http://[fe80::1]:6544")!)),
]

@MainActor
@Suite("Address screens: discovered backends")
struct AddressScreenDiscoveryTests {

    @Test(arguments: ScreenKind.allCases, foundBackends)
    func selectingADiscoveredBackendFillsTheAddress(_ kind: ScreenKind, _ item: (String, BackendConnection)) {
        let screen = kind.make(SetupRig())
        let backend = DiscoveredBackend(id: "x", name: "Living Room", connection: item.1)
        screen.select(backend)
        // Whatever form the text takes, it means exactly the backend that was chosen.
        #expect(BackendAddress.parse(screen.addressText) == item.1)
        #expect(screen.canTestConnection)
        #expect(screen.addressHint == nil)
        #expect(!screen.addressText.isEmpty)
    }

    @Test(arguments: ScreenKind.allCases)
    func anOrdinaryBackendIsShownWithoutTheSchemeOrTheWordHttp(_ kind: ScreenKind) {
        let screen = kind.make(SetupRig())
        screen.select(DiscoveredBackend(id: "x", name: "Den", connection: otherBackend))
        #expect(screen.addressText == "other.invalid:6544")
        screen.select(
            DiscoveredBackend(
                id: "y", name: "Den", connection: BackendConnection(baseURL: URL(string: "https://other.invalid:6544")!)))
        #expect(screen.addressText == "https://other.invalid:6544")
    }

    @Test(arguments: ScreenKind.allCases)
    func selectingAnotherBackendClearsAnEarlierTestResult(_ kind: ScreenKind) async {
        let rig = SetupRig(saved: AppSettings(backend: savedBackend))
        let screen = kind.make(rig)
        await screen.testConnection()
        screen.select(DiscoveredBackend(id: "o", name: "Other", connection: otherBackend))
        #expect(screen.connectionTest.isIdle)
        await screen.testConnection()
        #expect(screen.connectionTest.value?.hostName == "other-host")
    }

    @Test(arguments: ScreenKind.allCases)
    func selectingChangesNothingButTheText(_ kind: ScreenKind) {
        let rig = SetupRig(saved: AppSettings(backend: savedBackend))
        let screen = kind.make(rig)
        screen.select(DiscoveredBackend(id: "o", name: "Other", connection: otherBackend))
        #expect(rig.store.saveCount == 0)
        #expect(rig.reconnectCount == 0)
        #expect(rig.transport.requests.isEmpty)
    }

    @Test(arguments: ScreenKind.allCases)
    func listensOnlyBetweenStartAndStop(_ kind: ScreenKind) async {
        let rig = SetupRig()
        let screen = kind.make(rig)
        #expect(rig.discovery.discoverCount == 0)
        #expect(screen.discovered.isEmpty)

        screen.startDiscovery()
        screen.startDiscovery()  // already listening: no second stream
        #expect(rig.discovery.discoverCount == 1)
        let first = DiscoveredBackend(id: "a", name: "A", connection: savedBackend)
        let second = DiscoveredBackend(id: "b", name: "B", connection: otherBackend)
        rig.discovery.push([first])
        await waitUntil(screen) { $0.discovered == [first] }
        rig.discovery.push([first, second])
        await waitUntil(screen) { $0.discovered == [first, second] }

        screen.stopDiscovery()
        #expect(rig.discovery.activeStreamCount == 0)  // the stream was cancelled, not left open
        #expect(screen.discovered.isEmpty)
        rig.discovery.push([second])
        #expect(screen.discovered.isEmpty)

        // Listening again starts from what discovery already knows.
        screen.startDiscovery()
        #expect(rig.discovery.discoverCount == 2)
        await waitUntil(screen) { $0.discovered == [second] }
        screen.stopDiscovery()
        #expect(rig.discovery.activeStreamCount == 0)
    }

    @Test(arguments: ScreenKind.allCases)
    func stoppingWhenNotListeningIsHarmless(_ kind: ScreenKind) {
        let screen = kind.make(SetupRig())
        screen.stopDiscovery()
        #expect(screen.discovered.isEmpty)
    }

    @Test(arguments: ScreenKind.allCases)
    func aModelThatGoesAwayStopsListening(_ kind: ScreenKind) async {
        let rig = SetupRig()
        weak var weakScreen: (any AddressScreen)?
        do {
            let screen = kind.make(rig)
            weakScreen = screen
            screen.startDiscovery()
            rig.discovery.push([DiscoveredBackend(id: "a", name: "A", connection: savedBackend)])
            await waitUntil(screen) { !$0.discovered.isEmpty }
            #expect(rig.discovery.activeStreamCount == 1)
        }
        #expect(weakScreen == nil)
        #expect(rig.discovery.activeStreamCount == 0)
    }
}
