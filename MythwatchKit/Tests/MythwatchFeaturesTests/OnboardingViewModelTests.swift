import Foundation
import MythwatchBackend
import MythwatchDomain
import MythwatchFeatures
import MythwatchPlayback
import MythwatchTestSupport
import Testing

private let validAddresses = [
    "backend.invalid", "backend.invalid:6544", "http://backend.invalid", "HTTPS://Backend.Invalid:9",
    "  backend.invalid\n", "192.168.1.20", "[::1]:6544", "my_box-2.local",
]
private let invalidAddresses = [
    "", "   ", "ftp://backend.invalid", "backend.invalid:0", "backend.invalid:70000", "backend.invalid:",
    "backend.invalid/path", "backend.invalid?x=1", "user@backend.invalid", "a b", "::1", "..", "http://",
]

private let tuned = AppSettings(
    backend: nil, commercialSkipMode: .off, skipForwardSeconds: 15, skipBackwardSeconds: 30,
    deinterlace: false, askBeforeDelete: false)

@MainActor
@Suite("OnboardingViewModel: connect is only possible with a valid address")
struct OnboardingViewModelEnablementTests {
    @Test func startsWithAnEmptyAddressAndCannotConnect() {
        let model = SetupRig().onboardingModel()
        #expect(model.addressText == "")
        #expect(!model.canConnect)
        #expect(!model.canTestConnection)
        #expect(model.connectState.isIdle)
        #expect(model.addressHint == nil)
    }

    @Test(arguments: validAddresses)
    func aValidAddressEnablesConnect(_ text: String) {
        let model = SetupRig().onboardingModel()
        model.addressText = text
        #expect(model.canConnect)
        #expect(model.canTestConnection)
    }

    @Test(arguments: invalidAddresses)
    func anInvalidOrEmptyAddressDisablesConnect(_ text: String) async {
        let rig = SetupRig()
        let model = rig.onboardingModel()
        model.addressText = text
        #expect(!model.canConnect)
        #expect(!model.canTestConnection)
        await model.connect()
        #expect(rig.store.saveCount == 0)
        #expect(rig.reconnectCount == 0)
        #expect(model.connectState.isIdle)
        #expect(rig.transport.requests.isEmpty)
    }

    @Test func connectIsOffWhileConnectingAndAnotherCallIsIgnored() async {
        let rig = SetupRig()
        var release: CheckedContinuation<Void, Never>?
        rig.onReconnect = { await withCheckedContinuation { release = $0 } }
        let model = rig.onboardingModel()
        model.addressText = "backend.invalid"
        let running = Task { await model.connect() }
        await waitUntil(model) { $0.isConnecting }
        #expect(!model.canConnect)
        await model.connect()
        #expect(rig.reconnectCount == 1)
        release?.resume()
        await running.value
        #expect(!model.isConnecting)
    }
}

@MainActor
@Suite("OnboardingViewModel: connect")
struct OnboardingViewModelConnectTests {
    @Test func savesTheBackendKeepingEveryOtherSettingAndThenConnects() async {
        let rig = SetupRig(saved: tuned)
        let model = rig.onboardingModel()
        model.addressText = "http://Backend.Invalid"
        await model.connect()
        #expect(rig.store.saved == [AppSettings(
            backend: savedBackend, commercialSkipMode: .off, skipForwardSeconds: 15,
            skipBackwardSeconds: 30, deinterlace: false, askBeforeDelete: false)])
        #expect(rig.reconnectCount == 1)
        #expect(rig.savedBackendAtReconnect == [savedBackend])  // saved before connecting
    }

    @Test func showsLoadingWhileConnectingThenDoneWithTheVersionAndAdapter() async {
        let rig = SetupRig()
        var release: CheckedContinuation<Void, Never>?
        rig.onReconnect = { await withCheckedContinuation { release = $0 } }
        let model = rig.onboardingModel()
        model.addressText = "backend.invalid"
        #expect(model.connectState.isIdle)
        let running = Task { await model.connect() }
        await waitUntil(model) { $0.connectState.isLoading }
        #expect(model.isConnecting)
        rig.session = rig.loadedSession()
        release?.resume()
        await running.value
        #expect(model.connectState == .loaded(hostInfo))
        #expect(model.adapterName == adapterLabel)
        #expect(!model.isConnecting)
    }

    @Test func aFailureIsShownAsAMessageAndTheAddressIsKept() async {
        let rig = SetupRig()
        rig.onReconnect = { [rig] in rig.session = .failed(UserMessage(.unreachable("DIAG raw text"))) }
        let model = rig.onboardingModel()
        model.addressText = "backend.invalid"
        await model.connect()
        #expect(model.connectState == .failed(UserMessage(.unreachable("other text"))))
        #expect(model.adapterName == nil)
        // Kept, so the user can retry or edit it; and so a restart opens the app, not Onboarding.
        #expect(rig.store.load().backend == savedBackend)
        #expect(model.addressText == "backend.invalid")
    }

    @Test func anUnsupportedVersionShowsTheMessageThatNamesIt() async {
        let rig = SetupRig()
        rig.onReconnect = { [rig] in rig.session = .failed(UserMessage(.unsupportedVersion("v30.0"))) }
        let model = rig.onboardingModel()
        model.addressText = "old.invalid"
        await model.connect()
        #expect(model.connectState.message?.detail.contains("v30.0") == true)
        #expect(model.connectState.message?.canRetry == false)
    }

    @Test func aFailedConnectCanBeRetriedWithTheSameAddress() async {
        let rig = SetupRig()
        rig.onReconnect = { [rig] in rig.session = .failed(UserMessage(.timedOut)) }
        let model = rig.onboardingModel()
        model.addressText = "backend.invalid"
        await model.connect()
        #expect(model.canConnect)
        rig.onReconnect = { [rig] in rig.session = rig.loadedSession() }
        await model.connect()
        #expect(model.connectState == .loaded(hostInfo))
        #expect(rig.reconnectCount == 2)
    }

    @Test func editingTheAddressAfterAFailureClearsTheFailure() async {
        let rig = SetupRig()
        rig.onReconnect = { [rig] in rig.session = .failed(UserMessage(.timedOut)) }
        let model = rig.onboardingModel()
        model.addressText = "backend.invalid"
        await model.connect()
        model.addressText = "other.invalid"
        #expect(model.connectState.isIdle)
    }

    @Test func anotherSpellingOfTheSameAddressKeepsTheFailure() async {
        let rig = SetupRig()
        rig.onReconnect = { [rig] in rig.session = .failed(UserMessage(.timedOut)) }
        let model = rig.onboardingModel()
        model.addressText = "backend.invalid"
        await model.connect()
        model.addressText = "http://backend.invalid:6544"
        #expect(model.connectState.message != nil)
    }

    @Test func anOutcomeForAnAddressThatWasEditedAwayMeanwhileIsNotShown() async {
        let rig = SetupRig()
        var release: CheckedContinuation<Void, Never>?
        rig.onReconnect = { await withCheckedContinuation { release = $0 } }
        let model = rig.onboardingModel()
        model.addressText = "backend.invalid"
        let running = Task { await model.connect() }
        await waitUntil(model) { $0.isConnecting }
        model.addressText = "other.invalid"
        rig.session = rig.loadedSession()
        release?.resume()
        await running.value
        #expect(model.connectState.isIdle)
        #expect(model.adapterName == nil)
        #expect(model.canConnect)
    }

    @Test func aSessionThatIsNeitherLoadedNorFailedLeavesTheScreenIdle() async {
        let rig = SetupRig()
        rig.session = .idle
        let model = rig.onboardingModel()
        model.addressText = "backend.invalid"
        await model.connect()
        #expect(model.connectState.isIdle)
    }

    @Test func connectDoesNotUseTheConnectorItself() async {
        // The probe belongs to AppModel's reconnect; Onboarding only asks for it.
        let rig = SetupRig()
        let model = rig.onboardingModel()
        model.addressText = "backend.invalid"
        await model.connect()
        #expect(rig.transport.requests.isEmpty)
    }

    @Test func aTestDoesNotSaveOrConnectAndTheScreenStillOffersConnect() async {
        let rig = SetupRig()
        let model = rig.onboardingModel()
        model.addressText = "backend.invalid"
        await model.testConnection()
        #expect(model.connectionTest == .loaded(hostInfo))
        #expect(model.adapterName == adapterLabel)
        #expect(rig.store.saveCount == 0)
        #expect(rig.reconnectCount == 0)
        #expect(model.connectState.isIdle)
        #expect(model.canConnect)
    }
}
