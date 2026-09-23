import Foundation

enum MeetingRecordingWriterError: Error {
    case cannotOpenFile
}

/// Streams the whole-meeting recording (Toggle Meeting Capture start to stop) to disk as one
/// stereo 16 kHz Int16 WAV: left = microphone ("Me"), right = system audio ("Others"). Samples
/// are appended as they arrive (never held in memory for the whole meeting); `finish()` patches
/// the RIFF/data chunk sizes once the final length is known.
///
/// Microphone-only sessions (no system-audio tap) still produce a stereo file with the right
/// channel silent, rather than a mono file, so there is exactly one file format for playback and
/// for `MeetingRecordingTranscriber` to read.
final class MeetingRecordingWriter {
    static let sampleRate: UInt32 = 16000
    static let channels: UInt16 = 2
    static let bitsPerSample: UInt16 = 16

    let url: URL
    private let fileHandle: FileHandle
    private var dataByteCount: UInt64 = 0

    init(url: URL) throws {
        self.url = url
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
            let handle = FileHandle(forWritingAtPath: url.path)
        else {
            throw MeetingRecordingWriterError.cannotOpenFile
        }
        fileHandle = handle
        try fileHandle.write(contentsOf: Self.header(dataSize: 0))
    }

    /// Appends one interleaved chunk. `mic` and `system` must be the same length - callers
    /// always pass end-aligned tracks from the same drain (see `MeetingAudioCapture.alignedEnds`).
    func append(mic: [Int16], system: [Int16]) throws {
        guard !mic.isEmpty else { return }

        var interleaved = [Int16](repeating: 0, count: mic.count * 2)
        for i in 0..<mic.count {
            interleaved[i * 2] = mic[i]
            interleaved[i * 2 + 1] = system[i]
        }

        var data = Data()
        interleaved.withUnsafeBufferPointer { data.append(contentsOf: UnsafeRawBufferPointer($0)) }
        try fileHandle.write(contentsOf: data)
        dataByteCount += UInt64(data.count)
    }

    /// Patches the RIFF/data chunk sizes now that the final size is known, and closes the file.
    func finish() throws {
        try fileHandle.seek(toOffset: 0)
        try fileHandle.write(contentsOf: Self.header(dataSize: dataByteCount))
        try fileHandle.close()
    }

    private static func header(dataSize: UInt64) -> Data {
        let blockAlign = channels * (bitsPerSample / 8)
        let byteRate = sampleRate * UInt32(blockAlign)
        let clampedDataSize = UInt32(truncatingIfNeeded: dataSize)

        var header = [UInt8]()
        header.append(contentsOf: Array("RIFF".utf8))
        header.append(contentsOf: MeetingAudioCapture.leBytes(UInt32(36) &+ clampedDataSize))
        header.append(contentsOf: Array("WAVE".utf8))
        header.append(contentsOf: Array("fmt ".utf8))
        header.append(contentsOf: MeetingAudioCapture.leBytes(UInt32(16)))
        header.append(contentsOf: MeetingAudioCapture.leBytes(UInt16(1)))  // PCM
        header.append(contentsOf: MeetingAudioCapture.leBytes(channels))
        header.append(contentsOf: MeetingAudioCapture.leBytes(sampleRate))
        header.append(contentsOf: MeetingAudioCapture.leBytes(byteRate))
        header.append(contentsOf: MeetingAudioCapture.leBytes(blockAlign))
        header.append(contentsOf: MeetingAudioCapture.leBytes(bitsPerSample))
        header.append(contentsOf: Array("data".utf8))
        header.append(contentsOf: MeetingAudioCapture.leBytes(clampedDataSize))
        return Data(header)
    }

    /// Reads a stereo WAV written by this type back into its two channels.
    static func readChannels(from url: URL) throws -> (mic: [Int16], system: [Int16]) {
        let data = try Data(contentsOf: url)
        guard data.count > 44 else { return ([], []) }

        let frameCount = (data.count - 44) / 4
        var mic = [Int16](repeating: 0, count: frameCount)
        var system = [Int16](repeating: 0, count: frameCount)
        for i in 0..<frameCount {
            let micOffset = 44 + i * 4
            let systemOffset = micOffset + 2
            mic[i] = data[micOffset..<micOffset + 2].withUnsafeBytes { $0.loadUnaligned(as: Int16.self) }
            system[i] = data[systemOffset..<systemOffset + 2].withUnsafeBytes { $0.loadUnaligned(as: Int16.self) }
        }
        return (mic, system)
    }

    /// Reads a stereo WAV written by this type back in bounded-size blocks of stereo frames,
    /// without ever loading the whole file into memory - what `MeetingRecordingTranscriber` uses
    /// to process a long meeting a few minutes at a time instead of all at once.
    struct ChannelReader {
        private let handle: FileHandle

        init?(url: URL) {
            guard let handle = FileHandle(forReadingAtPath: url.path) else { return nil }
            self.handle = handle
            try? handle.seek(toOffset: 44)
        }

        /// The next up to `frameCount` stereo frames, or `nil` once the file is exhausted.
        func nextBlock(frameCount: Int) -> (mic: [Int16], system: [Int16])? {
            guard let data = try? handle.read(upToCount: frameCount * 4), !data.isEmpty else { return nil }
            let count = data.count / 4
            var mic = [Int16](repeating: 0, count: count)
            var system = [Int16](repeating: 0, count: count)
            for i in 0..<count {
                let base = data.startIndex + i * 4
                mic[i] = data[base..<base + 2].withUnsafeBytes { $0.loadUnaligned(as: Int16.self) }
                system[i] = data[base + 2..<base + 4].withUnsafeBytes { $0.loadUnaligned(as: Int16.self) }
            }
            return (mic, system)
        }

        func close() {
            try? handle.close()
        }
    }
}
