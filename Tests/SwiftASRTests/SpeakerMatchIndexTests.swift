import Foundation
import Testing
@testable import SwiftASR

@Suite("SpeakerMatchIndex")
@MainActor
struct SpeakerMatchIndexTests {
    private static func embedding(_ x: Float, _ y: Float) -> Data {
        var values = [Float](repeating: 0, count: 192)
        values[0] = x
        values[1] = y
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private static func profile(
        id: String,
        fingerprintId: String,
        embedding: Data,
        person: Person?
    ) -> SpeakerProfile {
        SpeakerProfile(
            id: id,
            fingerprintId: fingerprintId,
            speakerLabel: id,
            embeddingData: embedding,
            person: person
        )
    }

    private func waitUntilReady(
        _ index: SpeakerMatchIndex,
        target: SpeakerProfile,
        timeoutIterations: Int = 100
    ) async throws {
        for _ in 0..<timeoutIterations {
            if !index.isUpdating, index.hasCachedRow(for: target.id) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("SpeakerMatchIndex did not finish warming in time")
    }

    @Test func buildsInBackgroundAndIncrementallyUpdatesCandidateChanges() async throws {
        let index = SpeakerMatchIndex()
        let target = Self.profile(
            id: "target",
            fingerprintId: "fp_target",
            embedding: Self.embedding(1, 0),
            person: nil
        )
        let alice = Person(name: "Alice")
        let bob = Person(name: "Bob")
        let aliceProfile = Self.profile(
            id: "alice-profile",
            fingerprintId: "fp_alice",
            embedding: Self.embedding(0.8, 0.6),
            person: alice
        )

        index.update(profiles: [target, aliceProfile])
        try await waitUntilReady(index, target: target)
        #expect(index.matches(for: target, limit: 5).map(\.personName) == ["Alice"])

        let bobProfile = Self.profile(
            id: "bob-profile",
            fingerprintId: "fp_bob",
            embedding: Self.embedding(0.6, 0.8),
            person: bob
        )
        index.update(profiles: [target, aliceProfile, bobProfile])
        try await waitUntilReady(index, target: target)
        #expect(index.matches(for: target, limit: 5).map(\.personName) == ["Alice", "Bob"])

        aliceProfile.person = nil
        index.update(profiles: [target, aliceProfile, bobProfile])
        try await waitUntilReady(index, target: target)
        #expect(index.matches(for: target, limit: 5).map(\.personName) == ["Bob"])
    }

    @Test func queryExcludesCurrentFingerprintFromCachedAggregation() async throws {
        let index = SpeakerMatchIndex()
        let person = Person(name: "Alice")
        let target = Self.profile(
            id: "bound-target",
            fingerprintId: "fp_target",
            embedding: Self.embedding(1, 0),
            person: person
        )
        let other = Self.profile(
            id: "other-profile",
            fingerprintId: "fp_other",
            embedding: Self.embedding(0.8, 0.6),
            person: person
        )

        index.update(profiles: [target, other])
        try await waitUntilReady(index, target: target)
        let matches = index.matches(
            for: target,
            limit: 5,
            excludingFingerprintId: target.fingerprintId
        )
        #expect(matches.count == 1)
        #expect(matches[0].personName == "Alice")
        #expect(matches[0].score < 1)
    }
}
