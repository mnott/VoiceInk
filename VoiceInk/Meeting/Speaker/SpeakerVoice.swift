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

    var meetingsCount: Int { meetingIDs.count }
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
            meetingIDs: Array(Set(target.meetingIDs + source.meetingIDs))
        )
    }
}
