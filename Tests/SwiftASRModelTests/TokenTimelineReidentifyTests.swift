import Foundation
import Testing
@testable import SwiftASR

/// Opt-in real-model regression runner. It deliberately writes only under the
/// local experiments root and never replaces a user's Stage result.
///
/// SWIFTASR_TOKEN_TIMELINE_REIDENTIFY_MANIFEST=/tmp/manifest.json \
///   swift test --filter tokenTimelineReidentifyFromManifest
@Test(.disabled("Opt-in manifest-driven re-identification diagnostic."))
func tokenTimelineReidentifyFromManifest() async throws {
    guard let path = ProcessInfo.processInfo.environment["SWIFTASR_TOKEN_TIMELINE_REIDENTIFY_MANIFEST"],
          !path.isEmpty else { return }
    let manifest = try JSONDecoder().decode(
        TokenTimelineReidentifyManifest.self,
        from: Data(contentsOf: URL(fileURLWithPath: path))
    )
    let outputRoot = URL(fileURLWithPath: manifest.outputDirectory, isDirectory: true)
    try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
    let pipeline = try AudioPipeline(modelsRoot: manifest.modelsRoot)
    let overwriteStage = ProcessInfo.processInfo.environment["SWIFTASR_OVERWRITE_STAGE"] == "1"
    var reports: [TokenTimelineReidentifyReport] = []

    for task in manifest.tasks {
        let inputURL = URL(fileURLWithPath: task.speakerInputPath)
        let input = try ResultStore.readSpeakerInput(from: inputURL)
        let baselineURL = URL(fileURLWithPath: task.resultPath ?? inputURL.path.replacingOccurrences(of: ".speaker-input.json", with: ".result.json"))
        let baseline = try ResultStore.read(from: baselineURL)
        let started = Date()
        let result = try await pipeline.reidentifySpeakers(
            audioPath: input.audioPath,
            sentences: input.sentences,
            diagnosticsURL: outputRoot.appendingPathComponent("\(task.name).speaker-diagnostics.v4.json")
        )
        if overwriteStage {
            var payload = baseline
            guard payload.replaceSegmentsWithSpeakerTurns(from: result.utterances) else {
                throw NSError(domain: "TokenTimelineReidentify", code: -2, userInfo: [NSLocalizedDescriptionKey: "Speaker result text differs; Stage result.json was not overwritten."])
            }
            var fingerprints = Dictionary(uniqueKeysWithValues: result.speakerProfiles.map { ($0.speakerLabel, $0.fingerprintId) })
            fingerprints[SpeakerDiarizationPipeline.sentinelLabel] = SpeakerDiarizationPipeline.sentinelFingerprint
            payload.speakers = payload.speakers.map {
                ResultSpeaker(speakerLabel: $0.speakerLabel, fingerprintId: fingerprints[$0.speakerLabel])
            }
            try ResultStore.write(payload, to: baselineURL)
        }
        let report = TokenTimelineReidentifyReport(
            task: task.name,
            audioPath: input.audioPath,
            elapsedSeconds: Date().timeIntervalSince(started),
            baseline: .init(turns: baseline.segments.map(TokenTimelineTurn.init), speakerDurationsMs: TokenTimelineReidentifyReport.durationByLabel(baseline.segments.map(TokenTimelineTurn.init))),
            candidate: .init(turns: result.utterances.map(TokenTimelineTurn.init), speakerDurationsMs: TokenTimelineReidentifyReport.durationByLabel(result.utterances.map(TokenTimelineTurn.init))),
            candidateProfiles: result.speakerProfiles.map {
                .init(label: $0.speakerLabel, fingerprintId: $0.fingerprintId, durationMs: $0.totalDurationMs, chunkCount: $0.chunkCount)
            },
            newToOldOverlapMs: TokenTimelineReidentifyReport.overlapMatrix(old: baseline.segments.map(TokenTimelineTurn.init), new: result.utterances.map(TokenTimelineTurn.init)),
            textIsPreserved: baseline.segments.map(\.rawText).joined() == result.utterances.map(\.rawText).joined()
        )
        let destination = outputRoot.appendingPathComponent("\(task.name).token-timeline-reidentify.json")
        try JSONEncoder.pretty.encode(report).write(to: destination, options: .atomic)
        // Kept only in the local experiment directory. This is the immutable
        // candidate side of the later 1:N library review; result.json never
        // receives centroid vectors or automatic Person matches.
        let snapshot = CandidateProfileSnapshot(
            task: task.name,
            profiles: result.speakerProfiles.map {
                .init(
                    label: $0.speakerLabel,
                    fingerprintId: $0.fingerprintId,
                    durationMs: $0.totalDurationMs,
                    chunkCount: $0.chunkCount,
                    embeddingBase64: $0.embeddingData.base64EncodedString()
                )
            }
        )
        try JSONEncoder.pretty.encode(snapshot).write(
            to: outputRoot.appendingPathComponent("\(task.name).candidate-profile-snapshot.json"),
            options: .atomic
        )
        let elapsed = String(format: "%.2f", report.elapsedSeconds)
        print("[token-timeline-reidentify] task=\(task.name) turns=\(report.candidate.turns.count) profiles=\(report.candidateProfiles.count) elapsed=\(elapsed)s output=\(destination.path)")
        reports.append(report)
    }
    try Data(TokenTimelineComparisonMarkdown.render(reports).utf8).write(
        to: outputRoot.appendingPathComponent("Token_Timeline_Reidentify_Comparison_2026-07-14.md"),
        options: .atomic
    )
}

private struct CandidateProfileSnapshot: Codable {
    struct Profile: Codable {
        let label: String
        let fingerprintId: String
        let durationMs: Int
        let chunkCount: Int
        let embeddingBase64: String
    }
    let task: String
    let profiles: [Profile]
}

private struct TokenTimelineReidentifyManifest: Decodable {
    let modelsRoot: String
    let outputDirectory: String
    let tasks: [Task]

    struct Task: Decodable {
        let name: String
        let speakerInputPath: String
        let resultPath: String?
    }
}

private struct TokenTimelineReidentifyReport: Codable {
    struct Variant: Codable {
        let turns: [TokenTimelineTurn]
        let speakerDurationsMs: [String: Int]
    }
    struct Profile: Codable {
        let label: String
        let fingerprintId: String
        let durationMs: Int
        let chunkCount: Int
    }

    let task: String
    let audioPath: String
    let elapsedSeconds: Double
    let baseline: Variant
    let candidate: Variant
    let candidateProfiles: [Profile]
    /// Candidate label → old label → overlap duration. It is label-permutation
    /// tolerant and exposes both convergence (N→1) and fragmentation (1→N).
    let newToOldOverlapMs: [String: [String: Int]]
    let textIsPreserved: Bool
}

private enum TokenTimelineComparisonMarkdown {
    static func render(_ reports: [TokenTimelineReidentifyReport]) -> String {
        var lines = [
            "# Token Timeline Diarization：自动重识别新旧对照（2026-07-14）",
            "",
            "此报告由当前 SwiftASR `SpeakerDiarizationPipeline` 对冻结 Stage sidecar 自动重跑生成。它比较旧 Stage 输出与新候选输出；标签以时间重叠而非编号直接比较。该对照不是人工准确率。",
            "",
            "| 样本 | 旧/新 turns | 旧/新 label 数 | 新声学 profile 数 | 耗时 | 原文保持 |",
            "|---|---:|---:|---:|---:|---|"
        ]
        for report in reports.sorted(by: { $0.task < $1.task }) {
            let elapsed = String(format: "%.2fs", report.elapsedSeconds)
            let preserved = report.textIsPreserved ? "yes" : "NO"
            lines.append("| \(report.task) | \(report.baseline.turns.count) / \(report.candidate.turns.count) | \(report.baseline.speakerDurationsMs.count) / \(report.candidate.speakerDurationsMs.count) | \(report.candidateProfiles.count) | \(elapsed) | \(preserved) |")
        }
        for report in reports.sorted(by: { $0.task < $1.task }) {
            let profiles = report.candidateProfiles
                .map { "\($0.label)=\($0.fingerprintId), \($0.durationMs)ms" }
                .joined(separator: "；")
            lines += ["", "## \(report.task)", "", "- 旧 Stage 时长（ms）：\(renderDurations(report.baseline.speakerDurationsMs))", "- 新候选时长（ms）：\(renderDurations(report.candidate.speakerDurationsMs))", "- 新 profile：\(profiles)", "- 新 label → 旧 label 重叠（ms）：\(renderOverlap(report.newToOldOverlapMs))"]
        }
        lines += ["", "## 解读边界", "", "- `Speaker` 固定对应结果契约中的 `fp_system_speaker`；模型不为它自动建 profile、入库或绑定 Person，它也不等价于跨任务同一真人。", "- profile 数减少或关键人物时长增加仅是收敛信号；必须结合每个新 label→旧 label 的重叠矩阵和人工审阅判断，不能据此自动改说话人库。", "- 这里的原文保持仅验证旧 Stage 与新输出拼接后的文本相同，不证明说话人标签正确。"]
        return lines.joined(separator: "\n") + "\n"
    }

    private static func renderDurations(_ values: [String: Int]) -> String {
        values.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "；")
    }

    private static func renderOverlap(_ values: [String: [String: Int]]) -> String {
        values.sorted { $0.key < $1.key }.map { candidate, old in
            "\(candidate) → \(renderDurations(old))"
        }.joined(separator: "；")
    }
}

private struct TokenTimelineTurn: Codable {
    let startMs: Int
    let endMs: Int
    let speakerLabel: String
    let rawText: String

    init(_ segment: ResultSegment) {
        startMs = segment.startMs
        endMs = segment.endMs
        speakerLabel = segment.speakerLabel
        rawText = segment.rawText
    }

    init(_ utterance: UtteranceData) {
        startMs = utterance.startMs
        endMs = utterance.endMs
        speakerLabel = utterance.speakerLabel
        rawText = utterance.rawText
    }
}

private extension TokenTimelineReidentifyReport {
    static func durationByLabel(_ turns: [TokenTimelineTurn]) -> [String: Int] {
        turns.reduce(into: [:]) { sums, turn in
            sums[turn.speakerLabel, default: 0] += max(0, turn.endMs - turn.startMs)
        }
    }

    static func overlapMatrix(old: [TokenTimelineTurn], new: [TokenTimelineTurn]) -> [String: [String: Int]] {
        var output: [String: [String: Int]] = [:]
        for candidate in new {
            for baseline in old {
                let overlap = max(0, min(candidate.endMs, baseline.endMs) - max(candidate.startMs, baseline.startMs))
                guard overlap > 0 else { continue }
                output[candidate.speakerLabel, default: [:]][baseline.speakerLabel, default: 0] += overlap
            }
        }
        return output
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
