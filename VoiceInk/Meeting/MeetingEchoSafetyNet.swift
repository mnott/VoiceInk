import Foundation

/// Text-level safety net for the acoustic echo `EchoCanceller` doesn't fully remove: when the far
/// end's speech leaks into the mic loudly enough to be transcribed, the leaked words show up
/// almost verbatim - or as a slightly different ASR reading of the same audio - in the "Others"
/// turn that's playing at (or just before/after) the same time. For every "Me" turn that
/// time-overlaps an "Others" turn - allowing `overlapSlackSamples` of slack for the acoustic
/// round-trip delay - two passes apply, both using fuzzy word equality (same normalised word, a
/// shared leading stem of >= 4 chars, or a Levenshtein distance of <= 1 for words of length >= 4)
/// so that ASR variants like "scans"/"scanner" or "drop"/"dropped" still count as the same word:
/// short turns (<= `maxWholeTurnEchoWords` words) are dropped entirely if >= `wholeTurnEchoRatio`
/// of their words fuzzy-match, in order, words in the overlapping Others text; longer turns keep
/// the run-stripping, removing any run of `minEchoRunWords` or more consecutive fuzzy-matching
/// words and dropping the turn if fewer than `minRemainingWords` words survive. Genuine
/// double-talk ("I agree, that's a good idea" spoken over the other side) is untouched because it
/// shares neither a run nor enough in-order fuzzy matches with what the other side is saying.
enum MeetingEchoSafetyNet {
    static let overlapSlackSamples = Int(1.0 * MeetingVAD.sampleRate)
    static let minEchoRunWords = 3
    static let minRemainingWords = 3
    static let maxWholeTurnEchoWords = 8
    static let wholeTurnEchoRatio = 0.6

    private static let numberWords: [String: String] = [
        "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6",
        "seven": "7", "eight": "8", "nine": "9", "ten": "10", "eleven": "11", "twelve": "12",
        "thirteen": "13", "fourteen": "14", "fifteen": "15", "sixteen": "16", "seventeen": "17",
        "eighteen": "18", "nineteen": "19", "twenty": "20", "thirty": "30", "forty": "40",
        "fifty": "50", "sixty": "60", "seventy": "70", "eighty": "80", "ninety": "90",
        "hundred": "100", "thousand": "1000",
    ]

    typealias TranscribedTurn = MeetingTurnTranscriptRenderer.TranscribedTurn

    static func filter(_ turns: [TranscribedTurn]) -> [TranscribedTurn] {
        let othersTurns = turns.filter { $0.speaker.isOther }
        return turns.compactMap { turn in
            guard turn.speaker == .me else { return turn }

            let overlapping = othersTurns.filter { overlaps($0, turn) }.sorted { $0.start < $1.start }
            guard !overlapping.isEmpty else { return turn }

            // Concatenated, not matched per-turn: a VAD pause can split one continuous stretch of
            // the other side's speech into several turns, and the leaked echo of it into a single
            // Me turn shouldn't be spared just because no individual Others turn alone reaches the
            // run-length threshold.
            let othersWords = overlapping.flatMap { normalisedWords($0.text) }
            let meTokens = tokens(turn.text)

            if meTokens.count <= maxWholeTurnEchoWords,
                isMostlyEchoedSubsequence(meTokens.map(\.normalised), in: othersWords)
            {
                return nil
            }

            let kept = stripEchoedRuns(meTokens, against: othersWords)
            guard kept.count >= minRemainingWords else { return nil }

            return TranscribedTurn(
                speaker: .me, text: kept.map(\.original).joined(separator: " "), start: turn.start, end: turn.end)
        }
    }

    private static func overlaps(_ a: TranscribedTurn, _ b: TranscribedTurn) -> Bool {
        a.start - overlapSlackSamples < b.end && b.start - overlapSlackSamples < a.end
    }

    private static func stripEchoedRuns(
        _ meTokens: [(original: String, normalised: String)], against othersWords: [String]
    ) -> [(original: String, normalised: String)] {
        let meWords = meTokens.map(\.normalised)
        var kept: [(original: String, normalised: String)] = []
        var i = 0
        while i < meTokens.count {
            let matchLength = longestMatchLength(meWords, from: i, in: othersWords)
            if matchLength >= minEchoRunWords {
                i += matchLength
            } else {
                kept.append(meTokens[i])
                i += 1
            }
        }
        return kept
    }

    /// The longest run starting at `meWords[i]` that also appears, in the same order, starting
    /// somewhere in `othersWords` - i.e. a substring match anchored on the Me side only.
    private static func longestMatchLength(_ meWords: [String], from i: Int, in othersWords: [String]) -> Int {
        var best = 0
        for j in othersWords.indices {
            var length = 0
            while i + length < meWords.count, j + length < othersWords.count, fuzzyEqual(meWords[i + length], othersWords[j + length]) {
                length += 1
            }
            best = max(best, length)
        }
        return best
    }

    /// True if `>= wholeTurnEchoRatio` of `meWords` fuzzy-match words in `othersWords`, in order
    /// (a greedy in-order subsequence match - each Me word claims the next fuzzy-matching Others
    /// word after the previous claim, so out-of-order coincidental matches don't count).
    private static func isMostlyEchoedSubsequence(_ meWords: [String], in othersWords: [String]) -> Bool {
        guard !meWords.isEmpty else { return false }
        var searchFrom = 0
        var matched = 0
        for word in meWords {
            // A word that matches nothing leaves `searchFrom` where it was, so it doesn't burn
            // through the rest of `othersWords` and block later words from matching.
            if let foundIndex = (searchFrom..<othersWords.count).first(where: { fuzzyEqual(word, othersWords[$0]) }) {
                matched += 1
                searchFrom = foundIndex + 1
            }
        }
        return Double(matched) / Double(meWords.count) >= wholeTurnEchoRatio
    }

    /// Same normalised word, a shared leading stem of >= 4 chars, or one Levenshtein edit apart
    /// for words of length >= 4 - catches ASR variants of the same leaked audio ("scans" vs
    /// "scanner", "drop" vs "dropped") without conflating unrelated short words.
    private static func fuzzyEqual(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        if commonPrefixLength(a, b) >= 4 { return true }
        if a.count >= 4, b.count >= 4, levenshteinDistance(a, b) <= 1 { return true }
        return false
    }

    private static func commonPrefixLength(_ a: String, _ b: String) -> Int {
        var count = 0
        for (ca, cb) in zip(a, b) {
            guard ca == cb else { break }
            count += 1
        }
        return count
    }

    private static func levenshteinDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                current[j] = a[i - 1] == b[j - 1]
                    ? previous[j - 1]
                    : 1 + min(previous[j - 1], previous[j], current[j - 1])
            }
            previous = current
        }
        return previous[b.count]
    }

    private static func tokens(_ text: String) -> [(original: String, normalised: String)] {
        text.split(whereSeparator: { $0.isWhitespace }).map { word in
            (original: String(word), normalised: normalise(String(word)))
        }
    }

    private static func normalisedWords(_ text: String) -> [String] {
        tokens(text).map(\.normalised)
    }

    private static func normalise(_ word: String) -> String {
        let alphanumeric = String(word.lowercased().filter { $0.isLetter || $0.isNumber })
        return numberWords[alphanumeric] ?? alphanumeric
    }
}
