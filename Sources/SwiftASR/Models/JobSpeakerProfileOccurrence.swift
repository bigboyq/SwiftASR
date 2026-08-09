import Foundation
import SwiftData

/// The contribution of one job to one global speaker profile.
///
/// A `SpeakerProfile` is global and can be reused by many jobs. Keeping the
/// per-job contribution here makes reruns idempotent and prevents a job from
/// overwriting the profile's only source job.
@Model
public final class JobSpeakerProfileOccurrence {
    @Attribute(.unique) public var id: String
    public var speakerLabel: String
    public var utteranceCount: Int
    public var durationSeconds: Double

    public var job: ASRJob?

    public var profile: SpeakerProfile?

    public init(
        id: String? = nil,
        speakerLabel: String,
        utteranceCount: Int,
        durationSeconds: Double,
        job: ASRJob? = nil,
        profile: SpeakerProfile? = nil
    ) {
        self.id = id ?? Self.makeID(jobID: job?.id, profileID: profile?.id)
        self.speakerLabel = speakerLabel
        self.utteranceCount = utteranceCount
        self.durationSeconds = durationSeconds
        self.job = job
        self.profile = profile
    }

    /// Stable identity for the job/profile pair. A job can contribute to a
    /// profile only once; reruns update this row instead of inserting another.
    public static func makeID(jobID: String?, profileID: String?) -> String {
        "\(jobID ?? "unattached"):\(profileID ?? "unattached")"
    }
}
