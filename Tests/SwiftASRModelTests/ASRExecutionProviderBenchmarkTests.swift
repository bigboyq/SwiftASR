import Foundation
import Testing
@testable import SwiftASR

/// Opt-in route benchmark for the production INT8 ASR graph.  It keeps input,
/// model and frontend identical, so every candidate EP is comparable with CPU
/// even when ORT partitions only a subset of the graph to that provider.
///
/// Run manually:
/// `SWIFTASR_RUN_ASR_EP_BENCH=1 swift test --filter ASRExecutionProviderBenchmarkTests`
@Suite(.serialized)
struct ASRExecutionProviderBenchmarkTests {
    private static let fixture = ModelTestPaths.projectRoot
        .appendingPathComponent("Tests/Fixtures/asr_route_benchmark_2m.wav")
    private static let sampleDurationMs = 60_000
    private static let warmupCount = 1
    private static let measuredRunCount = 3

    @Test func compareProductionINT8ExecutionProviderRoutes() throws {
        guard ProcessInfo.processInfo.environment["SWIFTASR_RUN_ASR_EP_BENCH"] == "1" else {
            print("ASR EP benchmark skipped: set SWIFTASR_RUN_ASR_EP_BENCH=1")
            return
        }
        guard FileManager.default.fileExists(atPath: Self.fixture.path) else {
            Issue.record("Missing benchmark fixture: \(Self.fixture.path)")
            return
        }

        let pcm = try AudioConverter().loadAndResample(path: Self.fixture.path)
        let maxSamples = min(pcm.count, Self.sampleDurationMs * 16)
        let sample = Array(pcm.prefix(maxSamples))
        let extractor = FbankExtractor()
        let fbankStartedAt = Date()
        let fbank = extractor.extractFbank(pcmData: sample, workerCount: 1)
        let frontend = try ASRFrontend(modelsRoot: ModelTestPaths.modelsRoot.path)
        guard let input = frontend.makeInput(
            fbank80: fbank,
            batch: (startMs: 0, endMs: min(Self.sampleDurationMs, sample.count / 16)),
            extractor: extractor
        ) else {
            Issue.record("ASR frontend produced no input")
            return
        }
        if let exportPath = ProcessInfo.processInfo.environment["SWIFTASR_ASR_EXPORT_FEATURES_PATH"],
           !exportPath.isEmpty {
            var features = input.features
            let data = Data(
                bytes: &features,
                count: features.count * MemoryLayout<Float>.size
            )
            try data.write(to: URL(fileURLWithPath: exportPath), options: .atomic)
            print("ASR calibration features exported: path=\(exportPath) floats=\(features.count) seqLen=\(input.seqLen)")
        }
        let frontendMs = Date().timeIntervalSince(fbankStartedAt) * 1_000
        let defaultModel = ModelTestPaths.modelsRoot
            .appendingPathComponent("seaco_paraformer/model_quant.onnx").path
        let model = ProcessInfo.processInfo.environment["SWIFTASR_ASR_BENCH_MODEL_PATH"]
            .flatMap { $0.isEmpty ? nil : $0 } ?? defaultModel
        guard FileManager.default.fileExists(atPath: model) else {
            Issue.record("Missing benchmark model: \(model)")
            return
        }
        let decoder = try ASRDecoder(
            vocabJsonPath: ModelTestPaths.modelsRoot
                .appendingPathComponent("seaco_paraformer/tokens.json").path
        )

        let requestedRoute = ProcessInfo.processInfo.environment["SWIFTASR_ASR_EP_ROUTE"]
        let routes = [ASRBenchmarkRoute.cpu, .coreML, .xnnpack].filter { route in
            switch requestedRoute {
            case nil, "", "all": return true
            case "cpu": return route == .cpu
            case "coreml": return route == .coreML
            case "xnnpack": return route == .xnnpack
            case "cpu+xnnpack": return route == .cpu || route == .xnnpack
            default:
                Issue.record("SWIFTASR_ASR_EP_ROUTE must be cpu, coreml, xnnpack, cpu+xnnpack, or all")
                return false
            }
        }
        guard !routes.isEmpty else { return }

        let reports = try routes.map { route in
            let initializedAt = Date()
            let engine = try ASRONNXEngine(
                modelPath: model,
                useCoreML: route == .coreML,
                executionProvider: route.executionProvider
            )
            let initializationMs = Date().timeIntervalSince(initializedAt) * 1_000
            for _ in 0..<Self.warmupCount {
                _ = try engine.infer(fbankFeatures: input.features, seqLen: input.seqLen)
            }

            var inferenceMs: [Double] = []
            var decodedText = ""
            var timestampFingerprint = ""
            for _ in 0..<Self.measuredRunCount {
                let startedAt = Date()
                let output = try engine.infer(fbankFeatures: input.features, seqLen: input.seqLen)
                inferenceMs.append(Date().timeIntervalSince(startedAt) * 1_000)
                let decoded = try decoder.decode(output: output, seqLen: input.seqLen)
                decodedText = decoded.rawText
                timestampFingerprint = decoded.sentences.flatMap(\.tokens)
                    .map { "\($0.startMs)-\($0.endMs)" }
                    .joined(separator: ",")
            }
            return ASRExecutionProviderReport(
                route: route.description,
                initializationMs: initializationMs,
                firstMeasuredInferenceMs: inferenceMs.first ?? 0,
                medianInferenceMs: median(inferenceMs),
                textFingerprint: fingerprint(decodedText),
                timestampFingerprint: fingerprint(timestampFingerprint),
                characters: decodedText.count
            )
        }

        let report = """
        ASR_EP_BENCHMARK fixture=\(Self.fixture.lastPathComponent) sampleMs=\(sample.count / 16) \
        frontendAndFbankMs=\(String(format: "%.1f", frontendMs)) seqLen=\(input.seqLen)
        \(reports.map(reportLine).joined(separator: "\n"))
        """
        print(report)
        if reports.count == 2 {
            #expect(reports[0].textFingerprint == reports[1].textFingerprint, "EP must preserve decoded text")
            #expect(reports[0].timestampFingerprint == reports[1].timestampFingerprint, "EP must preserve token timestamps")
        }
        if let expectedText = ProcessInfo.processInfo.environment["SWIFTASR_ASR_BENCH_EXPECT_TEXT_FINGERPRINT"],
           !expectedText.isEmpty {
            #expect(
                reports.allSatisfy { $0.textFingerprint == expectedText },
                "Candidate model must preserve decoded text fingerprint"
            )
        }
        if let expectedTimestamps = ProcessInfo.processInfo.environment["SWIFTASR_ASR_BENCH_EXPECT_TIMESTAMP_FINGERPRINT"],
           !expectedTimestamps.isEmpty {
            #expect(
                reports.allSatisfy { $0.timestampFingerprint == expectedTimestamps },
                "Candidate model must preserve token timestamp fingerprint"
            )
        }
    }

    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    private func fingerprint(_ value: String) -> String {
        let hash = value.unicodeScalars.reduce(UInt64(1_469_598_103_934_665_603)) { partial, scalar in
            (partial ^ UInt64(scalar.value)) &* 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private func reportLine(_ report: ASRExecutionProviderReport) -> String {
        "\(report.route) initMs=\(String(format: "%.1f", report.initializationMs)) " +
        "firstMs=\(String(format: "%.1f", report.firstMeasuredInferenceMs)) " +
        "medianMs=\(String(format: "%.1f", report.medianInferenceMs)) " +
        "chars=\(report.characters) text=\(report.textFingerprint) timestamps=\(report.timestampFingerprint)"
    }
}

private enum ASRBenchmarkRoute: Equatable {
    case cpu
    case coreML
    case xnnpack

    var executionProvider: ASRExecutionProvider {
        switch self {
        case .cpu: return .cpu
        case .coreML: return .coreML
        case .xnnpack:
            return .xnnpack(intraOpThreads: ComputeConcurrency.performanceCoreCount)
        }
    }

    var description: String {
        switch self {
        case .cpu: return "CPU"
        case .coreML: return "CoreML EP (ANE/GPU/CPU partitioned)"
        case .xnnpack:
            return "XNNPACK EP (\(ComputeConcurrency.performanceCoreCount) threads; CPU fallback allowed)"
        }
    }
}

private struct ASRExecutionProviderReport {
    let route: String
    let initializationMs: Double
    let firstMeasuredInferenceMs: Double
    let medianInferenceMs: Double
    let textFingerprint: String
    let timestampFingerprint: String
    let characters: Int
}
