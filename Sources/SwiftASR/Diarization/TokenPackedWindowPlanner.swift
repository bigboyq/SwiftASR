import Foundation

/// Plans fixed-size speaker-model inputs without cutting normal ASR tokens.
/// It only describes source fbank spans; callers materialise tensors lazily.
struct TokenPackedWindowPlanner: Sendable {
    static let capacityFrames = 148
    static let targetStrideFrames = 75

    struct FbankSpan: Sendable, Hashable {
        let sourceFrames: Range<Int>
        let packedFrames: Range<Int>
    }

    struct Window: Sendable {
        let islandID: Int
        let tokenIDs: [TokenTimeline.TokenID]
        let spans: [FbankSpan]
        /// Total source-frame weight for each tokenID. This is separate from
        /// `spans` because one token may contain multiple source spans.
        let tokenFrameCounts: [Int]
        let packedFrameCount: Int
        let isOverlongTokenSubwindow: Bool

        init(
            islandID: Int,
            tokenIDs: [TokenTimeline.TokenID],
            spans: [FbankSpan],
            tokenFrameCounts: [Int] = [],
            packedFrameCount: Int,
            isOverlongTokenSubwindow: Bool
        ) {
            self.islandID = islandID
            self.tokenIDs = tokenIDs
            self.spans = spans
            self.tokenFrameCounts = tokenFrameCounts
            self.packedFrameCount = packedFrameCount
            self.isOverlongTokenSubwindow = isOverlongTokenSubwindow
        }

        var paddingFrames: Int { TokenPackedWindowPlanner.capacityFrames - packedFrameCount }
    }

    enum MaterializationError: Error, LocalizedError, Sendable {
        case malformedFbankLength(actual: Int, featureDimension: Int)
        case invalidPackedSpan(Range<Int>)
        case invalidSourceSpan(Range<Int>, totalFrames: Int)
        case spanLengthMismatch(source: Range<Int>, packed: Range<Int>)
        case packedFrameCountMismatch(expected: Int, actual: Int)

        var errorDescription: String? {
            switch self {
            case let .malformedFbankLength(actual, featureDimension):
                return "Speaker fbank 维度损坏：\(actual) 不是 \(featureDimension) 的整数倍。"
            case let .invalidPackedSpan(span):
                return "Speaker packed window 目标范围非法：\(span)。"
            case let .invalidSourceSpan(span, totalFrames):
                return "Speaker source fbank 范围越界：\(span)，总帧数 \(totalFrames)。"
            case let .spanLengthMismatch(source, packed):
                return "Speaker window source/packed 帧数不一致：source=\(source)，packed=\(packed)。"
            case let .packedFrameCountMismatch(expected, actual):
                return "Speaker window packed 帧数不一致：声明 \(expected)，实际 \(actual)。"
            }
        }
    }

    func makeWindows(timeline: TokenTimeline) -> [Window] {
        var windows: [Window] = []
        for island in timeline.islands {
            windows.append(contentsOf: makeIslandWindows(island: island, tokens: timeline.tokens))
        }
        return windows
    }

    /// Build windows for a single speaker island.  Splits the
    /// island's token run into 'normal' (each fits in one window) and
    /// 'overlong' (single token needs to be packed into multiple
    /// windows) sub-sequences, dispatching each to the right
    /// downstream helper.  Empty island is a no-op.
    private func makeIslandWindows(
        island: TokenTimeline.AcousticIsland,
        tokens: [TokenTimeline.Token]
    ) -> [Window] {
        let islandTokens = tokens[island.tokenIndexes].filter { !$0.sourceFrameSpans.isEmpty }
        guard !islandTokens.isEmpty else { return [] }
        var windows: [Window] = []
        var normal: [TokenTimeline.Token] = []
        for token in islandTokens {
            let frameCount = token.effectiveFrameCount
            if frameCount > Self.capacityFrames {
                // An overlong token is model-input-local but still a real
                // token boundary; never let packing jump across it.
                windows.append(contentsOf: makeNormalWindows(tokens: normal, islandID: island.id))
                normal.removeAll(keepingCapacity: true)
                windows.append(contentsOf: makeOverlongWindows(token: token, islandID: island.id))
            } else {
                normal.append(token)
            }
        }
        windows.append(contentsOf: makeNormalWindows(tokens: normal, islandID: island.id))
        return windows
    }

    private func makeOverlongWindows(token: TokenTimeline.Token, islandID: Int) -> [Window] {
        guard let source = token.sourceFrameSpans.first else { return [] }
        var result: [Window] = []
        var start = source.lowerBound
        while start < source.upperBound {
            let end = min(source.upperBound, start + Self.capacityFrames)
            result.append(Window(
                islandID: islandID,
                tokenIDs: [token.id],
                spans: [FbankSpan(sourceFrames: start..<end, packedFrames: 0..<(end - start))],
                tokenFrameCounts: [end - start],
                packedFrameCount: end - start,
                isOverlongTokenSubwindow: true
            ))
            guard end < source.upperBound else { break }
            start += Self.targetStrideFrames
        }
        return result
    }

    private func makeNormalWindows(tokens: [TokenTimeline.Token], islandID: Int) -> [Window] {
        guard !tokens.isEmpty else { return [] }
        let frameCounts = tokens.map(\.effectiveFrameCount)
        var boundaries = [0]
        for count in frameCounts { boundaries.append(boundaries.last! + count) }
        var output: [Window] = []
        var startIndex = 0
        while startIndex < tokens.count {
            var endIndex = startIndex
            var used = 0
            let currentSentenceID = tokens[startIndex].sentenceID
            while endIndex < tokens.count,
                  tokens[endIndex].sentenceID == currentSentenceID,
                  used + frameCounts[endIndex] <= Self.capacityFrames {
                used += frameCounts[endIndex]
                endIndex += 1
            }
            guard endIndex > startIndex else { break }
            var spans: [FbankSpan] = []
            spans.reserveCapacity(endIndex - startIndex)
            var packedCursor = 0
            for token in tokens[startIndex..<endIndex] {
                for source in token.sourceFrameSpans {
                    let count = source.count
                    spans.append(FbankSpan(sourceFrames: source, packedFrames: packedCursor..<(packedCursor + count)))
                    packedCursor += count
                }
            }
            output.append(Window(
                islandID: islandID,
                tokenIDs: tokens[startIndex..<endIndex].map(\.id),
                spans: spans,
                tokenFrameCounts: Array(frameCounts[startIndex..<endIndex]),
                packedFrameCount: used,
                isOverlongTokenSubwindow: false
            ))
            guard endIndex < tokens.count else { break }
            let target = boundaries[startIndex] + Self.targetStrideFrames
            let candidates = (startIndex + 1)...endIndex
            startIndex = candidates.min { lhs, rhs in
                let left = abs(boundaries[lhs] - target)
                let right = abs(boundaries[rhs] - target)
                return left == right ? lhs < rhs : left < right
            } ?? endIndex
        }
        return output
    }

    static func materialize(window: Window, from fbank80: [Float]) throws -> [Float] {
        guard fbank80.count.isMultiple(of: 80) else {
            throw MaterializationError.malformedFbankLength(actual: fbank80.count, featureDimension: 80)
        }
        var feature = [Float](repeating: 0, count: capacityFrames * 80)
        let totalFrames = fbank80.count / 80
        var copiedFrames = 0
        for span in window.spans {
            guard span.sourceFrames.lowerBound >= 0,
                  span.sourceFrames.upperBound <= totalFrames,
                  !span.sourceFrames.isEmpty else {
                throw MaterializationError.invalidSourceSpan(span.sourceFrames, totalFrames: totalFrames)
            }
            guard span.packedFrames.lowerBound >= 0,
                  span.packedFrames.upperBound <= capacityFrames,
                  !span.packedFrames.isEmpty else {
                throw MaterializationError.invalidPackedSpan(span.packedFrames)
            }
            guard span.sourceFrames.count == span.packedFrames.count else {
                throw MaterializationError.spanLengthMismatch(
                    source: span.sourceFrames,
                    packed: span.packedFrames
                )
            }
            copiedFrames += span.sourceFrames.count
            feature.replaceSubrange(
                (span.packedFrames.lowerBound * 80)..<(span.packedFrames.upperBound * 80),
                with: fbank80[(span.sourceFrames.lowerBound * 80)..<(span.sourceFrames.upperBound * 80)]
            )
        }
        guard copiedFrames == window.packedFrameCount else {
            throw MaterializationError.packedFrameCountMismatch(
                expected: window.packedFrameCount,
                actual: copiedFrames
            )
        }
        return feature
    }
}
