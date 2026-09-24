import Foundation

/// One remembered voice in the local speaker library (see `Notes/speaker-library-spec.md`).
/// `embedding` is a running average over every confirmed match, `embeddingCount` its sample count
/// - see `SpeakerMatching.averaging`. `sampleClipFileNames` are relative to
/// `SpeakerLibraryStore.clipsDirectory`.
struct SpeakerVoice: Codable, Identifiable, Equatable {
    var id: String
    var name: String?
    var embedding: [Float]
    var embeddingCount: Int
    var sampleClipFileNames: [String]
    var firstHeard: Date
    var lastHeard: Date
    var meetingIDs: [UUID]
    /// Whether this voice is flagged as the user's own - set once, from Settings -> Speakers or
    /// Identify Speakers ("This is me"), so Meeting Capture's in-person mode can tell which
    /// diarized mic speaker is the user instead of guessing from who talks most (see
    /// `MeetingMicSpeakerMapper`). At most one voice is ever flagged - see
    /// `SpeakerLibraryStore.setIsMe`.
    var isMe: Bool

    var meetingsCount: Int { meetingIDs.count }

    init(
        id: String, name: String?, embedding: [Float], embeddingCount: Int, sampleClipFileNames: [String],
        firstHeard: Date, lastHeard: Date, meetingIDs: [UUID], isMe: Bool = false
    ) {
        self.id = id
        self.name = name
        self.embedding = embedding
        self.embeddingCount = embeddingCount
        self.sampleClipFileNames = sampleClipFileNames
        self.firstHeard = firstHeard
        self.lastHeard = lastHeard
        self.meetingIDs = meetingIDs
        self.isMe = isMe
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, embedding, embeddingCount, sampleClipFileNames, firstHeard, lastHeard, meetingIDs, isMe
    }

    /// Custom decoding only to default `isMe` to `false` for a library saved before this flag
    /// existed - synthesized `Decodable` would otherwise fail on the missing key.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        embedding = try container.decode([Float].self, forKey: .embedding)
        embeddingCount = try container.decode(Int.self, forKey: .embeddingCount)
        sampleClipFileNames = try container.decode([String].self, forKey: .sampleClipFileNames)
        firstHeard = try container.decode(Date.self, forKey: .firstHeard)
        lastHeard = try container.decode(Date.self, forKey: .lastHeard)
        meetingIDs = try container.decode([UUID].self, forKey: .meetingIDs)
        isMe = try container.decodeIfPresent(Bool.self, forKey: .isMe) ?? false
    }
}

/// Pure (no file I/O) matching/merge/id-generation logic - the part of the speaker library that is
/// unit-testable with synthetic embeddings.
enum SpeakerMatching {
    /// Cosine similarity above which a new embedding is considered the same voice rather than a
    /// new one. Chosen conservatively (favouring a spurious new voice over silently merging two
    /// different people) since a wrong merge is much more disruptive to fix than an extra unnamed
    /// entry - ponytail: not yet tuned against real recordings; expose as a Settings slider if the
    /// fixed value proves wrong for some voices/hardware in practice.
    static let matchThreshold: Float = 0.55

    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        guard normA > 0, normB > 0 else { return 0 }
        return dot / (normA.squareRoot() * normB.squareRoot())
    }

    /// The library voice whose embedding is most similar to `embedding`, if any clears
    /// `threshold` - otherwise `nil`, meaning "register a new voice".
    static func bestMatch(for embedding: [Float], in voices: [SpeakerVoice], threshold: Float = matchThreshold) -> (
        id: String, similarity: Float
    )? {
        let scored = voices.map { (id: $0.id, similarity: cosineSimilarity(embedding, $0.embedding)) }
        guard let best = scored.max(by: { $0.similarity < $1.similarity }), best.similarity >= threshold else {
            return nil
        }
        return best
    }

    /// Running average of a voice's embedding after one more confirmed-match sample.
    static func averaging(existing: [Float], count: Int, new: [Float]) -> [Float] {
        guard count > 0, existing.count == new.count else { return new }
        let total = Float(count + 1)
        return zip(existing, new).map { ($0 * Float(count) + $1) / total }
    }

    /// A new `spk-` id, 4 hex chars (extended to 5-6 only if that space is already exhausted -
    /// astronomically unlikely for a local per-user library, but checked rather than assumed).
    static func generateID(excluding existingIDs: Set<String>) -> String {
        for length in 4...6 {
            for _ in 0..<64 {
                let id = "spk-" + randomHex(length: length)
                if !existingIDs.contains(id) { return id }
            }
        }
        return "spk-" + UUID().uuidString.prefix(6).lowercased()
    }

    private static func randomHex(length: Int) -> String {
        let digits = Array("0123456789abcdef")
        return String((0..<length).map { _ in digits.randomElement()! })
    }

    /// Merges `source` into `target`, averaging their embeddings weighted by sample count and
    /// unioning their clips/meetings; `target.id`/`target.name` (falling back to `source.name` if
    /// `target` has none) survive. Callers still need to remap every turn's `speakerID` from
    /// `source.id` to `target.id` across stored meeting records - this only merges the library
    /// entries themselves.
    static func merge(source: SpeakerVoice, into target: SpeakerVoice) -> SpeakerVoice {
        let totalCount = target.embeddingCount + source.embeddingCount
        let mergedEmbedding: [Float]
        if totalCount > 0, target.embedding.count == source.embedding.count {
            mergedEmbedding = zip(target.embedding, source.embedding).map {
                ($0 * Float(target.embeddingCount) + $1 * Float(source.embeddingCount)) / Float(totalCount)
            }
        } else {
            mergedEmbedding = target.embedding
        }

        return SpeakerVoice(
            id: target.id,
            name: target.name ?? source.name,
            embedding: mergedEmbedding,
            embeddingCount: totalCount,
            sampleClipFileNames: Array((target.sampleClipFileNames + source.sampleClipFileNames).prefix(3)),
            firstHeard: min(target.firstHeard, source.firstHeard),
            lastHeard: max(target.lastHeard, source.lastHeard),
            meetingIDs: Array(Set(target.meetingIDs + source.meetingIDs)),
            isMe: target.isMe || source.isMe
        )
    }
}
