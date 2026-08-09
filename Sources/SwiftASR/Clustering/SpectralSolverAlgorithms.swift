import Accelerate
import Foundation

/// LAPACK and K-Means kernels used by spectral clustering. The facade retains
/// its existing internal API and converts this value result at the boundary.
enum SpectralSolverAlgorithms {
    struct EigenDecomposition: Sendable {
        let m: Int
        let info: Int32
        let eigenvalues: [Float]
        let eigenvectors: [Float]
        let lwork: Int32
        let liwork: Int32
    }

    static func runEigenDecomposition(
        laplacian: inout [Float],
        count: Int,
        kEigengapLimit: Int
    ) -> EigenDecomposition {
        var jobz: CChar = 86
        var range: CChar = 73
        var uplo: CChar = 85
        var n = Int32(count)
        var lda = Int32(count)
        var vl: Float = 0
        var vu: Float = 0
        var il = Int32(1)
        var iu = Int32(kEigengapLimit)
        var abstol: Float = 0
        var m = Int32(0)
        var eigenvalues = [Float](repeating: 0, count: kEigengapLimit)
        var eigenvectors = [Float](repeating: 0, count: count * kEigengapLimit)
        var ldz = Int32(count)
        var isuppz = [Int32](repeating: 0, count: 2 * kEigengapLimit)
        var info = Int32(0)

        var workQuery: Float = 0
        var lwork = Int32(-1)
        var iworkQuery: Int32 = 0
        var liwork = Int32(-1)
        var queryInfo = Int32(0)
        ssyevr_(
            &jobz, &range, &uplo, &n, &laplacian, &lda,
            &vl, &vu, &il, &iu, &abstol, &m,
            &eigenvalues, &eigenvectors, &ldz, &isuppz,
            &workQuery, &lwork, &iworkQuery, &liwork, &queryInfo
        )
        if queryInfo != 0 {
            Logger.shared.error(
                "SpectralClustering: ssyevr_ workspace query failed " +
                "info=\(queryInfo), n=\(count), requested=\(kEigengapLimit)"
            )
            return EigenDecomposition(
                m: 0,
                info: queryInfo,
                eigenvalues: [],
                eigenvectors: [],
                lwork: 0,
                liwork: 0
            )
        }

        lwork = max(Int32(1), Int32(ceil(Double(workQuery))))
        liwork = max(Int32(1), iworkQuery)
        var work = [Float](repeating: 0, count: Int(lwork))
        var iwork = [Int32](repeating: 0, count: Int(liwork))
        m = 0
        info = 0

        ssyevr_(
            &jobz, &range, &uplo, &n, &laplacian, &lda,
            &vl, &vu, &il, &iu, &abstol, &m,
            &eigenvalues, &eigenvectors, &ldz, &isuppz,
            &work, &lwork, &iwork, &liwork, &info
        )
        return EigenDecomposition(
            m: Int(m),
            info: info,
            eigenvalues: eigenvalues,
            eigenvectors: eigenvectors,
            lwork: lwork,
            liwork: liwork
        )
    }

    static func runKMeans(
        data: [Float],
        sampleCount: Int,
        clusterCount: Int,
        dimension: Int
    ) -> [Int] {
        guard sampleCount > 0, clusterCount > 0, dimension > 0,
              data.count >= sampleCount * dimension else { return [] }
        var state = initializeKMeans(
            data: data,
            sampleCount: sampleCount,
            clusterCount: clusterCount,
            dimension: dimension
        )
        refineKMeans(
            data: data,
            sampleCount: sampleCount,
            clusterCount: clusterCount,
            dimension: dimension,
            centroids: &state.centroids,
            labels: &state.labels
        )
        return state.labels
    }

    private struct KMeansState {
        var centroids: [Float]
        var labels: [Int]
    }

    private static func initializeKMeans(
        data: [Float],
        sampleCount: Int,
        clusterCount: Int,
        dimension: Int
    ) -> KMeansState {
        var centroids = [Float](repeating: 0, count: clusterCount * dimension)
        let labels = [Int](repeating: 0, count: sampleCount)

        var selectedIndices = [0]
        for column in 0..<dimension {
            centroids[column] = data[column]
        }
        var randomState: UInt64 = 0x9E37_79B9_7F4A_7C15
        func nextUnitRandom() -> Double {
            randomState = randomState &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(randomState >> 11) / Double(UInt64(1) << 53)
        }
        if clusterCount > 1 {
            for centroidIndex in 1..<clusterCount {
                var nearestDistances = [Float](repeating: 0, count: sampleCount)
                var totalDistance: Double = 0
                for sampleIndex in 0..<sampleCount {
                    let sampleOffset = sampleIndex * dimension
                    var nearestDistance = Float.infinity
                    for selectedIndex in selectedIndices {
                        let selectedOffset = selectedIndex * dimension
                        var distance: Float = 0
                        for column in 0..<dimension {
                            let difference = data[sampleOffset + column] - data[selectedOffset + column]
                            distance += difference * difference
                        }
                        nearestDistance = min(nearestDistance, distance)
                    }
                    nearestDistances[sampleIndex] = selectedIndices.contains(sampleIndex) ? 0 : nearestDistance
                    totalDistance += Double(nearestDistances[sampleIndex])
                }

                let bestSample: Int
                if totalDistance > 0 {
                    let threshold = nextUnitRandom() * totalDistance
                    var cumulative = 0.0
                    var selected = sampleCount - 1
                    for sampleIndex in 0..<sampleCount {
                        cumulative += Double(nearestDistances[sampleIndex])
                        if cumulative >= threshold {
                            selected = sampleIndex
                            break
                        }
                    }
                    bestSample = selected
                } else {
                    bestSample = (0..<sampleCount).first {
                        !selectedIndices.contains($0)
                    } ?? 0
                }
                selectedIndices.append(bestSample)
                let sourceOffset = bestSample * dimension
                let destinationOffset = centroidIndex * dimension
                for column in 0..<dimension {
                    centroids[destinationOffset + column] = data[sourceOffset + column]
                }
            }
        }

        return KMeansState(centroids: centroids, labels: labels)
    }

    private static func refineKMeans(
        data: [Float],
        sampleCount: Int,
        clusterCount: Int,
        dimension: Int,
        centroids: inout [Float],
        labels: inout [Int]
    ) {
        var changed = true
        var iterations = 0
        while changed && iterations < 30 {
            changed = false
            iterations += 1

            for sampleIndex in 0..<sampleCount {
                let sampleOffset = sampleIndex * dimension
                var minimumDistance = Float.infinity
                var bestCentroid = 0
                for centroidIndex in 0..<clusterCount {
                    let centroidOffset = centroidIndex * dimension
                    var distance: Float = 0
                    data.withUnsafeBufferPointer { dataBuffer in
                        centroids.withUnsafeBufferPointer { centroidBuffer in
                            guard let dataBase = dataBuffer.baseAddress,
                                  let centroidBase = centroidBuffer.baseAddress else { return }
                            vDSP_distancesq(
                                dataBase.advanced(by: sampleOffset),
                                1,
                                centroidBase.advanced(by: centroidOffset),
                                1,
                                &distance,
                                vDSP_Length(dimension)
                            )
                        }
                    }
                    if distance < minimumDistance {
                        minimumDistance = distance
                        bestCentroid = centroidIndex
                    }
                }
                if labels[sampleIndex] != bestCentroid {
                    labels[sampleIndex] = bestCentroid
                    changed = true
                }
            }

            var counts = [Int](repeating: 0, count: clusterCount)
            var newCentroids = [Float](repeating: 0, count: clusterCount * dimension)
            for sampleIndex in 0..<sampleCount {
                let label = labels[sampleIndex]
                counts[label] += 1
                let sampleOffset = sampleIndex * dimension
                let centroidOffset = label * dimension
                data.withUnsafeBufferPointer { dataBuffer in
                    newCentroids.withUnsafeMutableBufferPointer { centroidBuffer in
                        guard let dataBase = dataBuffer.baseAddress,
                              let centroidBase = centroidBuffer.baseAddress else { return }
                        vDSP_vadd(
                            centroidBase.advanced(by: centroidOffset),
                            1,
                            dataBase.advanced(by: sampleOffset),
                            1,
                            centroidBase.advanced(by: centroidOffset),
                            1,
                            vDSP_Length(dimension)
                        )
                    }
                }
            }

            for centroidIndex in 0..<clusterCount where counts[centroidIndex] > 0 {
                for column in 0..<dimension {
                    centroids[centroidIndex * dimension + column] =
                        newCentroids[centroidIndex * dimension + column]
                        / Float(counts[centroidIndex])
                }
            }
        }
    }
}
