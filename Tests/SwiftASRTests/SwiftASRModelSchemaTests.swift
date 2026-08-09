import Foundation
import SwiftData
import Testing
@testable import SwiftASR

@Test func modelSchemaContainsEveryPersistentModel() throws {
    let schema = Schema(SwiftASRModelSchema.modelTypes)
    let container = try ModelContainer(
        for: schema,
        configurations: [ModelConfiguration("SwiftASRModelSchemaTests", schema: schema, isStoredInMemoryOnly: true)]
    )
    let context = ModelContext(container)

    context.insert(ASRJob(sourceAudioPath: "/tmp/schema.wav", sourceAudioHash: "schema", durationSeconds: 1))
    context.insert(Person(name: "Schema Person"))
    try context.save()

    #expect(try context.fetch(FetchDescriptor<ASRJob>()).count == 1)
    #expect(try context.fetch(FetchDescriptor<Person>()).count == 1)
    #expect(schema.entitiesByName["Utterance"] == nil)
}

@Test func personRepositoryUsesTrimmedUniqueNameLookup() throws {
    let schema = Schema(SwiftASRModelSchema.modelTypes)
    let container = try ModelContainer(
        for: schema,
        configurations: [ModelConfiguration("SwiftASRPersonRepositoryTests", schema: schema, isStoredInMemoryOnly: true)]
    )
    let context = ModelContext(container)

    let first = try #require(try PersonRepository.getOrCreate(name: "  Alice  ", in: context))
    let second = try #require(try PersonRepository.getOrCreate(name: "Alice", in: context))

    #expect(first.id == second.id)
    #expect(try context.fetch(FetchDescriptor<Person>()).count == 1)
}

@Test func personRepositoryUsesCaseInsensitiveCreateAndRenameRules() throws {
    let schema = Schema(SwiftASRModelSchema.modelTypes)
    let container = try ModelContainer(
        for: schema,
        configurations: [ModelConfiguration("SwiftASRPersonNameRulesTests", schema: schema, isStoredInMemoryOnly: true)]
    )
    let context = ModelContext(container)

    let alice = try PersonRepository.create(name: " Alice ", in: context)
    #expect(alice.name == "Alice")
    #expect(throws: PersonRepositoryError.self) {
        try PersonRepository.create(name: "alice", in: context)
    }
    try PersonRepository.rename(alice, to: "  ALICE  ", in: context)
    #expect(alice.name == "ALICE")
}

@Test func speakerLibrarySearchFiltersPeopleAndFingerprints() {
    let alice = Person(name: "Alice")
    let bob = Person(name: "Bob")
    let aliceProfile = SpeakerProfile(fingerprintId: "fp_alice", speakerLabel: "S1", person: alice)
    let bobProfile = SpeakerProfile(fingerprintId: "fp_needle", speakerLabel: "S2", person: bob)
    let unbound = SpeakerProfile(fingerprintId: "fp_unbound", speakerLabel: "S3")

    let byPerson = SpeakerLibraryPresentation.filteredBoundGroups(
        persons: [alice, bob], profiles: [aliceProfile, bobProfile], query: "alice"
    )
    #expect(byPerson.map(\.person.name) == ["Alice"])
    #expect(byPerson.first?.profiles.map(\.fingerprintId) == ["fp_alice"])

    let byFingerprint = SpeakerLibraryPresentation.filteredBoundGroups(
        persons: [alice, bob], profiles: [aliceProfile, bobProfile], query: "needle"
    )
    #expect(byFingerprint.map(\.person.name) == ["Bob"])
    #expect(byFingerprint.first?.profiles.map(\.fingerprintId) == ["fp_needle"])

    let unboundMatches = SpeakerLibraryPresentation.filteredUnboundProfiles(
        profiles: [aliceProfile, bobProfile, unbound], query: "unbound"
    )
    #expect(unboundMatches.map(\.fingerprintId) == ["fp_unbound"])
}

@Test func duplicateFingerprintLookupFailsLoudly() throws {
    let schema = Schema(SwiftASRModelSchema.modelTypes)
    let container = try ModelContainer(
        for: schema,
        configurations: [ModelConfiguration("SwiftASRDuplicateFingerprintTests", schema: schema, isStoredInMemoryOnly: true)]
    )
    let context = ModelContext(container)
    context.insert(SpeakerProfile(id: "p1", fingerprintId: "duplicate", speakerLabel: "S1"))
    context.insert(SpeakerProfile(id: "p2", fingerprintId: "duplicate", speakerLabel: "S2"))
    try context.save()

    #expect(throws: SpeakerProfileRepositoryError.self) {
        try SpeakerProfileRepository.findByFingerprintId("duplicate", in: context)
    }
}
