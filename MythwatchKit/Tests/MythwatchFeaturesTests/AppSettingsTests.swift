import Foundation
import Testing

@testable import MythwatchFeatures

/// A `UserDefaults` that keeps values in a dictionary and never reaches the preferences daemon
/// or the disk. (`UserDefaults(suiteName:)` plus `removePersistentDomain` was tried first and
/// leaves an empty `.plist` in `~/Library/Preferences` for every suite.) It overrides every
/// method `UserDefaultsSettingsStore` uses; `data(forKey:)` returns nil for a non-`Data` value,
/// as the real class does. Each test makes its own instance, so parallel tests share nothing.
final class InMemoryDefaults: UserDefaults {
    private var values: [String: Any] = [:]

    init() { super.init(suiteName: nil)! }

    override func data(forKey defaultName: String) -> Data? { values[defaultName] as? Data }
    override func object(forKey defaultName: String) -> Any? { values[defaultName] }
    override func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
    override func removeObject(forKey defaultName: String) { values[defaultName] = nil }
}

/// Runs `body` with a fresh in-memory `UserDefaults`.
func withScratchDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
    try body(InMemoryDefaults())
}

private let key = "settings.v1"

private func decode(_ json: String) throws -> AppSettings {
    try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
}

@Suite struct AppSettingsTests {
    @Test func defaults() {
        let s = AppSettings()
        #expect(s.backend == nil)
        #expect(s.commercialSkipMode == .auto)
        #expect(s.skipForwardSeconds == 30)
        #expect(s.skipBackwardSeconds == 10)
        #expect(s.deinterlace == true)
        #expect(s.askBeforeDelete == true)
    }

    @Test func freshStoreLoadsDefaults() {
        withScratchDefaults { d in
            #expect(UserDefaultsSettingsStore(defaults: d).load() == AppSettings())
        }
    }

    @Test func roundTripEveryNonDefaultField() {
        withScratchDefaults { d in
            let store = UserDefaultsSettingsStore(defaults: d)
            var s = AppSettings()
            s.backend = BackendAddress.parse("https://tv.example:1234")
            s.commercialSkipMode = .prompt
            s.skipForwardSeconds = 60
            s.skipBackwardSeconds = 30
            s.deinterlace = false
            s.askBeforeDelete = false
            #expect(s.backend != nil)
            store.save(s)
            #expect(store.load() == s)
            // A second store over the same defaults sees the same value.
            #expect(UserDefaultsSettingsStore(defaults: d).load() == s)
        }
    }

    @Test func savedBlobIsOneJSONValueUnderSettingsV1() throws {
        try withScratchDefaults { d in
            UserDefaultsSettingsStore(defaults: d).save(AppSettings())
            let data = try #require(d.data(forKey: key))
            #expect(try JSONSerialization.jsonObject(with: data) is [String: Any])
        }
    }

    @Test func saveReplacesEarlierValue() {
        withScratchDefaults { d in
            let store = UserDefaultsSettingsStore(defaults: d)
            var s = AppSettings()
            s.deinterlace = false
            store.save(s)
            store.save(AppSettings())
            #expect(store.load() == AppSettings())
        }
    }

    // MARK: corrupt data

    @Test func corruptNotJSON() {
        withScratchDefaults { d in
            d.set(Data("not json {{".utf8), forKey: key)
            #expect(UserDefaultsSettingsStore(defaults: d).load() == AppSettings())
        }
    }

    @Test func corruptJSONOfWrongType() {
        for json in ["[1,2,3]", "\"text\"", "42", "null", "true"] {
            withScratchDefaults { d in
                d.set(Data(json.utf8), forKey: key)
                #expect(
                    UserDefaultsSettingsStore(defaults: d).load() == AppSettings(),
                    "blob \(json)")
            }
        }
    }

    @Test func corruptEmptyData() {
        withScratchDefaults { d in
            d.set(Data(), forKey: key)
            #expect(UserDefaultsSettingsStore(defaults: d).load() == AppSettings())
        }
    }

    @Test func corruptValueIsNotData() {
        let values: [Any] = ["a string", 7, true, ["a", "b"], ["k": "v"]]
        for value in values {
            withScratchDefaults { d in
                d.set(value, forKey: key)
                #expect(
                    UserDefaultsSettingsStore(defaults: d).load() == AppSettings(),
                    "value \(value)")
            }
        }
    }

    // MARK: unknown / missing / invalid keys

    @Test func unknownKeysAreTolerated() throws {
        let s = try decode(
            #"{"deinterlace": false, "skipForwardSeconds": 60, "futureThing": {"a": [1, 2]}, "x": null}"#)
        #expect(s.deinterlace == false)
        #expect(s.skipForwardSeconds == 60)
        #expect(s.askBeforeDelete == true)
    }

    @Test func unknownKeysAreToleratedThroughTheStore() {
        withScratchDefaults { d in
            d.set(Data(#"{"askBeforeDelete": false, "newerSetting": 1}"#.utf8), forKey: key)
            var expected = AppSettings()
            expected.askBeforeDelete = false
            #expect(UserDefaultsSettingsStore(defaults: d).load() == expected)
        }
    }

    @Test func missingKeysLoadAsDefaultsAndKeepPresentOnes() throws {
        let s = try decode(
            #"{"commercialSkipMode": "off", "skipBackwardSeconds": 15}"#)
        var expected = AppSettings()
        expected.commercialSkipMode = .off
        expected.skipBackwardSeconds = 15
        #expect(s == expected)
        #expect(s.skipForwardSeconds == 30)
        #expect(s.deinterlace == true)
        #expect(s.backend == nil)
    }

    @Test func emptyObjectIsDefaults() throws {
        #expect(try decode("{}") == AppSettings())
    }

    @Test func missingBackendKeepsOtherFieldsAndBackendSurvivesWhenPresent() throws {
        let s = try decode(
            #"{"backend": {"baseURL": "http://tv:6544"}, "deinterlace": false}"#)
        #expect(s.backend?.baseURL.absoluteString == "http://tv:6544")
        #expect(s.deinterlace == false)
    }

    @Test func unknownCommercialSkipModeLoadsAsDefaultAndOthersSurvive() throws {
        let s = try decode(
            #"{"commercialSkipMode": "sometimes", "skipForwardSeconds": 60, "deinterlace": false}"#)
        #expect(s.commercialSkipMode == .auto)
        #expect(s.skipForwardSeconds == 60)
        #expect(s.deinterlace == false)
    }

    @Test(arguments: [7, 0, -10, 31, 1000])
    func skipForwardOutsideChoicesLoadsAsDefault(value: Int) throws {
        let s = try decode(#"{"skipForwardSeconds": \#(value), "askBeforeDelete": false}"#)
        #expect(s.skipForwardSeconds == 30)
        #expect(s.askBeforeDelete == false)
    }

    @Test(arguments: [7, 0, -5, 20, 1000])
    func skipBackwardOutsideChoicesLoadsAsDefault(value: Int) throws {
        let s = try decode(#"{"skipBackwardSeconds": \#(value), "skipForwardSeconds": 15}"#)
        #expect(s.skipBackwardSeconds == 10)
        #expect(s.skipForwardSeconds == 15)
    }

    @Test(arguments: [10, 15, 30, 60])
    func everyForwardChoiceIsKept(value: Int) throws {
        #expect(try decode(#"{"skipForwardSeconds": \#(value)}"#).skipForwardSeconds == value)
    }

    @Test(arguments: [5, 10, 15, 30])
    func everyBackwardChoiceIsKept(value: Int) throws {
        #expect(try decode(#"{"skipBackwardSeconds": \#(value)}"#).skipBackwardSeconds == value)
    }

    @Test func wrongTypedFieldLoadsAsDefaultAndOthersSurvive() throws {
        let s = try decode(
            #"{"skipForwardSeconds": "thirty", "deinterlace": "yes", "askBeforeDelete": false, "backend": 5}"#)
        #expect(s.skipForwardSeconds == 30)
        #expect(s.deinterlace == true)
        #expect(s.askBeforeDelete == false)
        #expect(s.backend == nil)
    }

    @Test func choiceListsMatchSpec() {
        #expect(AppSettings.skipForwardChoices == [10, 15, 30, 60])
        #expect(AppSettings.skipBackwardChoices == [5, 10, 15, 30])
    }

    @Test func storeIsSendable() {
        withScratchDefaults { d in
            let store: any SettingsStore = UserDefaultsSettingsStore(defaults: d)
            let _: any Sendable = store
        }
    }
}
