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
                    chunkPendingBaseOffset: chunkPendingBaseOffset, forceFullRelease: false,
                    pendingAudio: (Array(mic[chunkPendingBaseOffset..<end]), Array(system[chunkPendingBaseOffset..<end])))
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
        // (silence >= 1.0s) could never fire, and even the 60s hard-cap trigger deferred
        // everything (cutBoundary held at the still-"open" start of the session), so no automatic
        // chunk was ever actually delivered.
        // A 1s leading silence gives the VAD's calibration (see `MeetingVAD.calibrate`) genuine
        // ambience to calibrate the system channel's noise floor from - real capture always has at
        // least a brief instant before speech starts.
        var system: [Int16] = [Int16](repeating: 0, count: Int(Self.sampleRate))
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
        // A 1s leading silence gives the VAD's calibration (see `MeetingVAD.calibrate`) genuine
        // ambience to calibrate the noise floor from - real capture always has at least a brief
        // instant before speech starts; a synthetic tone at full volume from sample zero, with
        // nothing quieter anywhere in the stream, is not a scenario calibration can resolve.
        let leadIn = [Int16](repeating: 0, count: Int(Self.sampleRate))
        let openEndedRun = Self.speechBurst(seconds: 65)
        let laterUtteranceWithAGap = Self.speechBurst(seconds: 25) + [Int16](repeating: 0, count: Int(3 * Self.sampleRate))
        let system = leadIn + openEndedRun + laterUtteranceWithAGap
        let mic = [Int16](repeating: 0, count: system.count)

        let (triggerSilences, delivered) = run(mic: mic, system: system)

        #expect(triggerSilences.count >= 2, "the 60s-cap trigger firing must not prevent a later trigger")
        #expect(
            triggerSilences.contains { $0 >= MeetingAutoSendPolicy.requiredTrailingSilenceSeconds },
            "the later, cleanly-closed utterance's natural silence trigger must still fire")
        #expect(delivered > 0)
    }

    @Test func speechIsMeasuredAsUtteranceSpanNotJustVoicedFrames() {
        // Reproduces the reported bug: with some mics most frames between syllables fall below
        // the energy threshold even mid-word, so counting only voiced frames made the 5 s floor
        // practically unreachable. An utterance where only ~25% of frames are actually voiced
        // (alternating 20 ms loud / 60 ms silent, well under the 500 ms hangover so the region
        // never closes) must still count as ~10 s of speech - the span from first to last voiced
        // frame, not the sum of voiced frames.
        let frameSamples = MeetingVAD.frameSamples
        let loudFrame = [Int16](repeating: 6000, count: frameSamples)
        let silentFrames = [Int16](repeating: 0, count: frameSamples * 3)
        var mic: [Int16] = []
        while Double(mic.count) / Self.sampleRate < 10 {
            mic += loudFrame + silentFrames
        }
        let system = [Int16](repeating: 0, count: mic.count)

        let result = MeetingAutoSendEvaluator.step(
            mic: mic, system: system, sampleRate: Self.sampleRate, autoSendEnabled: true,
            micVADState: .initial, systemVADState: .initial, tracker: MeetingAutoSendTracker())

        #expect(
            result.tracker.speechSecondsSinceLastChunk >= 9.5,
            "the whole span must count as speech, not just the ~25% of voiced frames (got \(result.tracker.speechSecondsSinceLastChunk)s)"
        )
    }

    @Test func aLengthTriggerWithTheOpenRegionSpanningTheWholePendingBufferCutsAtTheLongestInternalPause() {
        // Reproduces the live 10:21 bug: 60s of uninterrupted speech kept the VAD region open from
        // the chunk start ("delivered=0 deferred=960320"), so nothing was ever sent until a manual
        // send or stop, with the pending buffer growing without bound. Instead of deferring
        // everything, the cut must land at the longest pause both channels share inside the open
        // region (nobody talking on either side) - the same "split at the longest internal pause"
        // idea as `MeetingTurnBuilder.cap`.
        let sr = Int(Self.sampleRate)
        let pauseStart = 30 * sr
        let pauseEnd = 31 * sr
        let system = Self.speechBurst(seconds: 30)
            + [Int16](repeating: 0, count: pauseEnd - pauseStart)
            + Self.speechBurst(seconds: 30)
        let mic = [Int16](repeating: 0, count: system.count)
        var openState = MeetingVAD.State.initial
        openState.inSpeech = true
        openState.speechStart = 0  // the open region spans the whole pending buffer

        let boundary = MeetingAutoSendEvaluator.cutBoundary(
            micVADState: openState, systemVADState: .initial, chunkPendingBaseOffset: 0,
            forceFullRelease: false, pendingAudio: (mic, system))

        #expect(boundary > 0, "a length trigger must never release nothing")
        #expect(boundary == (pauseStart + pauseEnd) / 2, "must cut at the midpoint of the longest shared pause, got \(boundary)")
    }

    @Test func aLengthTriggerWithNoInternalPauseAnywhereCutsAtThePendingEndInsteadOfDeliveringNothing() {
        // Continuous speech with genuinely no pause at all: no better cut point exists, so the
        // pending end (a hard cut) is the least-bad boundary - still never nothing.
        let system = Self.speechBurst(seconds: 61)
        let mic = [Int16](repeating: 0, count: system.count)
        var openState = MeetingVAD.State.initial
        openState.inSpeech = true
        openState.speechStart = 0

        let boundary = MeetingAutoSendEvaluator.cutBoundary(
            micVADState: openState, systemVADState: .initial, chunkPendingBaseOffset: 0,
            forceFullRelease: false, pendingAudio: (mic, system))

        #expect(boundary == system.count, "no pause to split at - deliver everything rather than nothing")
    }

    @Test func aNormalOpenUtteranceTailIsStillDeferredWhenRealClosedSpeechSitsAheadOfIt() {
        // The normal deferral case must stay exactly as it was: 30s of closed speech ahead of a
        // still-open tail is a real chunk on its own - the starvation fallback must not engage.
        let sr = Int(Self.sampleRate)
        let system = Self.speechBurst(seconds: 30) + Self.speechBurst(seconds: 30)
        let mic = [Int16](repeating: 0, count: system.count)
        var openState = MeetingVAD.State.initial
        openState.inSpeech = true
        openState.speechStart = 30 * sr  // the open tail starts where the closed speech ended

        let boundary = MeetingAutoSendEvaluator.cutBoundary(
            micVADState: openState, systemVADState: .initial, chunkPendingBaseOffset: 0,
            forceFullRelease: false, pendingAudio: (mic, system))

        #expect(boundary == 30 * sr, "the open tail must still be held back whole for the next chunk")
    }
}
