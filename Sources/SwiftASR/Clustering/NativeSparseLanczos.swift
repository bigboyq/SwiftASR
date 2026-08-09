import Accelerate
import Foundation

/// Exact sparse representation of the dense route's L = D - 0.5(A + Aᵀ).
/// Pair weights are combined before taking abs for degree, preserving the
/// existing dense Laplacian semantics even if an affinity edge is negative.
final class NativeSparseLaplacian: @unchecked Sendable {
    let count: Int
    let maxDegree: Float
    let matrix: AccelerateSparseMatrix

    init?(graph: BlockCSRGraph) {
        count = graph.count
        var pairWeights: [UInt64: Float] = [:]
        pairWeights.reserveCapacity(graph.columns.count)
        for row in 0..<graph.count {
            for edge in graph.rowOffsets[row]..<graph.rowOffsets[row + 1] {
                let column = graph.columns[edge]
                guard column != row else { continue }
                let low = min(row, column)
                let high = max(row, column)
                let key = (UInt64(low) << 32) | UInt64(high)
                pairWeights[key, default: 0] += 0.5 * graph.values[edge]
            }
        }

        var degree = [Float](repeating: 0, count: graph.count)
        let keys = pairWeights.keys.sorted()
        var rows = [Int32]()
        var columns = [Int32]()
        var values = [Float]()
        rows.reserveCapacity(keys.count * 2 + graph.count)
        columns.reserveCapacity(keys.count * 2 + graph.count)
        values.reserveCapacity(keys.count * 2 + graph.count)
        for key in keys {
            guard let weight = pairWeights[key], weight != 0 else { continue }
            let row = Int(key >> 32)
            let column = Int(key & 0xffff_ffff)
            degree[row] += abs(weight)
            degree[column] += abs(weight)
            rows.append(Int32(row)); columns.append(Int32(column)); values.append(-weight)
            rows.append(Int32(column)); columns.append(Int32(row)); values.append(-weight)
        }
        for row in 0..<graph.count {
            rows.append(Int32(row)); columns.append(Int32(row)); values.append(degree[row])
        }
        guard let matrix = AccelerateSparseMatrix(
            count: graph.count, rows: rows, columns: columns, values: values
        ) else {
            return nil
        }
        maxDegree = degree.max() ?? 0
        self.matrix = matrix
    }

    func multiply(_ input: [Float], into output: inout [Float]) -> Bool {
        matrix.multiply(input, into: &output)
    }
}

struct NativeSparseEigenpairs {
    let values: [Float]
    /// Column-major [N × K], matching the dense LAPACK route.
    let vectors: [Float]
    let residuals: [Float]
    let maxResidual: Float
}

/// Full-reorthogonalized Lanczos using Accelerate Sparse SpMV. It remains
/// experimental until frozen-label and end-to-end timing gates pass.
enum NativeSparseLanczos {
    static func smallestEigenpairs(
        laplacian: NativeSparseLaplacian,
        requestedCount: Int,
        krylovDimension requestedKrylovDimension: Int = 96
    ) -> NativeSparseEigenpairs? {
        let n = laplacian.count
        let pairCount = min(n, max(1, requestedCount))
        let krylovDimension = min(n, max(pairCount + 8, requestedKrylovDimension))
        guard n > 1, krylovDimension >= pairCount else { return nil }

        var basis = [Float](repeating: 0, count: n * krylovDimension)
        var alpha: [Float] = []
        var beta: [Float] = []
        alpha.reserveCapacity(krylovDimension)
        beta.reserveCapacity(krylovDimension)

        var vector = (0..<n).map { Float(sin(Double($0 + 1) * 0.618_033_988_75)) }
        normalize(&vector)
        var previous = [Float](repeating: 0, count: n)
        var previousBeta: Float = 0
        var laplacianVector = [Float](repeating: 0, count: n)
        // Gershgorin gives lambda_max <= 2*Dmax. The shifted operator targets
        // the smallest Laplacian eigenpairs as its largest Ritz values.
        let shift = max(1, 2 * laplacian.maxDegree)

        for iteration in 0..<krylovDimension {
            for row in 0..<n {
                basis[iteration * n + row] = vector[row]
            }
            guard laplacian.multiply(vector, into: &laplacianVector) else { return nil }
            var work = [Float](repeating: 0, count: n)
            for row in 0..<n {
                work[row] = shift * vector[row] - laplacianVector[row] - previousBeta * previous[row]
            }
            let diagonal = dot(vector, work)
            alpha.append(diagonal)
            for row in 0..<n {
                work[row] -= diagonal * vector[row]
            }
            for basisColumn in 0...iteration {
                let projection = dotColumn(basis, column: basisColumn, rowCount: n, vector: work)
                if projection != 0 {
                    for row in 0..<n {
                        work[row] -= projection * basis[basisColumn * n + row]
                    }
                }
            }
            let offDiagonal = l2Norm(work)
            guard offDiagonal.isFinite else { return nil }
            if offDiagonal < 1e-6 { break }
            beta.append(offDiagonal)
            previous = vector
            previousBeta = offDiagonal
            for row in 0..<n {
                vector[row] = work[row] / offDiagonal
            }
        }

        let actualDimension = alpha.count
        guard actualDimension >= pairCount else { return nil }
        var tridiagonal = [Float](repeating: 0, count: actualDimension * actualDimension)
        for index in 0..<actualDimension {
            tridiagonal[index * actualDimension + index] = alpha[index]
            if index + 1 < actualDimension {
                tridiagonal[index * actualDimension + index + 1] = beta[index]
                tridiagonal[(index + 1) * actualDimension + index] = beta[index]
            }
        }
        var jobz: CChar = 86
        var uplo: CChar = 85
        var order = Int32(actualDimension)
        var leadingDimension = order
        var eigenvalues = [Float](repeating: 0, count: actualDimension)
        var workspace = [Float](repeating: 0, count: max(1, 3 * actualDimension - 1))
        var workspaceCount = Int32(workspace.count)
        var info = Int32(0)
        ssyev_(
            &jobz, &uplo, &order, &tridiagonal, &leadingDimension,
            &eigenvalues, &workspace, &workspaceCount, &info
        )
        guard info == 0 else { return nil }

        var values = [Float](repeating: 0, count: pairCount)
        var vectors = [Float](repeating: 0, count: n * pairCount)
        for outputColumn in 0..<pairCount {
            let ritzColumn = actualDimension - 1 - outputColumn
            values[outputColumn] = max(0, shift - eigenvalues[ritzColumn])
            for row in 0..<n {
                var combined: Float = 0
                for basisColumn in 0..<actualDimension {
                    combined += basis[basisColumn * n + row]
                        * tridiagonal[ritzColumn * actualDimension + basisColumn]
                }
                vectors[outputColumn * n + row] = combined
            }
        }

        var maxResidual: Float = 0
        var residuals = [Float](repeating: 0, count: pairCount)
        for column in 0..<pairCount {
            let vector = Array(vectors[(column * n)..<((column + 1) * n)])
            guard laplacian.multiply(vector, into: &laplacianVector) else { return nil }
            var residualSquared: Float = 0
            for row in 0..<n {
                let residual = laplacianVector[row] - values[column] * vector[row]
                residualSquared += residual * residual
            }
            let residual = sqrt(residualSquared)
            residuals[column] = residual
            maxResidual = max(maxResidual, residual)
        }
        return maxResidual.isFinite
            ? NativeSparseEigenpairs(
                values: values,
                vectors: vectors,
                residuals: residuals,
                maxResidual: maxResidual
            )
            : nil
    }

    private static func dot(_ lhs: [Float], _ rhs: [Float]) -> Float {
        var result: Float = 0
        vDSP_dotpr(lhs, 1, rhs, 1, &result, vDSP_Length(lhs.count))
        return result
    }

    private static func dotColumn(
        _ matrix: [Float], column: Int, rowCount: Int, vector: [Float]
    ) -> Float {
        var result: Float = 0
        matrix.withUnsafeBufferPointer { matrixBuffer in
            vector.withUnsafeBufferPointer { vectorBuffer in
                vDSP_dotpr(
                    matrixBuffer.baseAddress!.advanced(by: column * rowCount), 1,
                    vectorBuffer.baseAddress!, 1, &result, vDSP_Length(rowCount)
                )
            }
        }
        return result
    }

    private static func l2Norm(_ vector: [Float]) -> Float {
        var sum: Float = 0
        vDSP_svesq(vector, 1, &sum, vDSP_Length(vector.count))
        return sqrt(sum)
    }

    private static func normalize(_ vector: inout [Float]) {
        let norm = l2Norm(vector)
        guard norm > 0 else { return }
        for index in vector.indices { vector[index] /= norm }
    }
}

/// Experimental deflated restart variant. It locks only residual-qualified
/// pairs, then restarts in their orthogonal complement. This is deliberately
/// a convergence probe before implementing a larger thick/block-restart
/// solver; it never participates in the production clustering route.
enum DeflatedRestartLanczos {
    static func smallestEigenpairs(
        laplacian: NativeSparseLaplacian,
        requestedCount: Int,
        krylovDimension: Int = 64,
        maximumRestarts: Int = 4,
        residualTolerance: Float = 5e-3
    ) -> NativeSparseEigenpairs? {
        let n = laplacian.count
        let pairCount = min(n, max(1, requestedCount))
        let basisDimension = min(n, max(8, krylovDimension))
        let shift = max(1, 2 * laplacian.maxDegree)
        var lockedValues: [Float] = []
        var lockedVectors: [Float] = [] // column-major [N × locked.count]
        var residuals: [Float] = []

        for target in 0..<pairCount {
            var seed = deterministicSeed(count: n, salt: target + 1)
            project(&seed, awayFrom: lockedVectors, count: n)
            normalize(&seed)
            var accepted = false

            for _ in 0..<maximumRestarts {
                guard let candidate = cycle(
                    laplacian: laplacian,
                    shift: shift,
                    lockedVectors: lockedVectors,
                    seed: seed,
                    basisDimension: basisDimension
                ) else {
                    return nil
                }
                var vector = candidate.vector
                project(&vector, awayFrom: lockedVectors, count: n)
                normalize(&vector)
                var product = [Float](repeating: 0, count: n)
                guard laplacian.multiply(vector, into: &product) else { return nil }
                var residualSquared: Float = 0
                for row in 0..<n {
                    let residual = product[row] - candidate.value * vector[row]
                    residualSquared += residual * residual
                }
                let residual = sqrt(residualSquared)
                if residual <= residualTolerance {
                    lockedValues.append(candidate.value)
                    lockedVectors.append(contentsOf: vector)
                    residuals.append(residual)
                    accepted = true
                    break
                }
                seed = vector
            }
            guard accepted else { return nil }
        }
        return NativeSparseEigenpairs(
            values: lockedValues,
            vectors: lockedVectors,
            residuals: residuals,
            maxResidual: residuals.max() ?? .infinity
        )
    }

    private static func cycle(
        laplacian: NativeSparseLaplacian,
        shift: Float,
        lockedVectors: [Float],
        seed: [Float],
        basisDimension: Int
    ) -> (value: Float, vector: [Float])? {
        let n = laplacian.count
        var basis = [Float](repeating: 0, count: n * basisDimension)
        var alpha: [Float] = []
        var beta: [Float] = []
        var vector = seed
        var previous = [Float](repeating: 0, count: n)
        var previousBeta: Float = 0
        var laplacianVector = [Float](repeating: 0, count: n)

        for iteration in 0..<basisDimension {
            for row in 0..<n { basis[iteration * n + row] = vector[row] }
            guard laplacian.multiply(vector, into: &laplacianVector) else { return nil }
            var work = [Float](repeating: 0, count: n)
            for row in 0..<n {
                work[row] = shift * vector[row] - laplacianVector[row] - previousBeta * previous[row]
            }
            project(&work, awayFrom: lockedVectors, count: n)
            let diagonal = dot(vector, work)
            alpha.append(diagonal)
            for row in 0..<n { work[row] -= diagonal * vector[row] }
            for column in 0...iteration {
                let projection = dotColumn(basis, column: column, rowCount: n, vector: work)
                if projection != 0 {
                    for row in 0..<n { work[row] -= projection * basis[column * n + row] }
                }
            }
            let offDiagonal = l2Norm(work)
            if !offDiagonal.isFinite || offDiagonal < 1e-6 { break }
            beta.append(offDiagonal)
            previous = vector
            previousBeta = offDiagonal
            for row in 0..<n { vector[row] = work[row] / offDiagonal }
        }

        let dimension = alpha.count
        guard dimension >= 2 else { return nil }
        var tridiagonal = [Float](repeating: 0, count: dimension * dimension)
        for index in 0..<dimension {
            tridiagonal[index * dimension + index] = alpha[index]
            if index + 1 < dimension {
                tridiagonal[index * dimension + index + 1] = beta[index]
                tridiagonal[(index + 1) * dimension + index] = beta[index]
            }
        }
        var jobz: CChar = 86
        var uplo: CChar = 85
        var order = Int32(dimension)
        var leadingDimension = order
        var eigenvalues = [Float](repeating: 0, count: dimension)
        var workspace = [Float](repeating: 0, count: max(1, 3 * dimension - 1))
        var workspaceCount = Int32(workspace.count)
        var info = Int32(0)
        ssyev_(
            &jobz, &uplo, &order, &tridiagonal, &leadingDimension,
            &eigenvalues, &workspace, &workspaceCount, &info
        )
        guard info == 0 else { return nil }
        let ritzColumn = dimension - 1
        var result = [Float](repeating: 0, count: n)
        for row in 0..<n {
            for column in 0..<dimension {
                result[row] += basis[column * n + row] * tridiagonal[ritzColumn * dimension + column]
            }
        }
        return (max(0, shift - eigenvalues[ritzColumn]), result)
    }

    private static func deterministicSeed(count: Int, salt: Int) -> [Float] {
        (0..<count).map { Float(sin(Double(($0 + 1) * (salt + 3)) * 0.618_033_988_75)) }
    }

    private static func project(_ vector: inout [Float], awayFrom locked: [Float], count: Int) {
        guard !locked.isEmpty else { return }
        let lockedCount = locked.count / count
        for column in 0..<lockedCount {
            let projection = dotColumn(locked, column: column, rowCount: count, vector: vector)
            if projection != 0 {
                for row in 0..<count { vector[row] -= projection * locked[column * count + row] }
            }
        }
    }

    private static func dot(_ lhs: [Float], _ rhs: [Float]) -> Float {
        var result: Float = 0
        vDSP_dotpr(lhs, 1, rhs, 1, &result, vDSP_Length(lhs.count))
        return result
    }

    private static func dotColumn(_ matrix: [Float], column: Int, rowCount: Int, vector: [Float]) -> Float {
        var result: Float = 0
        matrix.withUnsafeBufferPointer { matrixBuffer in
            vector.withUnsafeBufferPointer { vectorBuffer in
                vDSP_dotpr(matrixBuffer.baseAddress!.advanced(by: column * rowCount), 1,
                           vectorBuffer.baseAddress!, 1, &result, vDSP_Length(rowCount))
            }
        }
        return result
    }

    private static func l2Norm(_ vector: [Float]) -> Float {
        var sum: Float = 0
        vDSP_svesq(vector, 1, &sum, vDSP_Length(vector.count))
        return sqrt(sum)
    }

    private static func normalize(_ vector: inout [Float]) {
        let norm = l2Norm(vector)
        guard norm > 1e-10 else { return }
        for index in vector.indices { vector[index] /= norm }
    }
}
