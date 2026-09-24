import Foundation
import Testing

@testable import VoiceInk

// MARK: - Recognising a Meeting Capture recording from its audio file alone

struct MeetingAudioDetectorTests {
    private func tempURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "MeetingAudioDetectorTests-\(UUID().uuidString)-\(name)")
    }

    /// A minimal, valid PCM WAV file - same header layout as `MeetingRecordingWriter.header` - so
    /// `AVAudioFile(forReading:)` can read back its sample rate and channel count.
    private func writeWAV(to url: URL, sampleRate: UInt32, channels: UInt16) throws {
        let bitsPerSample: UInt16 = 16
        let frameCount: UInt32 = 16
        let blockAlign = channels * (bitsPerSample / 8)
        let byteRate = sampleRate * UInt32(blockAlign)
        let dataSize = frameCount * UInt32(blockAlign)

        func leBytes<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
            withUnsafeBytes(of: value.littleEndian, Array.init)
        }

        var header = [UInt8]()
        header += Array("RIFF".utf8)
        header += leBytes(UInt32(36) + dataSize)
        header += Array("WAVE".utf8)
        header += Array("fmt ".utf8)
        header += leBytes(UInt32(16))
        header += leBytes(UInt16(1))  // PCM
        header += leBytes(channels)
        header += leBytes(sampleRate)
        header += leBytes(byteRate)
        header += leBytes(blockAlign)
        header += leBytes(bitsPerSample)
        header += Array("data".utf8)
        header += leBytes(dataSize)

        var data = Data(header)
        data.append(Data(repeating: 0, count: Int(dataSize)))
        try data.write(to: url)
    }

    @Test func filenamePrefixIsDetectedWithoutReadingTheAudio() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "meeting-\(UUID().uuidString).wav")
        try Data("not audio".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(MeetingAudioDetector.isMeetingLayout(url: url))
    }

    @Test func stereo16kHzIsDetectedAsMeetingLayoutEvenWithAGenericName() throws {
        let url = tempURL("recording.wav")
        try writeWAV(to: url, sampleRate: 16000, channels: 2)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(MeetingAudioDetector.isMeetingLayout(url: url))
    }

    @Test func stereo44kHzIsNotMeetingLayout() throws {
        let url = tempURL("interview.wav")
        try writeWAV(to: url, sampleRate: 44100, channels: 2)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(!MeetingAudioDetector.isMeetingLayout(url: url))
    }

    @Test func mono16kHzIsNotMeetingLayout() throws {
        let url = tempURL("dictation.wav")
        try writeWAV(to: url, sampleRate: 16000, channels: 1)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(!MeetingAudioDetector.isMeetingLayout(url: url))
    }

    @Test func missingFileIsNotMeetingLayout() {
        let url = tempURL("missing.wav")
        #expect(!MeetingAudioDetector.isMeetingLayout(url: url))
    }
}
