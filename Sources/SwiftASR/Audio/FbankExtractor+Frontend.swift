import Foundation
import Accelerate

/// LFR/CMVN front-end operations live separately from the frame FFT kernel.
/// Keeping these transforms on the same extractor preserves the cached model
/// dimensions while making the streaming and offline paths independently
/// reviewable.
extension FbankExtractor {
    public func applyLFR_CMVN(
        fbank80: [Float],
        lfrM: Int,
        lfrN: Int,
        mvn: (addShift: [Float], rescale: [Float])?
    ) -> [Float] {
        guard lfrM > 0, lfrN > 0, fbank80.count.isMultiple(of: numMelBins) else { return [] }
        let totalFrames = fbank80.count / numMelBins
        guard totalFrames > 0 else { return [] }
        let featureDim = numMelBins * lfrM
        let lfrT = (totalFrames - 1) / lfrN + 1
        var out = [Float](repeating: 0.0, count: lfrT * featureDim)
        let paddedFrames = Self.officialLFRPaddedFrameIndexes(
            totalFrames: totalFrames,
            lfrM: lfrM,
            lfrN: lfrN,
            outputFrames: lfrT
        )
        fbank80.withUnsafeBufferPointer { fbankBuf in
            out.withUnsafeMutableBufferPointer { outBuf in
                guard let fbankPtr = fbankBuf.baseAddress,
                      let outPtr = outBuf.baseAddress else { return }
                let melBytes = numMelBins * MemoryLayout<Float>.size
                for t in 0..<lfrT {
                    for k in 0..<lfrM {
                        let paddedFrame = t * lfrN + k
                        let srcFrame = paddedFrames[min(paddedFrame, paddedFrames.count - 1)]
                        memcpy(
                            outPtr.advanced(by: t * featureDim + k * numMelBins),
                            fbankPtr.advanced(by: srcFrame * numMelBins),
                            melBytes
                        )
                    }
                }
            }
        }
        guard let mvn else { return out }
        guard mvn.addShift.count == featureDim, mvn.rescale.count == featureDim else { return [] }
        let featureDimI = vDSP_Length(featureDim)
        out.withUnsafeMutableBufferPointer { outBuf in
            mvn.addShift.withUnsafeBufferPointer { shiftBuf in
                mvn.rescale.withUnsafeBufferPointer { scaleBuf in
                    guard let outPtr = outBuf.baseAddress,
                          let shiftPtr = shiftBuf.baseAddress,
                          let scalePtr = scaleBuf.baseAddress else { return }
                    for t in 0..<lfrT {
                        let framePtr = outPtr.advanced(by: t * featureDim)
                        vDSP_vadd(framePtr, 1, shiftPtr, 1, framePtr, 1, featureDimI)
                        vDSP_vmul(framePtr, 1, scalePtr, 1, framePtr, 1, featureDimI)
                    }
                }
            }
        }
        return out
    }

    public func applyLFR_CMVNRange(
        fbank80: [Float],
        lfrM: Int,
        lfrN: Int,
        outputFrameRange: Range<Int>,
        mvn: (addShift: [Float], rescale: [Float])?
    ) -> [Float] {
        guard lfrN == 1, lfrM > 0, fbank80.count.isMultiple(of: numMelBins) else { return [] }
        let totalFrames = fbank80.count / numMelBins
        guard totalFrames > 0 else { return [] }
        let featureDim = numMelBins * lfrM
        let range = max(0, outputFrameRange.lowerBound)..<min(totalFrames, outputFrameRange.upperBound)
        if let mvn {
            guard mvn.addShift.count == featureDim, mvn.rescale.count == featureDim else { return [] }
        }
        let leftPadding = (lfrM - 1) / 2
        var out = [Float](repeating: 0.0, count: range.count * featureDim)
        fbank80.withUnsafeBufferPointer { fbankBuf in
            guard let fbankBase = fbankBuf.baseAddress else { return }
            out.withUnsafeMutableBufferPointer { outBuf in
                guard let outBase = outBuf.baseAddress else { return }
                if let mvn {
                    mvn.addShift.withUnsafeBufferPointer { shiftBuf in
                        guard let shiftBase = shiftBuf.baseAddress else { return }
                        mvn.rescale.withUnsafeBufferPointer { scaleBuf in
                            guard let scaleBase = scaleBuf.baseAddress else { return }
                            let melCount = vDSP_Length(self.numMelBins)
                            for (localFrame, frame) in range.enumerated() {
                                let localDstBase = outBase.advanced(by: localFrame * featureDim)
                                for k in 0..<lfrM {
                                    let sourceFrame = min(totalFrames - 1, max(0, frame + k - leftPadding))
                                    let srcPtr = fbankBase.advanced(by: sourceFrame * self.numMelBins)
                                    let shiftPtr = shiftBase.advanced(by: k * self.numMelBins)
                                    let scalePtr = scaleBase.advanced(by: k * self.numMelBins)
                                    let dstPtr = localDstBase.advanced(by: k * self.numMelBins)
                                    vDSP_vadd(srcPtr, 1, shiftPtr, 1, dstPtr, 1, melCount)
                                    vDSP_vmul(dstPtr, 1, scalePtr, 1, dstPtr, 1, melCount)
                                }
                            }
                        }
                    }
                } else {
                    let frameBytes = self.numMelBins * MemoryLayout<Float>.size
                    for (localFrame, frame) in range.enumerated() {
                        let localDstBase = outBase.advanced(by: localFrame * featureDim)
                        for k in 0..<lfrM {
                            let sourceFrame = min(totalFrames - 1, max(0, frame + k - leftPadding))
                            memcpy(
                                localDstBase.advanced(by: k * self.numMelBins),
                                fbankBase.advanced(by: sourceFrame * self.numMelBins),
                                frameBytes
                            )
                        }
                    }
                }
            }
        }
        return out
    }

    static func officialLFRPaddedFrameIndexes(
        totalFrames: Int,
        lfrM: Int,
        lfrN: Int,
        outputFrames: Int? = nil
    ) -> [Int] {
        guard totalFrames > 0, lfrM > 0, lfrN > 0 else { return [] }
        let lfrT = outputFrames ?? ((totalFrames - 1) / lfrN + 1)
        let leftPadding = (lfrM - 1) / 2
        var indexes = [Int](repeating: 0, count: leftPadding)
        indexes.append(contentsOf: 0..<totalFrames)
        let paddedT = totalFrames + leftPadding
        let lastIdx = floorDiv(paddedT - lfrM, lfrN) + 1
        let simplePadding = lfrM - (paddedT - lastIdx * lfrN)
        if simplePadding > 0 {
            let numerator = 2 * lfrM - 2 * paddedT + (lfrT - 1 + lastIdx) * lfrN
            let officialPadding = numerator * (lfrT - lastIdx) / 2
            if officialPadding > 0 {
                indexes.append(contentsOf: repeatElement(totalFrames - 1, count: officialPadding))
            }
        }
        let needed = max(0, (max(lfrT - 1, 0) * lfrN) + lfrM)
        if indexes.count < needed {
            indexes.append(contentsOf: repeatElement(totalFrames - 1, count: needed - indexes.count))
        }
        return indexes
    }

    private static func floorDiv(_ numerator: Int, _ denominator: Int) -> Int {
        precondition(denominator > 0)
        if numerator >= 0 { return numerator / denominator }
        return -(((-numerator) + denominator - 1) / denominator)
    }
}
