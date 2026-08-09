import Foundation

// MARK: - SpeakerProfile 扩展（详情面板的样本句）

extension SpeakerProfile {
    /// 从 job 的 result.json 拿最近 3 句属于这个 speaker_label 的 raw_text
    /// （Phase 4 之前没存样本句到 SwiftData 字段；这里走 job 反查）
    @MainActor
    func sampleText() async -> String? {
        guard let occurrence = jobOccurrences.max(by: {
            ($0.job?.createdAt ?? .distantPast) < ($1.job?.createdAt ?? .distantPast)
        }), let job = occurrence.job else {
            return nil
        }
        let jobId = job.id
        let transcriptPath = job.transcriptPath
        let speakerLabel = occurrence.speakerLabel

        let path = ResultStore.resolveStoredPath(transcriptPath)
            ?? ResultStore.stageResultPath(jobId: jobId)
        guard FileManager.default.fileExists(atPath: path.path) else {
            return nil
        }
        return await Task.detached(priority: .userInitiated) {
            guard let payload = try? ResultStore.read(from: path),
                  (try? payload.validate(expectedJobID: jobId)) != nil else {
                return nil
            }
            // speakerLabel is job-local: the same global profile can be emitted
            // as different acoustic labels in different jobs.
            let mySegs = payload.segments
                .filter { $0.speakerLabel == speakerLabel }
                .prefix(3)
                .map { $0.rawText }
            return mySegs.joined(separator: " / ")
        }.value
    }
}
