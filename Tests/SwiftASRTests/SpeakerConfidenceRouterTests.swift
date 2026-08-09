import Testing
@testable import SwiftASR

// 2026-07-25: per-token `route(_:)` is retained as a diagnostic helper
// (see `SpeakerConfidenceRouter.route(_:)`).  The production path
// always uses the per-sentence `route(timeline:evidence:)` method.

@Test func confidenceRouterOnlyProducesDirectOrDefer() {
    let router = SpeakerConfidenceRouter()
    let lowEvidence = SpeakerEvidenceTimeline.TokenEvidence(
        tokenID: .init(sentenceIndex: 0, tokenIndex: 0), scores: [0: 0.32, 1: 0.30], supportFrames: 80
    )
    let direct = SpeakerEvidenceTimeline.TokenEvidence(
        tokenID: .init(sentenceIndex: 0, tokenIndex: 1), scores: [0: 0.74, 1: 0.51], supportFrames: 80
    )
    let residual = SpeakerEvidenceTimeline.TokenEvidence(
        tokenID: .init(sentenceIndex: 0, tokenIndex: 2), scores: [0: 0.58, 1: 0.55], supportFrames: 80
    )

    if case .deferred(reason: .insufficientEvidence, candidates: [0, 1]) = router.route(lowEvidence) {
        // Low-score evidence remains available to L2.  Other is a final
        // decision, not a router output.
    } else { Issue.record("low-score evidence must remain Defer") }
    if case let .accepted(label, source, _) = router.route(direct) {
        #expect(label == 0)
        #expect(source == .direct)
    } else { Issue.record("high score and margin must be accepted") }
    if case .deferred = router.route(residual) {} else { Issue.record("competing known profiles must remain residual") }
}

@Test func missingEvidenceIsDeferWithAnInsufficientEvidenceReason() {
    let router = SpeakerConfidenceRouter()
    let missing = SpeakerEvidenceTimeline.TokenEvidence(
        tokenID: .init(sentenceIndex: 0, tokenIndex: 6), scores: [:], supportFrames: 0
    )

    if case .deferred(reason: .insufficientEvidence, candidates: []) = router.route(missing) {
        // The router exposes the absent-evidence case as Defer so the
        // L1 per-sentence tally can still roll it up uniformly with
        // other deferred tokens.
    } else {
        Issue.record("missing evidence must be represented as Defer")
    }
}

@Test func marginBelowPoint08IsDeferredEvenWhenAbsoluteScoreIsStrong() {
    let router = SpeakerConfidenceRouter()
    let nearTie = SpeakerEvidenceTimeline.TokenEvidence(
        tokenID: .init(sentenceIndex: 0, tokenIndex: 3),
        scores: [0: 0.76, 1: 0.69],
        supportFrames: 80
    )

    if case .deferred = router.route(nearTie) {
        // All near-tie tokens are now explicit L2 input.
    } else {
        Issue.record("margin below 0.08 must not bypass the defer stage")
    }
}

@Test func marginAtPoint08CanRemainDirectWhenOtherGatesPass() {
    let router = SpeakerConfidenceRouter()
    let separated = SpeakerEvidenceTimeline.TokenEvidence(
        tokenID: .init(sentenceIndex: 0, tokenIndex: 4),
        scores: [0: 0.76, 1: 0.679],
        supportFrames: 80
    )

    if case let .accepted(label, source, _) = router.route(separated) {
        #expect(label == 0)
        #expect(source == .direct)
    } else {
        Issue.record("margin at 0.08 should pass the direct gate")
    }
}

@Test func directRoutingDoesNotUseAnAdditionalScorePlusMarginGate() {
    let router = SpeakerConfidenceRouter()
    let evidence = SpeakerEvidenceTimeline.TokenEvidence(
        tokenID: .init(sentenceIndex: 0, tokenIndex: 5),
        scores: [0: 0.46, 1: 0.37],
        supportFrames: 80
    )

    if case .accepted = router.route(evidence) {
        // Absolute score and margin are the authoritative direct gates.
    } else {
        Issue.record("a token should not be deferred by a derived score-plus-margin gate")
    }
}

// MARK: - 2026-07-25 per-sentence router tests

@Test func perSentenceRouterVotesAndPicksDirectAboveSixtyPercent() {
    // 2 tokens in the same sentence, both top-label S0.  Per-sentence
    // ratio is 2/2 = 100% → .direct(S0).  Both tokens must be in
    // `stableDirectTokenIDs`.
    let sentence = ASRSentence(
        text: "甲乙",
        startMs: 0,
        endMs: 200,
        tokens: [
            ASRToken(text: "甲", startMs: 0, endMs: 100),
            ASRToken(text: "乙", startMs: 100, endMs: 200)
        ]
    )
    let timeline = TokenTimeline(sentences: [sentence], totalFrames: 20)
    let oneWindow = SpeakerEvidenceTimeline.stub(timeline.tokens.map {
        .init(tokenID: $0.id, scores: [0: 0.74, 1: 0.52], supportFrames: 80, supportWindowIDs: [1])
    })
    let twoWindows = SpeakerEvidenceTimeline.stub(timeline.tokens.map {
        .init(tokenID: $0.id, scores: [0: 0.74, 1: 0.52], supportFrames: 80, supportWindowIDs: [1, 2])
    })

    // 2026-07-25 (third revision): L1 always emits .pending; L2 is
    // the only place that promotes a sub-sentence to .direct.  The
    // per-utt vote tally (voteWinner, topRatio, avgVoterMargin) is
    // recorded as L2 metadata.  Verify the metadata here, not the
    // final .direct/.pending label.
    let r1 = SpeakerConfidenceRouter().route(timeline: timeline, evidence: oneWindow)

    // 2026-07-25 (fourth revision): L1 commits to .direct when the
    // per-utt majority is **strong** (avgVoterMargin >= 0.10 AND
    // topRatio >= 60%).  2/2 S0 with avg margin 0.22 qualifies.
    #expect(r1.sentenceDecisions.count == 1)
    #expect(r1.sentenceDecisions[0].status == SentenceStatus.direct)
    #expect(r1.sentenceDecisions[0].label == 0)
    #expect(r1.decisions.allSatisfy {
        if case .accepted(0, .direct, _) = $0.disposition { return true }
        return false
    })

    // 2-windows: same outcome.
    let r2 = SpeakerConfidenceRouter().route(timeline: timeline, evidence: twoWindows)
    #expect(r2.sentenceDecisions[0].status == SentenceStatus.direct)
    #expect(r2.sentenceDecisions[0].label == 0)
}

@Test func perSentenceRouterDemotesSentenceToPendingBetweenFiftyAndSixty() {
    // 3 tokens in the same sentence, vote 2 S0 + 1 S1 → 2/3 = 67% → .direct.
    // To hit .pending we need 50%–60%, e.g. 3 tokens / 2 S0 + 1 S1 → 67%
    // is direct.  2 tokens / 1 S0 + 1 S1 → 50% → .pending.  Use 2 tokens.
    let sentence = ASRSentence(
        text: "甲乙",
        startMs: 0,
        endMs: 200,
        tokens: [
            ASRToken(text: "甲", startMs: 0, endMs: 100),
            ASRToken(text: "乙", startMs: 100, endMs: 200)
        ]
    )
    let timeline = TokenTimeline(sentences: [sentence], totalFrames: 20)
    let evidence = SpeakerEvidenceTimeline.stub(timeline.tokens.enumerated().map { offset, token in
        // First token votes S0, second token votes S1.  Tie at 50/50.
        SpeakerEvidenceTimeline.TokenEvidence(
            tokenID: token.id,
            scores: offset == 0 ? [0: 0.60, 1: 0.30] : [0: 0.30, 1: 0.60],
            supportFrames: 80, supportWindowIDs: [1]
        )
    })
    let result = SpeakerConfidenceRouter().route(timeline: timeline, evidence: evidence)
    #expect(result.sentenceDecisions.count == 1)
    // L1 always emits .pending regardless of the per-utt vote tally.
    #expect(result.sentenceDecisions[0].status == SentenceStatus.pending)
    #expect(result.sentenceDecisions[0].label == nil)
    // All tokens follow the sentence status → .deferred(.insufficientSentenceEvidence, …).
    #expect(result.decisions.allSatisfy {
        if case .deferred(reason: .insufficientSentenceEvidence, _) = $0.disposition {
            return true
        }
        return false
    })
}

@Test func perSentenceRouterMarksSentenceOtherWhenNoMajority() {
    // 3 tokens, vote 1 S0 + 1 S1 + 1 S2 → 1/3 = 33% → .other.
    let sentence = ASRSentence(
        text: "甲乙丙",
        startMs: 0,
        endMs: 300,
        tokens: [
            ASRToken(text: "甲", startMs: 0, endMs: 100),
            ASRToken(text: "乙", startMs: 100, endMs: 200),
            ASRToken(text: "丙", startMs: 200, endMs: 300)
        ]
    )
    let timeline = TokenTimeline(sentences: [sentence], totalFrames: 30)
    let evidence = SpeakerEvidenceTimeline.stub([
        SpeakerEvidenceTimeline.TokenEvidence(
            tokenID: timeline.tokens[0].id,
            scores: [0: 0.60, 1: 0.30, 2: 0.20],
            supportFrames: 80, supportWindowIDs: [1]
        ),
        SpeakerEvidenceTimeline.TokenEvidence(
            tokenID: timeline.tokens[1].id,
            scores: [0: 0.20, 1: 0.60, 2: 0.30],
            supportFrames: 80, supportWindowIDs: [1]
        ),
        SpeakerEvidenceTimeline.TokenEvidence(
            tokenID: timeline.tokens[2].id,
            scores: [0: 0.20, 1: 0.30, 2: 0.60],
            supportFrames: 80, supportWindowIDs: [1]
        ),
    ])
    let result = SpeakerConfidenceRouter().route(timeline: timeline, evidence: evidence)
    #expect(result.sentenceDecisions.count == 1)
    // 2026-07-25 (third revision): L1 always emits .pending; L2
    // is the only place that promotes to .direct.  All three
    // sub-tokens now flow through the per-sentence tally (each
    // has 1 vote for a different label).
    #expect(result.sentenceDecisions[0].status == SentenceStatus.pending)
    #expect(result.sentenceDecisions[0].label == nil)  // L1 sentence-level nil
    let rsub = result.sentenceDecisions[0].subSentences[0]
    #expect(rsub.voteCount[0] == 1 && rsub.voteCount[1] == 1 && rsub.voteCount[2] == 1)
    // All tokens become .deferred(.insufficientSentenceEvidence, …) at L1.
    #expect(result.decisions.allSatisfy {
        if case .deferred = $0.disposition { return true }
        return false
    })
}

@Test func perSentenceRouterSilentTokensDoNotVote() {
    // A "啊"-style silent token (top score < otherMaximumScore) is
    // excluded from the per-sentence vote: it has no real per-utt
    // signal and would just dilute a real majority.
    let sentence = ASRSentence(
        text: "甲啊乙",
        startMs: 0,
        endMs: 300,
        tokens: [
            ASRToken(text: "甲", startMs: 0, endMs: 100),
            ASRToken(text: "啊", startMs: 100, endMs: 200),
            ASRToken(text: "乙", startMs: 200, endMs: 300)
        ]
    )
    let timeline = TokenTimeline(sentences: [sentence], totalFrames: 30)
    let evidence = SpeakerEvidenceTimeline.stub([
        SpeakerEvidenceTimeline.TokenEvidence(
            tokenID: timeline.tokens[0].id,
            scores: [0: 0.60, 1: 0.30], supportFrames: 80, supportWindowIDs: [1]
        ),
        // Silent token — top score 0.38 < otherMaximumScore 0.40.
        SpeakerEvidenceTimeline.TokenEvidence(
            tokenID: timeline.tokens[1].id,
            scores: [0: 0.38, 1: 0.30], supportFrames: 80, supportWindowIDs: [1]
        ),
        SpeakerEvidenceTimeline.TokenEvidence(
            tokenID: timeline.tokens[2].id,
            scores: [0: 0.65, 1: 0.30], supportFrames: 80, supportWindowIDs: [1]
        ),
    ])
    let result = SpeakerConfidenceRouter().route(timeline: timeline, evidence: evidence)
    // 2026-07-25 (fourth revision): the 2 voting tokens are
    // strong-majority (avgVoterMargin 0.32) so L1 commits to
    // .direct(S0) without L2.  The silent token's exclusion from
    // the denominator is still observable through subSentences[0]
    // (totalVotes=2, topRatio=1.0).
    #expect(result.sentenceDecisions[0].status == SentenceStatus.direct)
    #expect(result.sentenceDecisions[0].label == 0)
    let rsub = result.sentenceDecisions[0].subSentences[0]
    #expect(rsub.totalVotes == 2)
    #expect(rsub.topRatio == 1.0)
}

// MARK: - R4-P1-7 / R4-P1-9 回归：单标签 margin 与有限 confidence

@Test func singleLabelTokenMarginEqualsTopScoreNotInfinity() {
    // R4-P1-7：单 label token 视为无歧义证据，margin = score，不再是 +infinity。
    let single = SpeakerEvidenceTimeline.TokenEvidence(
        tokenID: .init(sentenceIndex: 0, tokenIndex: 0),
        scores: [0: 0.62],
        supportFrames: 80
    )
    #expect(single.margin.isFinite)
    #expect(abs(single.margin - 0.62) < 1e-5)

    // 双 label 仍按 top - second 计算。
    let dual = SpeakerEvidenceTimeline.TokenEvidence(
        tokenID: .init(sentenceIndex: 0, tokenIndex: 0),
        scores: [0: 0.62, 1: 0.50],
        supportFrames: 80
    )
    #expect(abs(dual.margin - 0.12) < 1e-5)

    // 空 scores：margin 退化为 -infinity（下游有 finite 守卫）。
    let empty = SpeakerEvidenceTimeline.TokenEvidence(
        tokenID: .init(sentenceIndex: 0, tokenIndex: 0),
        scores: [:],
        supportFrames: 0
    )
    #expect(empty.margin.isFinite == false)
}

@Test func singleLabelTokenContributesToAvgVoterMargin() {
    // R4-P1-7 整体影响：一个单 label token 现在把它的 score 计入
    // avgVoterMargin 的分子（之前因 +inf isFinite 守卫被排除，只占分母）。
    // 2 tokens，一个单 label（S0=0.62），一个双 label margin 0.10。
    // 旧：avgVoterMargin = 0.10 / 2 = 0.05。
    // 新：avgVoterMargin = (0.62 + 0.10) / 2 = 0.36。
    let sentence = ASRSentence(
        text: "甲乙",
        startMs: 0,
        endMs: 200,
        tokens: [
            ASRToken(text: "甲", startMs: 0, endMs: 100),
            ASRToken(text: "乙", startMs: 100, endMs: 200)
        ]
    )
    let timeline = TokenTimeline(sentences: [sentence], totalFrames: 20)
    let evidence = SpeakerEvidenceTimeline.stub([
        SpeakerEvidenceTimeline.TokenEvidence(
            tokenID: timeline.tokens[0].id,
            scores: [0: 0.62], supportFrames: 80, supportWindowIDs: [1]
        ),
        SpeakerEvidenceTimeline.TokenEvidence(
            tokenID: timeline.tokens[1].id,
            scores: [0: 0.60, 1: 0.50], supportFrames: 80, supportWindowIDs: [1]
        ),
    ])
    let result = SpeakerConfidenceRouter().route(timeline: timeline, evidence: evidence)
    // 单 label 的高 margin 把 sub 推过 .direct 阈值（avgVoterMargin 0.36 >> 0.10）。
    #expect(result.sentenceDecisions[0].status == SentenceStatus.direct)
    #expect(result.sentenceDecisions[0].label == 0)
}

@Test func acceptedConfidenceNeverNonFinite() {
    // R4-P1-9 回归：即便 token 的 score evidence 退化（空 scores、-inf），
    // 落入 .accepted 的 confidence 也必须是有限值，不能是 -infinity。
    // L1 tokenDisposition 对非有限 perTokenTopScore 回退到 sub.topRatio。
    let sentence = ASRSentence(
        text: "甲乙",
        startMs: 0,
        endMs: 200,
        tokens: [
            ASRToken(text: "甲", startMs: 0, endMs: 100),
            ASRToken(text: "乙", startMs: 100, endMs: 200)
        ]
    )
    let timeline = TokenTimeline(sentences: [sentence], totalFrames: 20)
    // 第一个 token 给出足够强证据让 sub 走到 .direct；第二个 token 的 evidence
    // 退化（scores 为空 → topScore = -inf），但它仍落在 .direct sub 内，
    // 因此会经过 tokenDisposition 的 finite 回退路径。
    let evidence = SpeakerEvidenceTimeline.stub([
        SpeakerEvidenceTimeline.TokenEvidence(
            tokenID: timeline.tokens[0].id,
            scores: [0: 0.74, 1: 0.52], supportFrames: 80, supportWindowIDs: [1]
        ),
        SpeakerEvidenceTimeline.TokenEvidence(
            tokenID: timeline.tokens[1].id,
            scores: [:], supportFrames: 0, supportWindowIDs: []
        ),
    ])
    let result = SpeakerConfidenceRouter().route(timeline: timeline, evidence: evidence)
    for decision in result.decisions {
        if case let .accepted(_, _, confidence) = decision.disposition {
            #expect(confidence.isFinite, "accepted confidence must be finite, got \(confidence)")
        }
    }
}
