import Testing
import Foundation
import Accelerate
@testable import SwiftASR
@testable import SparseClusteringExperiments

// 性能/实现对照测试放在 ModelTests，避免阻塞日常轻量回归。

@Test(.disabled("Opt-in clustering comparison diagnostic; not a deterministic unit test."))
func ssyev_vs_ssyevr_bestK_comparison() throws {
    let n = 300
    let dim = 192
    let perCluster = 100
    let clusters = 3

    var rng = SystemRandomNumberGenerator()
    var embeddings: [Float] = []
    var trueLabels: [Int] = []
    for cluster in 0..<clusters {
        var center = [Float](repeating: 0, count: dim)
        for k in 0..<5 { center[cluster * 5 + k] = 1.0 }
        for _ in 0..<perCluster {
            var e = center
            for j in 0..<dim { e[j] += Float.random(in: -0.1...0.1, using: &rng) }
            embeddings.append(contentsOf: e)
            trueLabels.append(cluster)
        }
    }

    let labels = SpectralClustering(minNumSpks: 2, maxNumSpks: 15)
        .cluster(embeddings: embeddings, count: n)
    #expect(labels.count == n, "label count should match input count")
    #expect(Set(labels).count >= 1, "should produce at least 1 cluster")
    _ = trueLabels
}

@Test(.disabled("Opt-in clustering performance diagnostic."))
func ssyev_vs_ssyevr_perf_300() throws {
    let n = 300
    let dim = 192
    var rng = SystemRandomNumberGenerator()
    var embeddings: [Float] = []
    for _ in 0..<n {
        var e = [Float](repeating: 0, count: dim)
        for j in 0..<dim { e[j] += Float.random(in: -1...1, using: &rng) }
        embeddings.append(contentsOf: e)
    }
    _ = SpectralClustering(minNumSpks: 2, maxNumSpks: 15)
        .cluster(embeddings: embeddings, count: n)
}

@Test func spectralClusteringProfile5284() throws {
    guard ProcessInfo.processInfo.environment["SWIFTASR_RUN_SPECTRAL_PROFILE"] == "1" else {
        print("Spectral profile skipped: set SWIFTASR_RUN_SPECTRAL_PROFILE=1")
        return
    }
    let rawCount = ProcessInfo.processInfo.environment["SWIFTASR_SPECTRAL_PROFILE_N"]
    let n = rawCount.flatMap(Int.init) ?? 5284
    guard n >= 6 else {
        Issue.record("SWIFTASR_SPECTRAL_PROFILE_N must be at least 6")
        return
    }
    let dim = 192
    let clusters = 3

    var embeddings: [Float] = []
    embeddings.reserveCapacity(n * dim)
    for cluster in 0..<clusters {
        let start = (n * cluster) / clusters
        let end = (n * (cluster + 1)) / clusters
        var center = [Float](repeating: 0, count: dim)
        for k in 0..<5 { center[cluster * 5 + k] = 1.0 }
        for sample in start..<end {
            var e = center
            for j in 0..<dim {
                e[j] += Float(sin(Double((cluster + 1) * (sample + 1) * (j + 3)) * 0.17)) * 0.1
            }
            embeddings.append(contentsOf: e)
        }
    }
    guard embeddings.count == n * dim else {
        Issue.record("Synthetic spectral input has unexpected shape: \(embeddings.count)")
        return
    }

    let startedAt = Date()
    let labels = SpectralClustering(minNumSpks: 2, maxNumSpks: 15)
        .cluster(embeddings: embeddings, count: n)
    let elapsed = Date().timeIntervalSince(startedAt)
    let fingerprint = labels.reduce(UInt64(1_469_598_103_934_665_603)) { partial, label in
        (partial ^ UInt64(label)) &* 1_099_511_628_211
    }
    print(
        "SPECTRAL_PROFILE n=\(n) elapsedMs=\(Int((elapsed * 1_000).rounded())) " +
        "clusters=\(Set(labels).count) labels=\(labels.count) fingerprint=\(String(fingerprint, radix: 16))"
    )
    if let profilePath = ProcessInfo.processInfo.environment["SWIFTASR_SPECTRAL_PROFILE_OUTPUT"], !profilePath.isEmpty {
        let profile = "n=\(n) elapsedMs=\(Int((elapsed * 1_000).rounded())) "
            + "clusters=\(Set(labels).count) labels=\(labels.count) "
            + "fingerprint=\(String(fingerprint, radix: 16))\n"
        try profile.write(to: URL(fileURLWithPath: profilePath), atomically: true, encoding: .utf8)
    }
    #expect(labels.count == n)
    #expect(Set(labels).count == clusters)
}

@Test func spectralClusteringFrozenEmbeddingProfile() throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["SWIFTASR_RUN_SPECTRAL_FROZEN_PROFILE"] == "1" else {
        print("Frozen spectral profile skipped: set SWIFTASR_RUN_SPECTRAL_FROZEN_PROFILE=1")
        return
    }
    guard let path = environment["SWIFTASR_SPECTRAL_EMBEDDINGS_PATH"], !path.isEmpty else {
        Issue.record("Set SWIFTASR_SPECTRAL_EMBEDDINGS_PATH to a native Float32 [N,192] file")
        return
    }
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    guard data.count.isMultiple(of: MemoryLayout<Float>.size) else {
        Issue.record("Frozen embedding file has a non-Float32 byte count: \(data.count)")
        return
    }
    let embeddings = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    guard embeddings.count.isMultiple(of: 192) else {
        Issue.record("Frozen embedding file is not divisible into 192-dim rows: \(embeddings.count)")
        return
    }
    let count = embeddings.count / 192
    let startedAt = Date()
    let labels = SpectralClustering(minNumSpks: 2, maxNumSpks: 15)
        .cluster(embeddings: embeddings, count: count)
    let elapsed = Date().timeIntervalSince(startedAt)
    let fingerprint = labels.reduce(UInt64(1_469_598_103_934_665_603)) { partial, label in
        (partial ^ UInt64(label)) &* 1_099_511_628_211
    }
    print(
        "FROZEN_SPECTRAL_PROFILE n=\(count) elapsedMs=\(Int((elapsed * 1_000).rounded())) " +
        "clusters=\(Set(labels).count) labels=\(labels.count) fingerprint=\(String(fingerprint, radix: 16))"
    )
    if let profilePath = environment["SWIFTASR_SPECTRAL_PROFILE_OUTPUT"], !profilePath.isEmpty {
        let profile = "n=\(count) elapsedMs=\(Int((elapsed * 1_000).rounded())) "
            + "clusters=\(Set(labels).count) labels=\(labels.count) "
            + "fingerprint=\(String(fingerprint, radix: 16))\n"
        try profile.write(to: URL(fileURLWithPath: profilePath), atomically: true, encoding: .utf8)
    }
    if let outputPath = environment["SWIFTASR_SPECTRAL_LABELS_OUTPUT"], !outputPath.isEmpty {
        let text = labels.map(String.init).joined(separator: ",")
        try text.write(to: URL(fileURLWithPath: outputPath), atomically: true, encoding: .utf8)
    }
    #expect(labels.count == count)
}

@Test func blockCSRGraphFrozenParityProfile() throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["SWIFTASR_RUN_BLOCK_CSR_PROFILE"] == "1" else {
        print("Block CSR profile skipped: set SWIFTASR_RUN_BLOCK_CSR_PROFILE=1")
        return
    }
    guard let path = environment["SWIFTASR_SPECTRAL_EMBEDDINGS_PATH"], !path.isEmpty else {
        Issue.record("Set SWIFTASR_SPECTRAL_EMBEDDINGS_PATH to a native Float32 [N,192] file")
        return
    }
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    guard data.count.isMultiple(of: MemoryLayout<Float>.size) else {
        Issue.record("Frozen embedding file has a non-Float32 byte count: \(data.count)")
        return
    }
    let embeddings = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    let dimension = 192
    guard embeddings.count.isMultiple(of: dimension) else {
        Issue.record("Frozen embedding file is not divisible into 192-dim rows: \(embeddings.count)")
        return
    }
    let count = embeddings.count / dimension
    let keep = max(6, count - Int((1 - 0.022) * Double(count)))
    var normalized = [Float](repeating: 0, count: embeddings.count)
    for row in 0..<count {
        var squaredNorm: Float = 0
        for feature in 0..<dimension {
            let value = embeddings[row * dimension + feature]
            squaredNorm += value * value
        }
        let norm = sqrt(squaredNorm)
        guard norm.isFinite, norm > 1e-10 else {
            Issue.record("Frozen embedding contains a zero-norm row")
            return
        }
        for feature in 0..<dimension {
            normalized[row * dimension + feature] = embeddings[row * dimension + feature] / norm
        }
    }

    var denseAffinity = [Float](repeating: 0, count: count * count)
    cblas_sgemm(
        CblasRowMajor, CblasNoTrans, CblasTrans,
        Int32(count), Int32(count), Int32(dimension),
        1, &normalized, Int32(dimension), &normalized, Int32(dimension),
        0, &denseAffinity, Int32(count)
    )
    let densePruned = SpectralClustering.prunedAffinityMatrix(
        denseAffinity, count: count, retainedCount: keep, workerCount: 1
    )
    let startedAt = Date()
    guard let csr = BlockCSRGraphBuilder.build(
        normalizedEmbeddings: normalized,
        count: count,
        dimension: dimension,
        retainedCount: keep
    ) else {
        Issue.record("Block CSR graph construction failed")
        return
    }
    let elapsed = Date().timeIntervalSince(startedAt)
    var edgeMismatchCount = 0
    var maxValueError: Float = 0
    for row in 0..<count {
        let expectedColumns = (0..<count).filter { densePruned[row * count + $0] != 0 }
        let actualColumns = (csr.rowOffsets[row]..<csr.rowOffsets[row + 1]).map { csr.columns[$0] }
        if actualColumns != expectedColumns {
            edgeMismatchCount += 1
        }
        for edge in csr.rowOffsets[row]..<csr.rowOffsets[row + 1] {
            let column = csr.columns[edge]
            maxValueError = max(maxValueError, abs(csr.values[edge] - denseAffinity[row * count + column]))
        }
    }
    let peakBytes = BlockCSRGraph.estimatedPeakBytes(
        count: count,
        retainedCount: keep,
        blockRows: BlockCSRGraphBuilder.defaultBlockRows
    )
    guard let sparseMatrix = AccelerateSparseMatrix(graph: csr) else {
        Issue.record("Accelerate sparse matrix construction failed")
        return
    }
    let iterationCount = environment["SWIFTASR_BLOCK_CSR_SPMV_ITERS"].flatMap(Int.init) ?? 100
    let input = (0..<count).map { Float(sin(Double($0 + 1) * 0.173)) }
    var nativeOutput = [Float](repeating: 0, count: count)
    let nativeStartedAt = Date()
    for _ in 0..<iterationCount {
        guard sparseMatrix.multiply(input, into: &nativeOutput) else {
            Issue.record("Accelerate sparse multiply failed")
            return
        }
    }
    let nativeMilliseconds = Int((Date().timeIntervalSince(nativeStartedAt) * 1_000).rounded())
    var swiftOutput = [Float](repeating: 0, count: count)
    let swiftStartedAt = Date()
    for _ in 0..<iterationCount {
        for row in 0..<count {
            var sum: Float = 0
            for edge in csr.rowOffsets[row]..<csr.rowOffsets[row + 1] {
                sum += csr.values[edge] * input[csr.columns[edge]]
            }
            swiftOutput[row] = sum
        }
    }
    let swiftMilliseconds = Int((Date().timeIntervalSince(swiftStartedAt) * 1_000).rounded())
    var spmvError: Float = 0
    for index in 0..<count {
        spmvError = max(spmvError, abs(nativeOutput[index] - swiftOutput[index]))
    }
    var eigenSummary = ""
    if environment["SWIFTASR_RUN_NATIVE_SPARSE_EIGEN"] == "1"
        || environment["SWIFTASR_RUN_DEFLATED_RESTART"] == "1" {
        guard let laplacian = NativeSparseLaplacian(graph: csr) else {
            Issue.record("Native sparse Laplacian construction failed")
            return
        }
        let eigenStartedAt = Date()
        let krylovDimension = environment["SWIFTASR_NATIVE_LANCZOS_DIM"].flatMap(Int.init) ?? 96
        let requestedEigenCount = environment["SWIFTASR_NATIVE_EIGEN_COUNT"].flatMap(Int.init) ?? 16
        let eigenpairs: NativeSparseEigenpairs?
        let solverName: String
        if environment["SWIFTASR_RUN_DEFLATED_RESTART"] == "1" {
            solverName = "deflatedRestart"
            eigenpairs = DeflatedRestartLanczos.smallestEigenpairs(
                laplacian: laplacian,
                requestedCount: min(requestedEigenCount, count),
                krylovDimension: krylovDimension
            )
        } else {
            solverName = "plain"
            eigenpairs = NativeSparseLanczos.smallestEigenpairs(
                laplacian: laplacian,
                requestedCount: min(requestedEigenCount, count),
                krylovDimension: krylovDimension
            )
        }
        guard let eigenpairs else {
            Issue.record("Native sparse Lanczos failed")
            return
        }
        let eigenMilliseconds = Int((Date().timeIntervalSince(eigenStartedAt) * 1_000).rounded())
        let bestK = SpectralClustering.speakerCountFromEigenvalues(
            eigenpairs.values,
            minNumSpks: 2,
            maxNumSpks: 15
        )
        eigenSummary = "nativeEigenMs=\(eigenMilliseconds) solver=\(solverName) eigenCount=\(requestedEigenCount) krylov=\(krylovDimension) residual=\(eigenpairs.maxResidual) "
            + "bestK=\(bestK) residuals=\(eigenpairs.residuals.prefix(6)) "
            + "eigenvalues=\(eigenpairs.values.prefix(6)) "
        #expect(eigenpairs.maxResidual < 5e-3)
    }
    let summary = "n=\(count) keep=\(keep) blockRows=\(BlockCSRGraphBuilder.defaultBlockRows) "
        + "buildMs=\(Int((elapsed * 1_000).rounded())) edgeMismatchRows=\(edgeMismatchCount) "
        + "maxValueError=\(maxValueError) estimatedPeakBytes=\(peakBytes) "
        + "spmvIterations=\(iterationCount) nativeSpmvMs=\(nativeMilliseconds) "
        + "swiftSpmvMs=\(swiftMilliseconds) spmvError=\(spmvError) \(eigenSummary)\n"
    print("BLOCK_CSR_PROFILE \(summary)")
    if let outputPath = environment["SWIFTASR_BLOCK_CSR_PROFILE_OUTPUT"], !outputPath.isEmpty {
        try summary.write(to: URL(fileURLWithPath: outputPath), atomically: true, encoding: .utf8)
    }
    #expect(edgeMismatchCount == 0)
    #expect(maxValueError < 1e-5)
    #expect(spmvError < 1e-5)
}

/// Sweep the native sparse candidate's Krylov basis size on the ten paired
/// frozen inputs. This is deliberately opt-in: it is a multi-minute
/// diagnostic and does not affect the production dense route.
@Test func nativeSparseLanczosDimensionSweep() throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["SWIFTASR_RUN_NATIVE_LANCZOS_SWEEP"] == "1" else {
        print("Native sparse dimension sweep skipped: set SWIFTASR_RUN_NATIVE_LANCZOS_SWEEP=1")
        return
    }
    let home = NSHomeDirectory()
    let roots = [
        "\(home)/Library/Application Support/SwiftASR/experiments/diarization-poc/cascade-samples",
        "\(home)/Library/Application Support/SwiftASR/experiments/diarization-next-2026-07-23/T00-baseline",
    ]
    let samples = ["adhd2", "xiangsheng", "oldeng2", "yadong", "fanfan"]
    let paths = roots.flatMap { root in
        samples.map { sample in "\(root)/\(sample)/evidence.embeddings.f32" }
    }
    let dimensions = environment["SWIFTASR_NATIVE_LANCZOS_SWEEP_DIMS"]
        .map { $0.split(separator: ",").compactMap { Int($0) } }
        ?? [48, 64, 80, 96, 128, 192, 256]
    let uniqueDimensions = Array(Set(dimensions.filter { $0 >= 24 })).sorted()
    guard uniqueDimensions.count >= 2 else {
        Issue.record("SWIFTASR_NATIVE_LANCZOS_SWEEP_DIMS must contain two or more dimensions >= 24")
        return
    }
    let anchorDimension = uniqueDimensions.max()!
    let outputURL = environment["SWIFTASR_NATIVE_LANCZOS_SWEEP_OUTPUT"].flatMap {
        $0.isEmpty ? nil : URL(fileURLWithPath: $0)
    }
    var report = [
        "# Native sparse Lanczos Krylov-dimension sweep",
        "",
        "Comparison anchor: m=\(anchorDimension); graph: block SGEMM + exact top-P CSR; residual is ||Lv-λv||₂.",
        "",
        "| snapshot | N | m | eigen ms | K | qualified / 16 | max residual | ARI vs m=\(anchorDimension) | label fingerprint |",
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |",
    ]
    defer {
        if let outputURL {
            try? report.joined(separator: "\n").appending("\n")
                .write(to: outputURL, atomically: true, encoding: .utf8)
        }
    }

    for path in paths {
        guard FileManager.default.fileExists(atPath: path) else {
            Issue.record("Missing frozen embedding: \(path)")
            continue
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let embeddings = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        guard embeddings.count.isMultiple(of: 192) else {
            Issue.record("Frozen embedding is not [N,192]: \(path)")
            continue
        }
        let count = embeddings.count / 192
        guard let normalized = normalizedSweepEmbeddings(embeddings, count: count, dimension: 192) else {
            Issue.record("Could not normalize frozen embedding: \(path)")
            continue
        }
        let keep = max(6, count - Int((1 - 0.022) * Double(count)))
        guard let graph = BlockCSRGraphBuilder.build(
            normalizedEmbeddings: normalized,
            count: count,
            dimension: 192,
            retainedCount: keep
        ), let laplacian = NativeSparseLaplacian(graph: graph) else {
            Issue.record("Could not build sparse Laplacian: \(path)")
            continue
        }
        let snapshot = path
            .replacingOccurrences(of: "\(home)/Library/Application Support/SwiftASR/experiments/", with: "")
            .replacingOccurrences(of: "/evidence.embeddings.f32", with: "")
        var results: [Int: NativeSweepResult] = [:]
        for dimension in uniqueDimensions.reversed() {
            let startedAt = Date()
            guard let eigenpairs = NativeSparseLanczos.smallestEigenpairs(
                laplacian: laplacian,
                requestedCount: min(16, count),
                krylovDimension: dimension
            ) else {
                Issue.record("Native sparse Lanczos failed: \(snapshot), m=\(dimension)")
                continue
            }
            let bestK = SpectralClustering.speakerCountFromEigenvalues(
                eigenpairs.values, minNumSpks: 2, maxNumSpks: 15
            )
            let labels = sweepLabels(
                eigenvectors: eigenpairs.vectors, count: count, clusterCount: bestK
            )
            results[dimension] = NativeSweepResult(
                milliseconds: Int((Date().timeIntervalSince(startedAt) * 1_000).rounded()),
                bestK: bestK,
                qualifiedPairs: eigenpairs.residuals.filter { $0 < 5e-3 }.count,
                maxResidual: eigenpairs.maxResidual,
                labels: labels
            )
        }
        guard let anchor = results[anchorDimension] else { continue }
        for dimension in uniqueDimensions {
            guard let result = results[dimension] else { continue }
            let ari = adjustedRandIndex(result.labels, anchor.labels)
            report.append(
                "| \(snapshot) | \(count) | \(dimension) | \(result.milliseconds) | \(result.bestK) | \(result.qualifiedPairs) | "
                    + "\(String(format: "%.5g", result.maxResidual)) | \(String(format: "%.8f", ari)) | "
                    + "\(labelFingerprint(result.labels)) |"
            )
            print("NATIVE_LANCZOS_SWEEP snapshot=\(snapshot) n=\(count) m=\(dimension) ms=\(result.milliseconds) k=\(result.bestK) qualified=\(result.qualifiedPairs) residual=\(result.maxResidual) ari=\(ari)")
        }
        if let outputURL {
            try report.joined(separator: "\n").appending("\n")
                .write(to: outputURL, atomically: true, encoding: .utf8)
        }
    }
}

private struct NativeSweepResult {
    let milliseconds: Int
    let bestK: Int
    let qualifiedPairs: Int
    let maxResidual: Float
    let labels: [Int]
}

private func normalizedSweepEmbeddings(_ embeddings: [Float], count: Int, dimension: Int) -> [Float]? {
    var normalized = [Float](repeating: 0, count: embeddings.count)
    for row in 0..<count {
        let offset = row * dimension
        var squaredNorm: Float = 0
        vDSP_svesq(Array(embeddings[offset..<(offset + dimension)]), 1, &squaredNorm, vDSP_Length(dimension))
        let norm = sqrt(squaredNorm)
        guard norm.isFinite, norm > 1e-10 else { return nil }
        var scalar = norm
        vDSP_vsdiv(
            Array(embeddings[offset..<(offset + dimension)]), 1, &scalar,
            &normalized[offset], 1, vDSP_Length(dimension)
        )
    }
    return normalized
}

private func sweepLabels(eigenvectors: [Float], count: Int, clusterCount: Int) -> [Int] {
    var lowDim = [Float](repeating: 0, count: count * clusterCount)
    for row in 0..<count {
        for column in 0..<clusterCount {
            lowDim[row * clusterCount + column] = eigenvectors[column * count + row]
        }
    }
    return SpectralClustering.runKMeans(data: lowDim, n: count, k: clusterCount, dim: clusterCount)
}

private func labelFingerprint(_ labels: [Int]) -> String {
    let value = labels.reduce(UInt64(1_469_598_103_934_665_603)) { partial, label in
        (partial ^ UInt64(label)) &* 1_099_511_628_211
    }
    return String(value, radix: 16)
}

private func adjustedRandIndex(_ lhs: [Int], _ rhs: [Int]) -> Double {
    guard lhs.count == rhs.count, lhs.count > 1 else { return lhs == rhs ? 1 : 0 }
    func pairs(_ value: Int) -> Double { Double(value * (value - 1)) / 2 }
    var lhsCounts: [Int: Int] = [:]
    var rhsCounts: [Int: Int] = [:]
    var intersections: [String: Int] = [:]
    for index in lhs.indices {
        lhsCounts[lhs[index], default: 0] += 1
        rhsCounts[rhs[index], default: 0] += 1
        intersections["\(lhs[index]):\(rhs[index])", default: 0] += 1
    }
    let observed = intersections.values.reduce(0.0) { $0 + pairs($1) }
    let lhsPairs = lhsCounts.values.reduce(0.0) { $0 + pairs($1) }
    let rhsPairs = rhsCounts.values.reduce(0.0) { $0 + pairs($1) }
    let totalPairs = pairs(lhs.count)
    let expected = lhsPairs * rhsPairs / totalPairs
    let maximum = 0.5 * (lhsPairs + rhsPairs)
    return maximum == expected ? (lhs == rhs ? 1 : 0) : (observed - expected) / (maximum - expected)
}

/// Measures the only comparison that can inform a fixed-m route boundary:
/// current production dense clustering versus the experimental native sparse
/// graph and a non-adaptive m=96 Lanczos solve, in one process and build.
@Test func fixedM96DenseCrossoverProfile() throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["SWIFTASR_RUN_FIXED_M96_CROSSOVER"] == "1" else {
        print("Fixed-m=96 crossover profile skipped: set SWIFTASR_RUN_FIXED_M96_CROSSOVER=1")
        return
    }
    let home = NSHomeDirectory()
    let root = "\(home)/Library/Application Support/SwiftASR/experiments/diarization-next-2026-07-23/T00-baseline"
    let samples = ["yadong", "xiangsheng", "adhd2", "oldeng2", "fanfan"]
    let outputURL = environment["SWIFTASR_FIXED_M96_CROSSOVER_OUTPUT"].flatMap {
        $0.isEmpty ? nil : URL(fileURLWithPath: $0)
    }
    var report = [
        "# Fixed m=96 native sparse vs current dense",
        "",
        "| sample | N | dense ms | sparse graph ms | fixed-m=96 sparse total ms | dense K | sparse K | partition ARI |",
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]
    defer {
        if let outputURL {
            try? report.joined(separator: "\n").appending("\n")
                .write(to: outputURL, atomically: true, encoding: .utf8)
        }
    }

    for sample in samples {
        let path = "\(root)/\(sample)/evidence.embeddings.f32"
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let embeddings = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        guard embeddings.count.isMultiple(of: 192) else {
            Issue.record("Frozen embedding is not [N,192]: \(path)")
            continue
        }
        let count = embeddings.count / 192
        let denseStartedAt = Date()
        let denseLabels = SpectralClustering(minNumSpks: 2, maxNumSpks: 15)
            .cluster(embeddings: embeddings, count: count)
        let denseMilliseconds = Int((Date().timeIntervalSince(denseStartedAt) * 1_000).rounded())
        guard denseLabels.count == count,
              let normalized = normalizedSweepEmbeddings(embeddings, count: count, dimension: 192) else {
            Issue.record("Dense clustering or normalization failed: \(sample)")
            continue
        }
        let keep = max(6, count - Int((1 - 0.022) * Double(count)))
        let sparseStartedAt = Date()
        guard let graph = BlockCSRGraphBuilder.build(
            normalizedEmbeddings: normalized,
            count: count,
            dimension: 192,
            retainedCount: keep
        ) else {
            Issue.record("Block CSR construction failed: \(sample)")
            continue
        }
        let graphMilliseconds = Int((Date().timeIntervalSince(sparseStartedAt) * 1_000).rounded())
        guard let laplacian = NativeSparseLaplacian(graph: graph),
              let eigenpairs = NativeSparseLanczos.smallestEigenpairs(
                laplacian: laplacian, requestedCount: min(16, count), krylovDimension: 96
              ) else {
            Issue.record("Fixed m=96 native sparse solve failed: \(sample)")
            continue
        }
        let sparseK = SpectralClustering.speakerCountFromEigenvalues(
            eigenpairs.values, minNumSpks: 2, maxNumSpks: 15
        )
        let sparseLabels = sweepLabels(
            eigenvectors: eigenpairs.vectors, count: count, clusterCount: sparseK
        )
        let sparseTotalMilliseconds = Int((Date().timeIntervalSince(sparseStartedAt) * 1_000).rounded())
        let ari = adjustedRandIndex(denseLabels, sparseLabels)
        report.append(
            "| \(sample) | \(count) | \(denseMilliseconds) | \(graphMilliseconds) | "
                + "\(sparseTotalMilliseconds) | \(Set(denseLabels).count) | \(sparseK) | "
                + "\(String(format: "%.8f", ari)) |"
        )
        print(
            "FIXED_M96_CROSSOVER sample=\(sample) n=\(count) denseMs=\(denseMilliseconds) "
                + "graphMs=\(graphMilliseconds) sparseMs=\(sparseTotalMilliseconds) "
                + "denseK=\(Set(denseLabels).count) sparseK=\(sparseK) ari=\(ari)"
        )
        if let outputURL {
            try report.joined(separator: "\n").appending("\n")
                .write(to: outputURL, atomically: true, encoding: .utf8)
        }
    }
}

/// Profiles the existing overlapping dense-batch route before introducing any
/// prototype-graph or final all-N refinement. This isolates the speed/quality
/// crossover caused by splitting alone.
@Test func denseBatchCrossoverProfile() throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["SWIFTASR_RUN_DENSE_BATCH_CROSSOVER"] == "1" else {
        print("Dense batch crossover profile skipped: set SWIFTASR_RUN_DENSE_BATCH_CROSSOVER=1")
        return
    }
    let home = NSHomeDirectory()
    let root = "\(home)/Library/Application Support/SwiftASR/experiments/diarization-next-2026-07-23/T00-baseline"
    let cases: [(name: String, path: String, count: Int)] = [
        ("fanfan-prefix2500", "\(root)/fanfan/evidence.embeddings.f32", 2_500),
        ("fanfan-prefix3000", "\(root)/fanfan/evidence.embeddings.f32", 3_000),
        ("fanfan-prefix3200", "\(root)/fanfan/evidence.embeddings.f32", 3_200),
        ("fanfan-prefix3500", "\(root)/fanfan/evidence.embeddings.f32", 3_500),
        ("adhd2", "\(root)/adhd2/evidence.embeddings.f32", 4_308),
        ("oldeng2", "\(root)/oldeng2/evidence.embeddings.f32", 4_553),
        ("fanfan", "\(root)/fanfan/evidence.embeddings.f32", 6_408),
    ]
    let batchSizes = [2_000, 3_000]
    let outputURL = environment["SWIFTASR_DENSE_BATCH_CROSSOVER_OUTPUT"].flatMap {
        $0.isEmpty ? nil : URL(fileURLWithPath: $0)
    }
    var report = [
        "# Overlapping dense-batch crossover",
        "",
        "Existing route only: local dense spectral, 256-window overlap, sequential centroid alignment at cosine 0.78; no final all-N refinement.",
        "",
        "| sample | N | route | elapsed ms | K | ARI vs global dense |",
        "| --- | ---: | --- | ---: | ---: | ---: |",
    ]
    defer {
        if let outputURL {
            try? report.joined(separator: "\n").appending("\n")
                .write(to: outputURL, atomically: true, encoding: .utf8)
        }
    }

    for item in cases {
        let data = try Data(contentsOf: URL(fileURLWithPath: item.path))
        let allEmbeddings = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        guard allEmbeddings.count >= item.count * 192 else {
            Issue.record("Frozen embedding is too short for \(item.name)")
            continue
        }
        let embeddings = Array(allEmbeddings.prefix(item.count * 192))
        let globalStartedAt = Date()
        let globalLabels = SpectralClustering(
            minNumSpks: 2,
            maxNumSpks: 15,
            batchLimit: SpectralClustering.spectralClusterMaxChunks
        ).cluster(embeddings: embeddings, count: item.count)
        let globalMilliseconds = Int((Date().timeIntervalSince(globalStartedAt) * 1_000).rounded())
        guard globalLabels.count == item.count else {
            Issue.record("Global dense clustering failed: \(item.name)")
            continue
        }
        report.append(
            "| \(item.name) | \(item.count) | global | \(globalMilliseconds) | "
                + "\(Set(globalLabels).count) | 1.00000000 |"
        )

        for batchSize in batchSizes {
            let startedAt = Date()
            let batchLabels = SpectralClustering(
                minNumSpks: 2,
                maxNumSpks: 15,
                batchLimit: batchSize
            ).cluster(embeddings: embeddings, count: item.count)
            let milliseconds = Int((Date().timeIntervalSince(startedAt) * 1_000).rounded())
            guard batchLabels.count == item.count else {
                Issue.record("Dense batch clustering failed: \(item.name), B=\(batchSize)")
                continue
            }
            let ari = adjustedRandIndex(globalLabels, batchLabels)
            report.append(
                "| \(item.name) | \(item.count) | B=\(batchSize) | \(milliseconds) | "
                    + "\(Set(batchLabels).count) | \(String(format: "%.8f", ari)) |"
            )
            print(
                "DENSE_BATCH_CROSSOVER sample=\(item.name) n=\(item.count) batch=\(batchSize) "
                    + "globalMs=\(globalMilliseconds) batchMs=\(milliseconds) "
                    + "globalK=\(Set(globalLabels).count) batchK=\(Set(batchLabels).count) ari=\(ari)"
            )
        }
        if let outputURL {
            try report.joined(separator: "\n").appending("\n")
                .write(to: outputURL, atomically: true, encoding: .utf8)
        }
    }
}

@Test func topPSelectionConcurrencyProfile() throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["SWIFTASR_RUN_TOP_P_PROFILE"] == "1" else {
        print("Top-P profile skipped: set SWIFTASR_RUN_TOP_P_PROFILE=1")
        return
    }
    let n = environment["SWIFTASR_TOP_P_PROFILE_N"].flatMap(Int.init) ?? 4_000
    guard n >= 6 else {
        Issue.record("SWIFTASR_TOP_P_PROFILE_N must be at least 6")
        return
    }
    let dim = 192
    let keep = max(6, n - Int((1 - 0.022) * Double(n)))
    var embeddings = [Float](repeating: 0, count: n * dim)
    for row in 0..<n {
        let cluster = row % 3
        for column in 0..<dim {
            let center = column / 5 == cluster ? Float(1) : Float(0)
            embeddings[row * dim + column] = center
                + Float(sin(Double((row + 1) * (column + 3)) * 0.17)) * 0.1
        }
        var sum: Float = 0
        vDSP_svesq(Array(embeddings[(row * dim)..<((row + 1) * dim)]), 1, &sum, vDSP_Length(dim))
        var norm = sqrt(sum)
        vDSP_vsdiv(
            Array(embeddings[(row * dim)..<((row + 1) * dim)]), 1, &norm,
            &embeddings[row * dim], 1, vDSP_Length(dim)
        )
    }
    var affinity = [Float](repeating: 0, count: n * n)
    cblas_sgemm(
        CblasRowMajor, CblasNoTrans, CblasTrans,
        Int32(n), Int32(n), Int32(dim),
        1, &embeddings, Int32(dim), &embeddings, Int32(dim), 0, &affinity, Int32(n)
    )

    let requestedWorkers = environment["SWIFTASR_TOP_P_PROFILE_WORKERS"]
        .map { $0.split(separator: ",").compactMap { Int($0) } } ?? [1, 2, 3, 6]
    let workers = Array(Set(requestedWorkers.filter { $0 > 0 })).sorted()
    guard !workers.isEmpty else {
        Issue.record("SWIFTASR_TOP_P_PROFILE_WORKERS must contain positive integers")
        return
    }

    var baseline: [Int]?
    for workerCount in workers {
        let startedAt = Date()
        let selected = topPIndices(
            affinity: affinity, count: n, keep: keep, workerCount: workerCount
        )
        let elapsed = Date().timeIntervalSince(startedAt)
        let fingerprint = selected.reduce(UInt64(1_469_598_103_934_665_603)) { partial, index in
            (partial ^ UInt64(index)) &* 1_099_511_628_211
        }
        print(
            "TOP_P_CONCURRENCY n=\(n) keep=\(keep) workers=\(workerCount) " +
            "selectionMs=\(Int((elapsed * 1_000).rounded())) fingerprint=\(String(fingerprint, radix: 16))"
        )
        if let baseline {
            #expect(selected == baseline, "Parallel selection must preserve every row's top-P indexes")
        } else {
            baseline = selected
        }
    }
}

private func topPIndices(
    affinity: [Float],
    count: Int,
    keep: Int,
    workerCount: Int
) -> [Int] {
    let store = TopPChunkStore(workerCount: workerCount)
    DispatchQueue.concurrentPerform(iterations: workerCount) { worker in
        let start = count * worker / workerCount
        let end = count * (worker + 1) / workerCount
        guard start < end else { return }
        var local: [Int] = []
        local.reserveCapacity((end - start) * keep)
        for row in start..<end {
            let indexes = topPIndices(
                values: affinity,
                offset: row * count,
                count: count,
                keep: keep
            ).sorted()
            local.append(contentsOf: indexes)
        }
        store.set(local, for: worker)
    }
    return (0..<workerCount).flatMap { store.selection(for: $0) }
}

private final class TopPChunkStore: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [[Int]]

    init(workerCount: Int) {
        chunks = Array(repeating: [], count: workerCount)
    }

    func set(_ selection: [Int], for worker: Int) {
        lock.lock()
        chunks[worker] = selection
        lock.unlock()
    }

    func selection(for worker: Int) -> [Int] {
        lock.lock()
        defer { lock.unlock() }
        return chunks[worker]
    }
}

private func topPIndices(
    values: [Float],
    offset: Int,
    count: Int,
    keep: Int
) -> [Int] {
    var heap: [(value: Float, index: Int)] = []
    heap.reserveCapacity(keep)
    for index in 0..<count {
        let value = values[offset + index]
        if heap.count < keep {
            heap.append((value, index))
            siftUp(&heap, from: heap.count - 1)
        } else if value > heap[0].value {
            heap[0] = (value, index)
            siftDown(&heap, from: 0)
        }
    }
    return heap.map(\.index)
}

private func siftUp(_ heap: inout [(value: Float, index: Int)], from start: Int) {
    var child = start
    while child > 0 {
        let parent = (child - 1) / 2
        guard heap[child].value < heap[parent].value else { break }
        heap.swapAt(child, parent)
        child = parent
    }
}

private func siftDown(_ heap: inout [(value: Float, index: Int)], from start: Int) {
    var parent = start
    while true {
        let left = parent * 2 + 1
        guard left < heap.count else { return }
        let right = left + 1
        let child = right < heap.count && heap[right].value < heap[left].value ? right : left
        guard heap[child].value < heap[parent].value else { return }
        heap.swapAt(child, parent)
        parent = child
    }
}
