import Testing
import Foundation
@testable import VoiceInk

struct MeetingVADTests {
    private static let sampleRate = MeetingVAD.sampleRate

    private static func silence(seconds: Double) -> [Int16] {
        [Int16](repeating: 0, count: Int(seconds * sampleRate))
    }

    private static func tone(seconds: Double, amplitude: Int16 = 6000, frequency: Double = 400, phaseStart: Double = 0) -> [Int16] {
        let count = Int(seconds * sampleRate)
        return (0..<count).map { i in
            let t = (Double(i) + phaseStart) / sampleRate
            return Int16(clamping: Int((Double(amplitude) * sin(2 * Double.pi * frequency * t)).rounded()))
        }
    }

    /// Alternates `loudMs` at `amplitude` with `quietMs` at `amplitude * quietFraction` for
    /// `totalSeconds` - realistic energy dips within one continuous utterance (louder voiced
    /// syllables, quieter consonants/breaths between them), phase-continuous across the switch so
    /// there's no artificial click at each boundary.
    private static func alternatingUtterance(
        totalSeconds: Double, loudMs: Double, quietMs: Double, amplitude: Int16, quietFraction: Double
    ) -> [Int16] {
        var out: [Int16] = []
        var phase = 0.0
        while Double(out.count) / sampleRate < totalSeconds {
            let loud = tone(seconds: loudMs / 1000, amplitude: amplitude, phaseStart: phase)
            phase += Double(loud.count)
            out += loud
            let quiet = tone(seconds: quietMs / 1000, amplitude: Int16(Double(amplitude) * quietFraction), phaseStart: phase)
            phase += Double(quiet.count)
            out += quiet
        }
        return out
    }

    @Test func silenceProducesNoRegions() {
        let regions = MeetingVAD.regions(for: Self.silence(seconds: 2))
        #expect(regions.isEmpty)
    }

    @Test func emptyInputProducesNoRegions() {
        #expect(MeetingVAD.regions(for: []).isEmpty)
    }

    @Test func lowLevelNoiseBelowTheAdaptiveThresholdProducesNoRegions() {
        // Amplitude well under absoluteFloor + margin (150 + 200), so it never crosses the gate
        // even before the noise floor has adapted to it.
        let regions = MeetingVAD.regions(for: Self.tone(seconds: 2, amplitude: 80))
        #expect(regions.isEmpty)
    }

    @Test func aSingleToneBurstProducesOnePaddedRegion() {
        let samples = Self.silence(seconds: 1) + Self.tone(seconds: 1) + Self.silence(seconds: 1)
        let regions = MeetingVAD.regions(for: samples)

        #expect(regions.count == 1)
        // Tone runs [16000, 32000). Padded 150 ms (2400 samples) each side.
        #expect(regions[0].start == 13600)
        #expect(regions[0].end == 34400)
    }

    @Test func twoToneBurstsSeparatedByEnoughSilenceProduceTwoRegions() {
        let samples =
            Self.silence(seconds: 0.5) + Self.tone(seconds: 0.4) + Self.silence(seconds: 1.0) + Self.tone(seconds: 0.4) + Self.silence(seconds: 0.5)
        let regions = MeetingVAD.regions(for: samples)

        #expect(regions.count == 2)
        // Tone 1: [8000, 14400) padded -> [5600, 16800).
        #expect(regions[0].start == 5600)
        #expect(regions[0].end == 16800)
        // Tone 2: [30400, 36800) padded -> [28000, 39200).
        #expect(regions[1].start == 28000)
        #expect(regions[1].end == 39200)
    }

    @Test func aGapShorterThanTheHangoverDoesNotSplitOneUtteranceIntoTwoRegions() {
        // 300 ms gap: well under the 500 ms hangover, so this should read as one continuous
        // utterance, not two regions.
        let samples = Self.silence(seconds: 0.5) + Self.tone(seconds: 0.4) + Self.silence(seconds: 0.3) + Self.tone(seconds: 0.4) + Self.silence(seconds: 1)
        let regions = MeetingVAD.regions(for: samples)
        #expect(regions.count == 1)
    }

    @Test func aBlipShorterThanTheMinimumUtteranceIsDropped() {
        // 100 ms of tone: below the 300 ms minimum, so it must not appear as a region even though
        // padding alone would otherwise stretch it past the minimum if the filter ran after padding.
        let samples = Self.silence(seconds: 1) + Self.tone(seconds: 0.1) + Self.silence(seconds: 1)
        let regions = MeetingVAD.regions(for: samples)
        #expect(regions.isEmpty)
    }

    @Test func regionsNeverExtendBeforeTheStartOfTheBuffer() {
        // Tone starts almost immediately, so the 150 ms of leading padding would go negative if
        // it weren't clamped.
        let samples = Self.silence(seconds: 0.05) + Self.tone(seconds: 0.5) + Self.silence(seconds: 1)
        let regions = MeetingVAD.regions(for: samples)
        #expect(regions.count == 1)
        #expect(regions[0].start == 0)
    }

    @Test func regionsNeverExtendPastTheEndOfTheBuffer() {
        // Tone ends right at the end of the buffer, so the 150 ms of trailing padding would run
        // past it if it weren't clamped.
        let samples = Self.silence(seconds: 1) + Self.tone(seconds: 0.5)
        let regions = MeetingVAD.regions(for: samples)
        #expect(regions.count == 1)
        #expect(regions[0].end == samples.count)
    }

    @Test func processingInSmallerBlocksProducesTheSameRegionsAsOneWholeBufferCall() {
        // A region that spans a block boundary must still close at the right point - state
        // carried through `process()` must behave identically to a single-call `regions(for:)`.
        let samples =
            Self.silence(seconds: 0.5) + Self.tone(seconds: 0.4) + Self.silence(seconds: 1.0) + Self.tone(seconds: 0.4) + Self.silence(seconds: 0.5)
        let wholeBufferRegions = MeetingVAD.regions(for: samples)

        var state = MeetingVAD.State.initial
        var blockedRegions: [MeetingVAD.Region] = []
        let blockSize = 777  // deliberately not frame-aligned
        var offset = 0
        while offset < samples.count {
            let end = min(offset + blockSize, samples.count)
            let (regions, _, newState) = MeetingVAD.process(Array(samples[offset..<end]), state: state)
            blockedRegions.append(contentsOf: regions)
            state = newState
            offset = end
        }
        blockedRegions.append(contentsOf: MeetingVAD.finish(state: state))

        #expect(blockedRegions == wholeBufferRegions)
    }

    @Test func steadyNoiseAboveTheInitialThresholdStillAdaptsTheFloorInsteadOfStayingStuckInSpeechForever() {
        // Amplitude 300 -> RMS ~= 212: above absoluteFloor (150) and above the very first
        // threshold (max(150, 0 + margin) = 200), before the noise floor has ever had a chance to
        // adapt. Reproduces a channel whose ambient level (steady mic noise/room hum) starts out
        // loud enough to read as speech from frame 1 - the bounded `stuckSpeechNoiseFloorAdaptRate`
        // nudge lets the floor catch up to this steady level within well under a second instead of
        // staying pinned at 0 (which would read this tone as one never-ending utterance forever).
        let samples = Self.tone(seconds: 6, amplitude: 300)
        let (regions, _, state) = MeetingVAD.process(samples, state: .initial)

        // The floor takes a brief moment to catch up, so the very start of the tone is read as one
        // short (padded) region - but it must not stay open for the rest of the 6s buffer.
        #expect(regions.count == 1, "only the brief startup misread should close, not the whole buffer")
        #expect(state.noiseFloor > 100, "the floor must climb toward the tone's own level, not stay pinned at 0")
        #expect(!state.inSpeech, "a merely-stationary signal must eventually reclassify as silence")
    }

    @Test func aRealSustainedLoudUtteranceIsNeverMisreadAsSilenceNoMatterHowLongItRuns() {
        // The fix must not let a channel's own long, genuinely loud speech catch its noise floor up
        // to itself: the slow "unstick" adaptation targets at most `absoluteFloor`, never the
        // frame's actual (possibly very loud) energy, so this never happens no matter how long the
        // utterance runs - and the confirmed-silence-gated adaptation never touches the floor at all
        // while `inSpeech`, so no combination of quiet dips inside it can either. Zero lead-in
        // silence at all (speech starting on the very first sample of the whole stream) is
        // deliberate: this must hold even for a chunk that opens fresh mid-utterance, not just for
        // a session with room to "warm up" first.
        let samples = Self.tone(seconds: 90, amplitude: 6000)
        let (regions, _, state) = MeetingVAD.process(samples, state: .initial)

        #expect(regions.isEmpty, "a 90s uninterrupted utterance must never close on its own")
        #expect(state.inSpeech, "genuinely loud, sustained speech must still read as speech at the end")
    }

    @Test func finishClosesAnUtteranceStillOpenAtEndOfStreamWithNoTrailingSilence() {
        // The buffer ends mid-utterance (no trailing silence to trigger hangover), so only
        // `finish()` can close it.
        let samples = Self.silence(seconds: 1) + Self.tone(seconds: 0.5)
        let (regions, _, state) = MeetingVAD.process(samples, state: .initial)
        #expect(regions.isEmpty)

        let finished = MeetingVAD.finish(state: state)
        #expect(finished.count == 1)
        #expect(finished[0].start == 13600)
    }

    // MARK: - Bug: noise floor drifting up during real speech drops the rest of the utterance

    @Test func realisticEnergyDipsWithinOneUtteranceNeverFragmentOrTruncateIt() {
        // Reproduces the reported bug directly: a continuous utterance with natural loud/quiet
        // variation (louder syllables, quieter ones in between - never actual silence) used to have
        // its noise floor dragged up by every quiet dip, within about a second reading the rest of
        // the utterance as silence and truncating or fragmenting it. A floor that only adapts during
        // confirmed (~1 s) non-speech silence - never while `inSpeech` - must read this as one
        // continuous region covering the whole utterance instead.
        let roomHum = Self.tone(seconds: 1.0, amplitude: 60, frequency: 50)
        let utterance = Self.alternatingUtterance(
            totalSeconds: 3.0, loudMs: 120, quietMs: 80, amplitude: 400, quietFraction: 0.35)
        let samples = roomHum + utterance + Self.silence(seconds: 1.5)

        let regions = MeetingVAD.regions(for: samples)

        #expect(regions.count == 1, "the whole utterance must read as one continuous region, not fragments")
        guard let region = regions.first else { return }
        #expect(region.start <= roomHum.count, "must not truncate the start of the utterance")
        #expect(
            region.end >= roomHum.count + utterance.count - MeetingVAD.frameSamples,
            "must not truncate the end of the utterance")
    }

    @Test func speechStartingWithinTheFirstSecondStillReadsAsOneContinuousUtterance() {
        // Only 1 s of room hum precedes the speech - well under the ~1s it can take the bounded
        // "unstick" nudge (see `MeetingVAD.stuckSpeechNoiseFloorAdaptRate`) to fully converge on a
        // steady ambient level - so this also exercises speech starting before the floor has fully
        // settled, not just after.
        let roomHum = Self.tone(seconds: 1.0, amplitude: 60, frequency: 50)
        let speech = Self.tone(seconds: 3.0, amplitude: 4000)
        let samples = roomHum + speech + Self.silence(seconds: 1)

        let regions = MeetingVAD.regions(for: samples)

        #expect(regions.count == 1)
        guard let region = regions.first else { return }
        #expect(region.start <= roomHum.count)
        #expect(region.end >= roomHum.count + speech.count - MeetingVAD.frameSamples)
    }

    @Test func autoSendEvaluatorSeesNoPauseInsideARealisticEnergyDipUtterance() {
        // The same alternating utterance as above, driven through `MeetingAutoSendEvaluator.step`
        // in 0.5 s ticks (as the real drain timer does) - `currentSilenceDuration` must stay near
        // zero throughout, never long enough to look like a genuine pause mid-utterance.
        let roomHum = Self.tone(seconds: 1.0, amplitude: 60, frequency: 50)
        let utterance = Self.alternatingUtterance(
            totalSeconds: 3.0, loudMs: 120, quietMs: 80, amplitude: 400, quietFraction: 0.35)
        let mic = roomHum + utterance
        let system = [Int16](repeating: 0, count: mic.count)

        var micState = MeetingVAD.State.initial
        var systemState = MeetingVAD.State.initial
        var tracker = MeetingAutoSendTracker()
        var maxSilenceDuringUtterance: TimeInterval = 0
        let tickSamples = Int(0.5 * Self.sampleRate)
        // Feeds the room hum through too, so the evaluator's VAD calibrates against genuine
        // ambience exactly as it would in a real session - only the silence duration seen once the
        // utterance itself has started is what this test cares about.
        var i = 0
        while i < mic.count {
            let end = min(i + tickSamples, mic.count)
            let result = MeetingAutoSendEvaluator.step(
                mic: Array(mic[i..<end]), system: Array(system[i..<end]), sampleRate: Self.sampleRate,
                autoSendEnabled: true, micVADState: micState, systemVADState: systemState, tracker: tracker)
            micState = result.micVADState
            systemState = result.systemVADState
            tracker = result.tracker
            if i >= roomHum.count {
                maxSilenceDuringUtterance = max(maxSilenceDuringUtterance, tracker.currentSilenceDuration)
            }
            i = end
        }

        #expect(
            maxSilenceDuringUtterance < MeetingAutoSendPolicy.requiredTrailingSilenceSeconds,
            "no dip inside the utterance must look like a genuine trailing pause")
    }

    // MARK: - Bug: loud steady ambient (headset mic in a train) never reads as silence

    @Test func aCalibratedFloorStillClassifiesPausesAsSilenceAfterLongLoudSpeech() {
        // The stuck-speech nudge decays `noiseFloor` back toward `absoluteFloor` during long
        // misread "speech"; the calibration pin must keep the *classified* floor up, so
        // pause-level ambience (RMS ~700, louder than absoluteFloor + margin) still reads as
        // silence after 20 s of loud speech.
        var state = MeetingVAD.State(noiseFloor: 900)
        state.pinnedNoiseFloor = 900
        (_, _, state) = MeetingVAD.process(Self.tone(seconds: 20, amplitude: 6000), state: state)
        #expect(state.noiseFloor < 400, "the adaptive floor does decay during speech - that's what the pin is for")

        (_, _, state) = MeetingVAD.process(Self.tone(seconds: 3, amplitude: 990), state: state)  // RMS ~= 700
        #expect(!state.inSpeech, "pause-level ambience must not reopen speech")
        #expect(state.confirmedSilenceRunFrames >= MeetingVAD.confirmedSilenceFrames, "the pause must confirm as silence")
    }

    @Test func withoutThePinADecayedFloorLetsTheAmbienceBackInAsSpeech() {
        // Same scenario, no pin: the decayed floor drops the threshold below the ambient level
        // and the pause reads as speech again - the failure the pin exists to prevent.
        var state = MeetingVAD.State(noiseFloor: 900)
        (_, _, state) = MeetingVAD.process(Self.tone(seconds: 20, amplitude: 6000), state: state)
        #expect(state.noiseFloor < 400)

        (_, _, state) = MeetingVAD.process(Self.tone(seconds: 3, amplitude: 990), state: state)
        #expect(state.inSpeech, "documents why calibration pins the floor instead of only seeding it")
    }

    @Test func calibrationLevelIsTheQuietLevelEvenWhenTheWindowContainsABlip() {
        // 2 s of quiet ambience (RMS ~= 354) with a 150 ms loud blip inside: the 90th-percentile
        // frame energy must land on the ambience, not the blip (RMS ~= 5657).
        let quiet = Self.tone(seconds: 2.0, amplitude: 500)
        let blipStart = Int(1.0 * Self.sampleRate)
        var window = quiet
        window.replaceSubrange(blipStart..<blipStart + Int(0.15 * Self.sampleRate), with: Self.tone(seconds: 0.15, amplitude: 8000))

        let level = MeetingVAD.calibrationLevel(window)
        #expect(level > 250, "must measure the ambience itself, not silence")
        #expect(level < 1000, "a short blip must not drag the calibrated floor up")
    }
}
