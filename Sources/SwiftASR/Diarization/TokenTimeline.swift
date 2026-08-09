import Foundation

/// The immutable coordinate system used by the speaker pipeline after
/// punctuation. Raw ASR timing is retained for audit/output; effective timing
/// is only used to prevent duplicate fbank coverage in token-packed windows.
struct TokenTimeline: Sendable {
    struct Policy: Sendable, Equatable {
        var acousticIslandGapMs: Int = 300

        static let production = Policy()
    }

    struct TokenID: Hashable, Sendable, Comparable {
        let sentenceIndex: Int
        let tokenIndex: Int

        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.sentenceIndex == rhs.sentenceIndex
                ? lhs.tokenIndex < rhs.tokenIndex
                : lhs.sentenceIndex < rhs.sentenceIndex
        }
    }

    enum TimingIssue: String, Sendable, Hashable {
        case clamped
        case outOfOrder
        case overlapClipped
        case zeroAcousticCoverage
        case overlong
        case sentenceFallback
    }

    struct Token: Sendable {
        let id: TokenID
        let text: String
        let rawRangeMs: Range<Int>
        let effectiveRangeMs: Range<Int>
        let sourceFrameSpans: [Range<Int>]
        let sentenceID: Int
        let islandID: Int
        let quality: Set<TimingIssue>

        var effectiveFrameCount: Int {
            sourceFrameSpans.reduce(0) { $0 + $1.count }
        }
    }

    struct AcousticIsland: Sendable {
        let id: Int
        let sentenceID: Int
        let tokenIndexes: Range<Int>
    }

    let tokens: [Token]
    let islands: [AcousticIsland]
    let totalFrames: Int

    init(
        sentences sourceSentences: [ASRSentence],
        totalFrames: Int,
        policy: Policy = .production
    ) {
        self.totalFrames = max(0, totalFrames)
        let timebase = AudioTimebase.standard
        let durationMs = timebase.milliseconds(forFrameCount: max(0, totalFrames))

        // 2026-07-26 P2 F3.8: 之前 init 是 165 行的巨函数，含 2 个 nested
        // struct (SourceToken / Draft) + 1 个 nested func (closeIsland) + 1
        // 个内联 ternary tuple。3 个 phase 抽到独立 static helper：
        //   1. collectSourceTokens  (sourceSentences → SourceToken[])
        //   2. buildClampedDrafts   (SourceToken[] → Draft[]，clamp 到 [0, durationMs])
        //   3. resolveOverlaps      (Draft[] 单调化有效区间，防嵌套重叠)
        //   4. buildOutput          (Draft[] → ([Token], [AcousticIsland])，含 island 检测)
        // 2 个 nested struct 提到 file-scope（fileprivate），4 个 helper
        // 共享。
        let source = Self.collectSourceTokens(from: sourceSentences)
        var drafts = Self.buildClampedDrafts(from: source, durationMs: durationMs)
        Self.resolveOverlaps(in: &drafts)
        let output = Self.buildOutput(
            from: drafts,
            totalFrames: totalFrames,
            timebase: timebase,
            policy: policy
        )
        self.tokens = output.tokens
        self.islands = output.islands
    }
}

// 2026-07-26 P2 F3.8: nested struct 提到 file-scope，4 个 init helper 共享。
fileprivate struct TokenTimelineSourceToken {
    let id: TokenTimeline.TokenID
    let text: String
    let rawStartMs: Int
    let rawEndMs: Int
    let sentenceID: Int
    let sourceOrdinal: Int
    let sentenceFallback: Bool
}

fileprivate struct TokenTimelineDraft {
    let source: TokenTimelineSourceToken
    let rawRangeMs: Range<Int>
    var effectiveRangeMs: Range<Int>
    var quality: Set<TokenTimeline.TimingIssue>
}

extension TokenTimeline {
    /// F3.8 phase 1: 把 ASRSentence 列表展平成 SourceToken 序列，附带
    /// sourceOrdinal 用于 phase 2 的 .outOfOrder 检测，以及
    /// sentenceFallback 标记空 tokens 列表的合成 token。
    fileprivate static func collectSourceTokens(
        from sentences: [ASRSentence]
    ) -> [TokenTimelineSourceToken] {
        var source: [TokenTimelineSourceToken] = []
        var ordinal = 0
        for (sentenceIndex, sentence) in sentences.enumerated() {
            let sentenceTokens: [(ASRToken, Int, Bool)] = sentence.tokens.isEmpty
                ? [(ASRToken(text: sentence.text, startMs: sentence.startMs, endMs: sentence.endMs), 0, true)]
                : sentence.tokens.enumerated().map { ($0.element, $0.offset, false) }
            for (token, tokenIndex, fallback) in sentenceTokens {
                source.append(TokenTimelineSourceToken(
                    id: TokenID(sentenceIndex: sentenceIndex, tokenIndex: tokenIndex),
                    text: token.text,
                    rawStartMs: token.startMs,
                    rawEndMs: token.endMs,
                    sentenceID: sentenceIndex,
                    sourceOrdinal: ordinal,
                    sentenceFallback: fallback
                ))
                ordinal += 1
            }
        }
        return source
    }

    /// F3.8 phase 2: 按 (rawStartMs, rawEndMs, id) 排序后 clamp 到
    /// [0, durationMs]（out-of-range 自动打 .clamped 标记），并标
    /// 记 .outOfOrder / .sentenceFallback 质控位。
    fileprivate static func buildClampedDrafts(
        from source: [TokenTimelineSourceToken],
        durationMs: Int
    ) -> [TokenTimelineDraft] {
        let sorted = source.sorted {
            if $0.rawStartMs != $1.rawStartMs { return $0.rawStartMs < $1.rawStartMs }
            if $0.rawEndMs != $1.rawEndMs { return $0.rawEndMs < $1.rawEndMs }
            return $0.id < $1.id
        }
        var drafts: [TokenTimelineDraft] = []
        drafts.reserveCapacity(sorted.count)
        for (sortedIndex, item) in sorted.enumerated() {
            let clampedStart = min(max(0, item.rawStartMs), durationMs)
            let clampedEnd = min(max(0, item.rawEndMs), durationMs)
            let rawLower = min(clampedStart, clampedEnd)
            let rawUpper = max(clampedStart, clampedEnd)
            var quality: Set<TokenTimeline.TimingIssue> = []
            if clampedStart != item.rawStartMs || clampedEnd != item.rawEndMs { quality.insert(.clamped) }
            if item.sourceOrdinal != sortedIndex { quality.insert(.outOfOrder) }
            if item.sentenceFallback { quality.insert(.sentenceFallback) }
            drafts.append(TokenTimelineDraft(
                source: item,
                rawRangeMs: rawLower..<rawUpper,
                effectiveRangeMs: rawLower..<rawUpper,
                quality: quality
            ))
        }
        return drafts
    }

    /// F3.8 phase 3: 嵌套区间（如 0..1000, 100..900, 200..300）单
    /// 调化。两两比较只解决相邻对，不保证首尾不交；需要 backward
    /// pass 把 boundaries 序列降序一致，最后按 boundary 收缩
    /// effectiveRangeMs。收缩过的标 .overlapClipped。
    fileprivate static func resolveOverlaps(in drafts: inout [TokenTimelineDraft]) {
        if drafts.count <= 1 { return }
        var boundaries: [Int?] = Array(repeating: nil, count: drafts.count - 1)
        for index in boundaries.indices {
            let previous = drafts[index].rawRangeMs
            let current = drafts[index + 1].rawRangeMs
            let overlapStart = max(previous.lowerBound, current.lowerBound)
            let overlapEnd = min(previous.upperBound, current.upperBound)
            guard overlapEnd > overlapStart else { continue }
            boundaries[index] = overlapStart + (overlapEnd - overlapStart) / 2
        }
        if boundaries.count > 1 {
            for index in stride(from: boundaries.count - 2, through: 0, by: -1) {
                guard let next = boundaries[index + 1] else { continue }
                if let current = boundaries[index] {
                    boundaries[index] = min(current, next)
                }
            }
        }
        for index in drafts.indices {
            let lower = index > 0 ? boundaries[index - 1] : nil
            let upper = index < boundaries.count ? boundaries[index] : nil
            let raw = drafts[index].rawRangeMs
            let effectiveLower = max(raw.lowerBound, lower ?? raw.lowerBound)
            let effectiveUpper = min(raw.upperBound, upper ?? raw.upperBound)
            drafts[index].effectiveRangeMs = effectiveLower..<max(effectiveLower, effectiveUpper)
            if drafts[index].effectiveRangeMs != raw {
                drafts[index].quality.insert(.overlapClipped)
            }
        }
    }

    /// F3.8 phase 4: 走 final Draft[]，分配 islandID、计算
    /// sourceFrameSpans、标 .zeroAcousticCoverage / .overlong，
    /// 同时累积 islandRanges 供 AcousticIsland 输出。
    fileprivate static func buildOutput(
        from drafts: [TokenTimelineDraft],
        totalFrames: Int,
        timebase: AudioTimebase,
        policy: Policy
    ) -> (tokens: [Token], islands: [AcousticIsland]) {
        var output: [Token] = []
        output.reserveCapacity(drafts.count)
        var islandID = -1
        var previousSentenceID: Int?
        var previousRawEndMs: Int?
        var islandStartIndex = 0
        var islandRanges: [(id: Int, sentenceID: Int, range: Range<Int>)] = []

        func closeIsland(at endIndex: Int) {
            guard islandID >= 0, islandStartIndex < endIndex,
                  let sentenceID = previousSentenceID else { return }
            islandRanges.append((islandID, sentenceID, islandStartIndex..<endIndex))
        }

        for (index, draft) in drafts.enumerated() {
            let startsNewIsland: Bool
            if let previousSentenceID {
                startsNewIsland = previousSentenceID != draft.source.sentenceID
                    || (draft.rawRangeMs.lowerBound - (previousRawEndMs ?? draft.rawRangeMs.lowerBound) >= policy.acousticIslandGapMs)
            } else {
                startsNewIsland = true
            }
            if startsNewIsland {
                closeIsland(at: index)
                islandID += 1
                islandStartIndex = index
            }

            let frameRange = timebase.frameRange(
                startMilliseconds: draft.effectiveRangeMs.lowerBound,
                endMilliseconds: draft.effectiveRangeMs.upperBound,
                totalFrames: totalFrames
            )
            let startFrame = frameRange?.lowerBound ?? 0
            let endFrame = frameRange?.upperBound ?? startFrame
            var quality = draft.quality
            if endFrame <= startFrame { quality.insert(.zeroAcousticCoverage) }
            if endFrame - startFrame > TokenPackedWindowPlanner.capacityFrames { quality.insert(.overlong) }
            output.append(Token(
                id: draft.source.id,
                text: draft.source.text,
                rawRangeMs: draft.rawRangeMs,
                effectiveRangeMs: draft.effectiveRangeMs,
                sourceFrameSpans: endFrame > startFrame ? [startFrame..<endFrame] : [],
                sentenceID: draft.source.sentenceID,
                islandID: islandID,
                quality: quality
            ))
            previousSentenceID = draft.source.sentenceID
            previousRawEndMs = draft.rawRangeMs.upperBound
        }
        closeIsland(at: output.count)
        let islands = islandRanges.map {
            AcousticIsland(id: $0.id, sentenceID: $0.sentenceID, tokenIndexes: $0.range)
        }
        return (output, islands)
    }
}

extension TokenTimeline {
    /// Map from sentenceID to the indices in `tokens` that belong to
    /// that sentence.  O(N) one-shot scan; L1 / L2 routing stages
    /// share one precomputed copy instead of each rebuilding the
    /// same map (L2's per-sentence helper previously rescanned
    /// `tokens` for every ASR sentence, an O(N·S) waste).
    ///
    /// Sentences are visited in source order because `tokens` is
    /// already sorted by (rawStartMs, rawEndMs, id) per the init's
    /// `sorted` pass; downstream consumers can rely on
    /// `map[sentenceID]` being a monotonic index list.
    func tokenIndicesBySentence() -> [Int: [Int]] {
        var result: [Int: [Int]] = [:]
        result.reserveCapacity(64)
        for (index, token) in tokens.enumerated() {
            result[token.sentenceID, default: []].append(index)
        }
        return result
    }
}
