import Foundation
import SwiftData

// MARK: - ASRJobRepository（jobs 通用 fetch 封装）
//
// 之前 view 和 coordinator 里散落 15+ 处 `try? modelContext.fetch(FetchDescriptor<ASRJob>(...))`，
// 把常见模式抽到一处。
public enum ASRJobRepository {
    /// 按 id 查单个 job。
    public static func findById(_ id: String, in context: ModelContext) throws -> ASRJob? {
        let descriptor = FetchDescriptor<ASRJob>(predicate: #Predicate { $0.id == id })
        return try context.fetch(descriptor).first
    }

    /// 全部 job（按 createdAt 倒序，新 → 旧）。
    /// 调用方需要 sort 改序时直接拿 `[ASRJob]` 自己做。
    public static func fetchAll(in context: ModelContext) throws -> [ASRJob] {
        let descriptor = FetchDescriptor<ASRJob>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        return try context.fetch(descriptor)
    }
}
