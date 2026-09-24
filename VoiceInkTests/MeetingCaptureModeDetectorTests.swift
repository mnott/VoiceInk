import Testing

@testable import VoiceInk

struct MeetingCaptureModeDetectorTests {
    @Test func systemTapAvailableAndNoForcedSettingIsTwoChannel() {
        #expect(
            MeetingCaptureModeDetector.mode(isCapturingSystemAudio: true, forcedInPersonSetting: false) == .twoChannel)
    }

    @Test func noSystemTapIsAlwaysInPersonRegardlessOfTheSetting() {
        #expect(
            MeetingCaptureModeDetector.mode(isCapturingSystemAudio: false, forcedInPersonSetting: false) == .inPerson)
        #expect(
            MeetingCaptureModeDetector.mode(isCapturingSystemAudio: false, forcedInPersonSetting: true) == .inPerson)
    }

    @Test func forcedSettingOverridesAnAvailableSystemTap() {
        // A call app happens to be open (tap available) but the meeting is actually in person.
        #expect(
            MeetingCaptureModeDetector.mode(isCapturingSystemAudio: true, forcedInPersonSetting: true) == .inPerson)
    }
}
