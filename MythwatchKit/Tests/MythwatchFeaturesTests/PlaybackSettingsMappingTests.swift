import MythwatchPlayback
import Testing

@testable import MythwatchFeatures

@Suite struct PlaybackSettingsMappingTests {
    @Test func defaultsMapToDefaultPlaybackSettings() {
        #expect(AppSettings().playbackSettings == PlaybackSettings())
    }

    @Test(arguments: CommercialSkipMode.allCases)
    func skipModeIsCarriedIntoTheSkipperConfig(mode: CommercialSkipMode) {
        let p = AppSettings(commercialSkipMode: mode).playbackSettings
        #expect(p.commercialSkip == CommercialSkipConfig(mode: mode))
    }

    @Test(arguments: AppSettings.skipForwardChoices)
    func everyForwardChoiceMapsToThatManySeconds(seconds: Int) {
        #expect(AppSettings(skipForwardSeconds: seconds).playbackSettings.skipForward == .seconds(seconds))
    }

    @Test(arguments: AppSettings.skipBackwardChoices)
    func everyBackwardChoiceMapsToThatManySeconds(seconds: Int) {
        #expect(AppSettings(skipBackwardSeconds: seconds).playbackSettings.skipBackward == .seconds(seconds))
    }

    @Test func otherPlaybackFieldsKeepTheirDefaults() {
        let p = AppSettings(commercialSkipMode: .off, skipForwardSeconds: 60, skipBackwardSeconds: 5, deinterlace: false)
            .playbackSettings
        #expect(p.saveInterval == PlaybackSettings().saveInterval)
        #expect(p.watchedFraction == PlaybackSettings().watchedFraction)
        #expect(p.minimumResumePosition == PlaybackSettings().minimumResumePosition)
    }
}
