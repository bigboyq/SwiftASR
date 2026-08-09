import Foundation

/// Pure-static utilities used by `AudioPipeline` and its test suite.
///
/// Before 2026-07-26 these were declared as `static func` on the
/// `AudioPipeline` actor itself, which was the right idea (no actor
/// isolation needed) but kept the actor file at 1035 lines for no
/// good reason — these helpers don't touch any actor-isolated state.
///
/// The 7 utilities here cover 3 concerns:
///   - **Time / sample / frame conversions** (`audioSampleRange`):
///     converts ms ↔ PCM sample range with the standard 16kHz timebase.
///   - **VAD segment sub-chunking** (`svChunk` x2 + `speakerChunkFromFbank80` +
///     `speakerReferenceSegments`): align with FunASR `sv_chunk` semantics
///     (1.5s window, 0.75s shift, 148 fbank frames target, zero-pad for
///     short turns).
///   - **ASR batch planning** (`asrBatches`): split + pad + merge
///     segments into stable ASR batches.
///   - **Speaker label canonicalization** (`relabelSpeakerLabelsByFirstOccurrence`):
///     re-order cluster labels by first occurrence so downstream
///     "Speaker 1" / "Speaker 2" display is stable.
///
/// The 2 `svChunk` overloads (`totalFrames:` and `pcm:`) are kept — the
/// pcm one is for model tests only; production goes through the
/// `totalFrames:` overload to avoid holding a pcm reference.
enum AudioPipelineUtilities {
    /// ASR may decode a wider range than it owns so very short VAD segments
    /// still satisfy the frontend's minimum input length.  Ownership is kept
    /// separately so decoded tokens from that borrowed padding can be removed
    /// deterministically before punctuation and speaker processing.
    struct ASRBatchPlan: Sendable, Equatable {
        let decodeRangeMs: Range<Int>
        let ownershipRangesMs: [Range<Int>]

        var startMs: Int { decodeRangeMs.lowerBound }
        var endMs: Int { decodeRangeMs.upperBound }
    }

    /// Converts a millisecond batch range to a bounded PCM range. Kept as a
    /// pure helper so long-audio boundary behavior is unit-testable.
    static func audioSampleRange(
        startMs: Int,
        endMs: Int,
        sampleRate: Int,
        totalSamples: Int
    ) -> Range<Int>? {
        // 之前这里现造一个 AudioTimebase instance 配 sampleRate + 标准
        // frameLength/frameShift/featureDimension，但所有维度都是从
        // AudioTimebase.standard 读出，逻辑上跟 .standard 等价。直接用
        // .standard 避免一次 stack alloc + 12 字节 init。
        guard sampleRate > 0 else { return nil }
        return AudioTimebase.standard.sampleRange(
            startMilliseconds: startMs,
            endMilliseconds: endMs,
            totalSamples: totalSamples
        )
    }

    // MARK: - sv_chunk：把 VAD 段按 1.5s 窗 + 0.75s shift 切成 sub-chunk
    // 对齐 funasr.models.campplus.utils.sv_chunk：每个 VAD 段拆成多个固定长度 chunk。
    // 返回的 chunk 仍是绝对时间戳（不是相对段起点），方便后续 overlap 匹配。
    //
    // D-2: 不再依赖 pcm，totalDurationMs 改由 `totalFrames`（来自 fbank80 长度）推。
    // 这样 `recognizeSpeakers` / `reidentifySpeakers` 都不必再持有 pcm 引用。
    static func svChunk(
        totalFrames: Int,
        segments: [(startMs: Int, endMs: Int)],
        windowSec: Double,
        shiftSec: Double
    ) -> [(startMs: Int, endMs: Int)] {
        let winMs = Int(windowSec * 1000)
        let shiftMs = Int(shiftSec * 1000)
        let totalMs = AudioTimebase.standard.milliseconds(forFrameCount: totalFrames)
        var out: [(Int, Int)] = []
        for seg in segments {
            let segmentStart = min(max(0, seg.startMs), totalMs)
            let segmentEnd = min(max(segmentStart, seg.endMs), totalMs)
            var lastChunkEnd = 0

            // Mirrors FunASR campplus `sv_chunk`: emit windows by their end
            // position, so a partial tail is aligned to the segment end. The
            // corresponding fbank is zero-padded to 1.5s frames by
            // `speakerChunkFromFbank80`.
            for relativeStart in stride(from: 0, to: segmentEnd - segmentStart, by: shiftMs) {
                let relativeEnd = min(relativeStart + winMs, segmentEnd - segmentStart)
                guard relativeEnd > lastChunkEnd else { break }
                lastChunkEnd = relativeEnd
                let alignedStart = max(0, relativeEnd - winMs)
                let start = segmentStart + alignedStart
                let end = segmentStart + relativeEnd
                if end - start > 100 {
                    out.append((start, end))
                }
            }
        }
        return out
    }

    /// D-2: pcm 路径的 sv_chunk 重载，仅供 model tests 使用（直接构造 pcm 输入验证
    /// speaker model 行为）。生产代码 (`recognizeSpeakers`) 改吃 totalFrames 重载，
    /// 避免持有 pcm 引用。内部用 `(pcm.count - 400) / 160 + 1` 算 totalFrames
    /// 跟 fbank80.count / 80 等效（同一个 PCM 16kHz 1 frame = 10ms hop = 160 samples）。
    static func svChunk(
        pcm: [Float],
        segments: [(startMs: Int, endMs: Int)],
        windowSec: Double,
        shiftSec: Double,
        sampleRate: Int
    ) -> [(startMs: Int, endMs: Int)] {
        // The speaker model and AudioTimebase are fixed at 16 kHz.  The old
        // overload silently ignored this parameter, producing incorrect
        // millisecond boundaries for callers that passed another rate.
        guard sampleRate == AudioTimebase.standard.sampleRate else { return [] }
        let totalFrames = AudioTimebase.standard.frameCount(forSampleCount: pcm.count)
        return svChunk(
            totalFrames: totalFrames,
            segments: segments,
            windowSec: windowSec,
            shiftSec: shiftSec
        )
    }

    /// Builds the exact waveform input for one FunASR `sv_chunk`: real audio
    /// in the diarization interval followed by zero padding to a 1.5-second
    /// embedding window. It must never borrow adjacent speech for short turns.
    ///
    /// D-2: 从整段 fbank80 切一段 speaker 窗口 fbank，按 targetFrames (1.5s pcm = 24000
    /// samples = 148 frames @ 10ms hop) zero-pad，对齐 funasr `sv_chunk` 的行为
    /// （pcm 端 zero-pad，fbank 端自然 0）。
    ///
    /// 关键：1.5s pcm = 24000 samples，fbank 帧数 = `(24000 - 400) / 160 + 1 = 148` 帧
    /// （不是 150！第一帧起点 = pcm[0]，最后一帧起点 = pcm[23600] = 147*160，
    /// 帧数 = 148）。ERes2NetV2 ONNX 模型期望 148 帧输入 (line 567 error 报 "Got: 150
    /// Expected: 148" 提示了这个)。
    /// - 真实 audio 在 [startFrame, endFrame) 范围
    /// - 不足 148 帧的部分用 0 填充（短段不借相邻语音）
    /// - 超过 148 帧被 svChunk 切到正好 ≤148 帧（不会触发截断）
    static func speakerChunkFromFbank80(
        fbank80: [Float],
        startMs: Int,
        endMs: Int,
        targetFrames: Int = 148
    ) -> [Float]? {
        let totalFrames = fbank80.count / 80
        let frameRange = AudioTimebase.standard.frameRange(
            startMilliseconds: startMs,
            endMilliseconds: endMs,
            totalFrames: totalFrames
        )
        let startFrame = frameRange?.lowerBound ?? 0
        let endFrame = frameRange?.upperBound ?? startFrame
        let availableFrames = endFrame - startFrame
        guard availableFrames > 0 else { return nil }
        let copyCount = min(availableFrames, targetFrames)
        var chunkFbank = [Float](repeating: 0, count: targetFrames * 80)
        if copyCount > 0 {
            let src = Array(fbank80[startFrame * 80 ..< (startFrame + copyCount) * 80])
            chunkFbank.replaceSubrange(0..<src.count, with: src)
        }
        return chunkFbank
    }

    /// Generates fbank/CMN for all requested cross windows and sends the
    /// compatible inputs through the shared speaker batch engine. The 300ms
    /// lower bound and 1.5s zero-padding rule are centralized here.
    ///
    /// D-2: fbank 改从整段 fbank80 切片 + zero-pad 到原生 CoreML speaker
    /// 模型固定的 148 帧，省 cross windows 的 fbank 重算。
    static func speakerReferenceSegments(
        sentences: [ASRSentence],
        fallback: [(startMs: Int, endMs: Int)],
        totalDurationMs: Int
    ) -> [(startMs: Int, endMs: Int)] {
        let segments = sentences.compactMap { sentence -> (startMs: Int, endMs: Int)? in
            let start = min(max(0, sentence.startMs), totalDurationMs)
            let end = min(max(start, sentence.endMs), totalDurationMs)
            guard end - start > 50 else { return nil }
            return (start, end)
        }
        return segments.isEmpty ? fallback : segments
    }

    static func asrBatchPlans(
        from segments: [(startMs: Int, endMs: Int)],
        totalDurationMs: Int,
        maxBatchMs: Int,
        minBatchMs: Int = 500,
        maxMergeGapMs: Int = 1_200,
        targetMergeDurationMs: Int = 15_000
    ) -> [ASRBatchPlan] {
        guard !segments.isEmpty else {
            return totalDurationMs > 0
                ? [ASRBatchPlan(
                    decodeRangeMs: 0..<totalDurationMs,
                    ownershipRangesMs: [0..<totalDurationMs]
                )]
                : []
        }
        var rawPlans: [ASRBatchPlan] = []
        var previousOwnershipEnd = 0
        for seg in segments.sorted(by: {
            ($0.startMs, $0.endMs) < ($1.startMs, $1.endMs)
        }) {
            var start = max(previousOwnershipEnd, max(0, seg.startMs))
            let end = min(totalDurationMs, max(start, seg.endMs))
            while end - start > maxBatchMs {
                rawPlans.append(ASRBatchPlan(
                    decodeRangeMs: start..<(start + maxBatchMs),
                    ownershipRangesMs: [start..<(start + maxBatchMs)]
                ))
                start += maxBatchMs
            }
            if end > start {
                let paddedEnd = min(totalDurationMs, max(end, start + minBatchMs))
                let paddedStart = max(0, min(start, paddedEnd - minBatchMs))
                rawPlans.append(ASRBatchPlan(
                    decodeRangeMs: paddedStart..<paddedEnd,
                    ownershipRangesMs: [start..<end]
                ))
            }
            previousOwnershipEnd = max(previousOwnershipEnd, end)
        }
        guard let first = rawPlans.first else {
            return totalDurationMs > 0
                ? [ASRBatchPlan(
                    decodeRangeMs: 0..<totalDurationMs,
                    ownershipRangesMs: [0..<totalDurationMs]
                )]
                : []
        }

        var merged: [ASRBatchPlan] = []
        var current = first

        for next in rawPlans.dropFirst() {
            let gap = next.decodeRangeMs.lowerBound - current.decodeRangeMs.upperBound
            let combinedSpan = next.decodeRangeMs.upperBound - current.decodeRangeMs.lowerBound
            if gap <= maxMergeGapMs && combinedSpan <= targetMergeDurationMs {
                let mergedStart = current.decodeRangeMs.lowerBound
                let mergedEnd = max(
                    current.decodeRangeMs.upperBound,
                    next.decodeRangeMs.upperBound
                )
                let ownershipStart = current.ownershipRangesMs.first?.lowerBound
                    ?? current.decodeRangeMs.lowerBound
                let ownershipEnd = next.ownershipRangesMs.last?.upperBound
                    ?? next.decodeRangeMs.upperBound
                current = ASRBatchPlan(
                    decodeRangeMs: mergedStart..<mergedEnd,
                    // A merge intentionally asks ASR to decode the silence/gap
                    // between nearby VAD segments. Only padding outside the
                    // first/last original boundary is borrowed.
                    ownershipRangesMs: [ownershipStart..<ownershipEnd]
                )
            } else {
                merged.append(current)
                current = next
            }
        }
        merged.append(current)
        return merged
    }

    static func asrBatches(
        from segments: [(startMs: Int, endMs: Int)],
        totalDurationMs: Int,
        maxBatchMs: Int,
        minBatchMs: Int = 500,
        maxMergeGapMs: Int = 1_200,
        targetMergeDurationMs: Int = 15_000
    ) -> [(startMs: Int, endMs: Int)] {
        asrBatchPlans(
            from: segments,
            totalDurationMs: totalDurationMs,
            maxBatchMs: maxBatchMs,
            minBatchMs: minBatchMs,
            maxMergeGapMs: maxMergeGapMs,
            targetMergeDurationMs: targetMergeDurationMs
        ).map { ($0.decodeRangeMs.lowerBound, $0.decodeRangeMs.upperBound) }
    }

    static func relabelSpeakerLabelsByFirstOccurrence(
        labels: [Int],
        chunks: [(startMs: Int, endMs: Int)]
    ) -> [Int] {
        guard labels.count == chunks.count else { return labels }

        var firstStartByLabel: [Int: Int] = [:]
        for (idx, label) in labels.enumerated() {
            guard label >= 0 else { continue }
            let start = chunks[idx].startMs
            firstStartByLabel[label] = min(firstStartByLabel[label] ?? start, start)
        }

        let orderedLabels = firstStartByLabel
            .sorted { lhs, rhs in
                if lhs.value == rhs.value {
                    return lhs.key < rhs.key
                }
                return lhs.value < rhs.value
            }
            .map(\.key)

        var remap: [Int: Int] = [:]
        for (newLabel, oldLabel) in orderedLabels.enumerated() where oldLabel >= 0 {
            remap[oldLabel] = newLabel
        }
        return labels.map { label in
            label < 0 ? label : (remap[label] ?? label)
        }
    }
}
