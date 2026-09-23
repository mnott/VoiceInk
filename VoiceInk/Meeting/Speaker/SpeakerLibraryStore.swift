import Foundation
import os

/// Local, persistent store for the speaker library: one JSON file for every `SpeakerVoice`
/// (without its clips) plus a `Clips` subdirectory of short WAV samples, both in Application
/// Support - the same base directory `MeetingDiarizationModels` uses for its model cache. Loaded
/// once and kept in memory; every mutation re-serializes the whole (small - one entry per distinct
/// voice ever heard) list to disk.
@MainActor
final class SpeakerLibraryStore: ObservableObject {
    static let shared = SpeakerLibraryStore()

    @Published private(set) var voices: [SpeakerVoice] = []

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "SpeakerLibraryStore")

    static var directory: URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        return base.appendingPathComponent("com.prakashjoshipax.VoiceInk").appendingPathComponent(
            "SpeakerLibrary", isDirectory: true)
    }

    static var clipsDirectory: URL { directory.appendingPathComponent("Clips", isDirectory: true) }
    private static var indexURL: URL { directory.appendingPathComponent("speakers.json") }

    private init() {
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.indexURL),
            let decoded = try? JSONDecoder().decode([SpeakerVoice].self, from: data)
        else { return }
        voices = decoded
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(voices)
            try data.write(to: Self.indexURL, options: .atomic)
        } catch {
            logger.error("Failed to save speaker library: \(error, privacy: .public)")
        }
    }

    func voice(for id: String) -> SpeakerVoice? { voices.first { $0.id == id } }

    func name(for id: String) -> String? { voice(for: id)?.name }

    /// Registers a brand-new voice from its first embedding, returning its freshly generated id.
    @discardableResult
    func registerVoice(embedding: [Float], clipSamples: [Int16]?, meetingID: UUID) -> SpeakerVoice {
        let id = SpeakerMatching.generateID(excluding: Set(voices.map(\.id)))
        let now = Date()
        var voice = SpeakerVoice(
            id: id, name: nil, embedding: embedding, embeddingCount: 1, sampleClipFileNames: [], firstHeard: now,
            lastHeard: now, meetingIDs: [meetingID])
        if let clipSamples, let fileName = saveClip(clipSamples, voiceID: id, index: 0) {
            voice.sampleClipFileNames = [fileName]
        }
        voices.append(voice)
        save()
        return voice
    }

    /// Updates a matched voice's running-average embedding, `lastHeard`, meeting membership, and -
    /// while it still has fewer than 3 samples - its clip set.
    func recordMatch(id: String, embedding: [Float], clipSamples: [Int16]?, meetingID: UUID) {
        guard let index = voices.firstIndex(where: { $0.id == id }) else { return }
        voices[index].embedding = SpeakerMatching.averaging(
            existing: voices[index].embedding, count: voices[index].embeddingCount, new: embedding)
        voices[index].embeddingCount += 1
        voices[index].lastHeard = Date()
        if !voices[index].meetingIDs.contains(meetingID) { voices[index].meetingIDs.append(meetingID) }
        if voices[index].sampleClipFileNames.count < 3, let clipSamples,
            let fileName = saveClip(clipSamples, voiceID: id, index: voices[index].sampleClipFileNames.count)
        {
            voices[index].sampleClipFileNames.append(fileName)
        }
        save()
    }

    func rename(id: String, to name: String?) {
        guard let index = voices.firstIndex(where: { $0.id == id }) else { return }
        voices[index].name = (name?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
        save()
    }

    /// Merges `sourceID` into `targetID` in the library only - callers (see
    /// `SpeakerLibraryService`) are responsible for remapping every meeting record's turns from
    /// `sourceID` to `targetID` and re-rendering their text.
    func merge(sourceID: String, intoTargetID targetID: String) {
        guard sourceID != targetID, let sourceIndex = voices.firstIndex(where: { $0.id == sourceID }),
            let targetIndex = voices.firstIndex(where: { $0.id == targetID })
        else { return }
        let merged = SpeakerMatching.merge(source: voices[sourceIndex], into: voices[targetIndex])
        deleteClips(for: voices[sourceIndex])
        voices[targetIndex] = merged
        voices.remove(at: sourceIndex)
        save()
    }

    func delete(id: String) {
        guard let index = voices.firstIndex(where: { $0.id == id }) else { return }
        deleteClips(for: voices[index])
        voices.remove(at: index)
        save()
    }

    func deleteAll() {
        for voice in voices { deleteClips(for: voice) }
        voices.removeAll()
        save()
    }

    func clipURL(for fileName: String) -> URL { Self.clipsDirectory.appendingPathComponent(fileName) }

    private func deleteClips(for voice: SpeakerVoice) {
        for fileName in voice.sampleClipFileNames {
            try? FileManager.default.removeItem(at: clipURL(for: fileName))
        }
    }

    private func saveClip(_ samples: [Int16], voiceID: String, index: Int) -> String? {
        let fileName = "\(voiceID)-\(index).wav"
        do {
            try FileManager.default.createDirectory(at: Self.clipsDirectory, withIntermediateDirectories: true)
            try MeetingAudioCapture.writeWAV(samples, to: clipURL(for: fileName))
            return fileName
        } catch {
            logger.error("Failed to save speaker sample clip: \(error, privacy: .public)")
            return nil
        }
    }
}
