import Foundation
import SparseAccelerateBridge

/// Owns Accelerate Sparse's native CSC representation. The input is our
/// stable CSR graph; coordinate conversion happens once when the graph is
/// built, while every later SpMV stays in Accelerate's native implementation.
final class AccelerateSparseMatrix: @unchecked Sendable {
    private var handle: OpaquePointer?
    let count: Int

    init?(count: Int, rows: [Int32], columns: [Int32], values: [Float]) {
        self.count = count
        guard count > 0,
              count <= Int(Int32.max),
              rows.count == columns.count,
              columns.count == values.count,
              !rows.isEmpty else {
            return nil
        }
        handle = rows.withUnsafeBufferPointer { rowBuffer in
            columns.withUnsafeBufferPointer { columnBuffer in
                values.withUnsafeBufferPointer { valueBuffer in
                    swiftasr_sparse_matrix_create(
                        Int32(count),
                        values.count,
                        rowBuffer.baseAddress,
                        columnBuffer.baseAddress,
                        valueBuffer.baseAddress
                    )
                }
            }
        }
        guard handle != nil else { return nil }
    }

    convenience init?(graph: BlockCSRGraph) {
        guard graph.columns.count == graph.values.count,
              graph.columns.count == graph.count * graph.retainedCount else {
            return nil
        }
        var rows = [Int32](repeating: 0, count: graph.columns.count)
        var columns = [Int32](repeating: 0, count: graph.columns.count)
        for row in 0..<graph.count {
            for edge in graph.rowOffsets[row]..<graph.rowOffsets[row + 1] {
                rows[edge] = Int32(row)
                columns[edge] = Int32(graph.columns[edge])
            }
        }
        self.init(count: graph.count, rows: rows, columns: columns, values: graph.values)
    }

    deinit {
        if let handle {
            swiftasr_sparse_matrix_destroy(handle)
        }
    }

    func multiply(_ input: [Float]) -> [Float]? {
        var output = [Float](repeating: 0, count: count)
        return multiply(input, into: &output) ? output : nil
    }

    /// Allocation-free SpMV for iterative eigensolvers. Callers retain their
    /// working vectors across iterations rather than paying Swift array setup
    /// on every Lanczos step.
    func multiply(_ input: [Float], into output: inout [Float]) -> Bool {
        guard input.count == count, output.count == count, let handle else { return false }
        return input.withUnsafeBufferPointer { inputBuffer in
            output.withUnsafeMutableBufferPointer { outputBuffer in
                swiftasr_sparse_matrix_multiply(handle, inputBuffer.baseAddress, outputBuffer.baseAddress)
            }
        }
    }
}
