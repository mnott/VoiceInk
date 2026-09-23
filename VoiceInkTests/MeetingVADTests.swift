import Testing
import Foundation
@testable import VoiceInk

struct MeetingVADTests {
    private static let sampleRate = MeetingVAD.sampleRate

    private static func silence(seconds: Double) -> [Int16] {
        [Int16](repeating: 0, count: Int(seconds * sampleRate))
    }

    private static func tone(seconds: Double, amplitude: Int16 = 6000, frequency: Double = 400) -> [Int16] {
        let count = Int(seconds * sampleRate)
        return (0..<count).map { i in
            let t = Double(i) / sampleRate
            return Int16(clamping: Int((Double(amplitude) * sin(2 * Double.pi * frequency * t)).rounded()))
        }
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
        // loud enough to read as speech from frame 1 - previously the noise floor only moved on
        // frames already classified silent, so it stayed pinned at 0 and this tone read as one
        // never-ending utterance for the rest of the session.
        let samples = Self.tone(seconds: 6, amplitude: 300)
        let (regions, _, state) = MeetingVAD.process(samples, state: .initial)

        // The floor takes a brief moment to catch up, so the very start of the tone is read as one
        // short (padded) region - but it must not stay open for the rest of the 6s buffer.
        #expect(regions.count == 1, "only the brief startup misread should close, not the whole buffer")
        #expect(state.noiseFloor > 100, "the floor must climb toward absoluteFloor, not stay pinned at its initial value")
        // Once the floor has caught up, the same steady level must stop reading as speech -
        // otherwise `currentSilenceDuration`/`openRegionStart` would stay stuck on this channel
        // for the rest of the session even though nothing new is actually being said.
        #expect(!state.inSpeech, "a merely-stationary signal must eventually reclassify as silence")
    }

    @Test func aRealSustainedLoudUtteranceIsNeverMisreadAsSilenceNoMatterHowLongItRuns() {
        // The fix above must not let a channel's own long, genuinely loud speech catch its noise
        // floor up to itself: the slow "unstick" adaptation targets at most `absoluteFloor`, never
        // the frame's actual (possibly very loud) energy, so this never happens no matter how long
        // the utterance runs.
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
}
