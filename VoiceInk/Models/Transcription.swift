import Foundation
import SwiftData

enum TranscriptionStatus: String, Codable {
    case pending
    case completed
    case failed
    case canceled
}

@Model
final class Transcription {
    static let canceledTranscriptionText = "The transcription was canceled."

    var id: UUID = UUID()
    var text: String = ""
    var enhancedText: String?
    var timestamp: Date = Date()
    var duration: TimeInterval = 0
    var audioFileURL: String?
    var transcriptionModelName: String?
    var aiEnhancementModelName: String?
    var promptName: String?
    var transcriptionDuration: TimeInterval?
    var enhancementDuration: TimeInterval?
    var aiRequestSystemMessage: String?
    var aiRequestUserMessage: String?
    @Attribute(originalName: "powerModeName")
    var modeName: String?
    @Attribute(originalName: "powerModeEmoji")
    var modeEmoji: String?
    var transcriptionStatus: String?
    /// Whether this record is the one continuous, speaker-labelled transcript of a Meeting
    /// Capture session (left = "Me"/mic, right = "Others"/system in `audioFileURL`), rather than
    /// a normal dictation. Defaults to `false` so existing records need no migration.
    var isMeetingRecording: Bool = false
    /// JSON-encoded `[MeetingTurnRecord]` for a meeting recording - `nil` for every non-meeting
    /// record and for meeting records predating this field, both lightweight-migration safe the
    /// same way `isMeetingRecording` is (a new `Optional` stored property with a default). `text`
    /// is rendered from this via `MeetingSpeakerTranscriptRenderer`, not edited directly, once it
    /// is present.
    var meetingTurnsData: Data?
    /// Non-`nil` once the record has been moved to "Recently Deleted" - the record and its audio
    /// are kept (see `TranscriptionTrashService`) until it is restored or purged after
    /// `TranscriptionTrashService.retentionDays`. `nil` for every pre-existing record, lightweight-
    /// migration safe the same way `isMeetingRecording` is.
    var deletedAt: Date?

    var meetingTurns: [MeetingTurnRecord]? {
        get { meetingTurnsData.flatMap { try? JSONDecoder().decode([MeetingTurnRecord].self, from: $0) } }
        set { meetingTurnsData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }

    init(
        text: String,
        duration: TimeInterval,
        enhancedText: String? = nil,
        audioFileURL: String? = nil,
        transcriptionModelName: String? = nil,
        aiEnhancementModelName: String? = nil,
        promptName: String? = nil,
        transcriptionDuration: TimeInterval? = nil,
        enhancementDuration: TimeInterval? = nil,
        aiRequestSystemMessage: String? = nil,
        aiRequestUserMessage: String? = nil,
        modeName: String? = nil,
        modeEmoji: String? = nil,
        transcriptionStatus: TranscriptionStatus = .pending,
        isMeetingRecording: Bool = false
    ) {
        self.id = UUID()
        self.text = text
        self.enhancedText = enhancedText
        self.timestamp = Date()
        self.duration = duration
        self.audioFileURL = audioFileURL
        self.transcriptionModelName = transcriptionModelName
        self.aiEnhancementModelName = aiEnhancementModelName
        self.promptName = promptName
        self.transcriptionDuration = transcriptionDuration
        self.enhancementDuration = enhancementDuration
        self.aiRequestSystemMessage = aiRequestSystemMessage
        self.aiRequestUserMessage = aiRequestUserMessage
        self.modeName = modeName
        self.modeEmoji = modeEmoji
        self.transcriptionStatus = transcriptionStatus.rawValue
        self.isMeetingRecording = isMeetingRecording
    }

    func markAsCanceledTranscription(
        duration: TimeInterval? = nil,
        modelName: String? = nil
    ) {
        text = Self.canceledTranscriptionText
        enhancedText = nil
        transcriptionStatus = TranscriptionStatus.canceled.rawValue
        if let duration {
            self.duration = duration
        }
        if let modelName {
            transcriptionModelName = modelName
        }
        transcriptionDuration = nil
        enhancementDuration = nil
        aiEnhancementModelName = nil
        promptName = nil
        aiRequestSystemMessage = nil
        aiRequestUserMessage = nil
    }
}
