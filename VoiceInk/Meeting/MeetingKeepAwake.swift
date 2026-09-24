import Foundation
import IOKit.pwr_mgt

/// Prevents idle *system* sleep for as long as Meeting Capture is running - display sleep is
/// irrelevant (the display can go dark; the system must not suspend). Does NOT prevent lid-closed
/// sleep: closing the lid still sleeps the Mac regardless of this assertion unless it is on power
/// with an external display attached (clamshell mode) or system sleep is disabled entirely via
/// `sudo pmset -a disablesleep 1` (reverted with `sudo pmset -a disablesleep 0`) - VoiceInk never
/// runs `sudo` itself; see the Meeting Capture settings footer for this caveat and
/// `MeetingLidSleepRisk`/`MeetingPowerState` for the one-time warning when it applies. An
/// `IOPMAssertion` is released automatically by the OS if the process exits while one is held, so
/// "app quit" needs no extra code here.
protocol MeetingKeepAwakeAssertion: AnyObject {
    func acquire()
    func release()
}

/// Real assertion, backed by `IOPMAssertionCreateWithName`/`IOPMAssertionRelease`.
final class IOPMKeepAwakeAssertion: MeetingKeepAwakeAssertion {
    private var assertionID: IOPMAssertionID?

    func acquire() {
        guard assertionID == nil else { return }
        var id: IOPMAssertionID = 0
        let status = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoIdleSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "VoiceInk Meeting Capture" as CFString, &id)
        assertionID = status == kIOReturnSuccess ? id : nil
    }

    func release() {
        guard let id = assertionID else { return }
        IOPMAssertionRelease(id)
        assertionID = nil
    }
}

/// Acquire-on-start/release-on-stop-or-failure lifecycle, factored out from the real IOKit calls
/// (`assertion`, injectable) so it is unit-testable without touching real power management - see
/// `MeetingKeepAwakeTests`. `captureEndedOrFailed()` is idempotent: calling it once from `stop()`
/// and, separately, from a capture-failure path that also ends up stopping never double-releases.
struct MeetingKeepAwakeController {
    private let assertion: any MeetingKeepAwakeAssertion
    private(set) var isHeld = false

    init(assertion: any MeetingKeepAwakeAssertion = IOPMKeepAwakeAssertion()) {
        self.assertion = assertion
    }

    mutating func captureStarted() {
        assertion.acquire()
        isHeld = true
    }

    mutating func captureEndedOrFailed() {
        guard isHeld else { return }
        assertion.release()
        isHeld = false
    }
}
