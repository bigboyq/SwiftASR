import Foundation
import CryptoKit

/// Speaker fingerprint utilities — pure functions, no FunASR dependency.
///
/// Aligned with FunASR-Mac's ``embedding.py`` / ``speaker_match.py`` so a
/// speaker_profile.json imported from the Python side is compatible.
public enum SpeakerFingerprint {
    /// 16 字节 fingerprint（hex 前 12 字符 + "fp_" 前缀）。
    /// ``embedding`` is a flat [Float] 1-D vector.
    public static func makeId(embedding: [Float], prefix: String = "fp") -> String {
        let arr = embedding.map { Float32($0) }
        let data = arr.withUnsafeBufferPointer { Data(buffer: $0) }
        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(prefix)_\(String(hex.prefix(12)))"
    }

    /// Cosine similarity. Returns 0.0 if either vector is zero.
    public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0.0 }
        var dot: Float = 0
        var na: Float = 0
        var nb: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        let denom = (na.squareRoot()) * (nb.squareRoot())
        return denom == 0 ? 0 : dot / denom
    }
}
