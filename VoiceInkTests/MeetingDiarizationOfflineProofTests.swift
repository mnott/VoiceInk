import AVFAudio
import FluidAudio
import Testing

@testable import VoiceInk

/// Empirical proof, not a regression test: runs both the live (streaming, fed in 0.5 s blocks -
/// mirrors `MeetingAudioCapture`'s drain tick) and offline diarizer paths on a real synthetic
/// 3-voice recording, prints the labelled turns against a hand-authored ground truth timeline,
/// and checks every ground-truth line is covered by some labelled region - i.e. that
/// `MeetingDiarizationLabeler` (WHAT stays VAD's job) never drops speech regardless of where the
/// diarizer's own segment boundaries land. No-ops (silently) if the fixture or downloaded models
/// aren't present, since neither ships with the repo.
struct MeetingDiarizationOfflineProofTests {
    // Not private: reused by MeetingRecordedAudioDiarizationTests to score a real recording's
    // diarized segments against the same hand-authored ground truth.
    struct TruthLine {
        let start: Double
        let end: Double
        let speaker: String
        let text: String
    }

    @Test func streamingAndOfflinePathsCoverGroundTruthWithoutDroppingSpeech() async throws {
        guard let truth = Self.loadTruth(), let samples = Self.loadMono16k("/tmp/vi-test/dialogue.wav"),
            MeetingDiarizationModels.isDownloaded
        else {
            print("MeetingDiarizationOfflineProofTests: fixture or models not present, skipping")
            return
        }

        var report = ""
        func log(_ s: String) {
            print(s)
            report += s + "\n"
        }
        defer { try? report.write(toFile: "/tmp/vi-test/proof-report.txt", atomically: true, encoding: .utf8) }

        let (vadRegions, _) = MeetingVAD.regionsAndEndingNoiseFloor(for: samples)
        let vadSpeechSamples = vadRegions.reduce(0) { $0 + ($1.end - $1.start) }
        log("VAD speech regions: \(vadRegions.count), total \(Double(vadSpeechSamples) / 16000)s")

        guard let streamingDiarizer = await MeetingDiarizer.makeIfAvailable(config: MeetingDiarizationModels.streamingConfig)
        else {
            log("MeetingDiarizationOfflineProofTests: streaming model failed to load, skipping")
            return
        }
        var i = 0
        let feedBlockSamples = 8000  // 0.5 s @ 16 kHz - same granularity as MeetingAudioCapture's drain tick
        while i < samples.count {
            let end = min(i + feedBlockSamples, samples.count)
            streamingDiarizer.append(Array(samples[i..<end]))
            i = end
        }
        streamingDiarizer.finish()
        let streamingSegments = streamingDiarizer.attribute(chunkStartGlobal: 0, chunkEndGlobal: samples.count).regions

        guard let offlineDiarizer = await MeetingDiarizer.makeIfAvailable(config: MeetingDiarizationModels.offlineConfig)
        else {
            log("MeetingDiarizationOfflineProofTests: offline model failed to load, skipping")
            return
        }
        offlineDiarizer.append(samples)
        offlineDiarizer.finish()
        let offlineSegments = offlineDiarizer.attribute(chunkStartGlobal: 0, chunkEndGlobal: samples.count).regions

        for (label, segments) in [("streaming (0.5s blocks)", streamingSegments), ("offline", offlineSegments)] {
            log("=== \(label) ===")
            log("--- raw diarizer segments ---")
            for s in segments {
                log("  speaker \(s.speaker): \(Double(s.start) / 16000)s - \(Double(s.end) / 16000)s")
            }

            var offsets: [Double] = []
            for line in truth {
                let lineStartSample = Int(line.start * 16000)
                if let nearest = segments.min(by: { abs($0.start - lineStartSample) < abs($1.start - lineStartSample) }) {
                    let offset = Double(nearest.start - lineStartSample) / 16000
                    offsets.append(offset)
                }
            }
            if !offsets.isEmpty {
                let mean = offsets.reduce(0, +) / Double(offsets.count)
                log("mean(nearest segment start - ground truth start) = \(mean)s over \(offsets.count) lines")
            }

            let (labelledRegions, labelledSpeakers) = MeetingDiarizationLabeler.label(
                vadRegions: vadRegions, diarizedSegments: segments, samples: samples,
                speakerForSlot: { .other($0) }, noSpeaker: .others)

            log("--- labelled turns ---")
            for (region, speaker) in zip(labelledRegions, labelledSpeakers) {
                log("  [\(Double(region.start) / 16000)s - \(Double(region.end) / 16000)s] \(Self.describe(speaker))")
            }

            var uncovered = 0
            for line in truth {
                let s = Int(line.start * 16000)
                let e = Int(line.end * 16000)
                let covered = labelledRegions.contains { max($0.start, s) < min($0.end, e) }
                if !covered {
                    uncovered += 1
                    log("  MISSING ground truth line \(line.speaker) [\(line.start)-\(line.end)]: \(line.text)")
                }
            }
            log("\(label): \(truth.count - uncovered)/\(truth.count) ground-truth lines covered")

            // Nothing is ever dropped: the labeller's regions always cover exactly what VAD heard.
            let labelledSamples = labelledRegions.reduce(0) { $0 + ($1.end - $1.start) }
            #expect(labelledSamples == vadSpeechSamples)
            #expect(uncovered == 0)

            let accuracy = Self.labelAccuracy(truth: truth, regions: labelledRegions, speakers: labelledSpeakers)
            log("--- per-line accuracy (truth, majority id, id maps to, correct?) ---")
            for (truthSpeaker, id, mapped, isCorrect) in accuracy.lines {
                log("  \(truthSpeaker) -> id \(id) -> \(mapped ?? "?") \(isCorrect ? "OK" : "WRONG")")
            }
            log(
                "\(label): \(accuracy.correct)/\(truth.count) lines labelled correctly (majority-mapped), \(accuracy.distinctIds) distinct speaker ids"
            )
            if label.hasPrefix("streaming") {
                #expect(accuracy.correct >= 11)
                #expect(accuracy.danielIds.isDisjoint(with: accuracy.femaleIds))
            }
        }
    }

    /// End-to-end proof for `MeetingDiarizerAttachBacklog`: simulates a diarizer that only attaches
    /// after 3 s of session audio has already been absorbed (a realistic cold CoreML load), the
    /// way `MeetingAudioCapture.startSystemDiarizerIfEnabled` does. Without the backlog, the
    /// diarizer's sample 0 is really session sample 48000, so every segment `attribute()` reports
    /// (which treats segment offsets as session-global) comes out 3 s too early. With the backlog
    /// replayed on attach first, segment offsets - and therefore labelling accuracy - match the
    /// no-delay baseline in `streamingAndOfflinePathsCoverGroundTruthWithoutDroppingSpeech`.
    @Test func attachingAfterThreeSecondsOfAbsorbedAudioNeedsTheBacklogToKeepSegmentsAlignedToSessionTime() async throws {
        guard let truth = Self.loadTruth(), let samples = Self.loadMono16k("/tmp/vi-test/dialogue.wav"),
            MeetingDiarizationModels.isDownloaded
        else {
            print("MeetingDiarizationOfflineProofTests: fixture or models not present, skipping")
            return
        }

        var report = ""
        func log(_ s: String) {
            print(s)
            report += s + "\n"
        }
        defer { try? report.write(toFile: "/tmp/vi-test/attach-backlog-proof-report.txt", atomically: true, encoding: .utf8) }

        let attachDelaySamples = 3 * 16000
        let feedBlockSamples = 8000  // 0.5 s, matching MeetingAudioCapture's drain tick

        // `useBacklog: false` never calls `startCollecting()`, so `backlog.absorb` below is a
        // no-op and every block before the attach delay is simply never fed to the diarizer -
        // exactly what `MeetingAudioCapture.absorbAndWrite` used to do while `systemDiarizer` was
        // still `nil`.
        func run(useBacklog: Bool) async -> (regions: [MeetingVAD.Region], speakers: [MeetingTurnBuilder.Speaker]) {
            guard let diarizer = await MeetingDiarizer.makeIfAvailable(config: MeetingDiarizationModels.streamingConfig)
            else { fatalError("model unavailable despite the isDownloaded guard above") }

            var backlog = MeetingDiarizerAttachBacklog()
            if useBacklog { backlog.startCollecting() }
            var attached = false
            var i = 0
            while i < samples.count {
                let end = min(i + feedBlockSamples, samples.count)
                let block = Array(samples[i..<end])
                if !attached, i < attachDelaySamples {
                    backlog.absorb(block)
                } else {
                    if !attached {
                        attached = true
                        let backlogged = backlog.drain()
                        if !backlogged.isEmpty { diarizer.append(backlogged) }
                    }
                    diarizer.append(block)
                }
                i = end
            }
            diarizer.finish()
            let segments = diarizer.attribute(chunkStartGlobal: 0, chunkEndGlobal: samples.count).regions

            let (vadRegions, _) = MeetingVAD.regionsAndEndingNoiseFloor(for: samples)
            return MeetingDiarizationLabeler.label(
                vadRegions: vadRegions, diarizedSegments: segments, samples: samples,
                speakerForSlot: { .other($0) }, noSpeaker: .others)
        }

        let withoutBacklog = await run(useBacklog: false)
        let withBacklog = await run(useBacklog: true)

        let accuracyWithoutBacklog = Self.labelAccuracy(
            truth: truth, regions: withoutBacklog.regions, speakers: withoutBacklog.speakers)
        let accuracyWithBacklog = Self.labelAccuracy(
            truth: truth, regions: withBacklog.regions, speakers: withBacklog.speakers)

        log(
            "attach-after-3s WITHOUT backlog: \(accuracyWithoutBacklog.correct)/\(truth.count) lines correct, \(accuracyWithoutBacklog.distinctIds) distinct ids"
        )
        log(
            "attach-after-3s WITH backlog: \(accuracyWithBacklog.correct)/\(truth.count) lines correct, \(accuracyWithBacklog.distinctIds) distinct ids"
        )

        // The bug: losing the first 3 s of audio measurably hurts accuracy relative to feeding it
        // through the backlog.
        #expect(accuracyWithoutBacklog.correct < accuracyWithBacklog.correct)
        // The fix: replaying the backlog on attach recovers (at least) the same accuracy the
        // streaming path gets with no attach delay at all.
        #expect(accuracyWithBacklog.correct >= 11)
    }

    /// Proof for the "swallowed interjection" bug: a short interjection from a second speaker with
    /// no >=200ms pause before/after it (spliced into a <80ms gap, or genuinely overlapping the
    /// other speaker's tail by ~150ms) used to be labelled with the majority (monologue) speaker
    /// for the whole enclosing VAD region. Only the streaming path is checked here (the fixture's
    /// point is the labeller's pause/overlap handling, not the diarizer's raw accuracy).
    @Test func streamingPathAttributesShortInterjectionsWithoutClearPauses() async throws {
        guard let truth = Self.loadTruth(path: "/tmp/vi-test/interjections.tsv"),
            let samples = Self.loadMono16k("/tmp/vi-test/interjections.wav"), MeetingDiarizationModels.isDownloaded
        else {
            print("MeetingDiarizationOfflineProofTests: interjections fixture or models not present, skipping")
            return
        }

        var report = ""
        func log(_ s: String) {
            print(s)
            report += s + "\n"
        }
        defer { try? report.write(toFile: "/tmp/vi-test/interjection-report.txt", atomically: true, encoding: .utf8) }

        let (vadRegions, _) = MeetingVAD.regionsAndEndingNoiseFloor(for: samples)
        let vadSpeechSamples = vadRegions.reduce(0) { $0 + ($1.end - $1.start) }
        log("VAD speech regions: \(vadRegions.count), total \(Double(vadSpeechSamples) / 16000)s")

        guard let diarizer = await MeetingDiarizer.makeIfAvailable(config: MeetingDiarizationModels.streamingConfig)
        else {
            log("MeetingDiarizationOfflineProofTests: streaming model failed to load, skipping")
            return
        }
        var i = 0
        let feedBlockSamples = 8000  // 0.5 s @ 16 kHz - same granularity as MeetingAudioCapture's drain tick
        while i < samples.count {
            let end = min(i + feedBlockSamples, samples.count)
            diarizer.append(Array(samples[i..<end]))
            i = end
        }
        diarizer.finish()
        let segments = diarizer.attribute(chunkStartGlobal: 0, chunkEndGlobal: samples.count).regions

        let (labelledRegions, labelledSpeakers) = MeetingDiarizationLabeler.label(
            vadRegions: vadRegions, diarizedSegments: segments, samples: samples,
            speakerForSlot: { .other($0) }, noSpeaker: .others)

        let labelledSamples = labelledRegions.reduce(0) { $0 + ($1.end - $1.start) }
        log("labelled samples == VAD speech samples: \(labelledSamples == vadSpeechSamples)")
        #expect(labelledSamples == vadSpeechSamples)

        let accuracy = Self.labelAccuracy(truth: truth, regions: labelledRegions, speakers: labelledSpeakers)
        log("--- per ground-truth line: speaker, majority id, mapped group, correct? ---")
        var interjectionsCorrect = 0
        var interjectionsTotal = 0
        for (line, (truthSpeaker, id, mapped, isCorrect)) in zip(truth, accuracy.lines) {
            let isInterjection = line.end - line.start < 3.0 && line.speaker != "Daniel"
            if isInterjection {
                interjectionsTotal += 1
                if isCorrect { interjectionsCorrect += 1 }
            }
            log(
                "  [\(line.start)-\(line.end)] \(truthSpeaker) (\(line.text.prefix(30))) -> id \(id) -> \(mapped ?? "?") \(isCorrect ? "OK" : "WRONG")"
            )
        }
        log("interjections attributed to the female id: \(interjectionsCorrect)/\(interjectionsTotal)")
        #expect(interjectionsCorrect >= 3)

        // Per-id -> group, derived the same way labelAccuracy's internal idToGroup is (majority
        // truth-line vote per id) - needed here because femaleIds/danielIds are just the sets of
        // ids that *ever* won a non-Daniel/Daniel line, which is misleading once an id wins lines
        // from both groups (exactly the failure this fixture is meant to catch).
        var idToGroup: [Int: String] = [:]
        for (truthSpeaker, id, mapped, _) in accuracy.lines {
            idToGroup[id] = mapped ?? Self.voiceGroup(truthSpeaker)
        }

        var monologueLinesBrokenOverOneSecond = 0
        for line in truth where line.speaker == "Daniel" {
            let lineStart = Int(line.start * 16000)
            let lineEnd = Int(line.end * 16000)
            var wrongGroupSamples = 0
            for (region, speaker) in zip(labelledRegions, labelledSpeakers) {
                let start = max(region.start, lineStart)
                let end = min(region.end, lineEnd)
                guard end > start else { continue }
                if idToGroup[Self.idKey(speaker)] == "female" { wrongGroupSamples += end - start }
            }
            let wrongSeconds = Double(wrongGroupSamples) / 16000
            if wrongSeconds > 1.0 {
                monologueLinesBrokenOverOneSecond += 1
                log("  MONOLOGUE BROKEN >1s: [\(line.start)-\(line.end)] \(wrongSeconds)s labelled as the female id")
            }
        }
        log("monologue lines broken into the wrong speaker for >1s: \(monologueLinesBrokenOverOneSecond)")
        #expect(monologueLinesBrokenOverOneSecond == 0)
    }

    private static func describe(_ speaker: MeetingTurnBuilder.Speaker) -> String {
        switch speaker {
        case .me: return "Me"
        case .other(nil): return "Others"
        case .other(let index?): return "Speaker \(index + 1)"
        case .otherMic(nil): return "Others (mic)"
        case .otherMic(let index?): return "Mic speaker \(index + 1)"
        }
    }

    // Not private: this is `labelAccuracy`'s return type, reused by MeetingRecordedAudioDiarizationTests.
    struct LabelAccuracy {
        let correct: Int
        let distinctIds: Int
        let danielIds: Set<Int>
        let femaleIds: Set<Int>
        let lines: [(truth: String, id: Int, mappedTruth: String?, correct: Bool)]
    }

    /// `.other(idx)` -> `idx`, `.others`/`.me` (never produced for the system channel here) -> -1.
    private static func idKey(_ speaker: MeetingTurnBuilder.Speaker) -> Int {
        if case .other(let idx?) = speaker { return idx }
        return -1
    }

    /// The diarized id with the largest overlap (by sample count) with `line`'s time span.
    private static func majorityId(
        for line: TruthLine, regions: [MeetingVAD.Region], speakers: [MeetingTurnBuilder.Speaker]
    ) -> Int {
        let lineStart = Int(line.start * 16000)
        let lineEnd = Int(line.end * 16000)
        var overlapById: [Int: Int] = [:]
        for (region, speaker) in zip(regions, speakers) {
            let start = max(region.start, lineStart)
            let end = min(region.end, lineEnd)
            guard end > start else { continue }
            overlapById[idKey(speaker), default: 0] += end - start
        }
        return overlapById.max { $0.value < $1.value }?.key ?? -1
    }

    /// The two female voices (Karen, Moira) are an accepted model limitation to merge (see this
    /// file's fixture doc comment) - only Daniel-vs-female needs to come out distinct, so scoring
    /// groups by voice, not by name, before mapping ids to truth.
    private static func voiceGroup(_ speaker: String) -> String { speaker == "Daniel" ? "Daniel" : "female" }

    /// Maps each diarized id to the truth voice group it labels most often (majority vote by line
    /// count), then counts how many truth lines that mapping gets right - so one id covering both
    /// Karen and Moira is scored fairly instead of requiring diarized ids to equal one truth
    /// speaker name directly. Not private: reused by MeetingRecordedAudioDiarizationTests.
    static func labelAccuracy(
        truth: [TruthLine], regions: [MeetingVAD.Region], speakers: [MeetingTurnBuilder.Speaker]
    ) -> LabelAccuracy {
        let lineIds = truth.map { majorityId(for: $0, regions: regions, speakers: speakers) }

        var groupCountsById: [Int: [String: Int]] = [:]
        for (line, id) in zip(truth, lineIds) {
            groupCountsById[id, default: [:]][voiceGroup(line.speaker), default: 0] += 1
        }
        let idToGroup = groupCountsById.mapValues { counts in counts.max { $0.value < $1.value }!.key }

        let correct = zip(truth, lineIds).filter { line, id in idToGroup[id] == voiceGroup(line.speaker) }.count
        let danielIds = Set(zip(truth, lineIds).filter { $0.0.speaker == "Daniel" }.map(\.1))
        let femaleIds = Set(zip(truth, lineIds).filter { $0.0.speaker != "Daniel" }.map(\.1))
        let lines = zip(truth, lineIds).map { line, id -> (String, Int, String?, Bool) in
            (line.speaker, id, idToGroup[id], idToGroup[id] == voiceGroup(line.speaker))
        }
        return LabelAccuracy(
            correct: correct, distinctIds: Set(lineIds).count, danielIds: danielIds, femaleIds: femaleIds, lines: lines)
    }

    // Not private: reused by MeetingRecordedAudioDiarizationTests (same fixture).
    static func loadTruth(path: String = "/tmp/vi-test/timeline.tsv") -> [TruthLine]? {
        guard let content = try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8) else { return nil }
        let lines = content.split(separator: "\n").compactMap { line -> TruthLine? in
            let cols = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
            guard cols.count == 4, let start = Double(cols[0]), let end = Double(cols[1]) else { return nil }
            return TruthLine(start: start, end: end, speaker: String(cols[2]), text: String(cols[3]))
        }
        return lines.isEmpty ? nil : lines
    }

    // Not private: reused by MeetingRecordedAudioDiarizationTests to load dialogue.wav.
    static func loadMono16k(_ path: String) -> [Int16]? {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path), let file = try? AVAudioFile(forReading: url) else { return nil }
        let sourceFormat = file.processingFormat
        guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(file.length))
        else { return nil }
        do { try file.read(into: sourceBuffer) } catch { return nil }

        let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else { return nil }
        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(sourceBuffer.frameLength) * ratio) + 16
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }

        var suppliedInput = false
        var conversionError: NSError?
        converter.convert(to: outBuffer, error: &conversionError) { _, inputStatus in
            if suppliedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return sourceBuffer
        }
        guard conversionError == nil, outBuffer.frameLength > 0, let channelData = outBuffer.int16ChannelData else {
            return nil
        }
        return Array(UnsafeBufferPointer(start: channelData[0], count: Int(outBuffer.frameLength)))
    }
}
