import Foundation
import SwiftData

/// 共享的 SwiftData 保存入口（审计 R4-P1-4）。
///
/// `ResultsContent`、`SpeakersTab`、`PersonPickerSheet` 各自写了
/// `try modelContext.save()` + `rollback` + `persistenceError = "...失败：
/// \(error.localizedDescription)"` 的模板，错误文案和日志行为容易再次分叉。
/// 本 helper 收敛保存 + 回滚 + 稳定中文文案，调用方只负责把返回的
/// `userMessage` 写入自己的 `@State`。
enum ModelContextSaver {
    /// 保存 `modelContext`；失败时回滚并返回稳定的中文用户文案。
    /// 原始 error 只进日志（不进 userMessage）。
    /// - Returns: `(success, userMessage)`。成功时 `userMessage == nil`；
    ///   失败时是可直接展示的中文文案。
    @discardableResult
    static func save(
        _ modelContext: ModelContext,
        action: String
    ) -> (success: Bool, userMessage: String?) {
        do {
            try modelContext.save()
            return (true, nil)
        } catch {
            modelContext.rollback()
            // R4-P1-6：不直接拼 localizedDescription（可能是 Foundation
            // _GenericObjCError 之类不可读文本），走统一 mapper。
            let message = "\(action)失败：" + UserFacingErrorMapper.message(
                for: error, context: .generic
            )
            Logger.shared.error("\(action)失败：\(error)")
            return (false, message)
        }
    }
}
