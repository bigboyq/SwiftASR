import Foundation

/// Pure filtering/grouping rules for the speaker-library UI.
/// Keeping these rules outside the View makes search behavior testable without
/// launching SwiftUI and keeps Person/Profile persistence out of rendering code.
enum SpeakerLibraryPresentation {
    static func filteredBoundGroups(
        persons: [Person],
        profiles: [SpeakerProfile],
        query: String
    ) -> [(person: Person, profiles: [SpeakerProfile])] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return persons.compactMap { person in
            let personMatches = normalizedQuery.isEmpty
                || person.name.lowercased().contains(normalizedQuery)
            let personProfiles = profiles
                .filter { $0.person?.id == person.id }
                .filter { personMatches || $0.fingerprintId.lowercased().contains(normalizedQuery) }
                .sorted { $0.fingerprintId < $1.fingerprintId }
            guard personMatches || !personProfiles.isEmpty else { return nil }
            return (person: person, profiles: personProfiles)
        }
    }

    static func filteredUnboundProfiles(
        profiles: [SpeakerProfile],
        query: String
    ) -> [SpeakerProfile] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return profiles
            .filter { $0.person == nil }
            .filter { normalizedQuery.isEmpty || $0.fingerprintId.lowercased().contains(normalizedQuery) }
            .sorted { $0.fingerprintId < $1.fingerprintId }
    }
}
