import Foundation

/// Turns two channels' `MeetingVAD` regions into one ordered, speaker-labelled list of turns.
/// Regions are ordered by start time, except where one speaker's region starts inside the
/// other's (an interjection): the host region is then split at the nearest internal pause to
/// the interjection, with the interjecting turn placed between the two halves; if no such pause
/// exists nearby, the host stays whole and the interjection is placed right after it. This is the
/// service-agnostic replacement for `MeetingAudioWindower`'s fixed 30 s windows, which could not
/// tell that a short "Yes, I know" landed in the middle of the other side's sentence.
enum MeetingTurnBuilder {
    /// `other(nil)` is the generic, undiarized "Others" - either diarization is unavailable/failed
    /// (see `MeetingDiarizer`), or a chunk's tail the diarizer hasn't committed yet. `other(i)` is
    /// a diarized remote speaker slot (arrival-ordered, 0-based - "Speaker 1" is `other(0)`).
    enum Speaker: Equatable {
        case me
        case other(Int?)
        static let others = Speaker.other(nil)

        var isOther: Bool {
            if case .other = self { return true }
            return false
        }
    }

    struct Turn: Equatable {
        let speaker: Speaker
        let start: Int
        let end: Int
    }

    private static let sampleRate = MeetingVAD.sampleRate
    static let interjectionToleranceSamples = Int(2.0 * sampleRate)
    static let minInternalPauseSamples = Int(0.2 * sampleRate)
    static let mergeGapSamples = Int(1.0 * sampleRate)
    static let maxTurnSamples = Int(25 * sampleRate)
    /// Silence added to each side of a turn's audio clip before transcription (separate from,
    /// and larger than, `MeetingVAD.paddingSamples`, which pads a *region* with real captured
    /// audio rather than the clip sent to the transcription service with synthetic silence).
    static let transcriptionPaddingSamples = Int(0.2 * sampleRate)

    /// - Parameter othersSpeakers: Per-`othersRegions`-element speaker label, e.g. from
    ///   `MeetingDiarizer` (`.other(0)`, `.other(1)`, ...). `nil` (the default) or a short array
    ///   keeps every region labelled the generic `.others` - the pre-diarization behaviour.
    static func build(
        meRegions: [MeetingVAD.Region], othersRegions: [MeetingVAD.Region],
        meSamples: [Int16], othersSamples: [Int16],
        othersSpeakers: [Speaker]? = nil
    ) -> [Turn] {
        struct Placed {
            let speaker: Speaker
            let start: Int
            let end: Int
            let orderKey: Int
        }

        func othersSpeaker(at index: Int) -> Speaker {
            guard let othersSpeakers, index < othersSpeakers.count else { return .others }
            return othersSpeakers[index]
        }

        func isInterjection(_ region: MeetingVAD.Region, into hosts: [MeetingVAD.Region]) -> Bool {
            hosts.contains { $0.start <= region.start && region.start < $0.end }
        }

        let meIsInterjection = meRegions.map { isInterjection($0, into: othersRegions) }
        let othersIsInterjection = othersRegions.map { isInterjection($0, into: meRegions) }

        var placed: [Placed] = []

        func placeHosts(
            _ hosts: [MeetingVAD.Region], hostFlags: [Bool], hostSpeaker: (Int) -> Speaker, hostSamples: [Int16],
            interjectors: [MeetingVAD.Region], interjectorFlags: [Bool], interjectorSpeaker: (Int) -> Speaker
        ) {
            for (index, host) in hosts.enumerated() where !hostFlags[index] {
                // ponytail: only the first eligible interjector per host is split out here; a
                // second interjector landing in the same host is still placed (see the orphan
                // pass below), just ordered by its own start rather than split precisely.
                let interjectorIndex = interjectors.indices.first {
                    interjectorFlags[$0] && host.start <= interjectors[$0].start && interjectors[$0].start < host.end
                }
                guard let interjectorIndex else {
                    placed.append(Placed(speaker: hostSpeaker(index), start: host.start, end: host.end, orderKey: host.start))
                    continue
                }

                let interjector = interjectors[interjectorIndex]
                let runs = MeetingVAD.silenceRuns(
                    in: hostSamples, range: host.start..<host.end, minRunSamples: minInternalPauseSamples)
                let splitPoint =
                    runs
                    .map { ($0.lowerBound + $0.upperBound) / 2 }
                    .filter { abs($0 - interjector.start) <= interjectionToleranceSamples }
                    .min { abs($0 - interjector.start) < abs($1 - interjector.start) }

                if let splitPoint, splitPoint > host.start, splitPoint < host.end {
                    placed.append(Placed(speaker: hostSpeaker(index), start: host.start, end: splitPoint, orderKey: host.start))
                    placed.append(
                        Placed(
                            speaker: interjectorSpeaker(interjectorIndex), start: interjector.start, end: interjector.end,
                            orderKey: interjector.start))
                    placed.append(Placed(speaker: hostSpeaker(index), start: splitPoint, end: host.end, orderKey: splitPoint))
                } else {
                    placed.append(Placed(speaker: hostSpeaker(index), start: host.start, end: host.end, orderKey: host.start))
                    placed.append(
                        Placed(
                            speaker: interjectorSpeaker(interjectorIndex), start: interjector.start, end: interjector.end,
                            orderKey: host.end))
                }
            }
        }

        placeHosts(
            othersRegions, hostFlags: othersIsInterjection, hostSpeaker: othersSpeaker, hostSamples: othersSamples,
            interjectors: meRegions, interjectorFlags: meIsInterjection, interjectorSpeaker: { _ in .me })
        placeHosts(
            meRegions, hostFlags: meIsInterjection, hostSpeaker: { _ in .me }, hostSamples: meSamples,
            interjectors: othersRegions, interjectorFlags: othersIsInterjection, interjectorSpeaker: othersSpeaker)

        // Interjection-flagged regions never visited as a host above (its own host was itself an
        // interjection, or it lost out to another interjector in the same host) still need a turn.
        for (index, region) in meRegions.enumerated() where meIsInterjection[index] {
            let alreadyPlaced = placed.contains { $0.speaker == .me && $0.start == region.start && $0.end == region.end }
            guard !alreadyPlaced else { continue }
            placed.append(Placed(speaker: .me, start: region.start, end: region.end, orderKey: region.start))
        }
        for (index, region) in othersRegions.enumerated() where othersIsInterjection[index] {
            let speaker = othersSpeaker(at: index)
            let alreadyPlaced = placed.contains { $0.speaker == speaker && $0.start == region.start && $0.end == region.end }
            guard !alreadyPlaced else { continue }
            placed.append(Placed(speaker: speaker, start: region.start, end: region.end, orderKey: region.start))
        }

        let ordered = placed.sorted { $0.orderKey < $1.orderKey }.map { Turn(speaker: $0.speaker, start: $0.start, end: $0.end) }
        let merged = mergeAdjacentSameSpeaker(ordered)
        return merged.flatMap { cap($0, samples: $0.speaker == .me ? meSamples : othersSamples) }
    }

    private static func mergeAdjacentSameSpeaker(_ turns: [Turn]) -> [Turn] {
        var result: [Turn] = []
        for turn in turns {
            if let last = result.last, last.speaker == turn.speaker, turn.start - last.end <= mergeGapSamples {
                result[result.count - 1] = Turn(speaker: last.speaker, start: last.start, end: turn.end)
            } else {
                result.append(turn)
            }
        }
        return result
    }

    /// Splits a turn longer than `maxTurnSamples` at the longest internal pause before the cap,
    /// recursing until every piece fits; falls back to a hard cut at the cap only when the
    /// speech never pauses in time.
    private static func cap(_ turn: Turn, samples: [Int16]) -> [Turn] {
        guard turn.end - turn.start > maxTurnSamples else { return [turn] }

        let runs = MeetingVAD.silenceRuns(in: samples, range: turn.start..<turn.end, minRunSamples: minInternalPauseSamples)
        let candidateRuns = runs.filter { $0.lowerBound - turn.start <= maxTurnSamples }
        let splitPoint: Int
        if let longest = candidateRuns.max(by: { ($0.upperBound - $0.lowerBound) < ($1.upperBound - $1.lowerBound) }) {
            splitPoint = (longest.lowerBound + longest.upperBound) / 2
        } else {
            splitPoint = turn.start + maxTurnSamples
        }

        let first = Turn(speaker: turn.speaker, start: turn.start, end: splitPoint)
        let rest = Turn(speaker: turn.speaker, start: splitPoint, end: turn.end)
        return cap(first, samples: samples) + cap(rest, samples: samples)
    }
}
