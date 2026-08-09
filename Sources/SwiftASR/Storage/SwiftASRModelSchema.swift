import SwiftData

/// The single source of truth for the SwiftData model graph.
///
/// Keeping the model inventory in one place prevents the app container and
/// in-memory test containers from silently drifting apart as relationships are
/// added. This is intentionally an inventory, not a migration plan: schema
/// versioning still needs to be introduced only after the existing on-disk
/// stores have been characterized.
public enum SwiftASRModelSchema {
    /// Segment content lives exclusively in each job's `result.json`; the
    /// retired SwiftData `Utterance` entity is intentionally absent.
    public static let modelTypes: [any PersistentModel.Type] = [
        ASRJob.self,
        SpeakerProfile.self,
        JobSpeakerProfileOccurrence.self,
        Person.self
    ]
}
