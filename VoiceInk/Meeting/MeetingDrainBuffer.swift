import Foundation

/// Pure buffering/drain logic behind `MeetingAudioCapture`, kept free of Core Audio, echo
/// cancellation and file I/O so it is unit-testable on its own.
///
/// Two buffering levels: `pendingMic`/`pendingSystem` accumulate raw hardware samples between
/// drains (a periodic timer tick or a cut); `chunkPendingMic`/`chunkPendingSystem` accumulate
/// every drain's *aligned* output between chunk-hotkey presses, so a periodic drain (feeding the
/// continuous meeting file) never causes the next hotkey press to lose or skip audio - it only
/// changes how many small pieces that audio arrives in.
struct MeetingDrainBuffer {
    private var pendingMic: [Int16] = []
    private var pendingSystem: [Int16] = []
    private var chunkPendingMic: [Int16] = []
    private var chunkPendingSystem: [Int16] = []

    mutating func appendMic(_ samples: [Int16]) {
        pendingMic.append(contentsOf: samples)
    }

    mutating func appendSystem(_ samples: [Int16]) {
        pendingSystem.append(contentsOf: samples)
    }

    /// Pulls everything captured since the previous drain or cut, exactly as appended - not
    /// end-aligned. Mic and system hardware callbacks fire independently, so the two can come back
    /// different lengths on any given tick; end-aligning them here (as this used to do) would
    /// zero-pad the shorter one and shift it relative to the other by a varying amount every ~0.5s,
    /// which is fatal to the echo canceller's reference alignment (see `EchoCanceller.cancelEcho`,
    /// which now carries any such length mismatch as a same-channel remainder instead). The result
    /// is both queued for the next chunk-hotkey cut and returned so the caller can feed it (after
    /// echo cancellation, which this type knows nothing about) to the continuous meeting file.
    mutating func drainRaw() -> (mic: [Int16], system: [Int16]) {
        let mic = pendingMic
        let system = pendingSystem
        pendingMic.removeAll()
        pendingSystem.removeAll()
        return (mic, system)
    }

    /// Queues a (typically echo-cancelled) drain result for the next chunk-hotkey cut.
    mutating func absorb(mic: [Int16], system: [Int16]) {
        chunkPendingMic.append(contentsOf: mic)
        chunkPendingSystem.append(contentsOf: system)
    }

    /// Pulls and clears everything queued since the previous cut (i.e. since the previous
    /// hotkey press or session start). Does not itself drain the raw buffers - callers that
    /// want an up-to-the-moment cut must `drainRaw()` (and `absorb`) first.
    mutating func cutChunkPending() -> (mic: [Int16], system: [Int16]) {
        let mic = chunkPendingMic
        let system = chunkPendingSystem
        chunkPendingMic.removeAll()
        chunkPendingSystem.removeAll()
        return (mic, system)
    }

    /// Read-only peek at what's queued for the next cut - `MeetingAutoSendEvaluator.cutBoundary`'s
    /// starvation fallback scans it for a shared internal pause. Mic and system are always
    /// equal-length here: every writer (`absorb`, and `releasePrefix`/`cutChunkPending` on the way
    /// out) appends both in lockstep.
    var chunkPending: (mic: [Int16], system: [Int16]) { (chunkPendingMic, chunkPendingSystem) }

    /// Releases only the first `sampleCount` samples of what's queued (clamped to what's actually
    /// pending), retaining the rest for the next cut instead of clearing it. Used by
    /// `MeetingAudioCapture.cut()` to hold back the tail of an utterance that's still open at the
    /// moment of the cut, so it lands whole in the next chunk instead of being split across two.
    mutating func releasePrefix(sampleCount: Int) -> (mic: [Int16], system: [Int16], deferredCount: Int) {
        let boundary = min(max(0, sampleCount), chunkPendingMic.count)
        let mic = Array(chunkPendingMic.prefix(boundary))
        let system = Array(chunkPendingSystem.prefix(boundary))
        chunkPendingMic.removeFirst(boundary)
        chunkPendingSystem.removeFirst(boundary)
        return (mic, system, chunkPendingMic.count)
    }
}
