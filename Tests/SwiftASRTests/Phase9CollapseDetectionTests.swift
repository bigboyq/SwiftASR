import Testing
import Foundation
@testable import SwiftASR

@Suite("SpeakerOrchestrator.looksLikeCollapsedFirstHalf 崩塌检测测试")
struct Phase9CollapseDetectionTests {

    @Test func singlePackedWindowBuildsOneAcousticProfile() {
        var embedding = [Float](repeating: 0, count: 192)
        embedding[0] = 1
        let result = SpeakerOrchestrator().cluster(
            embeddings: embedding,
            chunks: [(0, 1_000)]
        )
        #expect(result.failure == nil)
        #expect(result.labels == [0])
        #expect(result.profiles.count == 1)
        #expect(result.profiles.first?.acousticLabel == 0)
    }

    @Test func invalidOrchestratorEmbeddingFailsClosed() {
        let result = SpeakerOrchestrator().cluster(
            embeddings: [Float](repeating: 0, count: 100),
            chunks: [(0, 1_000)]
        )
        #expect(result.failure != nil)
        #expect(result.labels.isEmpty)
        #expect(result.profiles.isEmpty)
    }

    @Test func renumberCanPreserveOtherLabel() {
        let result = SpeakerOrchestrator().renumber([2, -1, 2, 5], preservingNegativeLabels: true)
        #expect(result == [0, -1, 0, 1])
    }

    @Test func profileBuilderDoesNotPromoteOtherLabelToAcousticProfile() {
        let embeddings = [Float](repeating: 0, count: 3 * 192)
        let result = SpeakerOrchestrator().buildProfiles(
            labels: [0, -1, 1],
            chunks: [(0, 1_000), (1_000, 2_000), (2_000, 3_000)],
            embeddings: embeddings,
            dim: 192,
            policy: .production
        )
        #expect(result.map(\.acousticLabel) == [0, 1])
        #expect(result.allSatisfy { $0.speakerLabel != "说话人 0" })
    }

    @Test func profileBuilderRejectsMismatchedLabelsWithoutIndexing() {
        let result = SpeakerOrchestrator().buildProfiles(
            labels: [],
            chunks: [(0, 1_000)],
            embeddings: [Float](repeating: 1, count: 192),
            dim: 192,
            policy: .production
        )
        #expect(result.isEmpty)
    }

    @Test func firstOccurrenceRelabelKeepsOtherSentinelNegative() {
        let labels = [-1, 4, -1, 4]
        let chunks = [(0, 1_000), (1_000, 2_000), (2_000, 3_000), (3_000, 4_000)]
        #expect(AudioPipeline.relabelSpeakerLabelsByFirstOccurrence(labels: labels, chunks: chunks) == [-1, 0, -1, 0])
    }

    @Test func cosineMergeRecomputesCentroidAfterEachMerge() {
        let vectors: [[Float]] = [
            [0.06996022, -0.94160545, 0.32937022],
            [-0.35936065, -0.80219248, -0.47680934],
            [0.53817133, -0.48472391, 0.68950298],
            [0.56571109, -0.58851933, 0.57759498],
            [0.10372538, -0.52526071, -0.84459590],
        ]
        let embeddings = vectors.flatMap { vector in
            vector + Array(repeating: Float(0), count: 189)
        }
        let result = SpeakerOrchestrator().mergeLabelsByCos(
            labels: [0, 1, 2, 3, 4],
            embeddings: embeddings,
            count: vectors.count,
            dim: 192,
            threshold: 0.78
        )
        #expect(result == [0, 1, 2, 2, 1])
    }

    // 场景 1: 健康 2 人对话 (interleaved)
    @Test func healthyTwoSpeakersInterleaved() {
        let orchestrator = SpeakerOrchestrator()
        let labels = [0, 1, 0, 1, 0, 1]
        let chunks = [
            (0, 10000),
            (10000, 20000),
            (20000, 30000),
            (30000, 40000),
            (40000, 50000),
            (50000, 60000)
        ]
        let result = orchestrator.looksLikeCollapsedFirstHalf(labels: labels, chunks: chunks)
        #expect(!result, "健康交替对话不应当判定为崩塌")
    }
    
    // 场景 2: 健康 3 人对话 (轮流)
    @Test func healthyThreeSpeakersSequential() {
        let orchestrator = SpeakerOrchestrator()
        let labels = [0, 1, 2, 0, 1, 2]
        let chunks = [
            (0, 10000),
            (10000, 20000),
            (20000, 30000),
            (30000, 40000),
            (40000, 50000),
            (50000, 60000)
        ]
        let result = orchestrator.looksLikeCollapsedFirstHalf(labels: labels, chunks: chunks)
        #expect(!result, "健康三人对话不应当判定为崩塌")
    }
    
    // 场景 3: 折叠 1 人 (unique label < 2)
    @Test func collapsedSingleSpeaker() {
        let orchestrator = SpeakerOrchestrator()
        let labels = [0, 0, 0]
        let chunks = [
            (0, 10000),
            (10000, 20000),
            (20000, 30000)
        ]
        let result = orchestrator.looksLikeCollapsedFirstHalf(labels: labels, chunks: chunks)
        #expect(!result, "单一说话人不满足 unique count >= 2 的崩塌检查前置条件")
    }
    
    // 场景 4: 崩塌折叠 (A 全程覆盖 + B 在极晚 95% 处短暂出现)
    @Test func collapsedLopsidedDominantSpeaker() {
        let orchestrator = SpeakerOrchestrator()
        let labels = [0, 0, 0, 0, 0, 0, 0, 0, 0, 1]
        let chunks = [
            (0, 10000),
            (10000, 20000),
            (20000, 30000),
            (30000, 40000),
            (40000, 50000),
            (50000, 60000),
            (60000, 70000),
            (70000, 80000),
            (80000, 95000),
            (95000, 96000)
        ]
        let result = orchestrator.looksLikeCollapsedFirstHalf(labels: labels, chunks: chunks)
        #expect(result, "A主宰全程且B极晚出现应被判定为崩塌并触发 fallback")
    }
    
    // 场景 5: 边缘 - biggest span 足够长，但它的 start 已经晚于 5%
    @Test func edgeCaseLateStartBiggest() {
        let orchestrator = SpeakerOrchestrator()
        // Audio span 0 -> 100000 (100s).
        // 5% start offset = 5000ms.
        // Biggest (0) starts at 6000ms (> 5%) and ends at 95000ms. span = 89s (89% of 100s).
        let labels = [1, 0, 0, 0, 2]
        let chunks = [
            (0, 5000),       // 1
            (6000, 30000),   // 0
            (30000, 60000),  // 0
            (60000, 95000),  // 0
            (95000, 99000)   // 2
        ]
        let result = orchestrator.looksLikeCollapsedFirstHalf(labels: labels, chunks: chunks)
        #expect(!result, "主导说话人开始时间较晚时不应当判定为崩塌")
    }
    
    // 场景 6: 边缘 - biggest span 覆盖高且在 0% 开始，但没有其他 late speaker (所有人都在 30% 之前出现过了)
    @Test func edgeCaseNoLateSpeaker() {
        let orchestrator = SpeakerOrchestrator()
        // Audio span 0 -> 100000 (100s).
        // Late threshold = 30000ms.
        // Speaker 1 starts at 10000ms (< 30s). No other speaker starts after 30s.
        let labels = [0, 1, 0, 0, 0]
        let chunks = [
            (0, 10000),      // 0
            (10000, 25000),  // 1
            (25000, 50000),  // 0
            (50000, 75000),  // 0
            (75000, 90000)   // 0
        ]
        let result = orchestrator.looksLikeCollapsedFirstHalf(labels: labels, chunks: chunks)
        #expect(!result, "若没有极晚出现的说话人，则不应当判定为崩塌")
    }
}
