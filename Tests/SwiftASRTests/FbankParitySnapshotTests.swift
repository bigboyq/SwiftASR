import Testing
import Foundation
@testable import SwiftASR

/// FbankExtractor 优化后必须 bit-exact 跟当前实现一致。
///
/// 用一段 1s 合成正弦波（440Hz + 880Hz + 静音段）做 fingerprint，存为二进制基线。
/// 60s 真实音频的 LFR 输出规模在 MB 级，不入仓。1s 已能覆盖：
///   - DC offset 扣除（vDSP_meanv）
///   - 预加重 + 加窗（vDSP_vsmul）
///   - 80 维 mel dotpr
///   - LFR 拼接 + CMVN
///   - LFR 范围切片
///
/// 基线更新：跑 `SWIFTASR_WRITE_FBANK_BASELINE=1 swift test --filter FbankParitySnapshotTests`
@Suite struct FbankParitySnapshotTests {

    /// 二进制格式 magic header，便于以后扩展
    /// magic(4) "FBK1" + pcmSeconds(uint32) + numMelBins(uint32)
    /// + fbankCount(uint32) + fbank[Float × fbankCount]
    /// + lfr7Count + lfr7[Float × lfr7Count]
    /// + range5Count + range5[Float × range5Count]
    static let magic: [UInt8] = [0x46, 0x42, 0x4B, 0x31]  // "FBK1"
    static let pcmSeconds = 1
    static let numMelBins = 80
    static let baselineRelativePath = "Tests/SwiftASRTests/Fixtures/fbank_baseline_sine1s.bin"

    /// Optional real-audio fixture supplied outside the repository.
    static let realFixturePath = ProcessInfo.processInfo.environment["SWIFTASR_TEST_AUDIO_16K"] ?? ""
    static let realBaselineRelativePath = "Tests/SwiftASRTests/Fixtures/fbank_baseline_10m_first60s.bin"
    static let realBaselinePcmSeconds = 60

    /// 1s 合成信号：440Hz + 880Hz 正弦 + 末尾静音。确定的位模式。
    static func syntheticPcm() -> [Float] {
        let sampleRate = AudioTimebase.standard.sampleRate  // 16000
        let count = sampleRate * pcmSeconds
        var pcm = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let t = Double(i) / Double(sampleRate)
            // 前 0.6s：440Hz + 880Hz 叠加；后 0.4s：静音
            let env: Double = t < 0.6 ? 0.3 : 0.0
            let s = sin(2.0 * .pi * 440.0 * t) * 0.5
                  + sin(2.0 * .pi * 880.0 * t) * 0.3
            pcm[i] = Float(s * env)
        }
        return pcm
    }

    static func baselineURL() -> URL {
        TestSupport.projectRoot.appendingPathComponent(baselineRelativePath)
    }

    static func realBaselineURL() -> URL {
        TestSupport.projectRoot.appendingPathComponent(realBaselineRelativePath)
    }

    static func snapshot(extractor: FbankExtractor, pcm: [Float]) -> Snap {
        let fbank = extractor.extractFbank(pcmData: pcm, workerCount: 1)
        let lfr7 = extractor.applyLFR_CMVN(fbank80: fbank, lfrM: 7, lfrN: 6, mvn: nil)
        let range5 = extractor.applyLFR_CMVNRange(
            fbank80: fbank, lfrM: 5, lfrN: 1,
            outputFrameRange: 0..<extractor.frameCount(pcmData: pcm), mvn: nil
        )
        return Snap(fbank: fbank, lfr7: lfr7, range5: range5, lfr7WithMvn: [], range5WithMvn: [])
    }

    static func writeBaseline(_ snap: Snap) throws {
        var data = Data()
        data.append(contentsOf: magic)
        var pcmSeconds32 = UInt32(pcmSeconds).littleEndian
        var numMelBins32 = UInt32(numMelBins).littleEndian
        data.append(Data(bytes: &pcmSeconds32, count: 4))
        data.append(Data(bytes: &numMelBins32, count: 4))
        func appendArray(_ arr: [Float]) {
            var count = UInt32(arr.count).littleEndian
            data.append(Data(bytes: &count, count: 4))
            data.append(arr.withUnsafeBufferPointer { Data(buffer: $0) })
        }
        appendArray(snap.fbank)
        appendArray(snap.lfr7)
        appendArray(snap.range5)
        appendArray(snap.lfr7WithMvn)
        appendArray(snap.range5WithMvn)
        let url = baselineURL()
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: url)
        print("[FbankParitySnapshotTests] wrote baseline (\(data.count) bytes) to \(url.path)")
    }

    struct ParsedBaseline {
        var fbank: [Float]
        var lfr7: [Float]
        var range5: [Float]
        var lfr7WithMvn: [Float]
        var range5WithMvn: [Float]
    }

    struct Snap {
        var fbank: [Float]
        var lfr7: [Float]
        var range5: [Float]
        var lfr7WithMvn: [Float]
        var range5WithMvn: [Float]
    }

    static func readBaseline() throws -> ParsedBaseline {
        let data = try Data(contentsOf: baselineURL())
        var cursor = 0
        func readBytes(_ n: Int) throws -> Data {
            guard cursor + n <= data.count else {
                throw NSError(domain: "FbankParitySnapshotTests", code: 100,
                              userInfo: [NSLocalizedDescriptionKey: "baseline truncated at \(cursor)"])
            }
            let slice = data.subdata(in: cursor..<(cursor + n))
            cursor += n
            return slice
        }
        func readUInt32() throws -> UInt32 {
            let bytes = try readBytes(4)
            return bytes.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
        }
        let m = try readBytes(4)
        guard m == Data(magic) else {
            throw NSError(domain: "FbankParitySnapshotTests", code: 101,
                          userInfo: [NSLocalizedDescriptionKey: "baseline magic mismatch"])
        }
        _ = try readUInt32()  // pcmSeconds
        _ = try readUInt32()  // numMelBins
        func readArray() throws -> [Float] {
            let count = Int(try readUInt32())
            let bytes = try readBytes(count * MemoryLayout<Float>.size)
            return bytes.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }
        return ParsedBaseline(
            fbank: try readArray(),
            lfr7: try readArray(),
            range5: try readArray(),
            lfr7WithMvn: try readArray(),
            range5WithMvn: try readArray()
        )
    }

    /// 给出第一个不匹配元素的 (index, baseline, actual, maxDelta)
    /// SIMD 重排（如用 cblas_sgemm 替换手算 dotpr）允许 1 ULP 漂移，
    /// 所以容差设到 1e-4（远大于 Float 在 ~10 值附近的 1 ULP = 1.5e-6）。
    /// 真实 bug（交换 buffer / 错常量）会差 1e-2 以上，会被这个阈值抓到。
    static func firstMismatch(_ a: [Float], _ b: [Float], tolerance: Float = 1e-4) -> (Int, Float, Float, Float)? {
        let n = min(a.count, b.count)
        var maxDelta: Float = 0
        for i in 0..<n {
            let d = abs(a[i] - b[i])
            if d > maxDelta { maxDelta = d }
            if d > tolerance { return (i, b[i], a[i], maxDelta) }
        }
        if a.count != b.count { return (n, 0, Float(a.count - b.count), maxDelta) }
        return nil
    }

    /// 80 维合成 mvn，addShift 跟 rescale 都有可观察数值
    static func makeSyntheticMvn80() -> (addShift: [Float], rescale: [Float]) {
        // addShift 用 [0..<80] 浮点（负对数域），rescale 用 0.1 * (1 + sin)
        let addShift: [Float] = (0..<80).map { Float($0) * 0.07 - 3.5 }
        let rescale: [Float] = (0..<80).map { Float(0.1) + 0.05 * sin(Float($0) * 0.3) }
        return (addShift, rescale)
    }

    @Test func fbankOutputMatchesBaseline() throws {
        let pcm = Self.syntheticPcm()
        let extractor = FbankExtractor()
        var snap = Self.snapshot(extractor: extractor, pcm: pcm)
        // 另跑一遍 LFR+CMVN 路径：构造一个 80 维合成 mvn，验证新代码位级一致
        let mvn = Self.makeSyntheticMvn80()
        snap.lfr7WithMvn = extractor.applyLFR_CMVN(fbank80: snap.fbank, lfrM: 7, lfrN: 6, mvn: mvn)
        snap.range5WithMvn = extractor.applyLFR_CMVNRange(
            fbank80: snap.fbank, lfrM: 5, lfrN: 1,
            outputFrameRange: 0..<extractor.frameCount(pcmData: pcm), mvn: mvn
        )

        let writeBaseline = ProcessInfo.processInfo.environment["SWIFTASR_WRITE_FBANK_BASELINE"] == "1"
        if writeBaseline {
            try Self.writeBaseline(snap)
            return
        }

        let url = Self.baselineURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("[FbankParitySnapshotTests] baseline missing: \(url.path). Re-run with SWIFTASR_WRITE_FBANK_BASELINE=1 to create it.")
            return
        }
        let base = try Self.readBaseline()

        if let m = Self.firstMismatch(snap.fbank, base.fbank, tolerance: 0) {
            Issue.record("fbank differs at index \(m.0): baseline=\(m.1) actual=\(m.2) maxDelta=\(m.3)")
        }
        if let m = Self.firstMismatch(snap.lfr7, base.lfr7, tolerance: 0) {
            Issue.record("lfr(7,6) differs at index \(m.0): baseline=\(m.1) actual=\(m.2) maxDelta=\(m.3)")
        }
        if let m = Self.firstMismatch(snap.range5, base.range5, tolerance: 0) {
            Issue.record("lfr(5,1) range differs at index \(m.0): baseline=\(m.1) actual=\(m.2) maxDelta=\(m.3)")
        }
        if let m = Self.firstMismatch(snap.lfr7WithMvn, base.lfr7WithMvn, tolerance: 0) {
            Issue.record("lfr(7,6)+mvn differs at index \(m.0): baseline=\(m.1) actual=\(m.2) maxDelta=\(m.3)")
        }
        if let m = Self.firstMismatch(snap.range5WithMvn, base.range5WithMvn, tolerance: 0) {
            Issue.record("lfr(5,1) range+mvn differs at index \(m.0): baseline=\(m.1) actual=\(m.2) maxDelta=\(m.3)")
        }
    }

    /// 同样的 1s 合成 + 8 worker 并行 fbank（模拟 pipeline 长音频路径）也必须位级一致
    @Test func fbankParallelWorkerOutputMatchesBaseline() throws {
        let pcm = Self.syntheticPcm()
        let extractor = FbankExtractor()
        let single = extractor.extractFbank(pcmData: pcm, workerCount: 1)
        let parallel = extractor.extractFbank(pcmData: pcm, workerCount: 4)
        // 这两路径必须位级一致（已有 extensive 测试，但 snapshot 工具再守一遍）
        if let m = Self.firstMismatch(parallel, single, tolerance: 0) {
            Issue.record("parallel vs single worker differs at \(m.0): maxDelta=\(m.3)")
        }
    }

    /// 真实 10m fixture 的前 60s 跑 fbank + LFR，落盘为第二个 baseline 文件
    /// (大小 ~ 几十 MB)，用来 catch 在合成信号上没事但在真实音频上飘的情况。
    @Test func fbankRealAudioMatchesBaseline() throws {
        guard FileManager.default.fileExists(atPath: Self.realFixturePath) else {
            return
        }
        let converter = AudioConverter()
        let fullPcm = try converter.loadAndResample(path: Self.realFixturePath)
        let limit = AudioTimebase.standard.sampleRate * Self.realBaselinePcmSeconds
        let pcm = Array(fullPcm.prefix(limit))

        let extractor = FbankExtractor()
        // 跑 single worker 和 parallel 4 worker，两者必须位级一致
        let fbank1 = extractor.extractFbank(pcmData: pcm, workerCount: 1)
        let fbank4 = extractor.extractFbank(pcmData: pcm, workerCount: 4)
        if let m = Self.firstMismatch(fbank1, fbank4, tolerance: 0) {
            Issue.record("real fbank single vs 4-worker differs at \(m.0): maxDelta=\(m.3)")
        }
        let fbank = fbank1
        let lfr7 = extractor.applyLFR_CMVN(fbank80: fbank, lfrM: 7, lfrN: 6, mvn: nil)
        let mvn = Self.makeSyntheticMvn560()  // 560 维 mvn（SeACo LFR(7) feature dim）
        let lfr7Mvn = extractor.applyLFR_CMVN(fbank80: fbank, lfrM: 7, lfrN: 6, mvn: mvn)

        let writeBaseline = ProcessInfo.processInfo.environment["SWIFTASR_WRITE_FBANK_BASELINE_REAL"] == "1"
        if writeBaseline {
            var data = Data()
            data.append(contentsOf: Self.magic)
            var pcmSeconds32 = UInt32(Self.realBaselinePcmSeconds).littleEndian
            var numMelBins32 = UInt32(Self.numMelBins).littleEndian
            data.append(Data(bytes: &pcmSeconds32, count: 4))
            data.append(Data(bytes: &numMelBins32, count: 4))
            func appendArray(_ arr: [Float]) {
                var count = UInt32(arr.count).littleEndian
                data.append(Data(bytes: &count, count: 4))
                data.append(arr.withUnsafeBufferPointer { Data(buffer: $0) })
            }
            appendArray(fbank)
            appendArray(lfr7)
            appendArray(lfr7Mvn)
            let url = Self.realBaselineURL()
            let dir = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: url)
            print("[FbankParitySnapshotTests] wrote real baseline (\(data.count) bytes) to \(url.path)")
            return
        }
        let url = Self.realBaselineURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("[FbankParitySnapshotTests] real baseline missing: \(url.path). Re-run with SWIFTASR_WRITE_FBANK_BASELINE_REAL=1 to create it.")
            return
        }
        let raw = try Data(contentsOf: url)
        var cursor = 4 + 4 + 4
        func readArray() throws -> [Float] {
            let count = Int(raw.subdata(in: cursor..<(cursor+4)).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian })
            cursor += 4
            let bytes = raw.subdata(in: cursor..<(cursor + count * 4))
            cursor += count * 4
            return bytes.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }
        let baseFbank = try readArray()
        let baseLfr7 = try readArray()
        let baseLfr7Mvn = try readArray()

        if let m = Self.firstMismatch(fbank, baseFbank, tolerance: 0) {
            Issue.record("real-fbank differs at \(m.0): baseline=\(m.1) actual=\(m.2) maxDelta=\(m.3)")
        }
        if let m = Self.firstMismatch(lfr7, baseLfr7, tolerance: 0) {
            Issue.record("real-lfr7 differs at \(m.0): maxDelta=\(m.3)")
        }
        if let m = Self.firstMismatch(lfr7Mvn, baseLfr7Mvn, tolerance: 0) {
            Issue.record("real-lfr7+mvn differs at \(m.0): maxDelta=\(m.3)")
        }
    }

    /// 560 维合成 mvn（SeACo LFR(7) 的 featureDim = 80 * 7）
    static func makeSyntheticMvn560() -> (addShift: [Float], rescale: [Float]) {
        let addShift: [Float] = (0..<560).map { Float($0) * 0.012 - 3.5 }
        let rescale: [Float] = (0..<560).map { Float(0.15) + 0.02 * sin(Float($0) * 0.1) }
        return (addShift, rescale)
    }
}
