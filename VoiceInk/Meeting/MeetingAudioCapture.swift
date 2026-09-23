import AVFAudio
import AudioToolbox
import CoreAudio
import Foundation
import os

/// Captures microphone and system (output) audio in parallel, without pausing or muting
/// playback, so a call can keep running while VoiceInk records both sides of it. Call `cut()`
/// on a hotkey press to pull everything captured since the previous cut for transcription
/// (minus the tail of any utterance still open at that instant, held back for the next cut so
/// speech is never split across a chunk boundary); recording continues uninterrupted.
final class MeetingAudioCapture: @unchecked Sendable {
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MeetingAudioCapture")

    // MARK: - Microphone

    private let micRecorder = CoreAudioRecorder()
    private let micOutputURL: URL
    private let micSetupQueue = DispatchQueue(label: "com.prakashjoshipax.voiceink.meetingMicSetup", qos: .userInitiated)

    // MARK: - Drain / chunk-pending buffering

    // ponytail: chunkPending side grows unbounded between cut() calls - fine for meeting-length
    // gaps between hotkey presses, cap it if chunks are ever left uncut for very long stretches.
    private let drainBuffer = OSAllocatedUnfairLock<MeetingDrainBuffer>(initialState: MeetingDrainBuffer())
    // Set (from the main actor) whenever a normal dictation recording starts/stops, read on
    // `tapQueue` in `absorbAndWrite` - see `MeetingDictationGate`.
    private let dictationActiveLock = OSAllocatedUnfairLock<Bool>(initialState: false)
    var isDictationActive: Bool {
        get { dictationActiveLock.withLock { $0 } }
        set { dictationActiveLock.withLock { $0 = newValue } }
    }
    // All drain/cut work is serialized on this queue (the periodic timer already fires here) so
    // two drains can never interleave their echo cancellation or meeting-file writes. Frequent
    // enough (rather than, say, 30s) that the auto-send trigger (see `evaluateAutoSend`) can
    // resolve a ~1.0s silence pause with that same granularity - draining more often is otherwise
    // free, per the docs on `drainTick` below.
    private var drainTimer: DispatchSourceTimer?
    private static let drainIntervalSeconds: TimeInterval = 0.5

    // ~-50 dBFS at 16-bit: below this a track is silence. Used by the per-track silence skip in
    // `VoiceInkEngine+Meeting`'s Whisper delivery (a different job than auto-send's speech
    // classification below, which instead reuses `MeetingVAD`'s own threshold/state so "speech"
    // means the same thing there as it does in the turn-ordering VAD).
    static let silenceRMSThreshold: Double = 100

    // MARK: - Automatic chunk delivery (see `MeetingAutoSendPolicy`)

    private var autoSendTracker = MeetingAutoSendTracker()
    private var isAutoSendPending = false
    // Longer than MeetingVAD's 500 ms hangover: a manual cut (`cutForManualSend`) waits this long
    // first, so a word spoken right up to the hotkey press has time to actually arrive from the
    // tap and its VAD region to close, before `cut(forceFullRelease: true)` releases everything
    // regardless - see `cutForManualSend`.
    static let manualCutDelaySeconds: TimeInterval = 0.6
    // Carries `MeetingVAD`'s adaptive noise floor and in-speech/hangover state across drain
    // ticks per channel. Always kept current (whether or not auto-send is on) since `cut()` also
    // needs it to know whether a chunk boundary would land inside an open utterance.
    private var micVADState = MeetingVAD.State.initial
    private var systemVADState = MeetingVAD.State.initial
    // The global (VAD-coordinate) sample offset represented by index 0 of `drainBuffer`'s
    // chunk-pending buffers - lets `cut()` translate an open region's `speechStart` (a
    // session-global offset) into a local index to cut at. Advances by however much of the
    // pending buffer `cut()` actually released, which is less than its full length whenever a
    // still-open utterance's tail was held back.
    private var chunkPendingBaseOffset = 0
    // The noise floor each channel's persistent `MeetingVAD.State` had adapted to as of the
    // previous cut - i.e. right when the audio that will start the *next* chunk began
    // accumulating. Handed back on that chunk's `MeetingCut` so `MeetingTurnTranscriber` can seed
    // its own (otherwise fresh, per-chunk) VAD with it instead of 0: a chunk that opens
    // mid-utterance (see `openRegionStart`/`cutBoundary`) has no leading silence of its own to
    // adapt against, so without this its first frames would be classified against an
    // unrepresentative threshold.
    private var chunkStartMicNoiseFloor = 0.0
    private var chunkStartSystemNoiseFloor = 0.0
    /// Fired (on `tapQueue`) when the auto-send trigger fires; the caller is responsible for
    /// hopping to the actor it needs and delivering the chunk exactly like a manual one.
    var onAutoSendTrigger: (() -> Void)?

    // MARK: - Continuous meeting recording

    /// Stereo 16 kHz WAV for the whole session (left = mic, right = system), written from `start()`
    /// to `stop()` so it can be (re-)transcribed as a full, speaker-labelled meeting later.
    let recordingURL: URL
    private var recordingWriter: MeetingRecordingWriter?

    // MARK: - System audio (Core Audio process tap)

    private let tapQueue = DispatchQueue(label: "com.prakashjoshipax.voiceink.meetingSystemTap", qos: .userInitiated)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var tapUUID: UUID?
    private var tapFormat: AVAudioFormat?
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var converter: AVAudioConverter?
    private let mixdownFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!

    private(set) var isCapturingSystemAudio = false

    // MARK: - Echo cancellation

    // One canceller per capture session: its adaptive filter must converge across `cut()`
    // calls, so it is created alongside the system tap in `start()` and torn down in `stop()`
    // rather than being recreated per cut. `nil` when there is no system audio to cancel against.
    private var echoCanceller: EchoCanceller?

    // MARK: - Speaker identification (Nemotron 3 diarization)

    // One continuous session for the whole capture (see `MeetingDiarizer`'s doc comment) - `nil`
    // until (if) the async load in `start()` completes, and forever if the model isn't downloaded,
    // the setting is off, or loading/streaming fails. Only ever touched on `tapQueue`.
    private var systemDiarizer: MeetingDiarizer?

    /// Diarized "Others" turns for one `cut()`, chunk-local sample coordinates - see
    /// `MeetingDiarizationAttributor`. `nil` when diarization isn't running this session.
    typealias SystemDiarization = MeetingDiarizationAttributor.Attribution

    init(recordingURL: URL) {
        micOutputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceink-meeting-mic-\(UUID().uuidString).wav")
        self.recordingURL = recordingURL
    }

    // MARK: - Public interface

    /// The two (echo-cancelled, end-aligned) tracks from a `cut()`, plus their mix for playback.
    struct MeetingCut {
        let mic: [Int16]
        let system: [Int16]
        let mix: [Int16]
        /// The noise floor each channel's session-long VAD had adapted to when this chunk's audio
        /// started - see `chunkStartMicNoiseFloor`/`chunkStartSystemNoiseFloor`.
        let micNoiseFloor: Double
        let systemNoiseFloor: Double
        /// How many samples were held back (an utterance still open at cut time - see
        /// `cutBoundary`) instead of being released into this chunk. Diagnostic only.
        let deferredSampleCount: Int
        /// This cut's diarized "Others" turns, if speaker identification is running - see
        /// `SystemDiarization`.
        let systemDiarization: SystemDiarization?
    }

    func start() {
        startMic()
        startSystemTap()
        echoCanceller = isCapturingSystemAudio ? EchoCanceller() : nil
        do {
            recordingWriter = try MeetingRecordingWriter(url: recordingURL)
        } catch {
            logger.error("Meeting capture: could not create the continuous recording file: \(error, privacy: .public)")
            recordingWriter = nil
        }
        startDrainTimer()
        startSystemDiarizerIfEnabled()
    }

    func stop() {
        drainTimer?.cancel()
        drainTimer = nil
        // Both teardowns deliver whatever they were still holding onto the drain buffer
        // (`stopMic` synchronously, `stopSystemTap` inline) before returning, so the drain below
        // picks up everything captured right up to the moment recording actually stopped instead
        // of whatever happened to be queued when the last `cut()` or periodic drain ran.
        stopMic()
        stopSystemTap()
        tapQueue.sync {
            self.finalDrainTick()
            self.systemDiarizer?.finish()
        }
        do {
            try recordingWriter?.finish()
        } catch {
            logger.error("Meeting capture: failed to finish the continuous recording file: \(error, privacy: .public)")
        }
        recordingWriter = nil
        echoCanceller = nil
    }

    /// Kicks off the (async) model load for live speaker identification, if system audio is being
    /// captured and the user hasn't turned the setting off - never triggers a download itself (see
    /// `MeetingDiarizer.makeIfAvailable`), so this is a no-op whenever the model isn't already
    /// downloaded from the AI Models page. `systemDiarizer` stays `nil` (silent fallback to the
    /// single "Others" label) until this completes, or forever if it fails.
    private func startSystemDiarizerIfEnabled() {
        guard isCapturingSystemAudio,
            UserDefaults.standard.bool(forKey: PinnedDestinationSettingsKeys.identifyRemoteSpeakers)
        else { return }
        Task { [weak self] in
            guard let diarizer = await MeetingDiarizer.makeIfAvailable(config: MeetingDiarizationModels.streamingConfig)
            else { return }
            self?.tapQueue.async { self?.systemDiarizer = diarizer }
        }
    }

    /// Atomically pulls everything captured since the previous chunk-hotkey cut (or session
    /// start). Recording keeps running. The mic and system tracks are returned separately (each
    /// track transcribed on its own preserves overlapping speakers that a single mixed-down
    /// transcription would drop); `mix` is still provided for playback. Draining happens in
    /// small increments (see `drainTick`/`startDrainTimer`) so this is normally just picking up
    /// whatever those increments have already queued, not a large amount of new work.
    /// - Parameter forceFullRelease: Skips the open-utterance safe-boundary check below and
    ///   releases everything pending regardless. Used when capture is about to stop (see
    ///   `VoiceInkEngine+Meeting.toggleMeetingCapture()`) and by `cutForManualSend()` - neither
    ///   has a guaranteed-soon "next chunk" to hand a held-back tail to.
    func cut(forceFullRelease: Bool = false) -> MeetingCut {
        let (mic, system, micNoiseFloor, systemNoiseFloor, deferredCount, systemDiarization) = tapQueue.sync {
            () -> ([Int16], [Int16], Double, Double, Int, SystemDiarization?) in
            self.drainTick()

            // Don't split an utterance that's still open (no closing silence yet) across this
            // cut and the next one - hold its tail back so it lands whole in the next chunk
            // instead.
            let boundary = MeetingAutoSendEvaluator.cutBoundary(
                micVADState: self.micVADState, systemVADState: self.systemVADState,
                chunkPendingBaseOffset: self.chunkPendingBaseOffset, forceFullRelease: forceFullRelease)

            let chunkStartGlobal = self.chunkPendingBaseOffset
            let released = self.drainBuffer.withLock { $0.releasePrefix(sampleCount: boundary) }
            self.chunkPendingBaseOffset += released.mic.count

            let systemDiarization = self.systemDiarizer?.attribute(
                chunkStartGlobal: chunkStartGlobal, chunkEndGlobal: chunkStartGlobal + released.system.count)

            let noiseFloors = (self.chunkStartMicNoiseFloor, self.chunkStartSystemNoiseFloor)
            self.chunkStartMicNoiseFloor = self.micVADState.noiseFloor
            self.chunkStartSystemNoiseFloor = self.systemVADState.noiseFloor

            // A chunk is about to be delivered (manual or automatic) - the next automatic one
            // starts timing from here, and the manual hotkey resetting this too is exactly the
            // "the manual hotkey ... resets the auto timer" behaviour.
            self.autoSendTracker.resetAfterChunkSent()
            self.isAutoSendPending = false
            return (released.mic, released.system, noiseFloors.0, noiseFloors.1, released.deferredCount, systemDiarization)
        }
        return MeetingCut(
            mic: mic, system: system, mix: Self.mix(mic: mic, system: system),
            micNoiseFloor: micNoiseFloor, systemNoiseFloor: systemNoiseFloor, deferredSampleCount: deferredCount,
            systemDiarization: systemDiarization)
    }

    /// A manual (hotkey) chunk cut. Waits `manualCutDelaySeconds` first - long enough for a word
    /// spoken right up to the key press to finish arriving and its VAD region to close - then
    /// forces full release regardless, so the last word is never held back for a later, possibly
    /// much-delayed chunk the way an automatic cut's open-utterance deferral would (see `cut`).
    func cutForManualSend() async -> MeetingCut {
        try? await Task.sleep(nanoseconds: UInt64(Self.manualCutDelaySeconds * 1_000_000_000))
        return cut(forceFullRelease: true)
    }

    // MARK: - Periodic draining

    /// Every drain increment is echo-cancelled (when applicable) and both queued for the next
    /// chunk-hotkey cut and appended to the continuous meeting file, so neither loses audio
    /// regardless of how often this runs. Always called on `tapQueue` (the timer already fires
    /// there; `cut()` hops onto it) so two drains never interleave.
    private func drainTick() {
        let (rawMic, rawSystem) = drainBuffer.withLock { $0.drainRaw() }
        processDrained(mic: rawMic, system: rawSystem)
    }

    /// One last drain, called from `stop()` after the recorders are fully stopped, plus whatever
    /// the echo canceller was still holding back for a `cancelEcho` call that will now never
    /// come - so the continuous meeting file always ends with everything that was captured
    /// instead of a truncated tail.
    private func finalDrainTick() {
        let (rawMic, rawSystem) = drainBuffer.withLock { $0.drainRaw() }
        processDrained(mic: rawMic, system: rawSystem)

        guard let echoCanceller, isCapturingSystemAudio else { return }
        let (flushedMic, flushedReference) = echoCanceller.flush()
        guard !flushedMic.isEmpty else { return }
        absorbAndWrite(mic: flushedMic, system: flushedReference)
    }

    private func processDrained(mic rawMic: [Int16], system rawSystem: [Int16]) {
        guard !rawMic.isEmpty else { return }

        let cleanedMic: [Int16]
        let referenceForMix: [Int16]
        if let echoCanceller, isCapturingSystemAudio {
            // Pass the raw, possibly unequal-length per-tick streams straight through - end-
            // aligning them here would corrupt the echo canceller's reference (see
            // `MeetingDrainBuffer.drainRaw`); `cancelEcho` itself carries any length mismatch
            // forward instead and always returns an equal-length pair.
            (cleanedMic, referenceForMix) = echoCanceller.cancelEcho(mic: rawMic, reference: rawSystem)
        } else {
            // No echo cancellation running (no system audio), so nothing needs the raw streams
            // kept separate by channel - end-align them here instead, so the mic-only case still
            // keeps `chunkPendingMic`/`chunkPendingSystem` (and the recording writer) in lockstep.
            (cleanedMic, referenceForMix) = Self.alignedEnds(mic: rawMic, system: rawSystem)
        }
        absorbAndWrite(mic: cleanedMic, system: referenceForMix)
    }

    private func absorbAndWrite(mic: [Int16], system: [Int16]) {
        let mic = MeetingDictationGate.silenceMicDuringDictation(mic, isDictationActive: isDictationActive)
        drainBuffer.withLock { $0.absorb(mic: mic, system: system) }
        // Same `system` samples, same call order as `absorb` above, so the diarizer's internal
        // absolute-sample position always matches `chunkPendingBaseOffset`'s coordinate frame.
        systemDiarizer?.append(system)
        do {
            try recordingWriter?.append(mic: mic, system: system)
        } catch {
            logger.error("Meeting capture: failed to append to the continuous recording file: \(error, privacy: .public)")
        }

        evaluateAutoSend(mic: mic, system: system)
    }

    /// Advances `MeetingVAD` per channel - the same detector `MeetingTurnBuilder` uses to order
    /// turns, so "speech" means the same thing everywhere - and, when "Send Chunks Automatically"
    /// is on, feeds the result to `MeetingAutoSendPolicy`. VAD state is advanced unconditionally
    /// (not just when auto-send is enabled): `cut()` needs it too, to avoid splitting an open
    /// utterance across a chunk boundary. The setting is read fresh on every tick rather than
    /// cached at `start()`, so toggling it mid-capture takes effect immediately either way.
    /// Always called on `tapQueue`, same as `drainTick`.
    private func evaluateAutoSend(mic: [Int16], system: [Int16]) {
        let autoSendEnabled =
            !isAutoSendPending
            && UserDefaults.standard.bool(forKey: PinnedDestinationSettingsKeys.sendMeetingChunksAutomatically)

        let result = MeetingAutoSendEvaluator.step(
            mic: mic, system: system, sampleRate: mixdownFormat.sampleRate, autoSendEnabled: autoSendEnabled,
            micVADState: micVADState, systemVADState: systemVADState, tracker: autoSendTracker)
        micVADState = result.micVADState
        systemVADState = result.systemVADState
        autoSendTracker = result.tracker

        logger.debug(
            "Meeting auto-send tick: micVoiced=\(result.micVADState.inSpeech, privacy: .public) systemVoiced=\(result.systemVADState.inSpeech, privacy: .public) speechS=\(String(format: "%.2f", self.autoSendTracker.speechSecondsSinceLastChunk), privacy: .public) silenceS=\(String(format: "%.2f", self.autoSendTracker.currentSilenceDuration), privacy: .public)"
        )

        guard result.shouldTrigger else { return }
        isAutoSendPending = true
        logger.info(
            "Meeting auto-send triggered: speechS=\(String(format: "%.2f", self.autoSendTracker.speechSecondsSinceLastChunk), privacy: .public) silenceS=\(String(format: "%.2f", self.autoSendTracker.currentSilenceDuration), privacy: .public) sinceLastS=\(String(format: "%.2f", self.autoSendTracker.secondsSinceLastChunk), privacy: .public)"
        )
        onAutoSendTrigger?()
    }

    private func startDrainTimer() {
        let timer = DispatchSource.makeTimerSource(queue: tapQueue)
        timer.schedule(deadline: .now() + Self.drainIntervalSeconds, repeating: Self.drainIntervalSeconds)
        timer.setEventHandler { [weak self] in self?.drainTick() }
        timer.resume()
        drainTimer = timer
    }

    /// Root-mean-square level of `samples`, used to skip transcribing a track that is silence
    /// (avoids Whisper-style models hallucinating text on silent audio).
    static func rms(_ samples: [Int16]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sumSquares = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        return (sumSquares / Double(samples.count)).squareRoot()
    }

    /// Aligns the two streams on their end (both were cut at the same instant), padding the
    /// shorter one at the front with silence, so real audio always lines up rather than being
    /// shifted.
    static func alignedEnds(mic: [Int16], system: [Int16]) -> (mic: [Int16], system: [Int16]) {
        let count = max(mic.count, system.count)
        guard count > 0 else { return ([], []) }

        var alignedMic = [Int16](repeating: 0, count: count)
        var alignedSystem = [Int16](repeating: 0, count: count)
        alignedMic.replaceSubrange((count - mic.count)..<count, with: mic)
        alignedSystem.replaceSubrange((count - system.count)..<count, with: system)
        return (alignedMic, alignedSystem)
    }

    static func mix(mic: [Int16], system: [Int16]) -> [Int16] {
        let (alignedMic, alignedSystem) = alignedEnds(mic: mic, system: system)
        guard !alignedMic.isEmpty else { return [] }

        var result = [Int16](repeating: 0, count: alignedMic.count)
        for i in 0..<alignedMic.count {
            result[i] = Int16(clamping: Int(alignedMic[i]) + Int(alignedSystem[i]))
        }
        return result
    }

    /// Adds `paddingSamples` of silence to each side of `samples` - used to give the
    /// transcription service a little silent lead-in/out around a single turn's clip.
    static func padded(_ samples: [Int16], paddingSamples: Int) -> [Int16] {
        guard paddingSamples > 0 else { return samples }
        let silence = [Int16](repeating: 0, count: paddingSamples)
        return silence + samples + silence
    }

    static func writeWAV(_ samples: [Int16], to url: URL) throws {
        let sampleRate: UInt32 = 16000
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let blockAlign = channels * (bitsPerSample / 8)
        let byteRate = sampleRate * UInt32(blockAlign)
        let dataSize = UInt32(samples.count * MemoryLayout<Int16>.size)

        var header = [UInt8]()
        header.append(contentsOf: Array("RIFF".utf8))
        header.append(contentsOf: leBytes(UInt32(36) + dataSize))
        header.append(contentsOf: Array("WAVE".utf8))
        header.append(contentsOf: Array("fmt ".utf8))
        header.append(contentsOf: leBytes(UInt32(16)))
        header.append(contentsOf: leBytes(UInt16(1)))  // PCM
        header.append(contentsOf: leBytes(channels))
        header.append(contentsOf: leBytes(sampleRate))
        header.append(contentsOf: leBytes(byteRate))
        header.append(contentsOf: leBytes(blockAlign))
        header.append(contentsOf: leBytes(bitsPerSample))
        header.append(contentsOf: Array("data".utf8))
        header.append(contentsOf: leBytes(dataSize))

        var data = Data(header)
        samples.withUnsafeBufferPointer { data.append(contentsOf: UnsafeRawBufferPointer($0)) }

        try data.write(to: url)
    }

    static func leBytes<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        withUnsafeBytes(of: value.littleEndian) { Array($0) }
    }

    // MARK: - Microphone capture

    private func startMic() {
        micRecorder.onAudioChunk = { [weak self] data in
            self?.appendMicSamples(from: data)
        }

        let deviceID = AudioDeviceManager.shared.getCurrentDevice()
        let url = micOutputURL
        micSetupQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.micRecorder.startRecording(toOutputFile: url, deviceID: deviceID)
            } catch {
                self.logger.error("Meeting capture: microphone start failed \(error, privacy: .public)")
            }
        }
    }

    /// Synchronous (not `.async`, unlike `startMic`): `stopRecording()` drains any mic samples
    /// still queued in the recorder through `onAudioChunk` before returning, so `onAudioChunk`
    /// must stay set until after that call, and `stop()` needs this to have finished - and that
    /// last drained audio to have reached `drainBuffer` - before it does the final drain below.
    /// Async-then-immediately-clearing-the-callback used to let exactly that queued audio through
    /// to the file writer (which doesn't route through `onAudioChunk`) but never into
    /// `drainBuffer`, silently dropping it from both the continuous recording and any chunk cut.
    private func stopMic() {
        let url = micOutputURL
        micSetupQueue.sync { [weak self] in
            self?.micRecorder.stopRecording()
            self?.micRecorder.onAudioChunk = nil
            self?.micRecorder.teardown()
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func appendMicSamples(from data: Data) {
        // `Data` is not guaranteed to be 2-byte aligned, so `load(fromByteOffset:as:)` can trap; copy out instead.
        var samples = [Int16](repeating: 0, count: data.count / MemoryLayout<Int16>.size)
        _ = samples.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        drainBuffer.withLock { $0.appendMic(samples) }
    }

    // MARK: - System audio capture (Core Audio process tap)

    private func startSystemTap() {
        guard createProcessTap(), createAggregateDevice(), startAggregateIO() else {
            logger.notice("Meeting capture: system audio tap unavailable, continuing microphone-only")
            stopSystemTap()
            return
        }
        isCapturingSystemAudio = true
    }

    private func stopSystemTap() {
        if let ioProcID {
            AudioDeviceStop(aggregateDeviceID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            self.ioProcID = nil
        }
        if aggregateDeviceID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        tapUUID = nil
        tapFormat = nil
        converter = nil
        isCapturingSystemAudio = false
    }

    private func createProcessTap() -> Bool {
        var pid = ProcessInfo.processInfo.processIdentifier
        var ownProcessObject = AudioObjectID(kAudioObjectUnknown)
        var propertySize = UInt32(MemoryLayout<AudioObjectID>.size)
        var translateAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let translateStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &translateAddress,
            UInt32(MemoryLayout<pid_t>.size), &pid, &propertySize, &ownProcessObject
        )
        guard translateStatus == noErr else {
            logger.notice("Meeting capture: could not resolve own process object, status=\(translateStatus, privacy: .public)")
            return false
        }

        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [ownProcessObject])
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &newTapID)
        guard tapStatus == noErr else {
            logger.notice("Meeting capture: AudioHardwareCreateProcessTap failed, status=\(tapStatus, privacy: .public)")
            return false
        }
        tapID = newTapID
        tapUUID = description.uuid

        var tapStreamDescription = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var formatAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let formatStatus = AudioObjectGetPropertyData(tapID, &formatAddress, 0, nil, &formatSize, &tapStreamDescription)
        guard formatStatus == noErr,
            let tapFormat = AVAudioFormat(streamDescription: &tapStreamDescription)
        else {
            logger.notice("Meeting capture: could not read tap format, status=\(formatStatus, privacy: .public)")
            return false
        }
        self.tapFormat = tapFormat

        guard let converter = AVAudioConverter(from: tapFormat, to: mixdownFormat) else {
            logger.notice("Meeting capture: could not create audio converter for the system tap")
            return false
        }
        converter.downmix = true
        self.converter = converter

        return true
    }

    private func createAggregateDevice() -> Bool {
        guard let tapUUID, let outputDeviceUID = defaultOutputDeviceUID() else { return false }

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "VoiceInk Meeting Capture",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputDeviceUID, kAudioSubDeviceDriftCompensationKey: true]
            ],
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapUUID.uuidString, kAudioSubTapDriftCompensationKey: true]
            ],
        ]

        var newAggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &newAggregateDeviceID)
        guard status == noErr else {
            logger.notice("Meeting capture: AudioHardwareCreateAggregateDevice failed, status=\(status, privacy: .public)")
            return false
        }
        aggregateDeviceID = newAggregateDeviceID
        return true
    }

    private func startAggregateIO() -> Bool {
        var newIOProcID: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcIDWithBlock(&newIOProcID, aggregateDeviceID, tapQueue) {
            [weak self] _, inputData, _, _, _ in
            self?.handleTapBuffer(inputData: inputData)
        }
        guard createStatus == noErr, let newIOProcID else {
            logger.notice("Meeting capture: AudioDeviceCreateIOProcIDWithBlock failed, status=\(createStatus, privacy: .public)")
            return false
        }
        ioProcID = newIOProcID

        let startStatus = AudioDeviceStart(aggregateDeviceID, newIOProcID)
        guard startStatus == noErr else {
            logger.notice("Meeting capture: AudioDeviceStart failed, status=\(startStatus, privacy: .public)")
            return false
        }
        return true
    }

    // ponytail: allocates a fresh AVAudioPCMBuffer + Array per tap callback; pool buffers if
    // this ever shows up as a hot path.
    private func handleTapBuffer(inputData: UnsafePointer<AudioBufferList>) {
        guard let tapFormat, let converter,
            let inputBuffer = AVAudioPCMBuffer(pcmFormat: tapFormat, bufferListNoCopy: inputData),
            inputBuffer.frameLength > 0
        else { return }

        let ratio = mixdownFormat.sampleRate / tapFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio) + 16
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: mixdownFormat, frameCapacity: capacity) else { return }

        var suppliedInput = false
        var conversionError: NSError?
        converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
            if suppliedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return inputBuffer
        }

        guard conversionError == nil,
            outputBuffer.frameLength > 0,
            let channelData = outputBuffer.int16ChannelData
        else { return }

        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: Int(outputBuffer.frameLength)))
        drainBuffer.withLock { $0.appendSystem(samples) }
    }

    private func defaultOutputDeviceUID() -> String? {
        var deviceID = AudioDeviceID(0)
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propertySize, &deviceID)
        guard status == noErr else { return nil }
        return deviceUID(for: deviceID)
    }

    private func deviceUID(for deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var propertySize = UInt32(MemoryLayout<CFString>.size)
        var uid: CFString?
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &propertySize, &uid)
        guard status == noErr, let uid else { return nil }
        return uid as String
    }
}
