import Foundation
import Accelerate

/// Builds immutable profile values from an acoustic partition. This helper is
/// intentionally unaware of file paths and orchestration/fallback state.
enum SpeakerProfileAssembler {
    private struct Member {
        let index: Int
        let chunk: (startMs: Int, endMs: Int)
    }

    static func build(
        labels: [Int],
        chunks: [(startMs: Int, endMs: Int)],
        embeddings: [Float],
        dimension: Int,
        policy: SpeakerTemporalPolicy
    ) -> [SpeakerProfileData] {
        guard labels.count == chunks.count,
              dimension > 0,
              embeddings.count == chunks.count * dimension else {
            Logger.shared.error(
                "SpeakerOrchestrator: refusing to build profiles from mismatched labels/embeddings " +
                "(labels=\(labels.count), chunks=\(chunks.count), embeddings=\(embeddings.count), dim=\(dimension))."
            )
            return []
        }

        var groups: [Int: [Member]] = [:]
        for (index, chunk) in chunks.enumerated() {
            groups[labels[index], default: []].append(Member(index: index, chunk: chunk))
        }

        var profiles: [SpeakerProfileData] = []
        embeddings.withUnsafeBufferPointer { embeddingBuffer in
            guard let baseAddress = embeddingBuffer.baseAddress else { return }
            for (label, members) in groups.sorted(by: { $0.key < $1.key }) {
                guard label >= 0 else { continue }

                var anchors = members
                if policy.enableSentinelIsolation {
                    var roughCentroid = [Float](repeating: 0, count: dimension)
                    for member in members {
                        let source = baseAddress.advanced(by: member.index * dimension)
                        vDSP_vadd(
                            roughCentroid, 1,
                            source, 1,
                            &roughCentroid, 1,
                            vDSP_Length(dimension)
                        )
                    }
                    var inverseMemberCount = 1 / Float(members.count)
                    vDSP_vsmul(
                        roughCentroid, 1,
                        &inverseMemberCount,
                        &roughCentroid, 1,
                        vDSP_Length(dimension)
                    )
                    normalize(&roughCentroid)

                    anchors = members.filter { member in
                        let duration = member.chunk.endMs - member.chunk.startMs
                        let similarity = cosineSimilarity(
                            baseAddress.advanced(by: member.index * dimension),
                            roughCentroid,
                            dimension: dimension
                        )
                        let isDegraded = duration < 180
                            || similarity < policy.acousticDegradedThreshold
                        return !isDegraded
                    }
                    if anchors.isEmpty {
                        anchors = members
                    }
                }

                var centroid = [Float](repeating: 0, count: dimension)
                for member in anchors {
                    let source = baseAddress.advanced(by: member.index * dimension)
                    vDSP_vadd(
                        centroid, 1,
                        source, 1,
                        &centroid, 1,
                        vDSP_Length(dimension)
                    )
                }
                var inverseAnchorCount = 1 / Float(anchors.count)
                vDSP_vsmul(
                    centroid, 1,
                    &inverseAnchorCount,
                    &centroid, 1,
                    vDSP_Length(dimension)
                )
                normalize(&centroid)

                let fingerprint = SpeakerFingerprint.makeId(embedding: centroid)
                let totalDuration = members.reduce(0) {
                    $0 + ($1.chunk.endMs - $1.chunk.startMs)
                }
                var embeddingData = Data(capacity: dimension * MemoryLayout<Float>.size)
                for value in centroid {
                    var littleEndian = value.bitPattern.littleEndian
                    withUnsafeBytes(of: &littleEndian) {
                        embeddingData.append(contentsOf: $0)
                    }
                }

                profiles.append(SpeakerProfileData(
                    speakerLabel: "说话人 \(label + 1)",
                    fingerprintId: fingerprint,
                    totalDurationMs: totalDuration,
                    chunkCount: members.count,
                    centroidEmbedding: centroid,
                    embeddingData: embeddingData,
                    acousticLabel: label
                ))
            }
        }
        return profiles
    }

    private static func normalize(_ values: inout [Float]) {
        var sumSquared: Float = 0
        vDSP_svesq(values, 1, &sumSquared, vDSP_Length(values.count))
        let norm = sqrt(sumSquared)
        if norm > 1e-10 {
            var divisor = norm
            vDSP_vsdiv(
                values, 1,
                &divisor,
                &values, 1,
                vDSP_Length(values.count)
            )
        }
    }

    private static func cosineSimilarity(
        _ embedding: UnsafePointer<Float>,
        _ centroid: [Float],
        dimension: Int
    ) -> Float {
        var dot: Float = 0
        var embeddingSquared: Float = 0
        var centroidSquared: Float = 0
        vDSP_dotpr(
            embedding, 1,
            centroid, 1,
            &dot,
            vDSP_Length(dimension)
        )
        vDSP_svesq(embedding, 1, &embeddingSquared, vDSP_Length(dimension))
        vDSP_svesq(centroid, 1, &centroidSquared, vDSP_Length(dimension))
        let denominator = sqrt(embeddingSquared) * sqrt(centroidSquared)
        guard denominator > 1e-10 else { return 0 }
        return dot / denominator
    }
}
