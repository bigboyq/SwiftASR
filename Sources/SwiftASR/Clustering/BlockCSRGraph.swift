import Accelerate
import Foundation

/// The directed P-pruned affinity graph in compressed sparse row form.
/// Entries are sorted by column within each row so later native sparse
/// kernels can consume a stable, reproducible layout.
struct BlockCSRGraph: Sendable {
    let count: Int
    let retainedCount: Int
    let rowOffsets: [Int]
    let columns: [Int]
    let values: [Float]

    /// Conservative memory owned by the completed graph plus one B×N Float32
    /// affinity block. The caller's normalized embedding input is excluded,
    /// because it exists before graph construction on both routes.
    static func estimatedPeakBytes(count: Int, retainedCount: Int, blockRows: Int) -> Int {
        guard count > 0, retainedCount > 0, blockRows > 0 else { return 0 }
        let edges = count * min(count, retainedCount)
        let affinityBlock = min(count, blockRows) * count * MemoryLayout<Float>.stride
        let csr = edges * (MemoryLayout<Int>.stride + MemoryLayout<Float>.stride)
        let rowOffsets = (count + 1) * MemoryLayout<Int>.stride
        return affinityBlock + csr + rowOffsets
    }
}

/// Builds the exact directed top-P graph without retaining the old N×N
/// affinity matrix. Each block performs one Accelerate SGEMM, then independent
/// rows are selected on at most the performance-core count. Never run blocks
/// concurrently: SGEMM already owns its internal CPU parallelism.
enum BlockCSRGraphBuilder {
    static let defaultBlockRows = 256

    static func build(
        normalizedEmbeddings: [Float],
        count: Int,
        dimension: Int,
        retainedCount: Int,
        blockRows: Int = defaultBlockRows,
        workerCount requestedWorkerCount: Int? = nil
    ) -> BlockCSRGraph? {
        guard count > 0,
              dimension > 0,
              normalizedEmbeddings.count == count * dimension,
              retainedCount > 0 else {
            return nil
        }

        let keep = min(count, retainedCount)
        let safeBlockRows = min(count, max(1, blockRows))
        let edgeCount = count * keep
        var columns = [Int](repeating: 0, count: edgeCount)
        var values = [Float](repeating: 0, count: edgeCount)
        let rowOffsets = (0...count).map { $0 * keep }
        // `workerCount` is the *outer* row-block concurrency used to slice
        // the affinity matrix into `selectTopP` chunks. The inner SGEMM
        // already owns its own Accelerate-managed thread pool, so the outer
        // budget is intentionally separate from that. `activeProcessorCount`
        // (all logical cores) gives the outer DispatchQueue.concurrentPerform
        // a wider work surface than perf-only would; the only consumer is
        // top-P selection, which is latency-tolerant and CPU-light per row.
        //
        // This file lives in the `SparseClusteringExperiments` target
        // (excluded from the main app), so it cannot import the production
        // `ComputeConcurrency.performanceCoreCount` helper from
        // `Sources/SwiftASR/Services/ComputeConcurrency.swift` — the helper
        // belongs to a different target. Routing through `ProcessInfo` keeps
        // the experiment self-contained; bit-exact parity with the
        // production sparse operator (when it lands) is the only contract.
        let workerCount = min(
            safeBlockRows,
            max(1, requestedWorkerCount ?? ProcessInfo.processInfo.activeProcessorCount)
        )

        normalizedEmbeddings.withUnsafeBufferPointer { embeddingsBuffer in
            guard let embeddingsBase = embeddingsBuffer.baseAddress else { return }
            for startRow in stride(from: 0, to: count, by: safeBlockRows) {
                let rows = min(safeBlockRows, count - startRow)
                var affinityBlock = [Float](repeating: 0, count: rows * count)
                affinityBlock.withUnsafeMutableBufferPointer { affinityBuffer in
                    cblas_sgemm(
                        CblasRowMajor, CblasNoTrans, CblasTrans,
                        Int32(rows), Int32(count), Int32(dimension),
                        1.0,
                        embeddingsBase.advanced(by: startRow * dimension), Int32(dimension),
                        embeddingsBase, Int32(dimension),
                        0.0,
                        affinityBuffer.baseAddress!, Int32(count)
                    )
                }

                let selected = selectTopP(
                    affinity: affinityBlock,
                    rowCount: rows,
                    rowWidth: count,
                    keep: keep,
                    workerCount: min(rows, workerCount)
                )
                for localRow in 0..<rows {
                    let selectedStart = localRow * keep
                    let outputStart = (startRow + localRow) * keep
                    // Heap order is implementation detail. CSR column order
                    // is fixed so the future sparse operator is deterministic.
                    let sortedColumns = selected[selectedStart..<(selectedStart + keep)].sorted()
                    for offset in 0..<keep {
                        let column = sortedColumns[sortedColumns.startIndex + offset]
                        columns[outputStart + offset] = column
                        values[outputStart + offset] = affinityBlock[localRow * count + column]
                    }
                }
            }
        }

        return BlockCSRGraph(
            count: count,
            retainedCount: keep,
            rowOffsets: rowOffsets,
            columns: columns,
            values: values
        )
    }

    private static func selectTopP(
        affinity: [Float],
        rowCount: Int,
        rowWidth: Int,
        keep: Int,
        workerCount: Int
    ) -> [Int] {
        let store = SelectionStore(workerCount: workerCount)
        DispatchQueue.concurrentPerform(iterations: workerCount) { worker in
            let startRow = rowCount * worker / workerCount
            let endRow = rowCount * (worker + 1) / workerCount
            var local: [Int] = []
            local.reserveCapacity((endRow - startRow) * keep)
            for row in startRow..<endRow {
                local.append(contentsOf: topKIndices(
                    values: affinity,
                    offset: row * rowWidth,
                    count: rowWidth,
                    keep: keep
                ))
            }
            store.set(local, for: worker)
        }
        return (0..<workerCount).flatMap { store.selection(for: $0) }
    }

    /// Kept local to the experiment target: production spectral clustering
    /// owns its own optimized neighbour-selection implementation.
    private static func topKIndices(
        values: [Float], offset: Int, count: Int, keep: Int
    ) -> [Int] {
        guard count > 0, keep > 0 else { return [] }
        let selectedCount = min(keep, count)
        return (0..<count)
            .sorted { lhs, rhs in
                let left = values[offset + lhs]
                let right = values[offset + rhs]
                return left == right ? lhs < rhs : left > right
            }
            .prefix(selectedCount)
            .map { $0 }
    }
}

private final class SelectionStore: @unchecked Sendable {
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
