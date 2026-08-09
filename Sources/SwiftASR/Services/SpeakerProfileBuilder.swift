import Foundation
import Accelerate

// MARK: - SpeakerProfileBuilder
//
// ABC 重构阶段 C：从 `actor AudioPipeline` 抽到独立 service 文件的
// pure 函数集合。actor 通过 `SpeakerProfileBuilder.xxx(...)` 调用。
//
// 设计意图：把 token → utterance → label assignment → profile 流程
// 集中到独立 namespace，方便单测覆盖。

enum SpeakerProfileBuilder {

    /// Matches ERes2NetV2 `feature - feature.mean(dim=0, keepdim=True)`.
    static func speakerMeanNormalize(_ fbank: [Float], featureDim: Int = 80) -> [Float] {
        guard featureDim > 0, fbank.count >= featureDim else { return fbank }
        let totalFrames = fbank.count / featureDim
        guard totalFrames > 0 else { return fbank }

        var means = [Float](repeating: 0, count: featureDim)
        var validFramesCount = 0
        var normalized = Array(fbank.prefix(totalFrames * featureDim))
        let vLen = vDSP_Length(featureDim)

        fbank.withUnsafeBufferPointer { fbankBuf in
            normalized.withUnsafeMutableBufferPointer { normBuf in
                means.withUnsafeMutableBufferPointer { meansBuf in
                    guard let fbankPtr = fbankBuf.baseAddress,
                          let normPtr = normBuf.baseAddress,
                          let meansPtr = meansBuf.baseAddress else { return }

                    for frame in 0..<totalFrames {
                        let framePtr = fbankPtr.advanced(by: frame * featureDim)
                        var maxMag: Float = 0
                        vDSP_maxmgv(framePtr, 1, &maxMag, vLen)
                        if maxMag > 0 {
                            validFramesCount += 1
                            vDSP_vadd(framePtr, 1, meansPtr, 1, meansPtr, 1, vLen)
                        }
                    }

                    var negMeanFactor = -1.0 / Float(max(1, validFramesCount))
                    vDSP_vsmul(meansPtr, 1, &negMeanFactor, meansPtr, 1, vLen)

                    for frame in 0..<totalFrames {
                        let normFramePtr = normPtr.advanced(by: frame * featureDim)
                        var maxMag: Float = 0
                        vDSP_maxmgv(normFramePtr, 1, &maxMag, vLen)
                        if maxMag > 0 {
                            vDSP_vadd(normFramePtr, 1, meansPtr, 1, normFramePtr, 1, vLen)
                        } else {
                            bzero(normFramePtr, featureDim * MemoryLayout<Float>.size)
                        }
                    }
                }
            }
        }

        return normalized
    }

}
