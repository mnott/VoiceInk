import Foundation

/// Splits one channel of 16 kHz mono Int16 audio into speech regions using frame energy against
/// an adaptive noise floor - service-agnostic (unlike fixed-window transcription, this needs no
/// timestamps back from `TranscriptionService`, which none of the seven providers behind it give).
/// `process(_:state:)` threads its state across calls so a long recording can be analyzed in
/// bounded-memory blocks instead of loading the whole file at once; `finish(state:)` closes out
/// any speech run still open at the end of the stream.
///
/// The noise floor never adapts while someone is speaking: a quiet syllable or a short gap between
/// words used to pull the floor toward its own (low) energy on every single frame, which raised
/// the threshold, which made the next quiet moment - or eventually a whole word - read as silence
/// too, snowballing within about a second into losing the rest of the utterance. It now only moves
/// during a confirmed (~1 s), already-non-speech silence run (see `confirmedSilenceFrames`) - never
/// while `inSpeech`, and never during the 500 ms hangover or a short gap between words. Separately,
/// a much slower, bounded nudge (see `stuckSpeechNoiseFloorAdaptRate`) lets a channel whose ambient
/// level itself starts out above the not-yet-adapted threshold (steady mic noise/room hum, or a
/// chunk that opens mid-utterance with nothing quieter in it at all) still converge, without ever
/// pulling the floor up anywhere near genuine, sustained speech loudness.
enum MeetingVAD {
    struct Region: Equatable {
        let start: Int
        let end: Int
    }

    struct State: Equatable {
        var noiseFloor: Double
        /// Session minimum for the classified floor, pinned by a "This Is Silence" calibration
        /// (see `MeetingAudioCapture.calibrateSilence`): the adaptive `noiseFloor` may sit above
        /// or decay below it, but classification always uses the larger of the two, until a fresh
        /// session starts back at 0.
        var pinnedNoiseFloor: Double = 0
        var inSpeech = false
        var speechStart = 0
        /// Sample index right after the last frame that was voiced - carried across block
        /// boundaries so a region that spans two `process()` calls still closes at the right
        /// point, not at whatever frame happened to end the block it was detected in.
        var lastVoicedEnd = 0
        var framesSinceLastVoiced = 0
        /// Consecutive non-speech, below-threshold frames seen since the last voiced frame or
        /// hangover close - `noiseFloor` only adapts here once this reaches `confirmedSilenceFrames`.
        var confirmedSilenceRunFrames = 0
        var globalSampleOffset = 0
        var leftoverSamples: [Int16] = []

        static let initial = State(noiseFloor: 0)
    }

    static let sampleRate: Double = 16000
    static let frameSamples = Int(0.02 * sampleRate)  // 20 ms
    static let hangoverFrames = Int(0.5 / 0.02)  // 500 ms of trailing silence closes a region
    static let minUtteranceSamples = Int(0.3 * sampleRate)  // 300 ms
    static let paddingSamples = Int(0.15 * sampleRate)  // 150 ms of real audio kept each side
    // ~-46 dBFS at 16-bit: below this a frame is silence regardless of how low the adaptive
    // noise floor has drifted, so true silence never gets misread as speech.
    static let absoluteFloor: Double = 150
    static let marginAboveNoiseFloor: Double = 200
    // A flat additive margin is only ~+2 dB on a loud-floor mic (an AirPods Max headset on a
    // train sits at ~650-1000 RMS in *pauses*), so pause frames kept clearing the threshold and
    // every pause read as speech. The margin therefore also scales with the floor (+4.9 dB at
    // 0.75), keeping pauses below threshold on loud floors; below ~267 RMS the additive term
    // still dominates and quiet-mic behaviour is unchanged. Calibration (see
    // `MeetingAudioCapture.calibrateSilence`) is what feeds the floor the ambient level in the
    // first place when the channel never sees real silence - no automatic adaptation can tell a
    // loud steady room from loud steady speech (see the stuck-speech nudge's doc comment).
    static let relativeMarginAboveNoiseFloor: Double = 0.75
    static let noiseFloorAdaptRate: Double = 0.05
    // How long a non-speech, below-threshold run must last before it counts as confirmed silence
    // the floor is allowed to adapt to - shorter than this and it's just a gap between words or
    // the 500 ms hangover after a region closes, not real silence.
    static let confirmedSilenceFrames = Int(1.0 / 0.02)
    // The floor above only moves on frames already classified silent - if a channel's ambient
    // level starts out above the not-yet-adapted threshold (e.g. steady mic noise/room hum, before
    // any real silence has been seen), every frame keeps reading as speech and the floor is stuck
    // at its initial value forever: the channel never closes its "utterance", pinning
    // currentSilenceDuration at 0 and openRegionStart at the very start of the session, so neither
    // the natural silence trigger nor cutBoundary can ever release anything. A much slower nudge
    // toward the observed energy even while classified as speech lets a merely-stationary signal
    // catch up to its own threshold and reclassify as silence within a few seconds, while a normal
    // (tens-of-seconds) speech utterance barely moves the floor in that time.
    static let stuckSpeechNoiseFloorAdaptRate: Double = 0.005

    /// Frame energy for one frame; also used by `MeetingTurnBuilder` to find internal pauses
    /// inside an already-detected speech region.
    static func rms(_ samples: ArraySlice<Int16>) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sumSquares = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        return (sumSquares / Double(samples.count)).squareRoot()
    }

    /// The noise level of a calibration window (the "This Is Silence" action): the 90th
    /// percentile of its 20 ms frame energies, so a short blip (a cough, a door) inside the
    /// otherwise-quiet window can't drag the calibrated floor up with it.
    static func calibrationLevel(_ samples: [Int16]) -> Double {
        var energies: [Double] = []
        var i = 0
        while i + frameSamples <= samples.count {
            energies.append(rms(samples[i..<i + frameSamples]))
            i += frameSamples
        }
        guard !energies.isEmpty else { return 0 }
        energies.sort()
        return energies[Int(0.9 * Double(energies.count - 1))]
    }

    /// Processes one block of samples. Returns regions that closed (500 ms of trailing silence
    /// seen) within this block, in sample coordinates spanning the whole stream, how many samples
    /// the currently-open (or just-extended) utterance span grew by in this block - from region
    /// start to last voiced frame, so it includes the short gaps between words the hangover
    /// bridges, not just voiced frames themselves (for `MeetingAutoSendEvaluator`'s speech-seconds
    /// accounting) - plus the state to pass into the next call.
    static func process(_ samples: [Int16], state: State) -> (regions: [Region], utteranceGrowthSamples: Int, state: State) {
        var state = state
        let combined = state.leftoverSamples + samples
        let frameCount = combined.count / frameSamples
        let consumed = frameCount * frameSamples
        state.leftoverSamples = Array(combined[consumed...])
        let processedEnd = state.globalSampleOffset + consumed

        var regions: [Region] = []
        var utteranceGrowthSamples = 0
        for i in 0..<frameCount {
            let frameStart = i * frameSamples
            let frame = combined[frameStart..<frameStart + frameSamples]
            let energy = rms(frame)
            classify(
                &state, energy: energy, absoluteStart: state.globalSampleOffset + frameStart,
                processedEnd: processedEnd, regions: &regions, utteranceGrowthSamples: &utteranceGrowthSamples)
        }
        state.globalSampleOffset += consumed
        return (regions, utteranceGrowthSamples, state)
    }

    /// Closes any speech run still open at end of stream (no trailing silence long enough to have
    /// closed it already), so the last utterance of a recording is never dropped.
    static func finish(state: State) -> [Region] {
        guard state.inSpeech else { return [] }
        return [closedRegion(state: state, processedEnd: state.globalSampleOffset)].compactMap { $0 }
    }

    /// Convenience for a whole buffer already in memory (chunk delivery, or one silence-bounded
    /// super-block of a longer recording) - `process` then `finish` in one call.
    /// - Parameter startingNoiseFloor: Seeds the adaptive noise floor instead of starting from 0 -
    ///   used when `samples` is the continuation of a chunk-hotkey cut (see
    ///   `MeetingAudioCapture.MeetingCut`) or a later super-block of a longer recording (see
    ///   `MeetingRecordingTranscriber`), so a chunk/super-block that opens mid-utterance (no leading
    ///   silence of its own to (re-)adapt against) classifies its first frames against the same
    ///   threshold the session/file had already converged on rather than a fresh one.
    static func regions(for samples: [Int16], startingNoiseFloor: Double = 0) -> [Region] {
        regionsAndEndingNoiseFloor(for: samples, startingNoiseFloor: startingNoiseFloor).regions
    }

    /// Same as `regions(for:startingNoiseFloor:)` but also returns the noise floor the channel
    /// ended on, so a caller transcribing a long recording in several super-blocks
    /// (`MeetingRecordingTranscriber`) can seed the next one with it instead of starting over at 0.
    static func regionsAndEndingNoiseFloor(
        for samples: [Int16], startingNoiseFloor: Double = 0
    ) -> (regions: [Region], noiseFloor: Double) {
        let (closed, _, state) = process(samples, state: State(noiseFloor: startingNoiseFloor))
        return (closed + finish(state: state), state.noiseFloor)
    }

    /// Classifies one frame against the current threshold, updating `state`, appending a closed
    /// region to `regions` if this frame's hangover just closed one, and adding to
    /// `utteranceGrowthSamples` how far the open utterance's span (region start to last voiced
    /// frame) advanced because of this frame - the jump from the previous last-voiced frame to
    /// this one if the utterance was already open (bridging any gap between them), or just this
    /// frame's own length if it is the first voiced frame of a new region.
    private static func classify(
        _ state: inout State, energy: Double, absoluteStart: Int, processedEnd: Int,
        regions: inout [Region], utteranceGrowthSamples: inout Int
    ) {
        let floor = max(state.noiseFloor, state.pinnedNoiseFloor)
        let threshold = max(absoluteFloor, floor + max(marginAboveNoiseFloor, floor * relativeMarginAboveNoiseFloor))

        if energy >= threshold {
            let newLastVoicedEnd = absoluteStart + frameSamples
            if !state.inSpeech {
                state.inSpeech = true
                state.speechStart = absoluteStart
                utteranceGrowthSamples += frameSamples
            } else {
                utteranceGrowthSamples += newLastVoicedEnd - state.lastVoicedEnd
            }
            state.lastVoicedEnd = newLastVoicedEnd
            state.framesSinceLastVoiced = 0
            state.confirmedSilenceRunFrames = 0
            // Nudged toward `absoluteFloor`, not the frame's own (possibly very loud) energy: this
            // only needs to climb enough to unstick a channel whose ambient level sits just above
            // the not-yet-adapted threshold, not all the way up to genuine speech loudness -
            // otherwise a long, real, uninterrupted monologue would eventually catch its own noise
            // floor up to itself and get spuriously reclassified as silence too.
            let stuckAdaptTarget = min(energy, absoluteFloor)
            state.noiseFloor = state.noiseFloor * (1 - stuckSpeechNoiseFloorAdaptRate) + stuckAdaptTarget * stuckSpeechNoiseFloorAdaptRate
        } else if state.inSpeech {
            state.framesSinceLastVoiced += 1
            if state.framesSinceLastVoiced >= hangoverFrames {
                if let region = closedRegion(state: state, processedEnd: processedEnd) {
                    regions.append(region)
                }
                state.inSpeech = false
                state.framesSinceLastVoiced = 0
                state.confirmedSilenceRunFrames = 0
            }
        } else {
            state.confirmedSilenceRunFrames += 1
            if state.confirmedSilenceRunFrames >= confirmedSilenceFrames {
                state.noiseFloor = state.noiseFloor * (1 - noiseFloorAdaptRate) + energy * noiseFloorAdaptRate
            }
        }
    }

    private static func closedRegion(state: State, processedEnd: Int) -> Region? {
        // Filtered on the raw voiced span, before padding is added - otherwise a couple of
        // frames of spurious noise would clear the 300 ms bar on padding alone.
        guard state.lastVoicedEnd - state.speechStart >= minUtteranceSamples else { return nil }
        let start = max(0, state.speechStart - paddingSamples)
        let end = min(state.lastVoicedEnd + paddingSamples, processedEnd)
        return Region(start: start, end: end)
    }

    /// Runs of frames below `threshold` for at least `minRunSamples` within `range` of `samples` -
    /// used by `MeetingTurnBuilder` to find a natural place to split a region an interjection
    /// lands inside, or to split a region that has grown past the turn length cap.
    static func silenceRuns(
        in samples: [Int16], range: Range<Int>, minRunSamples: Int, threshold: Double = absoluteFloor
    ) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        var runStart: Int?
        var i = range.lowerBound
        while i + frameSamples <= range.upperBound {
            let energy = rms(samples[i..<i + frameSamples])
            if energy < threshold {
                if runStart == nil { runStart = i }
            } else if let start = runStart {
                if i - start >= minRunSamples { runs.append(start..<i) }
                runStart = nil
            }
            i += frameSamples
        }
        if let start = runStart, range.upperBound - start >= minRunSamples {
            runs.append(start..<range.upperBound)
        }
        return runs
    }
}
