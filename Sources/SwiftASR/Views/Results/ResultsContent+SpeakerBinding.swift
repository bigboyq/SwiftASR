import SwiftData
import SwiftUI

/// Speaker-to-Person binding and suggestion projection for the result
/// workspace. The SwiftUI view owns presentation state; persistence remains in
/// `ResultSpeakerMappingService`, while this extension coordinates user intent.
extension ResultsContent {
    /// ResultPayload only stores SpeakerN → profile. Selecting a Person updates
    /// the referenced profile immediately.
    func selectPerson(label: String, personName: String?) {
        selectPerson(label: label, person: personName.flatMap { name in
            allPersons.first(where: { $0.name == name })
        })
    }

    /// A newly-created Person can be bound directly without waiting for
    /// `@Query` to refresh. The system Speaker sentinel only receives a
    /// user-managed profile after an explicit binding.
    @discardableResult
    private func selectPerson(label: String, person: Person?) -> Bool {
        guard let payload else { return false }
        do {
            guard let updated = try ResultSpeakerMappingService.assign(
                person: person,
                to: label,
                payload: payload,
                activeSegments: activeSegments(payload),
                currentJob: currentJob,
                profiles: loadProfilesForPresentation(),
                jobID: jobId,
                modelContext: modelContext
            ) else { return false }
            persistenceError = nil
            self.payload = updated
        } catch {
            persistenceError = "保存说话人映射失败："
                + UserFacingErrorMapper.message(for: error, context: .speakerMapping)
            Logger.shared.error("保存说话人映射失败：\(error)")
            return false
        }
        refreshSuggestions()
        return true
    }

    /// Create a globally unique Person and bind the active result speaker.
    func createPersonAndSelect(label: String, name: String) {
        do {
            let person = try PersonRepository.create(name: name, in: modelContext)
            if !selectPerson(label: label, person: person) {
                modelContext.delete(person)
                _ = saveModelChanges(action: "回滚新增说话人")
            }
        } catch {
            AlertHelper.showInfo(
                title: "无法新增说话人",
                message: UserFacingErrorMapper.message(for: error, context: .speakerMapping),
                buttonTitle: "好",
                style: .warning
            )
        }
    }

    func refreshSuggestions(profiles suppliedProfiles: [SpeakerProfile]? = nil) {
        guard let payload,
              let identity = viewState.currentIdentity(for: jobId)
        else { return }
        let distinctSpeakers = Set(activeSegments(payload).map(\.speakerLabel))
            .intersection(inScopeLabels)
        let jobProfiles = suppliedProfiles ?? loadProfilesForPresentation()
        viewState.speakerNames = ResultsPresentation.speakerNameMap(
            payload: payload,
            profiles: jobProfiles
        )
        let profileIDs = Set(payload.speakers.compactMap(\.speakerProfileId))
        let sourceProfiles = jobProfiles.filter { profileIDs.contains($0.id) }
        let profilesByID = Dictionary(
            uniqueKeysWithValues: sourceProfiles.map { ($0.id, $0) }
        )
        let profileByLabel = Dictionary(
            uniqueKeysWithValues: payload.speakers.compactMap {
                speaker -> (String, SpeakerProfile)? in
                guard distinctSpeakers.contains(speaker.speakerLabel),
                      let id = speaker.speakerProfileId,
                      let profile = profilesByID[id]
                else { return nil }
                return (speaker.speakerLabel, profile)
            }
        )
        let candidates = jobProfiles.filter {
            $0.person != nil
                && $0.fingerprintId != SpeakerDiarizationPipeline.sentinelFingerprint
        }
        let newSuggestions = computeSuggestions(
            labels: distinctSpeakers,
            profilesByLabel: profileByLabel,
            candidates: candidates
        )
        ResultsSpeakerSuggestionPublisher.publish(
            newSuggestions,
            for: identity,
            to: viewState
        )
    }

    /// Computes the speaker suggestions after the caller has loaded the
    /// profiles and published the current name map. This keeps the stateful
    /// refresh entry point focused on identity checks and publication while
    /// retaining the shared-index fast path and synchronous fallback.
    private func computeSuggestions(
        labels: Set<String>,
        profilesByLabel: [String: SpeakerProfile],
        candidates: [SpeakerProfile]
    ) -> [String: SpeakerSuggestion] {
        var suggestions: [String: SpeakerSuggestion] = [:]
        for label in labels {
            guard let profile = profilesByLabel[label],
                  profile.fingerprintId != SpeakerDiarizationPipeline.sentinelFingerprint
            else { continue }

            let matches: [SpeakerMatcher.PersonMatch]
            let hoverMatches: [SpeakerMatcher.PersonMatch]
            if matchIndex.hasCachedRow(for: profile.id) {
                matches = matchIndex.matches(for: profile, limit: 3)
                hoverMatches = matchIndex.matches(
                    for: profile,
                    limit: 3,
                    excludingFingerprintId: profile.fingerprintId
                )
            } else {
                // Keep synchronous matches while the shared index warms up so
                // the first render does not briefly lose suggestions.
                matches = SpeakerMatcher.topPersonMatches(
                    unbound: profile,
                    boundProfiles: candidates,
                    limit: 3
                )
                hoverMatches = SpeakerMatcher.topPersonMatches(
                    unbound: profile,
                    boundProfiles: candidates,
                    limit: 3,
                    excludingFingerprintId: profile.fingerprintId
                )
            }
            guard let best = matches.first else { continue }
            let confidence: SpeakerSuggestion.Confidence = best.score > 0.8
                ? .high
                : (best.score > 0.6 ? .medium : .low)
            suggestions[label] = SpeakerSuggestion(
                personName: best.personName,
                personId: best.personId,
                score: best.score,
                confidence: confidence,
                matches: matches,
                hoverMatches: hoverMatches
            )
        }
        return suggestions
    }
}

/// Publishes a derived suggestion projection only while its source job remains
/// active. Publication is synchronous because callers already run on the main
/// actor; an extra dispatch hop would allow a job switch between calculation
/// and assignment.
@MainActor
enum ResultsSpeakerSuggestionPublisher {
    static func publish(
        _ suggestions: [String: SpeakerSuggestion],
        for identity: ResultsViewState.JobIdentity,
        to state: ResultsViewState
    ) {
        guard state.isCurrent(identity) else { return }
        state.suggestions = suggestions
    }
}
