import Testing

@testable import VoiceInk

struct MeetingLidSleepRiskTests {
    @Test func onBatteryWithNoExternalDisplayWarrantsAWarning() {
        #expect(MeetingLidSleepRisk.warrantsWarning(isOnBattery: true, hasExternalDisplay: false))
    }

    @Test func onBatteryWithAnExternalDisplayDoesNotWarrantAWarning() {
        // Clamshell mode (lid closed, power + external display) keeps the Mac awake regardless.
        #expect(!MeetingLidSleepRisk.warrantsWarning(isOnBattery: true, hasExternalDisplay: true))
    }

    @Test func onACPowerNeverWarrantsAWarning() {
        #expect(!MeetingLidSleepRisk.warrantsWarning(isOnBattery: false, hasExternalDisplay: false))
        #expect(!MeetingLidSleepRisk.warrantsWarning(isOnBattery: false, hasExternalDisplay: true))
    }
}
