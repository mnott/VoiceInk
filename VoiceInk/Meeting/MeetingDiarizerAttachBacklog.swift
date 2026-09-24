import Foundation

/// Buffers samples absorbed on one channel while its `MeetingDiarizer`'s async model load is
/// still in flight, so the diarizer's own sample 0 lines up with the session's sample 0 once it
/// attaches instead of starting `startCollecting()`-to-attach seconds late - see
/// `MeetingAudioCapture.absorbAndWrite`/`startSystemDiarizerIfEnabled`. Pure/no I/O so the
/// ordering guarantees below are unit-testable without a real model.
/// ponytail: no size cap - at ~32 KB/s (16 kHz mono Int16) even a slow cold CoreML load (a few
/// seconds) is a trivial amount to hold; cap it if a diarizer is ever left unattached for minutes.
struct MeetingDiarizerAttachBacklog {
    private var samples: [Int16] = []
    private(set) var isCollecting = false

    /// Call once the diarizer's model load has actually started, before any more samples can be
    /// absorbed - a no-op before this (and after `drain()`/`discard()`) so nothing is buffered
    /// for a diarizer that was never requested or has already attached.
    mutating func startCollecting() {
        isCollecting = true
    }

    mutating func absorb(_ newSamples: [Int16]) {
        guard isCollecting else { return }
        samples.append(contentsOf: newSamples)
    }

    /// Everything absorbed since `startCollecting()`, in order - call once, when the diarizer
    /// attaches, and feed the result to `append` before any further live samples.
    mutating func drain() -> [Int16] {
        isCollecting = false
        let drained = samples
        samples = []
        return drained
    }

    /// The load failed, or the session stopped before it finished - stop collecting and drop
    /// whatever was buffered, since there is no diarizer left to replay it into.
    mutating func discard() {
        isCollecting = false
        samples = []
    }
}
