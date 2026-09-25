import Foundation

enum MeetingRecordingWriterError: Error, Equatable {
    case cannotOpenFile
    /// The file is not RIFF/WAVE at all - `found` is the leading ASCII the file actually carries.
    case notWaveFile(found: String)
    /// RIFF/WAVE, but its `fmt ` chunk is not stereo 16-bit PCM/float - `found` names what it is.
    case unsupportedFormat(found: String)
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

    /// Where the stereo PCM frames live in a (possibly foreign-written) RIFF/WAVE file: files from
    /// ffmpeg etc. carry extra chunks (`LIST`/`INFO`) before and/or after `data`, so the data chunk
    /// must be found by walking chunks instead of assuming the writer's own 44-byte header.
    struct WAVLayout: Equatable {
        let dataOffset: Int
        let dataByteCount: Int
    }

    /// Parses a RIFF/WAVE header and returns the `data` chunk's span. Verifies the `RIFF`/`WAVE`
    /// magic, walks chunks (id + little-endian UInt32 size, odd sizes padded to even), and rejects
    /// anything that is not stereo 16-bit PCM or IEEE float with a thrown error naming what was
    /// found instead. Only the first few kilobytes are inspected; trailing audio is never touched.
    static func parseWAVLayout(from url: URL) throws -> WAVLayout {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let head = try handle.read(upToCount: 4096), head.count >= 12 else {
            throw MeetingRecordingWriterError.notWaveFile(found: "file too short")
        }
        let bytes = [UInt8](head)

        func ascii(_ range: Range<Int>) -> String {
            String(bytes: bytes[range], encoding: .ascii) ?? "????"
        }
        func leUInt32(_ offset: Int) -> UInt32 {
            UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
        }
        func leUInt16(_ offset: Int) -> UInt16 {
            UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
        }

        guard ascii(0..<4) == "RIFF", ascii(8..<12) == "WAVE" else {
            throw MeetingRecordingWriterError.notWaveFile(found: "leading bytes \"\(ascii(0..<min(4, bytes.count)))\"")
        }

        var format: (code: UInt16, channels: UInt16, bitsPerSample: UInt16)?
        var offset = 12
        while offset + 8 <= bytes.count {
            let id = ascii(offset..<offset + 4)
            let size = Int(leUInt32(offset + 4))
            let content = offset + 8

            if id == "fmt " {
                guard content + 16 <= bytes.count else {
                    throw MeetingRecordingWriterError.unsupportedFormat(found: "truncated fmt chunk")
                }
                format = (leUInt16(content), leUInt16(content + 2), leUInt16(content + 14))
            } else if id == "data" {
                guard let format else {
                    throw MeetingRecordingWriterError.unsupportedFormat(found: "data chunk before fmt chunk")
                }
                guard [1, 3].contains(format.code), format.bitsPerSample == 16, format.channels == 2 else {
                    throw MeetingRecordingWriterError.unsupportedFormat(
                        found:
                        "format code \(format.code), \(format.bitsPerSample)-bit, \(format.channels)-channel"
                    )
                }
                // `size` governs; a truncated file just yields fewer frames (same as the old
                // whole-file read's behaviour for a recording interrupted mid-write).
                let fileEnd = Int((try? handle.seekToEnd()) ?? 0)
                return WAVLayout(dataOffset: content, dataByteCount: min(size, max(0, fileEnd - content)))
            }

            // Odd-sized chunks carry one pad byte that is not counted in `size`.
            offset = content + size + (size % 2)
        }

        throw MeetingRecordingWriterError.notWaveFile(found: "no data chunk")
    }

    /// Reads a stereo WAV written by this type back into its two channels.
    static func readChannels(from url: URL) throws -> (mic: [Int16], system: [Int16]) {
        let data = try Data(contentsOf: url)
        let layout = try parseWAVLayout(from: url)
        guard layout.dataByteCount >= 4 else { return ([], []) }

        let frameCount = layout.dataByteCount / 4
        var mic = [Int16](repeating: 0, count: frameCount)
        var system = [Int16](repeating: 0, count: frameCount)
        let base = data.startIndex + layout.dataOffset
        for i in 0..<frameCount {
            let micOffset = base + i * 4
            mic[i] = data[micOffset..<micOffset + 2].withUnsafeBytes { $0.loadUnaligned(as: Int16.self) }
            system[i] = data[micOffset + 2..<micOffset + 4].withUnsafeBytes { $0.loadUnaligned(as: Int16.self) }
        }
        return (mic, system)
    }

    /// Reads a stereo WAV written by this type back in bounded-size blocks of stereo frames,
    /// without ever loading the whole file into memory - what `MeetingRecordingTranscriber` uses
    /// to process a long meeting a few minutes at a time instead of all at once.
    struct ChannelReader {
        private let handle: FileHandle
        private let endOffset: UInt64

        init?(url: URL) {
            guard
                let handle = try? FileHandle(forReadingFrom: url),
                let layout = try? MeetingRecordingWriter.parseWAVLayout(from: url)
            else { return nil }
            self.handle = handle
            self.endOffset = UInt64(layout.dataOffset) + UInt64(layout.dataByteCount)
            try? handle.seek(toOffset: UInt64(layout.dataOffset))
        }

        /// The next up to `frameCount` stereo frames, or `nil` once the data chunk is exhausted.
        func nextBlock(frameCount: Int) -> (mic: [Int16], system: [Int16])? {
            let offset = (try? handle.offset()) ?? endOffset
            let remainingFrames = Int(max(0, endOffset - offset)) / 4
            guard remainingFrames > 0 else { return nil }
            guard let data = try? handle.read(upToCount: min(frameCount, remainingFrames) * 4), !data.isEmpty else { return nil }
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
