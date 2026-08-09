import Testing
import Foundation
@testable import SwiftASR
@testable import SparseClusteringExperiments

// MARK: - Spectral Clustering 全面测试

@Test func parallelPrunedAffinityMatchesSerialGraph() {
    let count = 17
    var affinity = [Float](repeating: 0, count: count * count)
    for row in 0..<count {
        for column in 0..<count {
            // Unique values exercise every heap replacement without relying
            // on implementation-dependent tie ordering.
            affinity[row * count + column] = Float(row * 101 + column * 3) / 1_000
        }
    }

    let serial = SpectralClustering.prunedAffinityMatrix(
        affinity, count: count, retainedCount: 6, workerCount: 1
    )
    let parallel = SpectralClustering.prunedAffinityMatrix(
        affinity, count: count, retainedCount: 6, workerCount: 4
    )
    #expect(parallel == serial)
}

@Test func blockCSRGraphMatchesDenseTopPEdgeSet() {
    let count = 37
    let dimension = 8
    let keep = 7
    var embeddings = [Float](repeating: 0, count: count * dimension)
    for row in 0..<count {
        var squaredNorm: Float = 0
        for column in 0..<dimension {
            let value = Float(sin(Double((row + 1) * (column + 3)) * 0.371))
                + Float(row * 17 + column) * 1e-4
            embeddings[row * dimension + column] = value
            squaredNorm += value * value
        }
        let norm = sqrt(squaredNorm)
        for column in 0..<dimension {
            embeddings[row * dimension + column] /= norm
        }
    }

    var denseAffinity = [Float](repeating: 0, count: count * count)
    for row in 0..<count {
        for column in 0..<count {
            var dot: Float = 0
            for feature in 0..<dimension {
                dot += embeddings[row * dimension + feature]
                    * embeddings[column * dimension + feature]
            }
            denseAffinity[row * count + column] = dot
        }
    }
    let densePruned = SpectralClustering.prunedAffinityMatrix(
        denseAffinity, count: count, retainedCount: keep, workerCount: 1
    )
    guard let csr = BlockCSRGraphBuilder.build(
        normalizedEmbeddings: embeddings,
        count: count,
        dimension: dimension,
        retainedCount: keep,
        blockRows: 5,
        workerCount: 3
    ) else {
        Issue.record("Block CSR graph construction failed")
        return
    }

    #expect(csr.rowOffsets == (0...count).map { $0 * keep })
    for row in 0..<count {
        let expectedColumns = (0..<count).filter { densePruned[row * count + $0] != 0 }
        let edges = csr.rowOffsets[row]..<csr.rowOffsets[row + 1]
        let actualColumns = edges.map { csr.columns[$0] }
        #expect(actualColumns == expectedColumns)
        for edge in edges {
            let column = csr.columns[edge]
            #expect(abs(csr.values[edge] - denseAffinity[row * count + column]) < 1e-5)
        }
    }
}

@Test func blockCSRGraphHasBoundedWorkingSet() {
    // N=6,688 is the proposed 512 MiB dense boundary. A 256-row block plus
    // directed CSR needs under 20 MiB beyond the embedding input.
    let bytes = BlockCSRGraph.estimatedPeakBytes(
        count: 6_688,
        retainedCount: 148,
        blockRows: 256
    )
    #expect(bytes < 20 * 1024 * 1024)
}

@Test func accelerateSparseMatrixMatchesCSRMultiply() {
    let embeddings: [Float] = [
        1, 0, 0,
        0.9, 0.1, 0,
        0, 1, 0,
        0, 0.9, 0.1
    ]
    guard let graph = BlockCSRGraphBuilder.build(
        normalizedEmbeddings: embeddings,
        count: 4,
        dimension: 3,
        retainedCount: 2,
        blockRows: 2,
        workerCount: 1
    ), let matrix = AccelerateSparseMatrix(graph: graph) else {
        Issue.record("Accelerate sparse matrix construction failed")
        return
    }
    let input: [Float] = [0.25, -0.5, 0.75, 1.0]
    guard let output = matrix.multiply(input) else {
        Issue.record("Accelerate sparse multiply failed")
        return
    }
    var expected = [Float](repeating: 0, count: graph.count)
    for row in 0..<graph.count {
        for edge in graph.rowOffsets[row]..<graph.rowOffsets[row + 1] {
            expected[row] += graph.values[edge] * input[graph.columns[edge]]
        }
    }
    for index in expected.indices {
        #expect(abs(output[index] - expected[index]) < 1e-6)
    }
}

@Test func nativeSparseLanczosFindsDisconnectedModes() {
    let count = 40
    let dimension = 4
    var embeddings = [Float](repeating: 0, count: count * dimension)
    for row in 0..<count {
        let cluster = row < count / 2 ? 0 : 1
        embeddings[row * dimension + cluster] = 1
        embeddings[row * dimension + 2] = Float(row % 5) * 0.001
        var squaredNorm: Float = 0
        for column in 0..<dimension {
            squaredNorm += embeddings[row * dimension + column] * embeddings[row * dimension + column]
        }
        let norm = sqrt(squaredNorm)
        for column in 0..<dimension {
            embeddings[row * dimension + column] /= norm
        }
    }
    guard let graph = BlockCSRGraphBuilder.build(
        normalizedEmbeddings: embeddings,
        count: count,
        dimension: dimension,
        retainedCount: 6,
        blockRows: 7,
        workerCount: 3
    ), let laplacian = NativeSparseLaplacian(graph: graph),
      let eigenpairs = NativeSparseLanczos.smallestEigenpairs(
        laplacian: laplacian,
        requestedCount: 4,
        krylovDimension: 24
      ) else {
        Issue.record("Native sparse Lanczos unexpectedly failed")
        return
    }
    #expect(eigenpairs.values.count == 4)
    #expect(eigenpairs.values[0] < 1e-3)
    #expect(eigenpairs.values[1] < 1e-3)
    #expect(eigenpairs.maxResidual < 5e-3)
}

@Test func clusteringEmpty() {
    let c = SpectralClustering(minNumSpks: 1)
    let labels = c.cluster(embeddings: [], count: 0)
    #expect(labels.isEmpty)
}

@Test func clusteringSingleChunk() {
    let c = SpectralClustering(minNumSpks: 1)
    let labels = c.cluster(embeddings: [Float](repeating: 0, count: 192), count: 1)
    #expect(labels == [0])
}

@Test func clusteringTwoIdenticalSpeakers() {
    // 2 个 chunk，embedding 完全一样 → 应该聚成 1 类
    let c = SpectralClustering(minNumSpks: 1)
    let emb = [Float](repeating: 1, count: 2 * 192)
    let labels = c.cluster(embeddings: emb, count: 2)
    #expect(Set(labels).count == 1, "expected 1 cluster, got \(Set(labels).count)")
}

@Test func clusteringMaxChunksConstant() {
    // 8192 remains the long-recording diagnostic threshold, but dense
    // clustering must use the stricter working-set limit below it.
    #expect(SpectralClustering.spectralClusterMaxChunks == 8192)
    #expect(SpectralClustering.denseSpectralMaxChunks == 4096)
}

@Test func oversizedClusteringUsesBoundedOverlappingBatchRanges() {
    let ranges = SpectralClustering.batchRanges(count: 16_384)
    #expect(ranges.count == 5)
    #expect(ranges.allSatisfy { $0.count <= SpectralClustering.denseSpectralMaxChunks })
    #expect(ranges[0] == 0..<4_096)
    #expect(ranges[1] == 3_840..<7_936)
    #expect(ranges[4] == 15_360..<16_384)
}

@Test func denseSpectralLimitBatchesAtHistoric8192Boundary() {
    // Regression: 8192 used to enter the dense route and allocate three
    // 256 MiB matrices. It must now be split even at the exact old boundary.
    #expect(SpectralClustering.boundedDenseBatchLimit(8_192) == 4_096)
    let ranges = SpectralClustering.batchRanges(
        count: SpectralClustering.spectralClusterMaxChunks,
        batchSize: SpectralClustering.spectralClusterMaxChunks
    )
    #expect(ranges.count > 1)
    #expect(ranges.allSatisfy { $0.count <= SpectralClustering.denseSpectralMaxChunks })
}

@Test func oversizedClusteringAlignsLabelsAcrossSmallTestBatches() {
    var speakerA = [Float](repeating: 0, count: 192)
    speakerA[0] = 1
    var speakerB = [Float](repeating: 0, count: 192)
    speakerB[1] = 1
    var embeddings: [Float] = []
    for index in 0..<10 {
        embeddings += index.isMultiple(of: 2) ? speakerA : speakerB
    }

    let clustering = SpectralClustering(minNumSpks: 1, maxNumSpks: 2, batchLimit: 4)
    let labels = clustering.cluster(embeddings: embeddings, count: 10)

    #expect(labels.count == 10)
    #expect(labels[0] == labels[2])
    #expect(labels[1] == labels[3])
    #expect(labels[0] != labels[1])
}

@Test func clusteringDimensionMismatch() {
    let c = SpectralClustering(minNumSpks: 1)
    let labels = c.cluster(embeddings: [Float](repeating: 0, count: 100), count: 10)
    #expect(labels.isEmpty, "invalid input must fail closed instead of manufacturing labels")
}

@Test func directKMeansRejectsInvalidShapeAndClusterCount() {
    let clustering = SpectralClustering(minNumSpks: 1)
    let embeddings = [Float](repeating: 1, count: 2 * 192)

    #expect(clustering.directKMeans(embeddings: embeddings, count: 0, k: 1).isEmpty)
    #expect(clustering.directKMeans(embeddings: embeddings, count: 2, k: 0).isEmpty)
    #expect(clustering.directKMeans(embeddings: embeddings, count: 2, k: 3).isEmpty)
    #expect(clustering.directKMeans(embeddings: Array(embeddings.dropLast()), count: 2, k: 1).isEmpty)
}

@Test func directKMeansRejectsNonFiniteInput() {
    let clustering = SpectralClustering(minNumSpks: 1)
    var embeddings = [Float](repeating: 1, count: 2 * 192)
    embeddings[10] = .infinity

    #expect(clustering.directKMeans(embeddings: embeddings, count: 2, k: 1).isEmpty)
}

@Test func clusteringNonFiniteEmbeddingFailsClosed() {
    let c = SpectralClustering(minNumSpks: 1)
    var embeddings = [Float](repeating: 1, count: 2 * 192)
    embeddings[3] = .nan
    let labels = c.cluster(embeddings: embeddings, count: 2)
    #expect(labels.isEmpty, "non-finite input must not enter K-Means fallback")
}

@Test func clusteringZeroNormEmbeddingFailsClosed() {
    let c = SpectralClustering(minNumSpks: 1)
    let labels = c.cluster(embeddings: [Float](repeating: 0, count: 2 * 192), count: 2)
    #expect(labels.isEmpty, "zero-norm input must not become a synthetic speaker")
}

@Test func clusteringTwoDistinctSpeakers() {
    // 6 个 chunk，3+3 模式，A = unit_e_0 (1, 0, 0...), B = unit_e_1 (0, 1, 0...)
    // 用 192 维 one-hot 编码，绝对线性可分
    var a: [Float] = Array(repeating: 0, count: 192)
    a[0] = 1
    var b: [Float] = Array(repeating: 0, count: 192)
    b[1] = 1
    let emb = a + a + a + b + b + b
    let c = SpectralClustering(minNumSpks: 1)
    let labels = c.cluster(embeddings: emb, count: 6)
    #expect(labels.count == 6)
    // 前 3 个应该同类，后 3 个应该同类
    let firstClass = labels[0]
    let secondClass = labels[3]
    #expect(labels[0] == firstClass)
    #expect(labels[1] == firstClass)
    #expect(labels[2] == firstClass)
    #expect(labels[3] == secondClass)
    #expect(labels[4] == secondClass)
    #expect(labels[5] == secondClass)
    #expect(firstClass != secondClass, "first 3 vs last 3 should be different speakers")
}

@Test func forceKIsClampedToAvailableSamplesAndEigenvectors() {
    var a = [Float](repeating: 0, count: 192)
    a[0] = 1
    var b = [Float](repeating: 0, count: 192)
    b[1] = 1
    let embeddings = a + a + a + b + b + b

    let labels = SpectralClustering(minNumSpks: 1, maxNumSpks: 15)
        .cluster(embeddings: embeddings, count: 6, forceK: 100)

    #expect(labels.count == 6)
}
