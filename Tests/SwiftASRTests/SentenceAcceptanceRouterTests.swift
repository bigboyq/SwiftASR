import Foundation
import Testing
@testable import SwiftASR

/// Unit tests for the four L2 critical boundaries the 2026-07-26 codex
/// audit flagged:
///
///   1. **P0** — a sub with no usable evidence must NOT be force-
///      promoted to `.direct`.  The `Other → Speaker/fp_system_speaker`
///      contract says zero-evidence subs stay `.other` and surface as
///      the Speaker sentinel at the result page.
///   2. **P1 boundary-exclusion** — only `.direct` neighbours count as
///      anchor labels.  A `.pending` neighbour carries a `label` (its
///      L1 voteWinner) but the boundary rule must not treat it as a
///      committed turn boundary.
///   3. **P1 mean-score fallback** — the fallback's mean-pick must
///      filter `excludedLabels` so the boundary rule's exclusion
///      cannot be undone by the fallback.  When the filter leaves an
///      empty candidate set with no finite mean, the sub stays
///      `.other` instead of falling back to `sub.voteWinner ?? 0`
///      (the pre-fix behaviour that pinned every zero-evidence sub
///      to label 0).
///   4. **pause-split evidence gate** — 800ms is only a timestamp
///      candidate. L2 must also see a contiguous low-energy run at
///      the boundary. This preserves the ADHD2 rescue without letting
///      a stretched CIF token split a word such as "什么".
///
/// These tests are **lightweight** — no audio / model load — so they
/// run in seconds and catch pure-logic regressions before the heavier
/// `SentenceAcceptanceDiagnostic` end-to-end suite does.
@Suite(.serialized)
struct SentenceAcceptanceRouterTests {

    // MARK: - Test helpers

    /// Build a hand-rolled `TokenTimeline` from a single ASR sentence.
    /// Tokens are placed at the given (startMs, endMs) so tests can
    /// exercise the pause-split logic with deterministic durations.
    private func singleSentenceTimeline(
        tokenSpecs: [(text: String, startMs: Int, endMs: Int)]
    ) -> TokenTimeline {
        let tokens = tokenSpecs.map { spec in
            ASRToken(text: spec.text, startMs: spec.startMs, endMs: spec.endMs)
        }
        let totalMs = (tokenSpecs.last?.endMs ?? 0)
        let sentence = ASRSentence(
            text: tokens.map(\.text).joined(),
            startMs: tokenSpecs.first?.startMs ?? 0,
            endMs: totalMs,
            tokens: tokens
        )
        return TokenTimeline(sentences: [sentence], totalFrames: totalMs / 10 + 10)
    }

    private func evidence(
        for timeline: TokenTimeline,
        perTokenScores: [Int: Float]
    ) -> SpeakerEvidenceTimeline {
        SpeakerEvidenceTimeline.stub(timeline.tokens.map {
            .init(tokenID: $0.id, scores: perTokenScores, supportFrames: 80, supportWindowIDs: [1])
        })
    }

    private func silentEvidence(for timeline: TokenTimeline) -> SpeakerEvidenceTimeline {
        // Zero-frame support + all -∞ scores — represents a token with
        // no usable acoustic evidence (silence, masked audio, etc.).
        SpeakerEvidenceTimeline.stub(timeline.tokens.map {
            .init(tokenID: $0.id, scores: [0: -.infinity, 1: -.infinity, 2: -.infinity], supportFrames: 0)
        })
    }

    /// Run the full L1 → L2 pipeline against the given timeline + evidence.
    private func runPipeline(
        timeline: TokenTimeline,
        evidence: SpeakerEvidenceTimeline,
        acousticPauseEvidence: AcousticPauseEvidence = AcousticPauseEvidence(fbank80: [])
    ) -> (l1: SpeakerRoutingResult, l2: SentenceAcceptanceRouter.Result) {
        let tokenMap = timeline.tokenIndicesBySentence()
        let l1 = SpeakerConfidenceRouter().route(
            timeline: timeline, evidence: evidence, tokenIndicesBySentence: tokenMap
        )
        let l2 = SentenceAcceptanceRouter(
            acousticPauseEvidence: acousticPauseEvidence
        ).route(
            timeline: timeline, l1: l1, evidence: evidence, tokenIndicesBySentence: tokenMap
        )
        return (l1, l2)
    }

    /// Synthetic pre-CMVN log-mel frames. Speech is 0, verified silence is
    /// -10 on every mel bin, comfortably below the evidence gate.
    private func pauseEvidence(totalMs: Int, quietRangesMs: [Range<Int>]) -> AcousticPauseEvidence {
        let frames = max(1, (totalMs + 9) / 10)
        var fbank = [Float](repeating: 0, count: frames * 80)
        for frame in 0..<frames {
            let ms = frame * 10
            guard quietRangesMs.contains(where: { $0.contains(ms) }) else { continue }
            for bin in 0..<80 { fbank[frame * 80 + bin] = -10 }
        }
        return AcousticPauseEvidence(fbank80: fbank)
    }

    // MARK: - P0: no usable evidence → .other

    @Test func allSilentSubStaysOtherInsteadOfForcingDirectZero() {
        // 3 tokens, all with supportFrames == 0 and all -∞ scores.
        // L1 sees zero voters → sub is .pending (label=nil, voteWinner=nil).
        // L2 must NOT pin this to .direct(0) (the pre-fix behaviour
        // via `sub.voteWinner ?? 0`).  It must stay .other and every
        // token must surface as .other → Speaker sentinel.
        let timeline = singleSentenceTimeline(tokenSpecs: [
            ("甲", 0, 100),
            ("乙", 100, 200),
            ("丙", 200, 300),
        ])
        let evidence = silentEvidence(for: timeline)
        let (l1, l2) = runPipeline(timeline: timeline, evidence: evidence)

        // L1: zero voters → .pending with no label.
        #expect(l1.sentenceDecisions.count == 1)
        #expect(l1.sentenceDecisions[0].status == .pending)
        #expect(l1.sentenceDecisions[0].label == nil)
        #expect(l1.sentenceDecisions[0].voteWinner == nil)

        // L2: no usable evidence → .other, NOT .direct(0).
        #expect(l2.sentenceDecisions.count == 1)
        #expect(l2.sentenceDecisions[0].status == .other, "no-evidence sentence must stay .other; got \(l2.sentenceDecisions[0].status)")
        #expect(l2.sentenceDecisions[0].label == nil)

        // Every token is .other (Other → Speaker/fp_system_speaker contract).
        for (idx, decision) in l2.tokenDecisions.enumerated() {
            if case .other = decision.disposition {
                // expected
            } else {
                Issue.record("token[\(idx)] should be .other; got \(decision.disposition)")
            }
        }

        // The L2 override should report applied=false (no usable evidence
        // to commit a label).
        #expect(l2.overrides.count == 1)
        #expect(l2.overrides[0].applied == false, "L2 override should be applied=false when no usable evidence; got applied=\(l2.overrides[0].applied)")
    }

    // MARK: - P1: only .direct neighbours trigger boundary exclusion

    @Test func pendingNeighbourBoundaryExclusionCannotFlipWinner() {
        // 3 sub-sentences, all .pending (avgVoterMargin 0.05 < 0.10
        // — every sub's per-utt majority is weak).
        //
        //   sub 0: both tokens vote S0, weak margin
        //   sub 1: token 0 votes S0, token 1 votes S1 — mixed tops,
        //          with **S0 holding the highest mean** (token 0 has
        //          a strong S0 score 0.55; token 1's S1 is weaker)
        //   sub 2: both tokens vote S2, weak margin
        //
        // Pre-fix behaviour: L1 + L2 both read neighbours' `.label`
        // without checking `.status`, so the `.pending` neighbours'
        // voteWinners (S0 and S2) are treated as anchors.  The
        // boundary rule on sub 1 returns `[S0]` (left != right →
        // `[left]`), re-votes sub 1 excluding S0, and the next-best
        // countExcl lands on S1 at 100% — sub 1 gets mis-promoted to
        // `.direct(S1)`.
        //
        // Post-fix behaviour: `.pending` neighbours are NOT anchors.
        // L1's boundary rule is consulted (avgMargin 0.05 < 0.10)
        // but excluded is [] because both neighbours are .pending.
        // L2's `computeBoundaryLabels` also returns [].  Sub 1 stays
        // .pending after L1.  L2's mean-score fallback picks S0
        // (the highest mean across sub 1's tokens: 0.55+0.40 = 0.95,
        // vs S1's 0.30+0.55 = 0.85), so sub 1 becomes .direct(S0).
        //
        // The pre-fix and post-fix outcomes differ on sub 1's L2
        // label (.direct(S1) vs .direct(S0)) and on the
        // `excludedLabels` field ([] vs [S0]).  Both assertions are
        // made so a future regression on either dimension is caught.
        let sentence = ASRSentence(
            text: "甲乙，丙丁，戊己，",
            startMs: 0, endMs: 600,
            tokens: [
                ASRToken(text: "甲", startMs: 0, endMs: 100),
                ASRToken(text: "乙，", startMs: 100, endMs: 200),
                ASRToken(text: "丙", startMs: 200, endMs: 300),
                ASRToken(text: "丁，", startMs: 300, endMs: 400),
                ASRToken(text: "戊", startMs: 400, endMs: 500),
                ASRToken(text: "己，", startMs: 500, endMs: 600),
            ]
        )
        let timeline = TokenTimeline(sentences: [sentence], totalFrames: 70)
        let evidence = SpeakerEvidenceTimeline.stub(timeline.tokens.enumerated().map { offset, token in
            // Per-sub margin setup:
            //   sub 0 (offsets 0, 1): margin 0.05 → avgMargin 0.05 < 0.10 → .pending
            //   sub 1 (offsets 2, 3): mixed per-utt tops — token 0 votes
            //     S0 (margin 0.10), token 3 votes S1 (margin 0.05).
            //     avgMargin 0.075 < 0.10 → L1's boundary rule FIRES (key
            //     to making the pre-fix bug manifest).  topRatio 0.5 →
            //     .pending.  S0 has the highest mean (0.55+0.50=1.05)
            //     vs S1's 0.45+0.55=1.00, so post-fix mean-fallback
            //     picks S0.
            //   sub 2 (offsets 4, 5): margin 0.05 → .pending
            //
            // topScore must be ≥ 0.40 (otherMaximumScore) for the
            // token to count as a voter.
            let scores: [Int: Float]
            switch offset {
            case 0, 1: scores = [0: 0.45, 1: 0.40, 2: 0.30]
            case 2: scores = [0: 0.55, 1: 0.45, 2: 0.30]
            case 3: scores = [0: 0.50, 1: 0.55, 2: 0.30]
            case 4, 5: scores = [0: 0.35, 1: 0.30, 2: 0.40]
            default: scores = [0: 0.30, 1: 0.30, 2: 0.30]
            }
            return SpeakerEvidenceTimeline.TokenEvidence(
                tokenID: token.id, scores: scores,
                supportFrames: 80, supportWindowIDs: [1]
            )
        })

        let tokenMap = timeline.tokenIndicesBySentence()
        let l1 = SpeakerConfidenceRouter().route(
            timeline: timeline, evidence: evidence, tokenIndicesBySentence: tokenMap
        )
        let l2 = SentenceAcceptanceRouter().route(
            timeline: timeline, l1: l1, evidence: evidence, tokenIndicesBySentence: tokenMap
        )

        // L1: all 3 subs .pending (avgVoterMargin 0.05 < 0.10).
        #expect(l1.sentenceDecisions.count == 1)
        let l1Subs = l1.sentenceDecisions[0].subSentences
        #expect(l1Subs.count == 3)
        for (n, sub) in l1Subs.enumerated() {
            #expect(sub.status == .pending,
                    "L1 sub[\(n)] should be .pending (avgVoterMargin<0.10); got \(sub.status) with avgMargin=\(sub.avgVoterMargin)")
        }

        // L2: sub 0 picks S0 (mean-fallback).  Sub 2 picks S2.
        // Sub 1: post-fix picks S0 via mean-fallback; pre-fix
        // would have mis-promoted to S1 via boundary-rule re-vote
        // (because pre-fix treated the .pending neighbours' labels
        // as anchors).  excludedLabels is the second signal: post-fix
        // it's [] (boundary rule skipped), pre-fix it would be [S0].
        let l2Subs = l2.sentenceDecisions[0].subSentences
        #expect(l2Subs.count == 3)
        #expect(l2Subs[0].status == .direct && l2Subs[0].label == 0)
        #expect(l2Subs[1].status == .direct,
                "L2 sub[1] should be promoted; got \(l2Subs[1].status)")
        #expect(l2Subs[1].label == 0,
                "L2 sub[1] should be S0 (highest mean; mean-fallback).  Pre-fix mis-promoted to S1 via boundary rule on .pending neighbours; got \(l2Subs[1].label.map { "S\($0)" } ?? "nil")")
        #expect(l2Subs[1].excludedLabels.isEmpty,
                "L2 sub[1] excludedLabels must be [] (neighbours are .pending, not .direct anchors); pre-fix would have set it to [S0]")
        #expect(l2Subs[2].status == .direct && l2Subs[2].label == 2)
    }

    @Test func rawTopRatioAtEightyPercentProtectsWinnerFromBoundaryExclusion() {
        // Jonathan 2026-07-30 regression, reduced to three sub-sentences:
        //
        //   direct S2 | weak 80% raw S2 | direct S2
        //
        // The middle sub is pending because avgMargin=0.08 < 0.10, but four
        // of five voters still choose S2. At the inclusive 80% guard,
        // neither L1 nor L2 may exclude S2 and manufacture a runner-up turn.
        var tokens: [ASRToken] = []
        let texts = ["甲", "乙，", "丙", "丁", "戊", "己", "庚，", "辛", "壬，"]
        for (index, text) in texts.enumerated() {
            tokens.append(ASRToken(
                text: text,
                startMs: index * 100,
                endMs: (index + 1) * 100
            ))
        }
        let sentence = ASRSentence(
            text: tokens.map(\.text).joined(),
            startMs: 0,
            endMs: 900,
            tokens: tokens
        )
        let timeline = TokenTimeline(sentences: [sentence], totalFrames: 100)
        let evidence = SpeakerEvidenceTimeline.stub(
            timeline.tokens.enumerated().map { offset, token in
                let scores: [Int: Float]
                switch offset {
                case 0, 1, 7, 8:
                    scores = [0: 0.35, 1: 0.30, 2: 0.75]
                case 2...5:
                    scores = [0: 0.42, 1: 0.30, 2: 0.50]
                case 6:
                    scores = [0: 0.50, 1: 0.30, 2: 0.42]
                default:
                    scores = [0: 0.30, 1: 0.30, 2: 0.30]
                }
                return SpeakerEvidenceTimeline.TokenEvidence(
                    tokenID: token.id,
                    scores: scores,
                    supportFrames: 80,
                    supportWindowIDs: [1]
                )
            }
        )

        let (l1, l2) = runPipeline(timeline: timeline, evidence: evidence)
        let l1Subs = l1.sentenceDecisions[0].subSentences
        #expect(l1Subs.count == 3)
        #expect(l1Subs[0].status == .direct && l1Subs[0].label == 2)
        #expect(l1Subs[1].status == .pending && l1Subs[1].voteWinner == 2)
        #expect(abs(l1Subs[1].topRatio - 0.80) < 0.0001)
        #expect(l1Subs[1].excludedLabels.isEmpty)
        #expect(l1Subs[2].status == .direct && l1Subs[2].label == 2)

        let l2Subs = l2.sentenceDecisions[0].subSentences
        #expect(l2Subs.count == 3)
        #expect(l2Subs[1].status == .direct && l2Subs[1].label == 2)
        #expect(l2Subs[1].excludedLabels.isEmpty)
    }

    @Test func meanScoreFallbackFiltersExcludedLabel() {
        // 3 sub-sentences.  Left and right are .direct(S0) (strong).
        // Middle is .pending (weak margin) with a 3/5 raw S0 majority.
        // This is deliberately below the 80% raw-majority protection.
        // After S0 exclusion, independent next-best votes spread across
        // S1/S2/S3, keeping the re-vote below 60% so the mean-score
        // fallback path is still exercised.
        //
        // L2's processL2Sub:
        //   1. isStrong = false (avgMargin 0.02)
        //   2. excluded = [S0] (neighbours are .direct S0)
        //   3. re-collect with excluded:
        //      voteCountExcl = {S1:2, S2:2, S3:1},
        //      ratio = 0.4 < 0.60 → no promotion.
        //   4. mean-score fallback runs.
        //      - scoreSum gives S1 and S2 an equal 1.62 after filtering S0.
        //      - max-by returns smaller key on tie = S1.
        //
        // The pre-fix and post-fix outcomes differ on sub 1's L2
        // label (.direct(S0) vs .direct(S1)).  Asserting
        // excludedLabels == [S0] pins the second signal that the
        // boundary rule did fire (so the test isolates the
        // mean-score-fallback filter from the boundary-rule
        // exclusion itself).
        let sentence = ASRSentence(
            text: "甲乙，丙丁戊己庚，辛壬，",
            startMs: 0, endMs: 900,
            tokens: [
                ASRToken(text: "甲", startMs: 0, endMs: 100),
                ASRToken(text: "乙，", startMs: 100, endMs: 200),
                ASRToken(text: "丙", startMs: 200, endMs: 300),
                ASRToken(text: "丁", startMs: 300, endMs: 400),
                ASRToken(text: "戊", startMs: 400, endMs: 500),
                ASRToken(text: "己", startMs: 500, endMs: 600),
                ASRToken(text: "庚，", startMs: 600, endMs: 700),
                ASRToken(text: "辛", startMs: 700, endMs: 800),
                ASRToken(text: "壬，", startMs: 800, endMs: 900),
            ]
        )
        let timeline = TokenTimeline(sentences: [sentence], totalFrames: 100)
        let evidence = SpeakerEvidenceTimeline.stub(timeline.tokens.enumerated().map { offset, token in
            let scores: [Int: Float]
            switch offset {
            case 0, 1, 7, 8:
                // Sub 0 and sub 2: strong S0 (margin 0.35) → .direct(S0).
                scores = [0: 0.75, 1: 0.40, 2: 0.30, 3: 0.20]
            case 2:
                scores = [0: 0.42, 1: 0.40, 2: 0.30, 3: 0.20]
            case 3:
                scores = [0: 0.42, 1: 0.20, 2: 0.40, 3: 0.30]
            case 4:
                scores = [0: 0.42, 1: 0.30, 2: 0.20, 3: 0.40]
            case 5:
                scores = [0: 0.40, 1: 0.42, 2: 0.30, 3: 0.20]
            case 6:
                scores = [0: 0.40, 1: 0.30, 2: 0.42, 3: 0.20]
            default:
                scores = [0: 0.30, 1: 0.30, 2: 0.30, 3: 0.30]
            }
            return SpeakerEvidenceTimeline.TokenEvidence(
                tokenID: token.id, scores: scores,
                supportFrames: 80, supportWindowIDs: [1]
            )
        })

        let tokenMap = timeline.tokenIndicesBySentence()
        let l1 = SpeakerConfidenceRouter().route(
            timeline: timeline, evidence: evidence, tokenIndicesBySentence: tokenMap
        )
        let l2 = SentenceAcceptanceRouter().route(
            timeline: timeline, l1: l1, evidence: evidence, tokenIndicesBySentence: tokenMap
        )

        // L1: sub 0 + sub 2 = .direct(S0); sub 1 remains .pending after
        // exclusion because the two surviving raw voters split S1/S2.
        let l1Subs = l1.sentenceDecisions[0].subSentences
        #expect(l1Subs.count == 3)
        #expect(l1Subs[0].status == .direct && l1Subs[0].label == 0)
        #expect(l1Subs[1].status == .pending,
                "middle sub should be .pending (weak margin); got \(l1Subs[1].status)")
        #expect(l1Subs[1].label == 1,
                "middle sub should retain the deterministic S1 tie winner after exclusion; got \(l1Subs[1].label.map { "S\($0)" } ?? "nil")")
        #expect(l1Subs[2].status == .direct && l1Subs[2].label == 0)

        // L2: middle sub's boundary rule fires, excludes S0.
        // voteCountExcl = {S1:2, S2:2, S3:1}, ratio 0.4 < 0.60.
        // Mean-score fallback filters S0; S1/S2 tie and S1 wins.
        // Sub = .direct(S1).  Pre-fix would have picked S0 (the
        // excluded label) and silently undone the boundary exclusion.
        let l2Subs = l2.sentenceDecisions[0].subSentences
        #expect(l2Subs.count == 3)
        #expect(l2Subs[0].status == .direct && l2Subs[0].label == 0)
        #expect(l2Subs[1].status == .direct,
                "L2 should promote the middle sub via mean-score fallback; got \(l2Subs[1].status)")
        #expect(l2Subs[1].label == 1,
                "L2 should pick S1 (next-best finite mean after S0 excluded).  Pre-fix would re-pick S0 (highest mean before filter); got \(l2Subs[1].label.map { "S\($0)" } ?? "nil")")
        #expect(l2Subs[1].excludedLabels == [0],
                "L2 sub[1] excludedLabels should be [S0] (boundary rule fired on .direct S0 neighbours); got \(l2Subs[1].excludedLabels)")
        #expect(l2Subs[2].status == .direct && l2Subs[2].label == 0)
    }

    // MARK: - pause-split evidence gate

    @Test func pauseSplitterUsesEarliestBoundaryWhenConfirmedGapsTie() {
        let timeline = singleSentenceTimeline(tokenSpecs: [
            ("甲", 0, 800),
            ("乙", 800, 1_600),
            ("丙", 1_600, 1_700),
        ])
        let acousticEvidence = AcousticPauseEvidence(replayCandidates: [
            .init(
                leftTokenStartMs: 0,
                rightTokenStartMs: 800,
                candidatePauseMs: 800,
                confirmedSilenceMs: 200
            ),
            .init(
                leftTokenStartMs: 800,
                rightTokenStartMs: 1_600,
                candidatePauseMs: 800,
                confirmedSilenceMs: 200
            ),
        ])
        let splitter = SentenceAcceptancePauseSplitter(
            acousticEvidence: acousticEvidence
        )
        let parent = SubSentenceDecision(
            startTokenIndex: 0,
            endTokenIndex: 3,
            status: .pending,
            label: nil,
            voteCount: [:],
            totalVotes: 0,
            topRatio: 0,
            voteWinner: nil,
            avgVoterMargin: 0,
            excludedLabels: []
        )

        let split = splitter.findSplit(
            sub: parent,
            tokenIndices: timeline.tokenIndicesBySentence()[0] ?? [],
            timeline: timeline,
            thresholdMs: 800,
            minimumSilenceMs: 200
        )

        #expect(split?.offset == 1)
        #expect(split?.gapMs == 800)
        #expect(split?.confirmedSilenceMs == 200)
    }

    @Test func pauseSplitFiresAtExactlyThresholdMs() {
        // 3 tokens in a single sub-sentence.  Middle token "乙" has
        // duration 800ms (= threshold).  L1 puts the sub in .pending
        // (3 different labels → topRatio 1/3 < 0.60).  L2 pause-split
        // should fire at 800ms (>= threshold) and split into 2
        // sub-shells: ["甲"] and ["乙丙"].
        let timeline = singleSentenceTimeline(tokenSpecs: [
            ("甲", 0, 100),
            ("乙", 100, 900),    // 800ms duration
            ("丙", 900, 1000),
        ])
        let evidence = SpeakerEvidenceTimeline.stub(timeline.tokens.enumerated().map { offset, token in
            let scores: [Int: Float]
            switch offset {
            case 0: scores = [0: 0.65, 1: 0.30, 2: 0.20]
            case 1: scores = [0: 0.30, 1: 0.65, 2: 0.20]
            default: scores = [0: 0.20, 1: 0.30, 2: 0.65]
            }
            return SpeakerEvidenceTimeline.TokenEvidence(
                tokenID: token.id, scores: scores,
                supportFrames: 80, supportWindowIDs: [1]
            )
        })

        let tokenMap = timeline.tokenIndicesBySentence()
        let l1 = SpeakerConfidenceRouter().route(
            timeline: timeline, evidence: evidence, tokenIndicesBySentence: tokenMap
        )
        let l2 = SentenceAcceptanceRouter(
            acousticPauseEvidence: pauseEvidence(totalMs: 1_000, quietRangesMs: [700..<900])
        ).route(
            timeline: timeline, l1: l1, evidence: evidence, tokenIndicesBySentence: tokenMap
        )

        // L1: 1 sub, 3 tokens voting 3 different labels, topRatio=1/3 < 0.60 → .pending.
        #expect(l1.sentenceDecisions[0].status == .pending)

        // L2: timestamp candidate + 200ms verified silence causes a split.
        // The split happens AT the boundary with the largest gap:
        // for "甲(0-100) 乙(100-900) 丙(900-1000)", the gap between
        // 乙 and 丙 is max(leftDur=800, interGap=0) = 800.  The split
        // is at offset 2 (start of 丙), so the LEFT shell covers
        // [0, 2) = "甲乙" and the RIGHT shell covers [2, 3) = "丙".
        // This matches the production s=1166 split pattern: the long
        // token ("我" 1100ms there, "乙" 800ms here) stays with the
        // LEFT half so its surrounding context votes together.
        let l2Subs = l2.sentenceDecisions[0].subSentences
        #expect(l2Subs.count == 2,
                "800ms duration should trigger pause-split (>= threshold); got \(l2Subs.count) sub-shells")
        #expect(l2Subs[0].startTokenIndex == 0)
        #expect(l2Subs[0].endTokenIndex == 2)
        #expect(l2Subs[1].startTokenIndex == 2)
        #expect(l2Subs[1].endTokenIndex == 3)

        // Each L2 sub should have applied=true (each half is rescued to .direct).
        #expect(l2Subs[0].status == .direct)
        #expect(l2Subs[1].status == .direct)

        // The pause-split override records the gap.
        let splitOverrides = l2.overrides.filter { $0.splitGapMs != nil }
        #expect(splitOverrides.count == 2, "expected 2 pause-split overrides; got \(splitOverrides.count)")
        for o in splitOverrides {
            #expect(o.splitGapMs == 800, "expected splitGapMs=800; got \(o.splitGapMs ?? -1)")
            #expect(o.confirmedSilenceMs == 200,
                    "expected 200ms confirmed silence; got \(o.confirmedSilenceMs ?? -1)")
        }
    }

    @Test func stretchedTokenWithoutSilenceDoesNotSplit() {
        // This mirrors “什/么”: CIF gives the first token an 800ms span,
        // but the fbank remains speech-like throughout. Timestamp length
        // alone must not create a false speaker boundary.
        let timeline = singleSentenceTimeline(tokenSpecs: [
            ("什", 0, 800),
            ("么", 800, 900),
            ("这", 900, 1_000),
        ])
        let evidence = SpeakerEvidenceTimeline.stub(timeline.tokens.enumerated().map { offset, token in
            let scores: [Int: Float] = switch offset {
            case 0: [0: 0.65, 1: 0.30, 2: 0.20]
            case 1: [0: 0.30, 1: 0.65, 2: 0.20]
            default: [0: 0.20, 1: 0.30, 2: 0.65]
            }
            return .init(tokenID: token.id, scores: scores, supportFrames: 80, supportWindowIDs: [1])
        })

        let (_, l2) = runPipeline(
            timeline: timeline,
            evidence: evidence,
            acousticPauseEvidence: pauseEvidence(totalMs: 1_000, quietRangesMs: [])
        )
        #expect(l2.sentenceDecisions[0].subSentences.count == 1)
        #expect(l2.overrides.allSatisfy { $0.splitGapMs == nil })
    }

    @Test func pauseSplitSkipsJustBelowThreshold() {
        // Same as the threshold test, but middle token duration is
        // 799ms (just below 800).  No split; L2 processes the sub
        // as a single (half-)sub.
        let timeline = singleSentenceTimeline(tokenSpecs: [
            ("甲", 0, 100),
            ("乙", 100, 899),    // 799ms duration
            ("丙", 899, 1000),
        ])
        let evidence = SpeakerEvidenceTimeline.stub(timeline.tokens.enumerated().map { offset, token in
            let scores: [Int: Float]
            switch offset {
            case 0: scores = [0: 0.65, 1: 0.30, 2: 0.20]
            case 1: scores = [0: 0.30, 1: 0.65, 2: 0.20]
            default: scores = [0: 0.20, 1: 0.30, 2: 0.65]
            }
            return SpeakerEvidenceTimeline.TokenEvidence(
                tokenID: token.id, scores: scores,
                supportFrames: 80, supportWindowIDs: [1]
            )
        })

        let tokenMap = timeline.tokenIndicesBySentence()
        let l1 = SpeakerConfidenceRouter().route(
            timeline: timeline, evidence: evidence, tokenIndicesBySentence: tokenMap
        )
        let l2 = SentenceAcceptanceRouter().route(
            timeline: timeline, l1: l1, evidence: evidence, tokenIndicesBySentence: tokenMap
        )

        // L1: .pending (same as above).
        #expect(l1.sentenceDecisions[0].status == .pending)

        // L2: 799ms < 800ms threshold → no split.  Single sub remains.
        let l2Subs = l2.sentenceDecisions[0].subSentences
        #expect(l2Subs.count == 1,
                "799ms duration should NOT trigger pause-split; got \(l2Subs.count) sub-shells")
        #expect(l2Subs[0].startTokenIndex == 0)
        #expect(l2Subs[0].endTokenIndex == 3)

        // No split overrides emitted.
        #expect(l2.overrides.allSatisfy { $0.splitGapMs == nil })
    }
}
