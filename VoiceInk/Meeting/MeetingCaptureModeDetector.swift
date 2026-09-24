import Foundation

/// Which channel Meeting Capture diarizes into individual speakers: the system channel (remote
/// participants of a call) or the microphone (everyone sharing one Mac's mic, in person). Decided
/// once, synchronously, at capture start (see `MeetingAudioCapture.start`) - never re-evaluated
/// mid-session, so labelling never flips partway through a meeting.
enum MeetingCaptureMode: Equatable {
    case twoChannel
    case inPerson
}

/// Picks the simplest robust trigger for `MeetingCaptureMode`: no system tap means there is
/// nothing remote to diarize at all, and an explicit Settings toggle covers the case where a tap
/// is technically open (some other app is playing audio) but the meeting is still in person -
/// both known synchronously at capture start. A delayed "no system-channel speech in the first
/// ~20 s" heuristic was considered and dropped: it would hold every chunk in two-channel mode
/// until the window closed, and a merely-quiet call in its first 20 s would misdiarize the mic as
/// if it were in person. The Settings toggle already covers that case more reliably.
enum MeetingCaptureModeDetector {
    static func mode(isCapturingSystemAudio: Bool, forcedInPersonSetting: Bool) -> MeetingCaptureMode {
        (!isCapturingSystemAudio || forcedInPersonSetting) ? .inPerson : .twoChannel
    }
}
