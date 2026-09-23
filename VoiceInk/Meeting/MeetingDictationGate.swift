import Foundation

/// Silences the mic channel while a normal (non-meeting) dictation recording is in flight, so
/// Meeting Capture - which taps the same microphone independently - never picks up a private
/// dictation to the AI a second time as a "Me:" meeting chunk or a line in the whole-meeting note.
/// The system channel is never touched: only the mic side can ever contain that dictation's audio.
enum MeetingDictationGate {
    static func silenceMicDuringDictation(_ mic: [Int16], isDictationActive: Bool) -> [Int16] {
        guard isDictationActive else { return mic }
        return [Int16](repeating: 0, count: mic.count)
    }
}
