import Combine
import Foundation

/// Immutable value snapshot used by the background match-index builder.
struct SpeakerMatchProfileSnapshot: Equatable, Sendable {
    let profileId: String
    let fingerprintId: String
    let personId: String?
    let personName: String?
    let embedding: [Float]

    var isCandidate: Bool { personId != nil }
}

private struct SpeakerMatchScore: Equatable, Sendable {
    let candidateProfileId: String
    let score: Float
}

private struct SpeakerMatchIndexData: Sendable {
    var profiles: [String: SpeakerMatchProfileSnapshot] = [:]
    var scoresByTarget: [String: [SpeakerMatchScore]] = [:]
}

/// Process-wide in-memory index for speaker reference matching.
///
/// The index is deliberately not a SwiftData model: scores are derived from
/// embeddings and can be rebuilt whenever the profile catalog changes. The
/// first build runs off the main actor. Later changes update only affected
/// target rows and candidate columns; person rename/bind changes reuse the
/// cosine scores and only change aggregation metadata.
@MainActor
final class SpeakerMatchIndex: ObservableObject {
    static let shared = SpeakerMatchIndex()

    @Published private(set) var generation: Int = 0
    @Published private(set) var isUpdating = false

    private var data = SpeakerMatchIndexData()
    private var pendingProfiles: [String: SpeakerMatchProfileSnapshot]?
    private var updateToken: UInt64 = 0
    private var updateTask: Task<Void, Never>?

    init() {}

    deinit {
        updateTask?.cancel()
    }

    /// Refreshes the catalog snapshot. Equal snapshots are a no-op, so views
    /// may safely call this whenever their @Query projection is rendered.
    func update(profiles: [SpeakerProfile]) {
        let snapshots: [String: SpeakerMatchProfileSnapshot] = Dictionary(
            uniqueKeysWithValues: profiles.map { profile in
                (profile.id, SpeakerMatchProfileSnapshot(
                profileId: profile.id,
                fingerprintId: profile.fingerprintId,
                personId: profile.person?.id,
                personName: profile.person?.name,
                embedding: profile.embedding ?? []
                ))
            }
        )
        guard snapshots != data.profiles, snapshots != pendingProfiles else { return }

        updateTask?.cancel()
        updateToken &+= 1
        let token = updateToken
        let previous = data
        pendingProfiles = snapshots
        isUpdating = true

        updateTask = Task { [weak self] in
            let next = await Task.detached(priority: .utility) {
                Self.reconcile(previous: previous, profiles: snapshots)
            }.value
            guard !Task.isCancelled, let self, self.updateToken == token else { return }
            self.data = next
            self.pendingProfiles = nil
            self.isUpdating = false
            self.generation &+= 1
        }
    }

    /// Updates the index from a background startup snapshot without passing
    /// SwiftData model objects across actor/context boundaries.
    func update(snapshots: [SpeakerMatchProfileSnapshot]) {
        let next = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.profileId, $0) })
        guard next != data.profiles, next != pendingProfiles else { return }

        updateTask?.cancel()
        updateToken &+= 1
        let token = updateToken
        let previous = data
        pendingProfiles = next
        isUpdating = true

        updateTask = Task { [weak self] in
            let reconciled = await Task.detached(priority: .utility) {
                Self.reconcile(previous: previous, profiles: next)
            }.value
            guard !Task.isCancelled, let self, self.updateToken == token else { return }
            self.data = reconciled
            self.pendingProfiles = nil
            self.isUpdating = false
            self.generation &+= 1
        }
    }

    /// Returns cached TOP-N person matches for one profile. An empty result
    /// while `isUpdating` is true simply means the initial index is warming;
    /// callers can fall back to the existing direct matcher if needed.
    func matches(
        for profile: SpeakerProfile,
        limit: Int,
        excludingFingerprintId: String? = nil
    ) -> [SpeakerMatcher.PersonMatch] {
        guard let row = data.scoresByTarget[profile.id] else { return [] }
        let scored = row.compactMap { score -> SpeakerMatcher.FingerprintMatch? in
            guard let candidate = data.profiles[score.candidateProfileId],
                  let personId = candidate.personId,
                  let personName = candidate.personName else { return nil }
            return SpeakerMatcher.FingerprintMatch(
                profileId: candidate.profileId,
                fingerprintId: candidate.fingerprintId,
                personId: personId,
                personName: personName,
                score: score.score
            )
        }
        return SpeakerMatcher.aggregatePersonMatches(
            scored,
            limit: limit,
            excludingFingerprintId: excludingFingerprintId
        )
    }

    func hasCachedRow(for profileId: String) -> Bool {
        data.scoresByTarget[profileId] != nil
    }

    // MARK: - Background incremental reconciliation

    private nonisolated static func reconcile(
        previous: SpeakerMatchIndexData,
        profiles: [String: SpeakerMatchProfileSnapshot]
    ) -> SpeakerMatchIndexData {
        guard !previous.profiles.isEmpty else {
            return SpeakerMatchIndexData(
                profiles: profiles,
                scoresByTarget: fullRows(profiles: profiles)
            )
        }

        let oldProfiles = previous.profiles
        let oldCandidateIDs = Set(oldProfiles.values.filter(\.isCandidate).map(\.profileId))
        let newCandidates = profiles.values.filter(\.isCandidate)
        let newCandidateIDs = Set(newCandidates.map(\.profileId))
        let allProfileIDs = Set(profiles.keys)

        let candidateMembershipChanged = Set(
            Set(oldProfiles.keys).union(profiles.keys).filter { id in
                oldProfiles[id]?.isCandidate != profiles[id]?.isCandidate
            }
        )
        let changedEmbeddings = Set<String>(
            profiles.compactMap { id, profile in
                guard let old = oldProfiles[id], old.embedding != profile.embedding else { return nil }
                return id
            }
        )
        let changedCandidateIDs = candidateMembershipChanged.union(
            changedEmbeddings.filter { oldCandidateIDs.contains($0) || newCandidateIDs.contains($0) }
        )

        var rows = previous.scoresByTarget
        rows = rows.filter { allProfileIDs.contains($0.key) }

        for profileID in allProfileIDs {
            guard let target = profiles[profileID] else { continue }
            let targetNeedsFullRow = oldProfiles[profileID] == nil
                || oldProfiles[profileID]?.embedding != target.embedding
                || rows[profileID] == nil

            if targetNeedsFullRow {
                rows[profileID] = scoreRow(target: target, candidates: newCandidates)
                continue
            }

            var row = rows[profileID] ?? []
            row.removeAll {
                !newCandidateIDs.contains($0.candidateProfileId)
                    || changedCandidateIDs.contains($0.candidateProfileId)
            }
            for candidate in newCandidates where changedCandidateIDs.contains(candidate.profileId) {
                if let score = cosine(target.embedding, candidate.embedding) {
                    row.append(SpeakerMatchScore(candidateProfileId: candidate.profileId, score: score))
                }
            }
            rows[profileID] = row
        }

        return SpeakerMatchIndexData(profiles: profiles, scoresByTarget: rows)
    }

    private nonisolated static func fullRows(
        profiles: [String: SpeakerMatchProfileSnapshot]
    ) -> [String: [SpeakerMatchScore]] {
        let candidates = profiles.values.filter(\.isCandidate)
        return Dictionary(uniqueKeysWithValues: profiles.values.map { target in
            (target.profileId, scoreRow(target: target, candidates: candidates))
        })
    }

    private nonisolated static func scoreRow(
        target: SpeakerMatchProfileSnapshot,
        candidates: [SpeakerMatchProfileSnapshot]
    ) -> [SpeakerMatchScore] {
        candidates.compactMap { candidate in
            guard let score = cosine(target.embedding, candidate.embedding) else { return nil }
            return SpeakerMatchScore(candidateProfileId: candidate.profileId, score: score)
        }
    }

    private nonisolated static func cosine(_ lhs: [Float], _ rhs: [Float]) -> Float? {
        guard !lhs.isEmpty, lhs.count == rhs.count else { return nil }
        let score = SpeakerFingerprint.cosine(lhs, rhs)
        return score.isFinite ? score : nil
    }
}
