import Foundation

/// The Paraformer input frontend shared by all ASR workers.
///
/// Full-audio fbank80 is produced once by `AudioPipeline`.  Each worker still
/// builds its own batch-local LFR(7, 6) view, but the immutable ASR CMVN
/// transform is loaded once and reused for every batch.
struct ASRFrontend: Sendable {
    struct Input: Sendable {
        let features: [Float]
        let seqLen: Int
    }

    private let mvn: (addShift: [Float], rescale: [Float])

    init(modelsRoot: String) throws {
        mvn = try FbankExtractor.loadMvnFile(
            path: ModelCatalog.filePath(definitionID: "asr", file: "am.mvn", modelsRoot: modelsRoot)
        )
    }

    func makeInput(
        fbank80: [Float],
        batch: (startMs: Int, endMs: Int),
        extractor: FbankExtractor
    ) -> Input? {
        let totalFrames = fbank80.count / 80
        guard let frameRange = AudioTimebase.standard.frameRange(
            startMilliseconds: batch.startMs,
            endMilliseconds: batch.endMs,
            totalFrames: totalFrames
        ) else { return nil }

        let batchFbank = Array(fbank80[frameRange.lowerBound * 80 ..< frameRange.upperBound * 80])
        let features = extractor.applyLFR_CMVN(
            fbank80: batchFbank, lfrM: 7, lfrN: 6, mvn: mvn
        )
        let seqLen = features.count / 560
        guard seqLen > 0 else { return nil }
        return Input(features: features, seqLen: seqLen)
    }
}
