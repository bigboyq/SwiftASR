import Foundation

/// 共享 npy loader + cosine similarity,给 CIF parity / 任何对比 Python fixture 的测试用。
enum TestSupport {
    static let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static func projectPath(_ relativePath: String) -> String {
        projectRoot.appendingPathComponent(relativePath).path
    }

    /// 读 npy v1.0 文件 (little-endian) 的 raw float32 payload。
    /// Format: magic(6) `b"\x93NUMPY"` + version(2) + header_len(uint16) + header dict + raw payload。
    /// 我们只关心 raw float32,不解析 header dict (dtype/shape 由调用方根据 fixture 名字约定)。
    static func loadNpyFloat32(path: String) throws -> [Float] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard data.count > 16,
              data[0] == 0x93, data[1] == 0x4E,
              data[2] == 0x55, data[3] == 0x4D,
              data[4] == 0x50, data[5] == 0x59 else {
            throw NSError(
                domain: "TestSupport", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Not a numpy file: \(path)"]
            )
        }
        let headerLen = Int(data[8]) | (Int(data[9]) << 8)
        let dataStart = 10 + headerLen
        let payload = data.suffix(from: dataStart)
        let count = payload.count / MemoryLayout<Float>.size
        return payload.withUnsafeBytes { ptr -> [Float] in
            let bound = ptr.baseAddress!.assumingMemoryBound(to: Float.self)
            return Array(UnsafeBufferPointer(start: bound, count: count))
        }
    }

    /// 标量 cosine similarity。NaN 行为: 任一 norm == 0 时返回 0 (避免除零,跟 numpy 行为一致)。
    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        precondition(a.count == b.count, "vectors must have same length, got \(a.count) vs \(b.count)")
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        let denom = sqrt(normA) * sqrt(normB)
        return denom > 0 ? dot / denom : 0
    }
}
