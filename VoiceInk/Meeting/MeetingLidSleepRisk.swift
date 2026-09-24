import AppKit
import Foundation
import IOKit.ps

/// Whether starting Meeting Capture right now risks the recording being cut short by the Mac
/// sleeping when the lid is closed - see `MeetingKeepAwake`'s doc comment for why the keep-awake
/// assertion alone doesn't prevent that.
enum MeetingLidSleepRisk {
    static func warrantsWarning(isOnBattery: Bool, hasExternalDisplay: Bool) -> Bool {
        isOnBattery && !hasExternalDisplay
    }
}

/// Real (impure) power/display state `MeetingLidSleepRisk` is evaluated against - kept separate
/// so the decision itself stays unit-testable without touching IOKit/AppKit (see
/// `MeetingLidSleepRiskTests`).
enum MeetingPowerState {
    static func isOnBattery() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else { return false }
        for source in sources {
            guard
                let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue()
                    as? [String: Any],
                let state = description[kIOPSPowerSourceStateKey as String] as? String
            else { continue }
            return state == kIOPSBatteryPowerValue as String
        }
        return false
    }

    /// A second `NSScreen` is the simplest robust signal for "an external display is attached" -
    /// it is true in extended-desktop AND clamshell (lid-closed, external-only) modes alike, which
    /// is exactly the condition that keeps the Mac awake with the lid closed.
    static func hasExternalDisplay() -> Bool {
        NSScreen.screens.count > 1
    }
}
