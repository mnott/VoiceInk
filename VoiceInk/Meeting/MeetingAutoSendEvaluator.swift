import Foundation

/// One drain tick's worth of `MeetingVAD` + `MeetingAutoSendPolicy` bookkeeping, extracted out of
/// `MeetingAudioCapture` so it can be replayed offline against a recorded session (no Core Audio,
/// no running capture) to see exactly why a tick did or didn't trigger.
///
/// VAD state is always advanced, whether or not auto-send is enabled: `MeetingAudioCapture.cut()`
/// also needs it, unconditionally, to know whether a chunk boundary would land inside an open
/// utterance (see `openRegionStart`).
enum MeetingAutoSendEvaluator {
    struct StepResult {
        let isSpeech: Bool
        let micVADState: MeetingVAD.State
        let systemVADState: MeetingVAD.State
        let tracker: MeetingAutoSendTracker
        let shouldTrigger: Bool
    }

    static func step(
        mic: [Int16], system: [Int16], sampleRate: Double, autoSendEnabled: Bool,
        micVADState: MeetingVAD.State, systemVADState: MeetingVAD.State, tracker: MeetingAutoSendTracker
    ) -> StepResult {
        let (micRegions, micUtteranceGrowth, newMicVADState) = MeetingVAD.process(mic, state: micVADState)
        let (systemRegions, systemUtteranceGrowth, newSystemVADState) = MeetingVAD.process(system, state: systemVADState)
        let isSpeech = !micRegions.isEmpty || !systemRegions.isEmpty || newMicVADState.inSpeech || newSystemVADState.inSpeech

        let tickDuration = Double(mic.count) / sampleRate
        guard autoSendEnabled, tickDuration > 0 else {
            return StepResult(
                isSpeech: isSpeech, micVADState: newMicVADState, systemVADState: newSystemVADState,
                tracker: tracker, shouldTrigger: false)
        }

        // Frame resolution, not tick booleans: a tick counted as "speech" whenever any speech
        // occurred in it (and MeetingVAD's ~500 ms hangover keeps a channel "in speech" briefly
        // after it actually stops) used to make a pause between paragraphs read as at most ~1 s of
        // silence regardless of how long it really was, so the 1.0 s trailing-silence policy could
        // only ever fire via the 60 s cap. `lastVoicedEnd` (the last frame whose energy actually
        // crossed the threshold) is unaffected by the hangover, so silence is the real time since
        // that frame ended. `max` over both channels: silence must have started on whichever
        // channel spoke most recently. Speech seconds are utterance-span growth (region start to
        // last voiced frame), not a count of voiced frames: with some mics, most frames between
        // syllables fall below the energy threshold even mid-word, which used to make the 5 s
        // minimum practically unreachable - counting the whole span instead (including the short
        // gaps the hangover bridges) reflects how long someone was actually talking. `max` (not
        // sum) of the two channels' growth so overlapping talk on both channels isn't double-counted.
        let speechSecondsThisTick = Double(max(micUtteranceGrowth, systemUtteranceGrowth)) / sampleRate
        let lastVoicedEnd = max(newMicVADState.lastVoicedEnd, newSystemVADState.lastVoicedEnd)
        let currentSilenceDuration = Double(newMicVADState.globalSampleOffset - lastVoicedEnd) / sampleRate

        var newTracker = tracker
        newTracker.recordTick(duration: tickDuration, speechSeconds: speechSecondsThisTick, silenceDuration: currentSilenceDuration)

        let shouldTrigger =
            newTracker.speechSecondsSinceLastChunk > 0
            && MeetingAutoSendPolicy.shouldSend(
                speechSecondsSinceLastChunk: newTracker.speechSecondsSinceLastChunk,
                currentSilenceDuration: newTracker.currentSilenceDuration,
                secondsSinceLastChunk: newTracker.secondsSinceLastChunk)

        return StepResult(
            isSpeech: isSpeech, micVADState: newMicVADState, systemVADState: newSystemVADState,
            tracker: newTracker, shouldTrigger: shouldTrigger)
    }

    /// The global sample offset of the utterance currently open in `state`, or `nil` if the
    /// channel is silent right now - i.e. where a chunk cut would have to stop to avoid splitting
    /// it. See `MeetingAudioCapture.cut()`.
    static func openRegionStart(_ state: MeetingVAD.State) -> Int? {
        state.inSpeech ? state.speechStart : nil
    }

    /// Below this little pending audio ahead of an open region, an automatic cut's delivery is
    /// starvation rather than a chunk - see `cutBoundary`'s fallback.
    static let minAutomaticReleaseSamples = Int(1.0 * MeetingVAD.sampleRate)

    /// Where `MeetingAudioCapture.cut()` should stop releasing pending audio, as a local index
    /// into the chunk-pending buffer (`chunkPendingBaseOffset` translates each channel's global
    /// `openRegionStart` into that buffer's coordinates). `.max` releases everything - either
    /// because the caller forced it (session stop, nothing left to defer to) or because neither
    /// channel has an utterance open right now. Otherwise the smaller of the two channels' open
    /// starts, so a whole in-progress utterance on either channel is held back rather than split.
    ///
    /// Passing `pendingAudio` (what `cut()` has queued) adds a starvation fallback for that
    /// deferral: a length-cap trigger (`MeetingAutoSendPolicy.maximumSecondsSinceLastChunk`) can
    /// fire while the open utterance spans the whole pending buffer - continuous speech, or a
    /// steady noise floor holding the VAD open - and plain deferral would then deliver nothing
    /// at all, with the pending buffer growing without bound. In that case the cut lands at the
    /// longest pause both channels share inside the open region (nobody talking on either side;
    /// the same "split at the longest internal pause" idea as `MeetingTurnBuilder.cap`), or, if
    /// the speech genuinely never pauses, at the pending end - a length trigger must never
    /// release nothing. A normal deferral (a real chunk of closed speech ahead of the open tail,
    /// i.e. a boundary at or beyond `minAutomaticReleaseSamples`) is unaffected.
    static func cutBoundary(
        micVADState: MeetingVAD.State, systemVADState: MeetingVAD.State,
        chunkPendingBaseOffset: Int, forceFullRelease: Bool,
        pendingAudio: (mic: [Int16], system: [Int16]) = ([], [])
    ) -> Int {
        guard !forceFullRelease else { return .max }
        let micBoundary = openRegionStart(micVADState).map { max(0, $0 - chunkPendingBaseOffset) } ?? .max
        let systemBoundary = openRegionStart(systemVADState).map { max(0, $0 - chunkPendingBaseOffset) } ?? .max
        let boundary = min(micBoundary, systemBoundary)
        let pendingCount = min(pendingAudio.mic.count, pendingAudio.system.count)
        guard boundary < minAutomaticReleaseSamples, boundary < pendingCount else { return boundary }

        // ponytail: pauses are detected against MeetingVAD.absoluteFloor, not each channel's
        // adaptive floor - on a loud-floor mic (calibrated or not) no pause may qualify and the
        // fallback degrades to the hard cut; reuse MeetingVAD's own floor logic if that bites.
        let scanRange = boundary..<pendingCount
        let minPause = MeetingTurnBuilder.minInternalPauseSamples
        let micRuns = MeetingVAD.silenceRuns(in: pendingAudio.mic, range: scanRange, minRunSamples: minPause)
        let systemRuns = MeetingVAD.silenceRuns(in: pendingAudio.system, range: scanRange, minRunSamples: minPause)
        var sharedRuns: [Range<Int>] = []
        for micRun in micRuns {
            for systemRun in systemRuns {
                let start = max(micRun.lowerBound, systemRun.lowerBound)
                let end = min(micRun.upperBound, systemRun.upperBound)
                if end - start >= minPause { sharedRuns.append(start..<end) }
            }
        }
        if let longest = sharedRuns.max(by: { $0.count < $1.count }) {
            return (longest.lowerBound + longest.upperBound) / 2
        }
        return pendingCount
    }
}
