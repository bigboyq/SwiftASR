import Foundation
import Testing
@testable import SwiftASR

/// Opt-in end-to-end timing profile. It preserves the production route and
/// emits only timing/shape facts; it does not write result artifacts.
///
/// Run manually:
/// `SWIFTASR_RUN_PIPELINE_PROFILE=1 swift test --filter PipelineExecutionProfileTests`
@Suite(.serialized)
struct PipelineExecutionProfileTests {
    @Test func profileProductionPipelineOnBundledFixture() async throws {
        guard ProcessInfo.processInfo.environment["SWIFTASR_RUN_PIPELINE_PROFILE"] == "1" else {
            print("Pipeline profile skipped: set SWIFTASR_RUN_PIPELINE_PROFILE=1")
            return
        }

        let source = ModelTestPaths.shortFixture.path
        guard FileManager.default.fileExists(atPath: source) else {
            Issue.record("Missing pipeline fixture: \(source)")
            return
        }

        let environment = ProcessInfo.processInfo.environment
        let workerCount = ASRCPUConcurrency.workerCount
        let intraOpThreads = try positiveInteger(
            environment["SWIFTASR_ASR_INTRA_OP_THREADS"],
            variable: "SWIFTASR_ASR_INTRA_OP_THREADS"
        )

        let pipeline = try AudioPipeline(
            modelsRoot: ModelTestPaths.modelsRoot.path,
            asrCPUIntraOpThreads: intraOpThreads
        )
        let transcript = ProfileTranscriptCapture()
        let startedAt = Date()
        let output = try await pipeline.runPipelineWithProfiles(
            audioPath: source,
            onProgress: { _, _, _ in },
            onSpeakerInput: { input in transcript.record(input.sentences) }
        )
        let totalMs = Date().timeIntervalSince(startedAt) * 1_000
        let metrics = output.metrics
        let asrFingerprint = fingerprint(transcript.sentences())
        if let expected = environment["SWIFTASR_PIPELINE_EXPECT_ASR_FINGERPRINT"], !expected.isEmpty {
            #expect(
                asrFingerprint == expected,
                "ASR text/timestamp fingerprint changed: expected \(expected), got \(asrFingerprint)"
            )
        }
        let report =
            "PIPELINE_PROFILE asrWorkers=\(workerCount) asrIntraOpThreads=\(intraOpThreads.map(String.init) ?? "default") " +
            "totalMs=\(String(format: "%.1f", totalMs)) " +
            "pcmMs=\(metrics.pcmDecodeMs) fbankMs=\(metrics.fbankMaterialiseMs) " +
            "vadAsrWallMs=\(metrics.vadAsrWallMs) puncMs=\(metrics.puncMs) " +
            "speakerMs=\(metrics.speakerMs) fbankFrames=\(metrics.fbankFrames) " +
            "vadSegments=\(metrics.vadSegmentCount) turns=\(output.utterances.count) " +
            "profiles=\(output.speakerProfiles.count) asrFingerprint=\(asrFingerprint)"
        print(report)
        let destination = ProcessInfo.processInfo.environment["SWIFTASR_PIPELINE_PROFILE_OUTPUT"]
            ?? "/tmp/swiftasr-pipeline-profile.txt"
        try report.write(toFile: destination, atomically: true, encoding: .utf8)
        print("PIPELINE_PROFILE_FILE=\(destination)")
        #expect(!output.utterances.isEmpty, "Profile run must still produce ASR output")
    }

    private func positiveInteger(_ raw: String?, variable: String) throws -> Int? {
        guard let raw, !raw.isEmpty else { return nil }
        guard let value = Int(raw), value > 0 else {
            throw NSError(
                domain: "PipelineExecutionProfileTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "\(variable) must be a positive integer"]
            )
        }
        return value
    }

    private func fingerprint(_ sentences: [ASRSentence]) -> String {
        let material = sentences.map {
            "\($0.startMs)-\($0.endMs):\($0.text):" +
                $0.tokens.map { "\($0.startMs)-\($0.endMs):\($0.text)" }.joined(separator: ",")
        }.joined(separator: "|")
        let hash = material.unicodeScalars.reduce(UInt64(1_469_598_103_934_665_603)) { partial, scalar in
            (partial ^ UInt64(scalar.value)) &* 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}

private final class ProfileTranscriptCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var capturedSentences: [ASRSentence] = []

    func record(_ sentences: [ASRSentence]) {
        lock.lock()
        capturedSentences = sentences
        lock.unlock()
    }

    func sentences() -> [ASRSentence] {
        lock.lock()
        defer { lock.unlock() }
        return capturedSentences
    }
}
