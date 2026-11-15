import Foundation
import MythwatchBackend
import MythwatchDomain
import MythwatchFeatures
import MythwatchPlayback
import MythwatchTestSupport
import Testing

private let custom = AppSettings(
    backend: savedBackend, commercialSkipMode: .prompt, skipForwardSeconds: 60,
    skipBackwardSeconds: 15, deinterlace: false, askBeforeDelete: false)

@MainActor
@Suite("SettingsViewModel: editing")
struct SettingsViewModelEditingTests {
    @Test func startsFromTheSavedSettings() {
        let rig = SetupRig(saved: custom)
        let model = rig.settingsModel()
        #expect(model.addressText == "backend.invalid:6544")
        #expect(model.commercialSkipMode == .prompt)
        #expect(model.skipForwardSeconds == 60)
        #expect(model.skipBackwardSeconds == 15)
        #expect(model.deinterlace == false)
        #expect(model.askBeforeDelete == false)
        #expect(model.editedSettings == custom)
        #expect(!model.hasUnsavedChanges)
        #expect(!model.canSave)
    }

    @Test func noBackendSavedStartsWithAnEmptyAddress() {
        let model = SetupRig().settingsModel()
        #expect(model.addressText == "")
        #expect(model.editedSettings == AppSettings())
        #expect(!model.hasUnsavedChanges)
        #expect(!model.canTestConnection)
    }

    @Test func editsAreKeptInTheModelUntilSaveIsCalled() {
        let rig = SetupRig(saved: custom)
        let model = rig.settingsModel()
        model.deinterlace = true
        model.addressText = "other.invalid"
        model.commercialSkipMode = .off
        #expect(rig.store.saveCount == 0)
        #expect(rig.store.load() == custom)
    }

    @Test(arguments: [10, 15, 30, 60])
    func acceptsEachAllowedForwardStep(_ seconds: Int) {
        let model = SetupRig().settingsModel()
        model.skipForwardSeconds = seconds
        #expect(model.skipForwardSeconds == seconds)
    }

    @Test(arguments: [5, 10, 15, 30])
    func acceptsEachAllowedBackStep(_ seconds: Int) {
        let model = SetupRig().settingsModel()
        model.skipBackwardSeconds = seconds
        #expect(model.skipBackwardSeconds == seconds)
    }

    @Test(arguments: [0, 5, 20, 45, 90, -30])
    func ignoresAForwardStepThatIsNotOffered(_ seconds: Int) {
        let model = SetupRig(saved: custom).settingsModel()
        model.skipForwardSeconds = seconds
        #expect(model.skipForwardSeconds == 60)
        #expect(!model.hasUnsavedChanges)
    }

    @Test(arguments: [0, 10_000, 20, 45, 60, -5])
    func ignoresABackStepThatIsNotOffered(_ seconds: Int) {
        let model = SetupRig(saved: custom).settingsModel()
        model.skipBackwardSeconds = seconds
        #expect(model.skipBackwardSeconds == 15)
        #expect(!model.hasUnsavedChanges)
    }

    @Test func tellsTheViewWhichStepsToOffer() {
        #expect(SettingsViewModel.skipForwardChoices == [10, 15, 30, 60])
        #expect(SettingsViewModel.skipBackwardChoices == [5, 10, 15, 30])
    }

    @Test func everyFieldCountsAsAnUnsavedChangeAndEditingBackUndoesIt() {
        let model = SetupRig(saved: custom).settingsModel()
        model.commercialSkipMode = .auto
        #expect(model.hasUnsavedChanges)
        model.commercialSkipMode = .prompt
        #expect(!model.hasUnsavedChanges)
        model.skipForwardSeconds = 30
        #expect(model.hasUnsavedChanges)
        model.skipForwardSeconds = 60
        model.skipBackwardSeconds = 5
        #expect(model.hasUnsavedChanges)
        model.skipBackwardSeconds = 15
        model.deinterlace = true
        #expect(model.hasUnsavedChanges)
        model.deinterlace = false
        model.askBeforeDelete = true
        #expect(model.hasUnsavedChanges)
        model.askBeforeDelete = false
        model.addressText = "other.invalid"
        #expect(model.hasUnsavedChanges)
        model.addressText = "backend.invalid"
        #expect(!model.hasUnsavedChanges)
    }

    @Test func anotherSpellingOfTheSavedBackendIsNotAChange() {
        let model = SetupRig(saved: custom).settingsModel()
        for text in ["http://backend.invalid", "BACKEND.invalid:6544", "  http://backend.invalid:6544/ "] {
            model.addressText = text
            #expect(!model.hasUnsavedChanges, "\(text)")
            #expect(!model.canSave)
        }
    }
}

@MainActor
@Suite("SettingsViewModel: the address controls Save")
struct SettingsViewModelAddressTests {
    @Test(arguments: [
        "ftp://backend.invalid", "backend.invalid:0", "backend.invalid:70000", "backend.invalid/path", "a b",
        "user@backend.invalid", "::1",
    ])
    func anInvalidAddressCannotBeSaved(_ text: String) async {
        let rig = SetupRig(saved: custom)
        let model = rig.settingsModel()
        model.addressText = text
        #expect(model.hasUnsavedChanges)  // there is something pending, but ...
        #expect(!model.canSave)
        #expect(model.editedSettings == nil)
        await model.save()
        #expect(rig.store.saveCount == 0)
        #expect(rig.reconnectCount == 0)
    }

    @Test(arguments: ["other.invalid", "https://other.invalid:8443", "192.168.1.20", "[::1]:6544"])
    func aValidChangedAddressCanBeSaved(_ text: String) {
        let model = SetupRig(saved: custom).settingsModel()
        model.addressText = text
        #expect(model.canSave)
        #expect(model.editedSettings?.backend == BackendAddress.parse(text))
    }

    @Test func anInvalidAddressDoesNotStopOtherSettingsFromBeingEditedBack() {
        let model = SetupRig(saved: custom).settingsModel()
        model.addressText = "backend.invalid:0"
        model.addressText = "backend.invalid"
        #expect(model.canSave == false)
        #expect(!model.hasUnsavedChanges)
    }

    @Test func clearingTheAddressIsAChangeThatCanBeSaved() {
        let model = SetupRig(saved: custom).settingsModel()
        model.addressText = "   "
        #expect(model.hasUnsavedChanges)
        #expect(model.canSave)
        #expect(model.addressHint == nil)
        #expect(!model.canTestConnection)
        #expect(model.editedSettings?.backend == nil)
    }
}

struct SaveCase: Sendable, CustomTestStringConvertible {
    var name: String
    var saved: BackendConnection?
    var text: String
    var reconnects: Bool
    var testDescription: String { name }
}

let saveCases = [
    SaveCase(name: "changed backend", saved: savedBackend, text: "other.invalid", reconnects: true),
    SaveCase(name: "changed port", saved: savedBackend, text: "backend.invalid:9000", reconnects: true),
    SaveCase(name: "changed scheme", saved: savedBackend, text: "https://backend.invalid", reconnects: true),
    SaveCase(name: "first backend", saved: nil, text: "backend.invalid", reconnects: true),
    SaveCase(name: "cleared", saved: savedBackend, text: "", reconnects: true),
    SaveCase(name: "unchanged", saved: savedBackend, text: "backend.invalid:6544", reconnects: false),
    SaveCase(name: "bare host spelling", saved: savedBackend, text: "backend.invalid", reconnects: false),
    SaveCase(name: "scheme spelling", saved: savedBackend, text: "http://backend.invalid", reconnects: false),
    SaveCase(name: "upper case spelling", saved: savedBackend, text: " HTTP://Backend.INVALID:6544/ ", reconnects: false),
    SaveCase(name: "still none", saved: nil, text: "  ", reconnects: false),
]

@MainActor
@Suite("SettingsViewModel: Save")
struct SettingsViewModelSaveTests {
    @Test(arguments: saveCases)
    func reconnectsOnlyWhenTheBackendChanged(_ c: SaveCase) async {
        let rig = SetupRig(saved: AppSettings(backend: c.saved))
        let model = rig.settingsModel()
        model.addressText = c.text
        model.deinterlace = false  // something else always changes, so Save is always possible
        await model.save()
        #expect(rig.reconnectCount == (c.reconnects ? 1 : 0))
        #expect(rig.store.saveCount == 1)
        #expect(rig.store.load().backend == BackendAddress.parse(c.text))
        #expect(rig.store.load().deinterlace == false)
    }

    @Test func changingOnlyPlaybackOrCommercialSettingsDoesNotReconnect() async {
        let rig = SetupRig(saved: AppSettings(backend: savedBackend))
        let model = rig.settingsModel()
        model.commercialSkipMode = .off
        model.skipForwardSeconds = 15
        model.skipBackwardSeconds = 30
        model.deinterlace = false
        model.askBeforeDelete = false
        await model.save()
        #expect(rig.reconnectCount == 0)
        #expect(rig.transport.requests.isEmpty)
        #expect(
            rig.store.load()
                == AppSettings(
                    backend: savedBackend, commercialSkipMode: .off, skipForwardSeconds: 15,
                    skipBackwardSeconds: 30, deinterlace: false, askBeforeDelete: false))
    }

    @Test func aBackendChangeAndOtherChangesAreSavedTogetherWithOneReconnect() async {
        let rig = SetupRig(saved: custom)
        let model = rig.settingsModel()
        model.addressText = "other.invalid"
        model.commercialSkipMode = .auto
        await model.save()
        #expect(rig.store.saved == [AppSettings(
            backend: otherBackend, commercialSkipMode: .auto, skipForwardSeconds: 60,
            skipBackwardSeconds: 15, deinterlace: false, askBeforeDelete: false)])
        #expect(rig.reconnectCount == 1)
    }

    @Test func theNewBackendIsInTheStoreBeforeTheReconnectStarts() async {
        let rig = SetupRig(saved: custom)
        let model = rig.settingsModel()
        model.addressText = "other.invalid"
        await model.save()
        #expect(rig.savedBackendAtReconnect == [otherBackend])
    }

    @Test func clearingTheBackendSavesNoBackendAndReconnects() async {
        let rig = SetupRig(saved: custom)
        let model = rig.settingsModel()
        model.addressText = ""
        await model.save()
        #expect(rig.store.load().backend == nil)
        #expect(rig.store.load().commercialSkipMode == .prompt)
        #expect(rig.reconnectCount == 1)
        #expect(rig.savedBackendAtReconnect == [nil])
    }

    @Test func afterSavingThereIsNothingLeftToSaveAndTheAddressIsTidied() async {
        let rig = SetupRig(saved: custom)
        let model = rig.settingsModel()
        model.addressText = " HTTP://Other.Invalid "
        model.deinterlace = true
        #expect(model.canSave)
        await model.save()
        #expect(!model.hasUnsavedChanges)
        #expect(!model.canSave)
        #expect(model.addressText == "other.invalid:6544")
        await model.save()  // nothing to do
        #expect(rig.store.saveCount == 1)
        #expect(rig.reconnectCount == 1)
    }

    @Test func savingWithNothingChangedDoesNothing() async {
        let rig = SetupRig(saved: custom)
        let model = rig.settingsModel()
        await model.save()
        #expect(rig.store.saveCount == 0)
        #expect(rig.reconnectCount == 0)
    }

    @Test func savingDoesNotTouchTheResultOfATestOfTheSameBackend() async {
        let rig = SetupRig(saved: custom)
        let model = rig.settingsModel()
        model.addressText = "other.invalid"
        await model.testConnection()
        model.addressText = "http://other.invalid"
        await model.save()
        #expect(model.connectionTest.value?.hostName == "other-host")
        #expect(model.adapterName == adapterLabel)
    }

    @Test func showsThatItIsReconnectingAndThenWhetherItWorked() async {
        let rig = SetupRig(saved: custom)
        var release: CheckedContinuation<Void, Never>?
        rig.onReconnect = { await withCheckedContinuation { release = $0 } }
        let model = rig.settingsModel()
        model.addressText = "other.invalid"
        #expect(!model.isReconnecting)
        let saving = Task { await model.save() }
        await waitUntil(model) { $0.isReconnecting }
        #expect(model.reconnectProblem == nil)
        #expect(!model.hasUnsavedChanges)  // already stored
        rig.session = .failed(UserMessage(.timedOut))
        release?.resume()
        await saving.value
        #expect(!model.isReconnecting)
        #expect(model.reconnectProblem == UserMessage(.timedOut))
    }

    @Test func aSuccessfulReconnectLeavesNoProblem() async {
        let rig = SetupRig(saved: custom)
        rig.onReconnect = { [rig] in rig.session = rig.loadedSession(hostName: "other-host") }
        let model = rig.settingsModel()
        model.addressText = "other.invalid"
        await model.save()
        #expect(model.reconnectProblem == nil)
        #expect(model.adapterName == adapterLabel)
        #expect(model.backendInfo?.hostName == "other-host")
    }

    @Test func aLaterSaveClearsTheEarlierProblem() async {
        let rig = SetupRig(saved: custom)
        rig.session = .failed(UserMessage(.unreachable("x")))
        let model = rig.settingsModel()
        model.addressText = "other.invalid"
        await model.save()
        #expect(model.reconnectProblem != nil)
        rig.onReconnect = { [rig] in rig.session = rig.loadedSession() }
        model.addressText = "backend.invalid"
        await model.save()
        #expect(model.reconnectProblem == nil)
    }
}

@MainActor
@Suite("SettingsViewModel: adapter name and version")
struct SettingsViewModelAdapterTests {
    @Test func showsTheLiveSessionsAdapterWhenTheAddressIsTheSavedOne() {
        let rig = SetupRig(saved: custom)
        rig.session = rig.loadedSession()
        let model = rig.settingsModel()
        #expect(model.adapterName == adapterLabel)
        #expect(model.backendInfo?.hostName == "backend-host")
        model.addressText = "http://Backend.Invalid"
        #expect(model.adapterName == adapterLabel)
    }

    @Test func showsNothingForTheLiveSessionOnceTheAddressIsEdited() {
        let rig = SetupRig(saved: custom)
        rig.session = rig.loadedSession()
        let model = rig.settingsModel()
        model.addressText = "other.invalid"
        #expect(model.adapterName == nil)
        #expect(model.backendInfo == nil)
        model.addressText = "backend.invalid"
        #expect(model.adapterName == adapterLabel)
        model.addressText = "backend.invalid:0"
        #expect(model.adapterName == nil)
    }

    @Test func showsNothingWithoutALoadedSession() {
        let rig = SetupRig(saved: custom)
        for session in [Loadable<BackendSession>.idle, .loading, .failed(.unexpected)] {
            rig.session = session
            #expect(rig.settingsModel().adapterName == nil)
        }
    }

    @Test func aTestResultTakesOverFromTheLiveSessionAndGoesBackWhenCleared() async {
        let rig = SetupRig(saved: custom)
        rig.session = rig.loadedSession()
        let model = rig.settingsModel()
        model.addressText = "other.invalid"
        await model.testConnection()
        #expect(model.backendInfo?.hostName == "other-host")
        model.addressText = "backend.invalid"
        #expect(model.connectionTest.isIdle)
        #expect(model.backendInfo?.hostName == "backend-host")  // the live session again
    }

    @Test func aFailedTestOfTheSavedAddressDoesNotHideTheLiveSession() async {
        let rig = SetupRig(saved: custom)
        rig.session = rig.loadedSession()
        let model = rig.settingsModel()
        rig.transport.parkNext("backend.invalid")
        let running = Task { await model.testConnection() }
        await rig.transport.waitForParked()
        rig.transport.releaseNext("backend.invalid", throwing: BackendError.timedOut)
        await running.value
        #expect(model.connectionTest == .failed(UserMessage(.timedOut)))
        #expect(model.adapterName == adapterLabel)  // what the app is connected to is still true
    }
}
