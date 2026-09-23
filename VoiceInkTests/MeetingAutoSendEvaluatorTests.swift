import Testing
import Foundation
@testable import VoiceInk

// MARK: - Meeting Capture: automatic chunk-send trigger

struct MeetingAutoSendEvaluatorTests {
    private static let sampleRate = MeetingVAD.sampleRate

    private static func steadyHum(seconds: Double, amplitude: Double) -> [Int16] {
        let count = Int(seconds * sampleRate)
        return (0..<count).map { i in
            let t = Double(i) / sampleRate
            return Int16(clamping: Int((amplitude * sin(2 * Double.pi * 400 * t)).rounded()))
        }
    }

    private static func speechBurst(seconds: Double) -> [Int16] {
        let count = Int(seconds * sampleRate)
        return (0..<count).map { i in
            let t = Double(i) / sampleRate
            return Int16(clamping: Int((6000 * sin(2 * Double.pi * 400 * t)).rounded()))
        }
    }

    /// Drives `MeetingAutoSendEvaluator.step` (and `cutBoundary`, mirroring what
    /// `MeetingAudioCapture.cut()` does on every trigger) in 1s ticks over the whole stream,
    /// exactly like the periodic drain timer does.
    private func run(mic: [Int16], system: [Int16]) -> (triggerSilenceDurations: [TimeInterval], deliveredTotal: Int) {
        var micState = MeetingVAD.State.initial
        var systemState = MeetingVAD.State.initial
        var tracker = MeetingAutoSendTracker()
        var isAutoSendPending = false
        var chunkPendingBaseOffset = 0
        var triggerSilenceDurations: [TimeInterval] = []
        let tickSamples = Int(Self.sampleRate)
        var i = 0
        while i < mic.count {
            let end = min(i + tickSamples, mic.count)
            let result = MeetingAutoSendEvaluator.step(
                mic: Array(mic[i..<end]), system: Array(system[i..<end]), sampleRate: Self.sampleRate,
                autoSendEnabled: !isAutoSendPending, micVADState: micState, systemVADState: systemState,
                tracker: tracker)
            micState = result.micVADState
            systemState = result.systemVADState
            tracker = result.tracker

            if result.shouldTrigger {
                triggerSilenceDurations.append(tracker.currentSilenceDuration)
                let boundary = MeetingAutoSendEvaluator.cutBoundary(
                    micVADState: micState, systemVADState: systemState,
                    chunkPendingBaseOffset: chunkPendingBaseOffset, forceFullRelease: false)
                let pendingLength = end - chunkPendingBaseOffset
                let delivered = boundary == .max ? pendingLength : min(boundary, pendingLength)
                chunkPendingBaseOffset += delivered
                isAutoSendPending = true
                tracker.resetAfterChunkSent()
                isAutoSendPending = false
            }
            i = end
        }
        return (triggerSilenceDurations, chunkPendingBaseOffset)
    }

    @Test func steadyLowLevelMicNoiseDoesNotPreventTheNaturalSilenceTriggerFromLandingInAGap() {
        // Reproduces the root cause: a mic channel whose ambient noise starts out above
        // absoluteFloor (150), before the noise floor has ever adapted, used to read as one
        // never-ending "speech" region for the rest of the session (the floor only moved on
        // frames already classified silent, so a channel that starts loud never adapted). That
        // pinned currentSilenceDuration at 0 forever, so a natural trailing-silence trigger
        // (silence >= 1.5s) could never fire, and even the 60s hard-cap trigger deferred
        // everything (cutBoundary held at the still-"open" start of the session), so no automatic
        // chunk was ever actually delivered.
        var system: [Int16] = []
        for _ in 0..<3 {
            system += Self.speechBurst(seconds: 20)
            system += [Int16](repeating: 0, count: Int(2.5 * Self.sampleRate))
        }
        let mic = Self.steadyHum(seconds: Double(system.count) / Self.sampleRate, amplitude: 300)

        let (triggerSilences, delivered) = run(mic: mic, system: system)

        #expect(
            triggerSilences.contains { $0 >= MeetingAutoSendPolicy.requiredTrailingSilenceSeconds },
            "a trigger must land during one of the 2.5s gaps, not only via the 60s hard cap")
        #expect(delivered > 0, "a trigger must actually release audio - not defer everything forever")
    }

    @Test func aTriggerThatDefersEverythingDoesNotLeaveAutoSendStuckPending() {
        // One continuous, never-pausing utterance running well past the 60s hard cap: the cap
        // trigger fires while the utterance is still open, so `cutBoundary` defers essentially
        // everything back into the pending buffer. `cut()` must still reset the pending flag and
        // tracker regardless, so a second, later, cleanly-closed utterance (with a real gap) can
        // go on to trigger normally instead of auto-send staying permanently disabled.
        let openEndedRun = Self.speechBurst(seconds: 65)
        let laterUtteranceWithAGap = Self.speechBurst(seconds: 25) + [Int16](repeating: 0, count: Int(3 * Self.sampleRate))
        let system = openEndedRun + laterUtteranceWithAGap
        let mic = [Int16](repeating: 0, count: system.count)

        let (triggerSilences, delivered) = run(mic: mic, system: system)

        #expect(triggerSilences.count >= 2, "the 60s-cap trigger firing must not prevent a later trigger")
        #expect(
            triggerSilences.contains { $0 >= MeetingAutoSendPolicy.requiredTrailingSilenceSeconds },
            "the later, cleanly-closed utterance's natural silence trigger must still fire")
        #expect(delivered > 0)
    }
}
