import Testing
import Foundation
import CoreML
@testable import SwiftASR

/// Diagnostic-only profile audit for the Summer 21-minute fixture.
/// It does not alter clustering; it reports cohesion, cross-profile leakage,
/// ambiguous windows and a two-mode split inside each final profile.
@Test(.disabled("Opt-in profile-quality diagnostic; it depends on local historical artifacts."))
func profileQualityMixtureDiagnostic() throws {
    let jobID = "51a47cbf9e0b1708bf796bfd6c99db251c7049bfb860d8d0845964ff4f8fd1fe"
    let inputURL = ResultStore.speakerInputPath(jobId: jobID)
    guard FileManager.default.fileExists(atPath: inputURL.path) else {
        print("Profile audit input not found: \(inputURL.path)")
        return
    }
    let input = try JSONDecoder().decode(
        SpeakerRecognitionInput.self,
        from: Data(contentsOf: inputURL)
    )
    let modelsRoot = ModelTestPaths.modelsRoot.path
    let batchModel = ModelCatalog.filePath(definitionID: "speaker", file: "model_batch16.mlmodelc", modelsRoot: modelsRoot)
    let speaker = try SpeakerNativeCoreMLEngine(
        modelPath: batchModel,
        inferenceBatchSize: SpeakerNativeCoreMLEngine.preferredBatchSize
    )

    let pcm = try AudioConverter().loadAndResample(path: input.audioPath)
    let fbank = FbankExtractor().extractFbank(
        pcmData: pcm,
        workerCount: FbankExtractor.maximumParallelWorkers,
        reportEveryN: 0
    )
    let timeline = TokenTimeline(sentences: input.sentences, totalFrames: fbank.count / 80)
    let windows = TokenPackedWindowPlanner().makeWindows(timeline: timeline)
    let extraction = try AudioPipeline.extractPackedSpeakerEmbeddings(
        fbank80: fbank,
        windows: windows,
        speaker: speaker,
        onProgress: { _, _, _ in },
        shouldCancel: { false }
    )
    let chunks = windows.map { window -> (startMs: Int, endMs: Int) in
        let starts = window.spans.map { $0.sourceFrames.lowerBound }
        let ends = window.spans.map { $0.sourceFrames.upperBound }
        return ((starts.min() ?? 0) * 10, (ends.max() ?? 0) * 10)
    }
    let clustered = SpeakerOrchestrator(clustering: SpectralClustering()).cluster(
        embeddings: extraction.embeddings,
        chunks: chunks,
        policy: .production
    )
    let labels = AudioPipeline.relabelSpeakerLabelsByFirstOccurrence(labels: clustered.labels, chunks: chunks)
    var rawToRelabeled: [Int: Int] = [:]
    for index in labels.indices where clustered.labels.indices.contains(index) {
        rawToRelabeled[clustered.labels[index]] = labels[index]
    }
    let centroids = Dictionary(uniqueKeysWithValues: clustered.profiles.compactMap { profile -> (Int, [Float])? in
        guard let suffix = profile.speakerLabel.split(separator: " ").last,
              let raw = Int(suffix).map({ $0 - 1 })
        else { return nil }
        return (rawToRelabeled[raw] ?? raw, profile.centroidEmbedding)
    })
    let profileLabels = centroids.keys.sorted()
    let dimension = 192

    func vector(at index: Int) -> [Float] {
        let offset = index * dimension
        return Array(extraction.embeddings[offset..<(offset + dimension)])
    }
    func quantile(_ values: [Float], _ fraction: Double) -> Float {
        guard !values.isEmpty else { return -.infinity }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, max(0, Int(Double(sorted.count - 1) * fraction)))
        return sorted[index]
    }
    func rendered(_ value: Float) -> String { String(format: "%.3f", value) }
    func bestOther(for label: Int, scores: [Int: Float]) -> (label: Int, score: Float) {
        scores.filter { $0.key != label }.max { $0.value < $1.value } ?? (label, -.infinity)
    }

    print("=== PROFILE QUALITY AUDIT ===")
    let fallbackReason = clustered.fallbackReason ?? "none"
    print("windows=\(windows.count) profiles=\(profileLabels.count) fallback=\(clustered.fallbackTriggered) reason=\(fallbackReason)")
    print("Role assumption for review: SPK0/SPK1/SPK2=Yadong, SPK3=Summer")

    print("=== PROFILE CENTROID COSINE MATRIX ===")
    for left in profileLabels {
        let row = profileLabels.map { right in
            rendered(SpeakerOrchestrator.cosineSimilarity(centroids[left] ?? [], centroids[right] ?? []))
        }.joined(separator: " ")
        print("SPK\(left): \(row)")
    }

    var memberIndexes: [Int: [Int]] = [:]
    for (index, label) in labels.enumerated() { memberIndexes[label, default: []].append(index) }

    print("=== PROFILE COHESION / AMBIGUITY ===")
    for label in profileLabels {
        let members = memberIndexes[label] ?? []
        let scores = members.map { index -> (own: Float, other: Float, otherLabel: Int) in
            let embedding = vector(at: index)
            let all = Dictionary(uniqueKeysWithValues: profileLabels.map {
                ($0, SpeakerOrchestrator.cosineSimilarity(embedding, centroids[$0] ?? []))
            })
            let other = bestOther(for: label, scores: all)
            return (all[label] ?? -.infinity, other.score, other.label)
        }
        let own = scores.map(\.own)
        let margins = scores.map { $0.own - $0.other }
        let confused = scores.filter { $0.own < $0.other }.count
        let ambiguous = scores.filter { $0.own - $0.other < 0.05 }.count
        let nearestOther = Dictionary(grouping: scores, by: \.otherLabel)
            .mapValues(\.count)
            .sorted { $0.value > $1.value }
            .map { "SPK\($0.key):\($0.value)" }
            .joined(separator: ",")
        let duration = members.reduce(0) { $0 + chunks[$1].endMs - chunks[$1].startMs }
        print(
            "SPK\(label) windows=\(members.count) duration=\(duration)ms " +
            "own[min/p10/p50/p90]=\(rendered(own.min() ?? 0))/\(rendered(quantile(own, 0.10)))/\(rendered(quantile(own, 0.50)))/\(rendered(quantile(own, 0.90))) " +
            "margin[p10/p50]=\(rendered(quantile(margins, 0.10)))/\(rendered(quantile(margins, 0.50))) " +
            "confused=\(confused) ambiguous<.05=\(ambiguous) nearestOther={\(nearestOther)}"
        )
    }

    print("=== LOW-MARGIN WINDOWS ===")
    for label in profileLabels {
        let candidates = (memberIndexes[label] ?? []).compactMap { index -> (index: Int, margin: Float, scores: [Int: Float])? in
            let embedding = vector(at: index)
            let scores = Dictionary(uniqueKeysWithValues: profileLabels.map {
                ($0, SpeakerOrchestrator.cosineSimilarity(embedding, centroids[$0] ?? []))
            })
            let other = bestOther(for: label, scores: scores)
            return (index, (scores[label] ?? 0) - other.score, scores)
        }.sorted { $0.margin < $1.margin }.prefix(8)
        for item in candidates {
            let scoreText = item.scores.sorted { $0.value > $1.value }
                .map { "SPK\($0.key)=\(rendered($0.value))" }
                .joined(separator: " ")
            print("SPK\(label) window=\(item.index) \(chunks[item.index].startMs)-\(chunks[item.index].endMs)ms margin=\(rendered(item.margin)) \(scoreText)")
        }
    }

    print("=== TWO-MODE PROFILE SPLIT ===")
    for label in profileLabels {
        let members = memberIndexes[label] ?? []
        guard members.count >= 20 else {
            print("SPK\(label): skipped, only \(members.count) windows")
            continue
        }
        let memberEmbeddings = members.flatMap { vector(at: $0) }
        let splitLabels = SpectralClustering(minNumSpks: 2, maxNumSpks: 2, pval: 0.05).cluster(
            embeddings: memberEmbeddings,
            count: members.count,
            forceK: 2
        )
        let modes = Array(Set(splitLabels)).sorted()
        for mode in modes {
            let positions = splitLabels.indices.filter { splitLabels[$0] == mode }
            guard !positions.isEmpty else { continue }
            var centroid = [Float](repeating: 0, count: dimension)
            for position in positions {
                let emb = Array(memberEmbeddings[(position * dimension)..<((position + 1) * dimension)])
                for component in 0..<dimension { centroid[component] += emb[component] }
            }
            for component in 0..<dimension { centroid[component] /= Float(positions.count) }
            let norm = sqrt(centroid.reduce(0) { $0 + $1 * $1 })
            if norm > 1e-10 { centroid = centroid.map { $0 / norm } }
            let similarities = profileLabels.map {
                ($0, SpeakerOrchestrator.cosineSimilarity(centroid, centroids[$0] ?? []))
            }.sorted { $0.1 > $1.1 }
            let top = similarities.first ?? (label, 0)
            let allSimilarities = similarities
                .map { "SPK\($0.0):\(rendered($0.1))" }
                .joined(separator: " ")
            print("SPK\(label) mode\(mode) windows=\(positions.count) nearest=SPK\(top.0) sim=\(rendered(top.1)) all=\(allSimilarities)")
        }
    }

    print("=== FORCED-K QUALITY SWEEP ===")
    for k in 2...6 {
        let forcedLabels = SpectralClustering(minNumSpks: k, maxNumSpks: k).cluster(
            embeddings: extraction.embeddings,
            count: windows.count,
            forceK: k
        )
        let forcedGroups = Dictionary(grouping: forcedLabels.indices, by: { forcedLabels[$0] })
        var forcedCentroids: [Int: [Float]] = [:]
        for (label, indexes) in forcedGroups {
            var centroid = [Float](repeating: 0, count: dimension)
            for index in indexes {
                let emb = vector(at: index)
                for component in 0..<dimension { centroid[component] += emb[component] }
            }
            for component in 0..<dimension { centroid[component] /= Float(indexes.count) }
            let norm = sqrt(centroid.reduce(0) { $0 + $1 * $1 })
            if norm > 1e-10 { centroid = centroid.map { $0 / norm } }
            forcedCentroids[label] = centroid
        }
        var cohesion: [Float] = []
        var silhouettes: [Float] = []
        for index in forcedLabels.indices {
            let label = forcedLabels[index]
            let embedding = vector(at: index)
            let own = SpeakerOrchestrator.cosineSimilarity(embedding, forcedCentroids[label] ?? [])
            let other = forcedCentroids
                .filter { $0.key != label }
                .map { SpeakerOrchestrator.cosineSimilarity(embedding, $0.value) }
                .max() ?? own
            cohesion.append(own)
            let a = max(0, 1 - own)
            let b = max(0, 1 - other)
            silhouettes.append(max(a, b) > 1e-6 ? (b - a) / max(a, b) : 0)
        }
        let sizes = forcedGroups.values.map(\.count).sorted(by: >)
        let cohesionSummary = "\(rendered(quantile(cohesion, 0.10)))/\(rendered(quantile(cohesion, 0.50)))"
        let silhouetteSummary = "\(rendered(quantile(silhouettes, 0.10)))/\(rendered(quantile(silhouettes, 0.50)))"
        print(
            "K=\(k) sizes=\(sizes) cohesion[p10/p50]=\(cohesionSummary) " +
            "silhouette[p10/p50]=\(silhouetteSummary)"
        )
    }
}

// MARK: - Route A/B: ComputeUnits Sweep Benchmark
//
// \u8fd0\u884c\u65b9\u5f0f\uff1a
//   SWIFTASR_RUN_SPEAKER_COMPUTE_SWEEP=1 swift test --filter speakerComputeUnitsSweepBenchmark
//
// \u5bf9\u6bcf\u4e2a computeUnits \u9009\u9879\uff08cpuOnly / cpuAndGPU / cpuAndNeuralEngine / all\uff09\uff1a
//   - \u52a0\u8f7d\u6a21\u578b\uff08\u65e0\u9884\u70ed\uff09
//   - \u5bf9\u5168\u90e8 speaker \u7a97\u53e3\u8fdb\u884c\u8fdb\u884c\u63a8\u65ad\uff0c\u8bb0\u5f55\u603b\u8017\u65f6\u4e0e\u6bcf 16-batch \u5e73\u5747\u8017\u65f6
//   - \u4e0e Float32 cpuOnly \u57fa\u7ebf\u8ba1\u7b97 cosine \u7c7b\u4f3c\u5ea6\uff0c\u9a8c\u8bc1\u6570\u5b57\u7cbe\u5ea6\u662f\u5426\u5728 0.9999 \u4ee5\u4e0a
@Test func speakerComputeUnitsSweepBenchmark() throws {
    guard ProcessInfo.processInfo.environment["SWIFTASR_RUN_SPEAKER_COMPUTE_SWEEP"] == "1" else {
        print("Skipped: set SWIFTASR_RUN_SPEAKER_COMPUTE_SWEEP=1 to run.")
        return
    }

    let jobID = "51a47cbf9e0b1708bf796bfd6c99db251c7049bfb860d8d0845964ff4f8fd1fe"
    let inputURL = ResultStore.speakerInputPath(jobId: jobID)
    guard FileManager.default.fileExists(atPath: inputURL.path) else {
        print("Speaker sweep: input not found at \(inputURL.path)")
        return
    }
    let input = try JSONDecoder().decode(SpeakerRecognitionInput.self, from: Data(contentsOf: inputURL))
    let modelsRoot = ModelTestPaths.modelsRoot.path
    let modelPath = ModelCatalog.filePath(definitionID: "speaker", file: "model_batch16.mlmodelc", modelsRoot: modelsRoot)

    // \u51c6\u5907\u5171\u7528\u7684 fbank + windows\uff08\u6240\u6709 units \u5171\u7528\u540c\u4e00\u8f93\u5165\uff09
    let pcm = try AudioConverter().loadAndResample(path: input.audioPath)
    let fbank = FbankExtractor().extractFbank(pcmData: pcm, workerCount: FbankExtractor.maximumParallelWorkers, reportEveryN: 0)
    let timeline = TokenTimeline(sentences: input.sentences, totalFrames: fbank.count / 80)
    let windows = TokenPackedWindowPlanner().makeWindows(timeline: timeline)
    let batchCount = Int(ceil(Double(windows.count) / Double(SpeakerNativeCoreMLEngine.preferredBatchSize)))

    // Float32 cpuOnly 作为数值基线
    // do{} 隔离：确保基线 engine 在 sweep 循环开始前已被释放，
    // 避免 CoreML 同时持有两个 compiled model 实例导致 SIGSEGV。
    let baselineEmbs: [Float]
    do {
        let baselineEngine = try SpeakerNativeCoreMLEngine(modelPath: modelPath, computeUnits: .cpuOnly)
        let baselineResult = try AudioPipeline.extractPackedSpeakerEmbeddings(
            fbank80: fbank, windows: windows, speaker: baselineEngine,
            onProgress: { _, _, _ in }, shouldCancel: { false }
        )
        baselineEmbs = baselineResult.embeddings
    } // baselineEngine 在此释放

    // 待对比的 computeUnits 列表
    var candidates: [(String, MLComputeUnits)] = [
        ("cpuOnly",            .cpuOnly),
        ("cpuAndGPU",          .cpuAndGPU),
        ("cpuAndNeuralEngine", .cpuAndNeuralEngine),
    ]
    if #available(macOS 15, *) {
        candidates.append(("all", .all))
    }

    // 列宽辅助函数：右填充到指定宽度（避免 %s 的 C-string UB）
    func col(_ s: String, _ w: Int) -> String {
        s + String(repeating: " ", count: max(0, w - s.count))
    }
    func rpad(_ s: String, _ w: Int) -> String {
        String(repeating: " ", count: max(0, w - s.count)) + s
    }

    print("\n=== Speaker ComputeUnits Sweep (\(windows.count) windows / \(batchCount) batches) ===")
    print("\(col("computeUnits", 22))  \(rpad("wall(s)", 8))  \(rpad("ms/batch", 8))  \(rpad("cosine", 8))")
    print(String(repeating: "-", count: 56))

    for (name, units) in candidates {
        // do{} 隔离：每个候选 engine 在本次迭代结束时释放，确保下一个 engine
        // 初始化时前一个已完全释放，避免两个 MLModel 同时存活。
        // 外层 do-catch 捕获 ANE 等硬件不支持的错误，不中断后续候选。
        do {
            let wall: Double
            let cosine: Float
            do {
                let engine = try SpeakerNativeCoreMLEngine(modelPath: modelPath, computeUnits: units)
                let t0 = Date()
                let result = try AudioPipeline.extractPackedSpeakerEmbeddings(
                    fbank80: fbank, windows: windows, speaker: engine,
                    onProgress: { _, _, _ in }, shouldCancel: { false }
                )
                wall = Date().timeIntervalSince(t0)
                let embs = result.embeddings
                let n = min(embs.count, baselineEmbs.count)
                var dot: Float = 0; var na: Float = 0; var nb: Float = 0
                for i in 0..<n {
                    dot += embs[i] * baselineEmbs[i]
                    na  += embs[i] * embs[i]
                    nb  += baselineEmbs[i] * baselineEmbs[i]
                }
                cosine = na > 0 && nb > 0 ? dot / (na.squareRoot() * nb.squareRoot()) : 0
            } // engine 在此释放
            let msPerBatch = wall / Double(batchCount) * 1000.0
            let wallStr   = String(format: "%.3f", wall)
            let msStr     = String(format: "%.1f", msPerBatch)
            let cosineStr = String(format: "%.6f", cosine)
            print("\(col(name, 22))  \(rpad(wallStr, 8))  \(rpad(msStr, 8))  \(rpad(cosineStr, 8))")
        } catch {
            // ANE 或 GPU 不支持此模型时优雅降级，不中断后续候选
            let errShort = (error as NSError).localizedDescription.prefix(80)
            print("\(col(name, 22))  ERROR: \(errShort)")
        }
    }
    print(String(repeating: "=", count: 56))
}
