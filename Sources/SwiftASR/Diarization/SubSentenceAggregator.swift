import Foundation

/// Shared sub-sentence rollup logic for L1 (`SpeakerConfidenceRouter`)
/// and L2 (`SentenceAcceptanceRouter`).  2026-07-26 refactor: L1 and
/// L2 each had a private `rollUpSubSentences` that shared ~80% of the
/// implementation (vote-tally aggregation + most-conservative status
/// rollup), differing only in:
///   - L1 weighted the avgVoterMargin by per-sub `totalVotes`
///   - L2 left avgVoterMargin at 0 (L2 always emits `.direct`, so
///     the per-sub avgVoterMargin is no longer meaningful)
///
/// Centralising the rollup makes "most-conservative" a single source
/// of truth and removes the ~60 lines of duplicated aggregation.
struct SubSentenceAggregator: Sendable {
    /// Summed per-label vote counts across the input sub-sentences.
    let voteCount: [Int: Int]
    /// Sum of `totalVotes` across the input sub-sentences.
    let totalVotes: Int
    /// `voteCount[voteWinner] / totalVotes` for the aggregated winner,
    /// or 0 if no votes.  Used for the parent `SentenceDecision.topRatio`.
    let topRatio: Float
    /// Tie-broken by larger label (matches L1's per-sub tiebreaker).
    let voteWinner: Int?
    /// Largest `topRatio` across the input subs.  Used for the parent
    /// `SentenceDecision.maxSubTopRatio` heuristic (renamed from
    /// `maxPerTokenScore` in R4-P2-13 — the value is a ratio, not a score).
    let maxTopRatio: Float
    /// Most-conservative status rollup:
    ///   - any .other  → .other
    ///   - else any .pending → .pending
    ///   - else all sub-sentences .direct must agree on the same label,
    ///     else .pending
    let status: SentenceStatus
    let label: Int?

    /// Aggregate a list of sub-sentences (any order) into a single
    /// rollup.  Empty input yields `.other, label: nil, all zeros`.
    /// Single-all-.direct input yields `.direct(winner)` when all
    /// subs agree on a label, otherwise `.pending`.
    static func rollUp(_ subSentences: [SubSentenceDecision]) -> SubSentenceAggregator {
        guard !subSentences.isEmpty else {
            return SubSentenceAggregator(
                voteCount: [:], totalVotes: 0, topRatio: 0,
                voteWinner: nil, maxTopRatio: 0,
                status: .other, label: nil
            )
        }
        var voteCount: [Int: Int] = [:]
        var totalVotes = 0
        var maxTopRatio: Float = 0
        for sub in subSentences {
            for (label, count) in sub.voteCount {
                voteCount[label, default: 0] += count
            }
            totalVotes += sub.totalVotes
            if sub.topRatio > maxTopRatio { maxTopRatio = sub.topRatio }
        }
        let voteWinner = voteCount.max(by: { left, right in
            left.value == right.value ? left.key > right.key : left.value < right.value
        })?.key
        let topRatio: Float = (totalVotes > 0 && voteWinner != nil)
            ? Float(voteCount[voteWinner!] ?? 0) / Float(totalVotes)
            : 0
        // Most-conservative status rollup.
        let status: SentenceStatus
        let label: Int?
        if subSentences.contains(where: { $0.status == .other }) {
            status = .other
            label = nil
        } else if subSentences.contains(where: { $0.status == .pending }) {
            status = .pending
            label = nil
        } else {
            let labels = Set(subSentences.compactMap(\.label))
            if labels.count == 1, let single = labels.first {
                status = .direct
                label = single
            } else {
                status = .pending
                label = nil
            }
        }
        return SubSentenceAggregator(
            voteCount: voteCount, totalVotes: totalVotes,
            topRatio: topRatio, voteWinner: voteWinner,
            maxTopRatio: maxTopRatio,
            status: status, label: label
        )
    }
}

extension SentenceDecision {
    /// Build a parent `SentenceDecision` from a list of (post-L1 or
    /// post-L2) sub-sentences + the parent's `sentenceID`.  Shared by
    /// L1 (which sets a real `avgVoterMargin` weighted by per-sub
    /// totalVotes) and L2 (which always emits `.direct` after its
    /// rescue chain, so `avgVoterMargin` is left at 0).
    static func rollUp(
        sentenceID: Int,
        subSentences: [SubSentenceDecision],
        avgVoterMargin: Float
    ) -> SentenceDecision {
        let agg = SubSentenceAggregator.rollUp(subSentences)
        return SentenceDecision(
            sentenceID: sentenceID,
            status: agg.status,
            label: agg.label,
            voteCount: agg.voteCount,
            totalVotes: agg.totalVotes,
            topRatio: agg.topRatio,
            voteWinner: agg.voteWinner,
            maxSubTopRatio: agg.maxTopRatio,
            avgVoterMargin: avgVoterMargin,
            subSentences: subSentences
        )
    }

}

/// L1/L2 共享的边界排除规则（审计 R4-P1-2 合并点）。
///
/// 当一个 sub-sentence 处在两个已 commit 的 `.direct` 邻居之间时，它的
/// token 不能简单继承邻居的 label（否则会把边界 token 错误并入相邻 turn）。
/// 规则：左右邻居都已 commit（非 nil）时，排除**左**邻居的 label；
/// 否则不排除。两边是同一 label 时也排除该 label（与原 L1/L2 行为一致）。
///
/// 2026-07-26 前 L1 (`SpeakerConfidenceRouter`) 和 L2
/// (`SentenceAcceptanceL2Evaluator`) 各写一份；本函数是单一来源。两份
/// 原实现的 guard 语义等价：都要求左右邻居非 nil 才返回 `[left]`。
///
/// 注意：不放在 `SubSentenceAggregator` 内是因为本仓库的模块 emit 启用了
/// `-experimental-skip-non-inlinable-function-bodies-without-types`，只引用
/// 内置类型（`Int?`/`[Int]`）的 static 方法会被剥离出 partial module，跨
/// 文件调用解析失败。放在模块级 free function 不受该优化影响。
func diarizationBoundaryExcludedLabels(leftLabel: Int?, rightLabel: Int?) -> [Int] {
    guard let left = leftLabel, rightLabel != nil else { return [] }
    return [left]
}
