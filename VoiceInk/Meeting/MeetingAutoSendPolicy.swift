import Foundation

/// Decides when Meeting Capture should send a chunk on its own, without a hotkey press, once
/// "Send chunks automatically" is on. Pure and stateless so the trigger boundary is unit-testable
/// without a running audio capture.
enum MeetingAutoSendPolicy {
    /// A chunk is not sent before at least this much speech (either channel) has accumulated
    /// since the last one - a few words is not worth a chunk.
    static let minimumSpeechSecondsSinceLastChunk: TimeInterval = 5
    /// Once there is enough speech, sending waits for both channels to have been silent this
    /// long - a natural turn boundary rather than cutting someone off mid-sentence.
    static let requiredTrailingSilenceSeconds: TimeInterval = 1.5
    /// If no such pause happens (a long uninterrupted monologue), send anyway rather than let a
    /// chunk grow without bound.
    static let maximumSecondsSinceLastChunk: TimeInterval = 60

    static func shouldSend(
        speechSecondsSinceLastChunk: TimeInterval,
        currentSilenceDuration: TimeInterval,
        secondsSinceLastChunk: TimeInterval
    ) -> Bool {
        if secondsSinceLastChunk >= maximumSecondsSinceLastChunk {
            return true
        }

        guard speechSecondsSinceLastChunk >= minimumSpeechSecondsSinceLastChunk else {
            return false
        }

        return currentSilenceDuration >= requiredTrailingSilenceSeconds
    }
}

/// Accumulates the three inputs `MeetingAutoSendPolicy.shouldSend` needs, tick by tick, between
/// chunk deliveries. Kept separate from the policy itself so the decision boundary stays a pure
/// function while this does the (equally simple, but stateful) bookkeeping.
///
/// Both `speechSeconds` and `silenceDuration` are frame-resolution measurements computed by the
/// caller from `MeetingVAD` state (see `MeetingAutoSendEvaluator.step`), not tick-level booleans:
/// silence is accounted as the actual time since the last voiced frame, so a pause is measured
/// correctly however many 1 s drain ticks it spans and regardless of `MeetingVAD`'s ~500 ms
/// hangover, which used to keep a whole tick misclassified as "speech" long after the talking
/// stopped.
struct MeetingAutoSendTracker {
    private(set) var speechSecondsSinceLastChunk: TimeInterval = 0
    private(set) var currentSilenceDuration: TimeInterval = 0
    private(set) var secondsSinceLastChunk: TimeInterval = 0

    mutating func recordTick(duration: TimeInterval, speechSeconds: TimeInterval, silenceDuration: TimeInterval) {
        secondsSinceLastChunk += duration
        speechSecondsSinceLastChunk += speechSeconds
        currentSilenceDuration = silenceDuration
    }

    mutating func resetAfterChunkSent() {
        speechSecondsSinceLastChunk = 0
        currentSilenceDuration = 0
        secondsSinceLastChunk = 0
    }
}
