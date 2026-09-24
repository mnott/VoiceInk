import Foundation
import SwiftData

/// "Recently Deleted" for History: deleting a `Transcription` (manually or via retention/auto-
/// cleanup) moves it here instead of removing it outright, so an accidental delete - metadata and
/// audio - can be undone. Records are purged for good, audio included, once they are older than
/// `retentionDays`.
enum TranscriptionTrashService {
    static let retentionDays = 30
    static let trashDirectoryName = "RecentlyDeleted"

    private static var recordingsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.prakashjoshipax.VoiceInk")
            .appendingPathComponent("Recordings")
    }

    static var trashDirectory: URL {
        recordingsDirectory.appendingPathComponent(trashDirectoryName)
    }

    // MARK: - Visibility

    /// Every normal History list/query should use this - records with a `deletedAt` are only
    /// shown in "Recently Deleted".
    static func visiblePredicate() -> Predicate<Transcription> {
        #Predicate<Transcription> { $0.deletedAt == nil }
    }

    static func deletedPredicate() -> Predicate<Transcription> {
        #Predicate<Transcription> { $0.deletedAt != nil }
    }

    // MARK: - Purge rule

    /// Pure: whether a record soft-deleted at `deletedAt` is old enough to purge as of `now`.
    static func isExpired(deletedAt: Date, now: Date = Date(), retentionDays: Int = retentionDays) -> Bool {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: retentionDays, to: deletedAt) else {
            return false
        }
        return now >= cutoff
    }

    // MARK: - Actions

    /// Moves the audio file into the trash subfolder (if it exists) and marks the record deleted;
    /// the record itself is kept so "Recently Deleted" can list and restore it.
    static func softDelete(_ transcription: Transcription, recordingsDirectory: URL = Self.recordingsDirectory) {
        let trashDir = recordingsDirectory.appendingPathComponent(trashDirectoryName)
        if let urlString = transcription.audioFileURL,
            let url = URL(string: urlString),
            FileManager.default.fileExists(atPath: url.path)
        {
            try? FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
            let trashedURL = trashDir.appendingPathComponent(url.lastPathComponent)
            if (try? FileManager.default.moveItem(at: url, to: trashedURL)) != nil {
                transcription.audioFileURL = trashedURL.absoluteString
            }
        }
        transcription.deletedAt = Date()
    }

    /// Moves the audio file back out of the trash subfolder (if it is there) and clears the
    /// deleted flag.
    static func restore(_ transcription: Transcription, recordingsDirectory: URL = Self.recordingsDirectory) {
        let trashDir = recordingsDirectory.appendingPathComponent(trashDirectoryName)
        if let urlString = transcription.audioFileURL,
            let url = URL(string: urlString),
            url.deletingLastPathComponent().standardizedFileURL == trashDir.standardizedFileURL,
            FileManager.default.fileExists(atPath: url.path)
        {
            let restoredURL = recordingsDirectory.appendingPathComponent(url.lastPathComponent)
            if (try? FileManager.default.moveItem(at: url, to: restoredURL)) != nil {
                transcription.audioFileURL = restoredURL.absoluteString
            }
        }
        transcription.deletedAt = nil
    }

    /// Deletes the audio file (wherever it currently lives) and the record itself, for good.
    static func permanentlyDelete(_ transcription: Transcription, modelContext: ModelContext) {
        if let urlString = transcription.audioFileURL,
            let url = URL(string: urlString),
            FileManager.default.fileExists(atPath: url.path)
        {
            try? FileManager.default.removeItem(at: url)
        }
        modelContext.delete(transcription)
    }

    /// Permanently deletes every "Recently Deleted" record older than `retentionDays`. Safe to
    /// call at launch and periodically - a no-op when nothing is expired.
    static func purgeExpired(modelContext: ModelContext, now: Date = Date()) {
        guard
            let candidates = try? modelContext.fetch(
                FetchDescriptor<Transcription>(predicate: deletedPredicate()))
        else { return }

        var purgedCount = 0
        for transcription in candidates {
            guard let deletedAt = transcription.deletedAt, isExpired(deletedAt: deletedAt, now: now) else { continue }
            permanentlyDelete(transcription, modelContext: modelContext)
            purgedCount += 1
        }
        if purgedCount > 0 {
            try? modelContext.save()
        }
    }
}
