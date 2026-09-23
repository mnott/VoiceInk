import AppKit
import FluidAudio
import Foundation
import os

/// Download/delete/status for FluidAudio's standard diarizer model pair on the AI Models page -
/// used only for speaker fingerprinting (see `MeetingSpeakerEmbedder`), never for transcription or
/// for Meeting Capture's own turn-taking diarization (that is Nemotron 3, managed separately by
/// `MeetingDiarizationModelManager`). Mirrors that manager's structure exactly.
@MainActor
final class MeetingSpeakerEmbeddingModelManager: ObservableObject {
    static let shared = MeetingSpeakerEmbeddingModelManager()

    @Published private(set) var downloadStatus: FluidAudioDownloadStatus?
    private var activeDownloadID: UUID?

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MeetingSpeakerEmbeddingModelManager")

    private init() {}

    var isDownloaded: Bool { MeetingSpeakerEmbeddingModels.isDownloaded }
    var isDownloading: Bool { downloadStatus != nil }

    func download() async {
        guard !isDownloaded, !isDownloading else { return }
        let downloadID = UUID()
        activeDownloadID = downloadID
        downloadStatus = FluidAudioDownloadStatus(fractionCompleted: 0, message: String(localized: "Preparing download..."))
        defer {
            if activeDownloadID == downloadID {
                activeDownloadID = nil
                downloadStatus = nil
            }
        }

        let handler: ProgressHandler = { [weak self] progress in
            Task { @MainActor [weak self] in
                guard let self, self.activeDownloadID == downloadID else { return }
                self.downloadStatus = FluidAudioDownloadStatus(
                    fractionCompleted: progress.fractionCompleted, message: Self.statusMessage(for: progress),
                    isIndeterminate: Self.isIndeterminatePhase(progress.phase))
            }
        }

        do {
            _ = try await DiarizerModels.downloadIfNeeded(progressHandler: handler)
        } catch {
            logger.error("Speaker embedding model download failed: \(error, privacy: .public)")
        }
    }

    func delete() {
        try? FileManager.default.removeItem(at: MeetingSpeakerEmbeddingModels.cacheDirectory)
    }

    func showInFinder() {
        guard FileManager.default.fileExists(atPath: MeetingSpeakerEmbeddingModels.cacheDirectory.path) else { return }
        NSWorkspace.shared.selectFile(MeetingSpeakerEmbeddingModels.cacheDirectory.path, inFileViewerRootedAtPath: "")
    }

    private static func isIndeterminatePhase(_ phase: DownloadPhase) -> Bool {
        if case .compiling(let modelName) = phase { return modelName.isEmpty }
        return false
    }

    private static func statusMessage(for progress: DownloadProgress) -> String {
        switch progress.phase {
        case .listing:
            return String(localized: "Listing files from repository...")
        case .downloading(let completedFiles, let totalFiles):
            guard totalFiles > 0 else { return String(localized: "Checking cached models...") }
            return String(
                format: String(localized: "Downloading model files: %lld/%lld"), Int64(completedFiles), Int64(totalFiles))
        case .compiling(let modelName):
            guard !modelName.isEmpty else { return String(localized: "Finalizing models...") }
            return String(format: String(localized: "Compiling %@"), modelName.replacingOccurrences(of: ".mlmodelc", with: ""))
        }
    }
}
