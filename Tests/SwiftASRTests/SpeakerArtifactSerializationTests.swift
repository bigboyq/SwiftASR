import Foundation
import Testing
@testable import SwiftASR

@Test func nonFiniteSpeakerScoresAreRemovedAtPersistenceBoundary() {
    let scores: [Int: Float] = [
        0: 0.82,
        1: -.infinity,
        2: .nan,
        3: .infinity,
        4: 0.41,
    ]

    let sanitized = SpeakerDiagnosticsArtifact.finiteScores(scores)
    #expect(sanitized == [0: 0.82, 4: 0.41])
    #expect(sanitized.values.allSatisfy { $0.isFinite })
    #expect(throws: Never.self) {
        _ = try JSONEncoder().encode(sanitized)
    }
}
