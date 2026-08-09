import Foundation
import SwiftData

public enum SpeakerProfileRepositoryError: Error, LocalizedError {
    case resultPathUnavailable(jobID: String, storedPath: String)
    case resultUnreadable(jobID: String, underlying: Error)
    case duplicateFingerprint(fingerprintId: String, count: Int)

    public var errorDescription: String? {
        switch self {
        case let .resultPathUnavailable(jobID, _):
            return "任务 \(jobID) 的结果路径不可用。"
        case let .resultUnreadable(jobID, underlying):
            return "任务 \(jobID) 的 result.json 无法读取：\(underlying.localizedDescription)"
        case let .duplicateFingerprint(fingerprintId, count):
            return "声纹库中发现重复 fingerprint（\(fingerprintId)，共 \(count) 条），已停止继续写入。"
        }
    }
}

public enum PersonRepositoryError: Error, LocalizedError {
    case duplicateName(String)
    case emptyName

    public var errorDescription: String? {
        switch self {
        case .duplicateName(let name): return "说话人「\(name)」已存在。"
        case .emptyName: return "说话人名称不能为空。"
        }
    }
}

// MARK: - PersonRepository（get_or_create 工具）

/// Person 表的 get_or_create helper。
/// PersonPickerSheet 选已有 Person / 新建 Person 时用。
public enum PersonRepository {
    public static func findByName(_ name: String, in context: ModelContext) throws -> Person? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Person.name 的 SwiftData unique constraint 不保证大小写不敏感，
        // 因此在应用层统一做 trim + case-insensitive 去重。
        let people = try context.fetch(FetchDescriptor<Person>())
        return people.first {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(trimmed) == .orderedSame
        }
    }

    public static func create(name: String, in context: ModelContext) throws -> Person {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PersonRepositoryError.emptyName }
        if try findByName(trimmed, in: context) != nil {
            throw PersonRepositoryError.duplicateName(trimmed)
        }
        let person = Person(name: trimmed)
        context.insert(person)
        return person
    }

    public static func rename(_ person: Person, to name: String, in context: ModelContext) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PersonRepositoryError.emptyName }
        if let existing = try findByName(trimmed, in: context), existing.id != person.id {
            throw PersonRepositoryError.duplicateName(trimmed)
        }
        person.name = trimmed
    }

    public static func getOrCreate(name: String, in context: ModelContext) throws -> Person? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let existing = try findByName(trimmed, in: context) {
            return existing
        }
        let new = Person(name: trimmed)
        context.insert(new)
        return new
    }

    public static func fetchAll(in context: ModelContext) throws -> [Person] {
        let descriptor = FetchDescriptor<Person>(sortBy: [SortDescriptor(\.name)])
        return try context.fetch(descriptor)
    }
}

// MARK: - SpeakerProfileRepository（跨 job 去重的 fetch helper）

public enum SpeakerProfileRepository {
    public static func findByFingerprintId(_ fingerprintId: String, in context: ModelContext) throws -> SpeakerProfile? {
        let descriptor = FetchDescriptor<SpeakerProfile>(predicate: #Predicate { $0.fingerprintId == fingerprintId })
        let matches = try context.fetch(descriptor)
        guard matches.count <= 1 else {
            throw SpeakerProfileRepositoryError.duplicateFingerprint(
                fingerprintId: fingerprintId,
                count: matches.count
            )
        }
        return matches.first
    }

    /// 按 id 查单个 SpeakerProfile。
    public static func findById(_ id: String, in context: ModelContext) throws -> SpeakerProfile? {
        let descriptor = FetchDescriptor<SpeakerProfile>(predicate: #Predicate { $0.id == id })
        return try context.fetch(descriptor).first
    }

    /// 全部 SpeakerProfile（按 fingerprintId 升序，跟 UI 列表展示顺序一致）。
    /// 调用方需要 sort 改序时直接拿 `[SpeakerProfile]` 自己做。
    public static func fetchAll(in context: ModelContext) throws -> [SpeakerProfile] {
        let descriptor = FetchDescriptor<SpeakerProfile>(sortBy: [SortDescriptor(\.fingerprintId)])
        return try context.fetch(descriptor)
    }

    /// 找出仍被持久化 result.json 引用的 profile。
    ///
    /// Profile 是全局声纹库对象，不能因为从库中删除就破坏历史结果页的
    /// speaker_profile_id 映射。因此删除前必须检查所有任务的结果文件。
    /// 结果路径或文件读取失败时抛错，由调用方 fail-closed，禁止删除。
    public static func referencingJobs(
        profile: SpeakerProfile,
        in context: ModelContext
    ) throws -> [ASRJob] {
        let jobs = try context.fetch(
            FetchDescriptor<ASRJob>(predicate: #Predicate { $0.transcriptPath != nil })
        )
        var matches: [ASRJob] = []
        for job in jobs {
            guard let storedPath = job.transcriptPath else { continue }
            guard let path = ResultStore.resolveStoredPath(storedPath) else {
                throw SpeakerProfileRepositoryError.resultPathUnavailable(
                    jobID: job.id,
                    storedPath: storedPath
                )
            }
            do {
                let payload = try ResultStore.read(from: path)
                try payload.validate(expectedJobID: job.id)
                let referenced = payload.speakers.contains {
                    $0.speakerProfileId == profile.id || $0.fingerprintId == profile.fingerprintId
                }
                if referenced { matches.append(job) }
            } catch {
                throw SpeakerProfileRepositoryError.resultUnreadable(jobID: job.id, underlying: error)
            }
        }
        return matches
    }

    /// Finds library profiles that are no longer referenced by any persisted
    /// task result. This is deliberately a single task scan, rather than
    /// calling `referencingJobs` once per profile, so a large historical
    /// library does not repeatedly decode the same result files.
    ///
    /// If any task claims to have a result but its path is unavailable or its
    /// JSON cannot be read, this throws. Callers must then leave the library
    /// unchanged: an incomplete scan must never turn into destructive cleanup.
    public static func unreferencedProfiles(in context: ModelContext) throws -> [SpeakerProfile] {
        let profiles = try fetchAll(in: context)
        let jobs = try context.fetch(
            FetchDescriptor<ASRJob>(predicate: #Predicate { $0.transcriptPath != nil })
        )
        var referencedProfileIDs = Set<String>()
        var referencedFingerprints = Set<String>()

        for job in jobs {
            guard let storedPath = job.transcriptPath else { continue }
            guard let path = ResultStore.resolveStoredPath(storedPath) else {
                throw SpeakerProfileRepositoryError.resultPathUnavailable(
                    jobID: job.id,
                    storedPath: storedPath
                )
            }
            do {
                let payload = try ResultStore.read(from: path)
                try payload.validate(expectedJobID: job.id)
                for speaker in payload.speakers {
                    if let profileID = speaker.speakerProfileId {
                        referencedProfileIDs.insert(profileID)
                    }
                    if let fingerprintID = speaker.fingerprintId {
                        referencedFingerprints.insert(fingerprintID)
                    }
                }
            } catch {
                throw SpeakerProfileRepositoryError.resultUnreadable(jobID: job.id, underlying: error)
            }
        }

        return profiles.filter {
            !referencedProfileIDs.contains($0.id)
                && !referencedFingerprints.contains($0.fingerprintId)
        }
    }
}
