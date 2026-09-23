import Testing
import Foundation
@testable import VoiceInk

// MARK: - Meeting Capture: mixing microphone and system audio

struct MeetingAudioCaptureMixTests {
    @Test func mixAlignsOnTheEndAndPadsTheShorterStreamAtTheFront() {
        let mic: [Int16] = [1, 2, 3, 4, 5]
        let system: [Int16] = [10, 20]

        let mixed = MeetingAudioCapture.mix(mic: mic, system: system)

        #expect(mixed.count == 5)
        // The first three samples have no matching system audio, so they pass through unchanged.
        #expect(Array(mixed[0..<3]) == [1, 2, 3])
        // The last two samples align: mic's tail with system's only samples.
        #expect(mixed[3] == 4 + 10)
        #expect(mixed[4] == 5 + 20)
    }

    @Test func mixWithEmptySystemAudioReturnsMicUnchanged() {
        let mic: [Int16] = [7, 8, 9]
        let mixed = MeetingAudioCapture.mix(mic: mic, system: [])
        #expect(mixed == mic)
    }

    @Test func mixWithBothEmptyReturnsEmpty() {
        #expect(MeetingAudioCapture.mix(mic: [], system: []).isEmpty)
    }

    @Test func mixClampsOverflowInsteadOfWrapping() {
        let mixed = MeetingAudioCapture.mix(mic: [Int16.max], system: [Int16.max])
        #expect(mixed == [Int16.max])
    }

    @Test func mixClampsUnderflowInsteadOfWrapping() {
        let mixed = MeetingAudioCapture.mix(mic: [Int16.min], system: [Int16.min])
        #expect(mixed == [Int16.min])
    }
}

// MARK: - Meeting Capture: WAV header

struct MeetingAudioCaptureWAVTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
    }

    @Test func writeWAVProducesExactlyFortyFourBytesOfHeaderPlusSamples() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let samples: [Int16] = [1, -1, 100, -100, 0]

        try MeetingAudioCapture.writeWAV(samples, to: url)

        let data = try Data(contentsOf: url)
        #expect(data.count == 44 + samples.count * 2)
    }

    @Test func writeWAVStartsWithRIFFAndHasDataChunkAtOffsetThirtySix() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        try MeetingAudioCapture.writeWAV([1, 2, 3], to: url)

        let data = try Data(contentsOf: url)
        #expect(data.prefix(4) == Data("RIFF".utf8))
        #expect(data[8..<12] == Data("WAVE".utf8))
        #expect(data[36..<40] == Data("data".utf8))
    }

    @Test func writeWAVSamplesRoundTripFromOffsetFortyFour() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let samples: [Int16] = [1, -1, 12345, -12345, 0, Int16.max, Int16.min]

        try MeetingAudioCapture.writeWAV(samples, to: url)

        let data = try Data(contentsOf: url)
        let decoded = stride(from: 44, to: data.count, by: 2).map { offset -> Int16 in
            // The slice's base offset is not 2-byte aligned, so `load(as:)` can trap.
            data[offset..<offset + 2].withUnsafeBytes { $0.loadUnaligned(as: Int16.self) }
        }
        #expect(decoded == samples)
    }

    @Test func writeWAVWithNoSamplesStillProducesAValidFortyFourByteHeader() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        try MeetingAudioCapture.writeWAV([], to: url)

        let data = try Data(contentsOf: url)
        #expect(data.count == 44)
        #expect(data.prefix(4) == Data("RIFF".utf8))
        #expect(data[36..<40] == Data("data".utf8))
    }
}

// MARK: - Meeting Capture: echo cancellation

struct EchoCancellerTests {
    private static let sampleRate = 16000.0
    private static let totalSamples = 96_000 // 6 s, a multiple of EchoCanceller.frameSize (320)
    private static let echoDelaySamples = 640 // 40 ms
    private static let echoAttenuation = 0.4
    // Far-only for the first 4 s so the adaptive filter has real time to converge before
    // double-talk starts - MDF's NLMS-style filter needs a few seconds of excitation, not just a
    // few hundred ms, to null out even a simple single-tap echo path like this one.
    private static let nearEndStart = 64_000

    /// A linear chirp standing in for the far-end (system-tap) signal.
    private static func farEndChirp() -> [Int16] {
        let f0 = 300.0, f1 = 3000.0
        let duration = Double(totalSamples) / sampleRate
        return (0..<totalSamples).map { i in
            let t = Double(i) / sampleRate
            let phase = 2 * Double.pi * (f0 * t + (f1 - f0) / (2 * duration) * t * t)
            return Int16(clamping: Int((6000 * sin(phase)).rounded()))
        }
    }

    /// A near-end sine tone in a band the chirp has already swept past by the time it starts,
    /// so the two are distinguishable.
    private static func nearEndSine() -> [Int16] {
        var out = [Int16](repeating: 0, count: totalSamples)
        for i in nearEndStart..<totalSamples {
            let t = Double(i - nearEndStart) / sampleRate
            out[i] = Int16(clamping: Int((4000 * sin(2 * Double.pi * 500 * t)).rounded()))
        }
        return out
    }

    /// The "mic" signal: a delayed, attenuated copy of the far end (the acoustic echo) plus the
    /// near-end speech, exactly as a real microphone would pick up both the loudspeaker and the
    /// person talking into it.
    private static func micSignal(farEnd: [Int16], nearEnd: [Int16]) -> [Int16] {
        (0..<totalSamples).map { i in
            let echo = i >= echoDelaySamples ? Double(farEnd[i - echoDelaySamples]) * echoAttenuation : 0
            return Int16(clamping: Int(echo.rounded()) + Int(nearEnd[i]))
        }
    }

    private static func rmsDB(_ samples: ArraySlice<Int16>) -> Double {
        let sumSquares = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        let meanSquare = sumSquares / Double(samples.count)
        guard meanSquare > 0 else { return -.infinity }
        return 10 * log10(meanSquare)
    }

    @Test func cancelEchoReducesTheEchoByAtLeastFifteenDecibelsAfterConvergenceAndPreservesTheNearEndSpeechWithinTwoDecibelsDuringDoubleTalk() {
        let farEnd = Self.farEndChirp()
        let nearEnd = Self.nearEndSine()
        let mic = Self.micSignal(farEnd: farEnd, nearEnd: nearEnd)

        let canceller = EchoCanceller()
        let (cleaned, _) = canceller.cancelEcho(mic: mic, reference: farEnd)
        #expect(cleaned.count == mic.count)

        // Echo-only region (before the near end starts), read right before the near end starts
        // so the adaptive filter has had the most time available to converge.
        let echoOnlyWindow = 60_000..<64_000
        let rawEchoDB = Self.rmsDB(mic[echoOnlyWindow])
        let cleanedEchoDB = Self.rmsDB(cleaned[echoOnlyWindow])
        let echoReductionDB = rawEchoDB - cleanedEchoDB
        #expect(echoReductionDB >= 15, "measured echo reduction was \(echoReductionDB) dB")

        // Near-end region, read near the end so the filter has converged there too. The cleaned
        // output in this window is near-end plus whatever echo residual remains, so it should be
        // close in level to the pure near-end reference. The bound is 2 dB (not looser) because
        // this is a double-talk property: see EchoCanceller's doc comment for why its
        // residual-echo preprocessor stage was measured out entirely - it passed a similar,
        // energy-only check on synthetic tones like this one while destroying near-end waveform
        // correlation on real speech, so this test's margin is intentionally tight.
        let nearEndWindow = 88_000..<96_000
        let nearEndOnlyDB = Self.rmsDB(nearEnd[nearEndWindow])
        let cleanedNearEndDB = Self.rmsDB(cleaned[nearEndWindow])
        let nearEndDeltaDB = abs(cleanedNearEndDB - nearEndOnlyDB)
        #expect(nearEndDeltaDB <= 2, "near-end level shifted by \(nearEndDeltaDB) dB")
    }

    @Test func cancelEchoCarriesPartialFramesOverToTheNextCallInsteadOfDroppingThem() {
        // 321 samples: one full frame (320) plus a single leftover sample that cannot yet form a
        // frame. It must reappear once enough samples arrive to complete a frame, not vanish.
        let canceller = EchoCanceller()
        let farEnd = [Int16](repeating: 0, count: 321)
        let mic = [Int16](repeating: 0, count: 321)
        let (firstCleaned, firstReference) = canceller.cancelEcho(mic: mic, reference: farEnd)
        #expect(firstCleaned.count == 320)
        #expect(firstReference.count == 320)

        let (secondCleaned, secondReference) = canceller.cancelEcho(
            mic: [Int16](repeating: 0, count: 319), reference: [Int16](repeating: 0, count: 319))
        #expect(secondCleaned.count == 320)
        #expect(secondReference.count == 320)
    }

    @Test func cancelEchoSkipsCancellationWhenThereIsNoSystemAudioBecauseCutFallsBackToPlainMix() {
        // Mirrors what MeetingAudioCapture.cut() does when isCapturingSystemAudio is false: mix
        // the mic straight through with no echo canceller involved.
        let mic: [Int16] = [1, 2, 3]
        #expect(MeetingAudioCapture.mix(mic: mic, system: []) == mic)
    }

    @Test func flushReturnsThePartialFrameCancelEchoWasStillHoldingBackInsteadOfDroppingItAtSessionEnd() {
        // 321 samples leaves a 1-sample remainder that cancelEcho carries over (see the test
        // above); at session end there is no next cancelEcho call to carry it into, so it must
        // come back from flush() instead of vanishing when the canceller is torn down.
        let canceller = EchoCanceller()
        _ = canceller.cancelEcho(mic: [Int16](repeating: 0, count: 321), reference: [Int16](repeating: 0, count: 321))

        let (flushedMic, flushedReference) = canceller.flush()
        #expect(flushedMic.count == 1)
        #expect(flushedReference.count == 1)

        // A second flush has nothing left to return.
        let (secondMic, secondReference) = canceller.flush()
        #expect(secondMic.isEmpty)
        #expect(secondReference.isEmpty)
    }

    @Test func flushOnAFreshCancellerWithNothingHeldBackReturnsEmpty() {
        let canceller = EchoCanceller()
        let (mic, reference) = canceller.flush()
        #expect(mic.isEmpty)
        #expect(reference.isEmpty)
    }
}

// MARK: - Meeting Capture: drain / chunk-pending buffering

struct MeetingDrainBufferTests {
    @Test func drainRawReturnsExactlyWhatWasAppendedSinceThePreviousDrain() {
        var buffer = MeetingDrainBuffer()
        buffer.appendMic([1, 2, 3])
        buffer.appendSystem([10, 20, 30])

        let (mic, system) = buffer.drainRaw()
        #expect(mic == [1, 2, 3])
        #expect(system == [10, 20, 30])

        // Nothing left to drain a second time.
        let (secondMic, secondSystem) = buffer.drainRaw()
        #expect(secondMic.isEmpty)
        #expect(secondSystem.isEmpty)
    }

    @Test func drainRawEndAlignsUnevenTracksJustLikeMeetingAudioCapture() {
        var buffer = MeetingDrainBuffer()
        buffer.appendMic([1, 2, 3, 4, 5])
        buffer.appendSystem([10, 20])

        let (mic, system) = buffer.drainRaw()
        #expect(mic == [1, 2, 3, 4, 5])
        #expect(system == [0, 0, 0, 10, 20])
    }

    @Test func cutChunkPendingIsEmptyBeforeAnyDrainOrAbsorb() {
        var buffer = MeetingDrainBuffer()
        let (mic, system) = buffer.cutChunkPending()
        #expect(mic.isEmpty)
        #expect(system.isEmpty)
    }

    @Test func absorbedAudioIsReturnedOnceByCutChunkPendingAndThenCleared() {
        var buffer = MeetingDrainBuffer()
        buffer.absorb(mic: [1, 2], system: [10, 20])
        buffer.absorb(mic: [3, 4], system: [30, 40])

        let (mic, system) = buffer.cutChunkPending()
        #expect(mic == [1, 2, 3, 4])
        #expect(system == [10, 20, 30, 40])

        let (secondMic, secondSystem) = buffer.cutChunkPending()
        #expect(secondMic.isEmpty)
        #expect(secondSystem.isEmpty)
    }

    @Test func periodicDrainsBetweenTwoCutsAreAllDeliveredByTheSecondCutWithoutLossOrDuplication() {
        // Simulates: hardware appends audio, a periodic timer drains it several times (feeding
        // the continuous meeting file), then a chunk hotkey press cuts. The cut must contain
        // everything appended since the previous cut - exactly once, not zero and not twice -
        // regardless of how many periodic drains happened in between.
        var buffer = MeetingDrainBuffer()

        buffer.appendMic([1, 2])
        let firstDrain = buffer.drainRaw()
        buffer.absorb(mic: firstDrain.mic, system: firstDrain.system)

        buffer.appendMic([3, 4])
        let secondDrain = buffer.drainRaw()
        buffer.absorb(mic: secondDrain.mic, system: secondDrain.system)

        buffer.appendMic([5])
        // No drain before the cut - MeetingAudioCapture.cut() always drains first, so simulate
        // that here too.
        let thirdDrain = buffer.drainRaw()
        buffer.absorb(mic: thirdDrain.mic, system: thirdDrain.system)

        let (mic, _) = buffer.cutChunkPending()
        #expect(mic == [1, 2, 3, 4, 5])
    }

    @Test func aCutDoesNotAffectWhatTheNextCutReceives() {
        var buffer = MeetingDrainBuffer()

        buffer.appendMic([1, 2])
        buffer.absorb(mic: buffer.drainRaw().mic, system: [])
        _ = buffer.cutChunkPending()

        buffer.appendMic([3, 4])
        buffer.absorb(mic: buffer.drainRaw().mic, system: [])
        let (mic, _) = buffer.cutChunkPending()

        #expect(mic == [3, 4])
    }

    @Test func rawSamplesAppendedAfterADrainAreNotLostAndAppearInTheNextDrain() {
        var buffer = MeetingDrainBuffer()
        buffer.appendMic([1])
        _ = buffer.drainRaw()

        buffer.appendMic([2, 3])
        let (mic, _) = buffer.drainRaw()
        #expect(mic == [2, 3])
    }
}

// MARK: - Meeting Capture: chunk-boundary continuity (an utterance open at cut time must survive
// whole, once, in the next chunk - never split, lost, or duplicated)

struct MeetingAudioCaptureChunkBoundaryTests {
    private func loud(_ count: Int) -> [Int16] { [Int16](repeating: 5000, count: count) }
    private func quiet(_ count: Int) -> [Int16] { [Int16](repeating: 0, count: count) }

    /// Advances `micState`/`systemState` and queues `mic` (with a matching-length silent system
    /// track) into `buffer`, exactly as `MeetingAudioCapture.absorbAndWrite` does on every drain
    /// tick - `MeetingAutoSendEvaluator.cutBoundary` needs both to stay in lockstep to translate
    /// its global-offset decision into a local buffer index correctly.
    private func absorb(
        _ mic: [Int16], into buffer: inout MeetingDrainBuffer,
        micState: inout MeetingVAD.State, systemState: inout MeetingVAD.State
    ) {
        let system = [Int16](repeating: 0, count: mic.count)
        let (_, _, newMicState) = MeetingVAD.process(mic, state: micState)
        let (_, _, newSystemState) = MeetingVAD.process(system, state: systemState)
        micState = newMicState
        systemState = newSystemState
        buffer.absorb(mic: mic, system: system)
    }

    /// Mirrors `MeetingAudioCapture.cut()`'s boundary + release logic exactly (it delegates to the
    /// same `MeetingAutoSendEvaluator.cutBoundary`), without the Core Audio/echo-cancellation
    /// machinery around it.
    private func cut(
        from buffer: inout MeetingDrainBuffer, micState: MeetingVAD.State, systemState: MeetingVAD.State,
        baseOffset: inout Int, forceFullRelease: Bool = false
    ) -> [Int16] {
        let boundary = MeetingAutoSendEvaluator.cutBoundary(
            micVADState: micState, systemVADState: systemState,
            chunkPendingBaseOffset: baseOffset, forceFullRelease: forceFullRelease)
        let released = buffer.releasePrefix(sampleCount: boundary)
        baseOffset += released.mic.count
        return released.mic
    }

    @Test func anUtteranceOpenAtCutTimeSurvivesWholeInTheNextChunkAcrossThreeConsecutiveCutsWithNoLossOrDuplication() {
        let s0 = quiet(3200), u1 = loud(6400), s1 = quiet(9600)
        let u2 = loud(32000), s2 = quiet(9600)
        let u3 = loud(16000)
        let fullStream = s0 + u1 + s1 + u2 + s2 + u3

        var buffer = MeetingDrainBuffer()
        var micState = MeetingVAD.State.initial
        var systemState = MeetingVAD.State.initial
        var baseOffset = 0

        // Cut 1: lands mid-way through u2, which is still open (no trailing silence yet) - only
        // the already-closed s0+u1+s1 prefix should be released; all of u2 held back.
        absorb(s0 + u1 + s1 + Array(u2.prefix(16000)), into: &buffer, micState: &micState, systemState: &systemState)
        let cut1 = cut(from: &buffer, micState: micState, systemState: systemState, baseOffset: &baseOffset)
        #expect(cut1 == s0 + u1 + s1)

        // Cut 2: the rest of u2, then s2 (which closes it), then half of u3 (still open) - u2 must
        // now appear complete, exactly once, at the start of this chunk.
        absorb(Array(u2.suffix(16000)) + s2 + Array(u3.prefix(8000)), into: &buffer, micState: &micState, systemState: &systemState)
        let cut2 = cut(from: &buffer, micState: micState, systemState: systemState, baseOffset: &baseOffset)
        #expect(cut2 == u2 + s2)

        // Cut 3: session stop - the rest of u3, still open (no trailing silence at all), must be
        // flushed anyway rather than staying stuck in the buffer.
        absorb(Array(u3.suffix(8000)), into: &buffer, micState: &micState, systemState: &systemState)
        let cut3 = cut(
            from: &buffer, micState: micState, systemState: systemState, baseOffset: &baseOffset, forceFullRelease: true)
        #expect(cut3 == u3)

        // No loss or duplication across the three cuts: concatenated, in order, they reproduce
        // the original input exactly.
        #expect(cut1 + cut2 + cut3 == fullStream)

        // Each utterance appears exactly once, complete, when the per-chunk turn-builder analyzes
        // that chunk in isolation (fresh VAD state, exactly as MeetingTurnTranscriber does).
        #expect(MeetingVAD.regions(for: cut1).count == 1)

        let cut2Regions = MeetingVAD.regions(for: cut2)
        #expect(cut2Regions.count == 1)
        #expect(cut2Regions[0].end - cut2Regions[0].start >= u2.count, "u2 must appear whole, not truncated")

        let cut3Regions = MeetingVAD.regions(for: cut3)
        #expect(cut3Regions.count == 1)
        #expect(cut3Regions[0].end - cut3Regions[0].start >= u3.count, "u3 must appear whole, not truncated")
    }
}

// MARK: - Meeting Capture: continuous stereo recording writer

struct MeetingRecordingWriterTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
    }

    @Test func finishPatchesTheRIFFAndDataChunkSizesToTheTotalAppendedByteCount() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try MeetingRecordingWriter(url: url)
        try writer.append(mic: [1, 2, 3], system: [10, 20, 30])
        try writer.append(mic: [4, 5], system: [40, 50])
        try writer.finish()

        let data = try Data(contentsOf: url)
        // 5 stereo frames * 2 channels * 2 bytes = 20 bytes of sample data.
        let expectedDataSize: UInt32 = 20
        let riffSize = data[4..<8].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        let dataSize = data[40..<44].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        #expect(riffSize == 36 + expectedDataSize)
        #expect(dataSize == expectedDataSize)
        #expect(data.count == 44 + Int(expectedDataSize))
    }

    @Test func headerDeclaresStereoSixteenKilohertzSixteenBit() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try MeetingRecordingWriter(url: url)
        try writer.finish()

        let data = try Data(contentsOf: url)
        let channels = data[22..<24].withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }
        let sampleRate = data[24..<28].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        let bitsPerSample = data[34..<36].withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }
        #expect(channels == 2)
        #expect(sampleRate == 16000)
        #expect(bitsPerSample == 16)
    }

    @Test func readChannelsRoundTripsMicAndSystemAcrossSeveralAppendsInLeftRightOrder() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try MeetingRecordingWriter(url: url)
        try writer.append(mic: [1, 2, 3], system: [-1, -2, -3])
        try writer.append(mic: [100, Int16.max], system: [-100, Int16.min])
        try writer.finish()

        let (mic, system) = try MeetingRecordingWriter.readChannels(from: url)
        #expect(mic == [1, 2, 3, 100, Int16.max])
        #expect(system == [-1, -2, -3, -100, Int16.min])
    }

    @Test func readChannelsOnAnEmptyRecordingReturnsTwoEmptyChannels() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try MeetingRecordingWriter(url: url)
        try writer.finish()

        let (mic, system) = try MeetingRecordingWriter.readChannels(from: url)
        #expect(mic.isEmpty)
        #expect(system.isEmpty)
    }

    @Test func appendWithEmptyArraysIsANoOp() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try MeetingRecordingWriter(url: url)
        try writer.append(mic: [], system: [])
        try writer.finish()

        let data = try Data(contentsOf: url)
        #expect(data.count == 44)
    }

    @Test func channelReaderReadsTheSameSamplesAsReadChannelsAcrossSeveralNotEvenlySizedBlocks() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let mic = (0..<10_000).map { Int16($0 % 4000) }
        let system = (0..<10_000).map { Int16(-($0 % 4000)) }
        let writer = try MeetingRecordingWriter(url: url)
        try writer.append(mic: mic, system: system)
        try writer.finish()

        let reader = try #require(MeetingRecordingWriter.ChannelReader(url: url))
        defer { reader.close() }
        var readMic: [Int16] = []
        var readSystem: [Int16] = []
        while let block = reader.nextBlock(frameCount: 777) {
            readMic.append(contentsOf: block.mic)
            readSystem.append(contentsOf: block.system)
        }

        #expect(readMic == mic)
        #expect(readSystem == system)
    }

    @Test func channelReaderOnAnEmptyRecordingReturnsNoBlocks() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try MeetingRecordingWriter(url: url)
        try writer.finish()

        let reader = try #require(MeetingRecordingWriter.ChannelReader(url: url))
        defer { reader.close() }
        #expect(reader.nextBlock(frameCount: 777) == nil)
    }
}
