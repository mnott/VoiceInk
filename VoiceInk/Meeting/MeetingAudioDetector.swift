import AVFoundation
import Foundation

/// Recognises a Meeting Capture recording from its audio file alone, so re-transcribing or
/// importing a file whose History `isMeetingRecording` flag was lost (e.g. after deleting and
/// re-importing a recovered recording) still gets the two-channel, speaker-labelled treatment
/// instead of being silently downmixed to mono.
///
/// Conservative rule: a file counts as meeting-layout audio if its name carries the `meeting-`
/// prefix `AudioTranscriptionService`/`MeetingRecordingWriter` give their own files, or if it is
/// exactly stereo at 16 kHz - the layout `MeetingRecordingWriter` always writes (left = mic, right
/// = system) and one generic stereo audio (music, podcasts, video, interviews) essentially never
/// uses, since those are recorded at 44.1/48 kHz.
enum MeetingAudioDetector {
    static func isMeetingLayout(url: URL) -> Bool {
        if url.lastPathComponent.hasPrefix("meeting-") { return true }
        guard let format = try? AVAudioFile(forReading: url).processingFormat else { return false }
        return format.channelCount == 2 && format.sampleRate == Double(MeetingRecordingWriter.sampleRate)
    }
}
