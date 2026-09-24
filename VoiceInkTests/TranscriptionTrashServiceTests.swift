import Foundation
import Testing

@testable import VoiceInk

// MARK: - Recently Deleted: purge rule, visible/deleted filtering, restore

struct TranscriptionTrashServiceTests {
    private func transcription(deletedAt: Date? = nil, audioFileURL: String? = nil) -> Transcription {
        let transcription = Transcription(text: "hello", duration: 1)
        transcription.deletedAt = deletedAt
        transcription.audioFileURL = audioFileURL
        return transcription
    }

    // MARK: - Purge rule (30 days)

    @Test func recordDeletedLessThanRetentionDaysAgoIsNotExpired() {
        let now = Date()
        let deletedAt = Calendar.current.date(byAdding: .day, value: -29, to: now)!
        #expect(!TranscriptionTrashService.isExpired(deletedAt: deletedAt, now: now))
    }

    @Test func recordDeletedExactlyRetentionDaysAgoIsExpired() {
        let now = Date()
        let deletedAt = Calendar.current.date(byAdding: .day, value: -30, to: now)!
        #expect(TranscriptionTrashService.isExpired(deletedAt: deletedAt, now: now))
    }

    @Test func recordDeletedMoreThanRetentionDaysAgoIsExpired() {
        let now = Date()
        let deletedAt = Calendar.current.date(byAdding: .day, value: -31, to: now)!
        #expect(TranscriptionTrashService.isExpired(deletedAt: deletedAt, now: now))
    }

    // MARK: - Visible/deleted filtering

    @Test func visiblePredicateExcludesDeletedRecords() throws {
        let predicate = TranscriptionTrashService.visiblePredicate()
        #expect(try predicate.evaluate(transcription(deletedAt: nil)))
        #expect(try !predicate.evaluate(transcription(deletedAt: Date())))
    }

    @Test func deletedPredicateOnlyIncludesDeletedRecords() throws {
        let predicate = TranscriptionTrashService.deletedPredicate()
        #expect(try !predicate.evaluate(transcription(deletedAt: nil)))
        #expect(try predicate.evaluate(transcription(deletedAt: Date())))
    }

    // MARK: - Soft delete / restore state transitions

    @Test func softDeleteWithoutAnAudioFileOnlyMarksTheRecordDeleted() {
        let transcription = transcription(audioFileURL: nil)
        TranscriptionTrashService.softDelete(transcription)
        #expect(transcription.deletedAt != nil)
    }

    @Test func restoreWithoutAnAudioFileClearsTheDeletedFlag() {
        let transcription = transcription(deletedAt: Date(), audioFileURL: nil)
        TranscriptionTrashService.restore(transcription)
        #expect(transcription.deletedAt == nil)
    }

    // MARK: - Restore moves the audio file back out of the trash subfolder

    @Test func softDeleteMovesTheAudioFileIntoTheTrashDirectoryAndRestoreMovesItBack() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "TranscriptionTrashServiceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let audioURL = tempDir.appendingPathComponent("clip.wav")
        try Data("fake audio".utf8).write(to: audioURL)

        let transcription = transcription(audioFileURL: audioURL.absoluteString)
        TranscriptionTrashService.softDelete(transcription, recordingsDirectory: tempDir)

        let trashedURL = tempDir.appendingPathComponent(TranscriptionTrashService.trashDirectoryName)
            .appendingPathComponent("clip.wav")
        #expect(transcription.deletedAt != nil)
        #expect(transcription.audioFileURL == trashedURL.absoluteString)
        #expect(FileManager.default.fileExists(atPath: trashedURL.path))
        #expect(!FileManager.default.fileExists(atPath: audioURL.path))

        TranscriptionTrashService.restore(transcription, recordingsDirectory: tempDir)
        #expect(transcription.deletedAt == nil)
        #expect(transcription.audioFileURL == audioURL.absoluteString)
        #expect(FileManager.default.fileExists(atPath: audioURL.path))
        #expect(!FileManager.default.fileExists(atPath: trashedURL.path))
    }

    @Test func restoreIgnoresAnAudioFileThatIsNotInTheTrashDirectory() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "TranscriptionTrashServiceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let audioURL = tempDir.appendingPathComponent("clip.wav")
        try Data("fake audio".utf8).write(to: audioURL)

        // Deleted flag set without ever moving the file (e.g. a record restored twice) - restore
        // should not touch a file that isn't sitting in the trash subfolder.
        let transcription = transcription(deletedAt: Date(), audioFileURL: audioURL.absoluteString)
        TranscriptionTrashService.restore(transcription, recordingsDirectory: tempDir)

        #expect(transcription.deletedAt == nil)
        #expect(transcription.audioFileURL == audioURL.absoluteString)
        #expect(FileManager.default.fileExists(atPath: audioURL.path))
    }
}
