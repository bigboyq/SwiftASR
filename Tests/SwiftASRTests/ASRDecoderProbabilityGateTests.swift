import Foundation
import Testing
@testable import SwiftASR

@Test func acceleratedASRProbabilityGateMatchesScalarReference() {
    let rows: [[Float]] = [
        [0, 0],
        [0, -4],
        (0..<17).map { Float($0 % 5) - 2 },
        (0..<8_404).map { Float(sin(Double($0) * 0.17)) * 3 }
    ]

    for row in rows {
        let maxLogit = row.max()!
        let expected = scalarProbabilityGate(row, maxLogit: maxLogit, minimumProbability: 0.2)
        var scratch = [Float](repeating: 0, count: row.count)
        let actual = ASRDecoder.clearsProbabilityThreshold(
            logits: row,
            offset: 0,
            vocabularySize: row.count,
            maxLogit: maxLogit,
            minimumProbability: 0.2,
            scratch: &scratch
        )
        #expect(actual == expected)
    }
}

private func scalarProbabilityGate(
    _ logits: [Float],
    maxLogit: Float,
    minimumProbability: Float
) -> Bool {
    let denominator = logits.reduce(Float(0)) { partial, logit in
        partial + exp(logit - maxLogit)
    }
    return denominator.isFinite && denominator > 0 && (1 / denominator) >= minimumProbability
}
