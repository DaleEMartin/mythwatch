import Foundation
import MythwatchDomain
import MythwatchFeatures
import Testing

/// A distinctive string put in every associated value, so a leak into user text is easy to spot.
private let diag = "DIAG-7f3a"

/// One sample of every `BackendError` case. The switch in `expected(for:)` is exhaustive, so a new
/// case does not compile until it has a row here and a wording in SPEC §6.
private let samples: [BackendError] = [
    .unreachable("\(diag) Could not connect to the server. NSURLErrorDomain -1004"),
    .timedOut,
    .http(status: 503, message: "\(diag) <html><body>503 Service Unavailable</body></html>"),
    .malformedResponse("\(diag) The data couldn't be read because it isn't in the correct format."),
    .notFound,
    .rejected("\(diag) not implemented until M3-5 / M5-1"),
    .unsupportedVersion("v37-Pre-676-g5474cf09b0"),
    .notAuthorized,
]

private func expected(for error: BackendError) -> (title: String, canRetry: Bool) {
    switch error {
    case .unreachable: ("Can't Reach Your MythTV Backend", true)
    case .timedOut: ("Your MythTV Backend Didn't Answer in Time", true)
    case .http: ("Your MythTV Backend Had a Problem", true)
    case .malformedResponse: ("Mythwatch Didn't Understand the Reply", true)
    case .notFound: ("This Recording Is No Longer Available", false)
    case .rejected: ("Your MythTV Backend Turned That Down", false)
    case .unsupportedVersion: ("This Version of MythTV Isn't Supported", false)
    case .notAuthorized: ("Your MythTV Backend Wants a Sign-In", false)
    }
}

/// Words and marks that must never reach the screen (compared case-insensitively).
private let forbidden = [
    "error", "http", "malformed", "adapter", "probe", "endpoint", "json", "url", "status",
    "nsurl", "!", "503", "-1004", diag,
]

@Suite("UserMessage")
struct UserMessageTests {
    @Test(arguments: samples)
    func eachCaseHasItsTitleAndRetryChoice(_ error: BackendError) {
        let message = UserMessage(error)
        let want = expected(for: error)
        #expect(message.title == want.title)
        #expect(message.canRetry == want.canRetry)
        #expect(!message.detail.isEmpty)
    }

    @Test func titlesAreDistinct() {
        let titles = samples.map { UserMessage($0).title } + [UserMessage.unexpected.title, UserMessage.playbackFailed.title]
        #expect(Set(titles).count == titles.count)
    }

    @Test func detailsAreDistinct() {
        let details = samples.map { UserMessage($0).detail } + [UserMessage.unexpected.detail, UserMessage.playbackFailed.detail]
        #expect(Set(details).count == details.count)
    }

    @Test(arguments: samples + [nil])
    func noDiagnosticOrJargonReachesTheScreen(_ error: BackendError?) {
        let message = error.map(UserMessage.init) ?? .unexpected
        for text in [message.title, message.detail] {
            for word in forbidden {
                #expect(!text.localizedCaseInsensitiveContains(word), "\"\(word)\" in: \(text)")
            }
        }
    }

    @Test func playbackFailedReadsPlainlyAndOffersARetry() {
        let message = UserMessage.playbackFailed
        #expect(message.title == "Can't Play This Recording")
        #expect(message.detail == "Mythwatch couldn't get the video from your MythTV backend. Make sure the "
            + "backend is turned on, then try again. Mythwatch will pick up where you left off.")
        #expect(message.canRetry)
        for text in [message.title, message.detail] {
            for word in forbidden { #expect(!text.localizedCaseInsensitiveContains(word), "\"\(word)\" in: \(text)") }
        }
    }

    @Test func titlesHaveNoDigits() {
        for error in samples {
            let title = UserMessage(error).title
            let hasDigit = title.contains { $0.isNumber }
            #expect(!hasDigit, "digits in: \(title)")
        }
    }

    @Test func unsupportedVersionNamesTheVersion() {
        let message = UserMessage(.unsupportedVersion("v37-Pre-676-g5474cf09b0"))
        #expect(message.detail.contains("v37-Pre-676-g5474cf09b0"))
        #expect(!message.title.contains("v37"))
    }

    @Test func unsupportedVersionWithABlankVersionStillReads() {
        let message = UserMessage(.unsupportedVersion("  "))
        #expect(message.title == expected(for: .unsupportedVersion("")).title)
        #expect(!message.detail.contains("  "))
        #expect(message.detail.contains("MythTV"))
    }

    @Test func unreachablePointsAtTheAddressInSettings() {
        #expect(UserMessage(.unreachable("x")).detail.contains("address in Settings"))
    }

    @Test func unexpectedIsAGenericRetryableMessage() {
        let message = UserMessage.unexpected
        #expect(message.title == "Something Went Wrong")
        #expect(message.canRetry)
    }

    @Test func memberwiseInitialiserAndEquality() {
        let a = UserMessage(title: "T", detail: "D", canRetry: true)
        #expect(a == UserMessage(title: "T", detail: "D", canRetry: true))
        #expect(a != UserMessage(title: "T", detail: "D", canRetry: false))
    }
}

@Suite("Loadable")
struct LoadableTests {
    private let message = UserMessage(title: "T", detail: "D", canRetry: false)

    @Test func helpersReadEachState() {
        let idle = Loadable<Int>.idle
        let loading = Loadable<Int>.loading
        let loaded = Loadable<Int>.loaded(3)
        let failed = Loadable<Int>.failed(message)

        #expect(idle.isIdle && !idle.isLoading && idle.value == nil && idle.message == nil)
        #expect(!loading.isIdle && loading.isLoading && loading.value == nil && loading.message == nil)
        #expect(!loaded.isIdle && !loaded.isLoading && loaded.value == 3 && loaded.message == nil)
        #expect(!failed.isIdle && !failed.isLoading && failed.value == nil && failed.message == message)
    }

    @Test func equatableWhenTheValueIs() {
        #expect(Loadable<Int>.loaded(1) == .loaded(1))
        #expect(Loadable<Int>.loaded(1) != .loaded(2))
        #expect(Loadable<Int>.failed(message) == .failed(message))
        #expect(Loadable<Int>.idle != .loading)
    }
}
