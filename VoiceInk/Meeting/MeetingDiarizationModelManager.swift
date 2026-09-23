import AppKit
import FluidAudio
import Foundation
import os

/// Download/delete/status for the Nemotron 3 diarization model on the AI Models page - a speaker-
/// identification model for Meeting Capture, not a transcription model, so it is deliberately kept
/// out of `TranscriptionModelRegistry`/`FluidAudioModelManager` and can never be selected as the
/// active transcription model. Downloads both presets Meeting Capture uses (`.offline` for the
/// whole-meeting note, `.fast32` for live chunks - see `MeetingDiarizer`) as one user-visible
/// action, reusing `Nemotron3Models.loadFromHuggingFace`'s own cache/resume handling per preset.
@MainActor
final class MeetingDiarizationModelManager: ObservableObject {
    static let shared = MeetingDiarizationModelManager()

    @Published private(set) var downloadStatus: FluidAudioDownloadStatus?
    private var activeDownloadID: UUID?

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MeetingDiarizationModelManager")

    private init() {}

    var isDownloaded: Bool { MeetingDiarizationModels.isDownloaded }
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

        do {
            try await loadPreset(MeetingDiarizationModels.offlineConfig, progressRange: 0..<0.5, downloadID: downloadID)
            try await loadPreset(MeetingDiarizationModels.streamingConfig, progressRange: 0.5..<1.0, downloadID: downloadID)
        } catch {
            logger.error("Nemotron 3 diarization download failed: \(error, privacy: .public)")
        }
    }

    private func loadPreset(_ config: Nemotron3Config, progressRange: Range<Double>, downloadID: UUID) async throws {
        let handler: ProgressHandler = { [weak self] progress in
            Task { @MainActor [weak self] in
                guard let self, self.activeDownloadID == downloadID else { return }
                let span = progressRange.upperBound - progressRange.lowerBound
                let scaled = progressRange.lowerBound + progress.fractionCompleted * span
                self.downloadStatus = FluidAudioDownloadStatus(
                    fractionCompleted: scaled, message: Self.statusMessage(for: progress),
                    isIndeterminate: Self.isIndeterminatePhase(progress.phase))
            }
        }
        _ = try await Nemotron3Models.loadFromHuggingFace(config: config, progressHandler: handler)
    }

    func delete() {
        try? FileManager.default.removeItem(at: MeetingDiarizationModels.cacheDirectory)
    }

    func showInFinder() {
        guard FileManager.default.fileExists(atPath: MeetingDiarizationModels.cacheDirectory.path) else { return }
        NSWorkspace.shared.selectFile(MeetingDiarizationModels.cacheDirectory.path, inFileViewerRootedAtPath: "")
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
