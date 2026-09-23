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
        let (micRegions, micVoicedSamples, newMicVADState) = MeetingVAD.process(mic, state: micVADState)
        let (systemRegions, systemVoicedSamples, newSystemVADState) = MeetingVAD.process(system, state: systemVADState)
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
        // silence regardless of how long it really was, so the 1.5 s trailing-silence policy could
        // only ever fire via the 60 s cap. `lastVoicedEnd` (the last frame whose energy actually
        // crossed the threshold) is unaffected by the hangover, so silence is the real time since
        // that frame ended. `max` over both channels: silence must have started on whichever
        // channel spoke most recently. Speech seconds likewise come from voiced-frame counts
        // rather than whole ticks; `max` (not sum) of the two channels' voiced-sample counts so
        // overlapping talk on both channels isn't double-counted.
        let speechSecondsThisTick = Double(max(micVoicedSamples, systemVoicedSamples)) / sampleRate
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

    /// Where `MeetingAudioCapture.cut()` should stop releasing pending audio, as a local index
    /// into the chunk-pending buffer (`chunkPendingBaseOffset` translates each channel's global
    /// `openRegionStart` into that buffer's coordinates). `.max` releases everything - either
    /// because the caller forced it (session stop, nothing left to defer to) or because neither
    /// channel has an utterance open right now. Otherwise the smaller of the two channels' open
    /// starts, so a whole in-progress utterance on either channel is held back rather than split.
    static func cutBoundary(
        micVADState: MeetingVAD.State, systemVADState: MeetingVAD.State,
        chunkPendingBaseOffset: Int, forceFullRelease: Bool
    ) -> Int {
        guard !forceFullRelease else { return .max }
        let micBoundary = openRegionStart(micVADState).map { max(0, $0 - chunkPendingBaseOffset) } ?? .max
        let systemBoundary = openRegionStart(systemVADState).map { max(0, $0 - chunkPendingBaseOffset) } ?? .max
        return min(micBoundary, systemBoundary)
    }
}
