import Accelerate
import Foundation

/// Stateless graph preparation and oversized-batch geometry used by
/// `SpectralClustering`. Keeping these allocation-heavy primitives separate
/// makes the clustering facade responsible only for orchestration.
enum SpectralGraphAlgorithms {
    static func normalize(
        embeddings: [Float],
        count: Int,
        dimension: Int
    ) -> [Float]? {
        var normalized = [Float](repeating: 0, count: count * dimension)
        var badNorm = false
        embeddings.withUnsafeBufferPointer { source in
            normalized.withUnsafeMutableBufferPointer { destination in
                guard let sourceBase = source.baseAddress,
                      let destinationBase = destination.baseAddress else { return }
                let dimensionLength = vDSP_Length(dimension)
                for row in 0..<count {
                    let offset = row * dimension
                    let rowPointer = sourceBase.advanced(by: offset)
                    var sumSquared: Float = 0
                    vDSP_svesq(rowPointer, 1, &sumSquared, dimensionLength)
                    let norm = sqrt(sumSquared)
                    guard norm.isFinite, norm > 1e-10 else {
                        badNorm = true
                        return
                    }
                    var divisor = norm
                    vDSP_vsdiv(
                        rowPointer,
                        1,
                        &divisor,
                        destinationBase.advanced(by: offset),
                        1,
                        dimensionLength
                    )
                }
            }
        }
        return badNorm ? nil : normalized
    }

    static func batchRanges(
        count: Int,
        batchSize: Int,
        overlap: Int,
        maximumBatchSize: Int
    ) -> [Range<Int>] {
        guard count > 0, batchSize > 0 else { return [] }
        let denseBatchSize = min(max(2, batchSize), maximumBatchSize)
        let safeOverlap = min(max(0, overlap), max(0, denseBatchSize - 1))
        var ranges: [Range<Int>] = []
        var start = 0
        while start < count {
            let end = min(count, start + denseBatchSize)
            ranges.append(start..<end)
            guard end < count else { break }
            let nextStart = end - safeOverlap
            start = nextStart > start ? nextStart : end
        }
        return ranges
    }

    static func centroid(
        embeddings: [Float],
        indexes: [Int],
        dimension: Int
    ) -> [Float] {
        var result = [Float](repeating: 0, count: dimension)
        for index in indexes {
            let offset = index * dimension
            for column in 0..<dimension {
                result[column] += embeddings[offset + column]
            }
        }
        let divisor = Float(max(1, indexes.count))
        for column in 0..<dimension {
            result[column] /= divisor
        }
        return result
    }

    static func cosineSimilarity(_ lhs: [Float], _ rhs: [Float]) -> Float {
        var dot: Float = 0
        var lhsNorm: Float = 0
        var rhsNorm: Float = 0
        for index in 0..<min(lhs.count, rhs.count) {
            dot += lhs[index] * rhs[index]
            lhsNorm += lhs[index] * lhs[index]
            rhsNorm += rhs[index] * rhs[index]
        }
        let denominator = sqrt(lhsNorm) * sqrt(rhsNorm)
        return denominator > 1e-10 ? dot / denominator : 0
    }

    static func prunedAffinityMatrix(
        _ affinityMatrix: [Float],
        count: Int,
        retainedCount: Int,
        workerCount requestedWorkerCount: Int?
    ) -> [Float] {
        guard count > 0,
              affinityMatrix.count == count * count,
              retainedCount > 0 else {
            return [Float](repeating: 0, count: max(0, count * count))
        }

        let keep = min(count, retainedCount)
        let workerCount = min(
            count,
            max(1, requestedWorkerCount ?? ComputeConcurrency.performanceCoreCount)
        )
        let selections = TopKSelectionStore(workerCount: workerCount)

        DispatchQueue.concurrentPerform(iterations: workerCount) { worker in
            let startRow = count * worker / workerCount
            let endRow = count * (worker + 1) / workerCount
            var local: [Int] = []
            local.reserveCapacity((endRow - startRow) * keep)
            for row in startRow..<endRow {
                local.append(contentsOf: topKIndices(
                    values: affinityMatrix,
                    offset: row * count,
                    count: count,
                    keep: keep
                ))
            }
            selections.set(local, for: worker)
        }

        var pruned = [Float](repeating: 0, count: count * count)
        for worker in 0..<workerCount {
            let startRow = count * worker / workerCount
            let endRow = count * (worker + 1) / workerCount
            let local = selections.selection(for: worker)
            var cursor = 0
            for row in startRow..<endRow {
                let rowOffset = row * count
                for _ in 0..<keep {
                    let index = local[cursor]
                    cursor += 1
                    pruned[rowOffset + index] = affinityMatrix[rowOffset + index]
                }
            }
            assert(cursor == local.count)
        }
        return pruned
    }

    static func topKIndices(
        values: [Float],
        offset: Int,
        count: Int,
        keep: Int
    ) -> [Int] {
        guard keep > 0 else { return [] }
        guard keep < count else { return Array(0..<count) }
        var heap: [(value: Float, index: Int)] = []
        heap.reserveCapacity(keep)
        for index in 0..<count {
            let value = values[offset + index]
            if heap.count < keep {
                heap.append((value, index))
                siftUpMinHeap(&heap, from: heap.count - 1)
            } else if value > heap[0].value {
                heap[0] = (value, index)
                siftDownMinHeap(&heap, from: 0)
            }
        }
        return heap.map(\.index)
    }

    private static func siftUpMinHeap(
        _ heap: inout [(value: Float, index: Int)],
        from start: Int
    ) {
        var child = start
        while child > 0 {
            let parent = (child - 1) / 2
            guard heap[child].value < heap[parent].value else { break }
            heap.swapAt(child, parent)
            child = parent
        }
    }

    private static func siftDownMinHeap(
        _ heap: inout [(value: Float, index: Int)],
        from start: Int
    ) {
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

    private final class TopKSelectionStore: @unchecked Sendable {
        private let lock = NSLock()
        private var selections: [[Int]]

        init(workerCount: Int) {
            selections = Array(repeating: [], count: workerCount)
        }

        func set(_ selection: [Int], for worker: Int) {
            lock.lock()
            selections[worker] = selection
            lock.unlock()
        }

        func selection(for worker: Int) -> [Int] {
            lock.lock()
            defer { lock.unlock() }
            return selections[worker]
        }
    }
}
