import Foundation

/// 把底层 error 映射成稳定的、面向用户的中文文案。
///
/// 背景（审计 R4-P1-6）：
/// - SwiftData 错误的 `localizedDescription` 对用户是
///   "The operation couldn't be completed. (Foundation._GenericObjCError
///   error 0.)"，不可读。
/// - Gemini 401/403/429 的原始错误文本可能含技术细节。
/// - 启动恢复 / 终止确认里裸 UUID 会让用户困惑。
///
/// 约束：原始 error 只进脱敏日志（调用方负责），这里返回稳定中文文案。
/// 不在本文件里调用 Logger，避免循环依赖。
enum UserFacingErrorMapper {
    /// 把任意 error 映射成稳定的中文用户文案。
    ///
    /// 已知分类：SwiftData 持久化失败、文件不存在、权限不足、Gemini 鉴权/
    /// 配额、网络、模型未就绪。未识别的错误返回通用文案 + 简短错误类别，
    /// 不直接拼接 `localizedDescription`，避免把 Foundation 内部字符串暴露
    /// 给用户。
    static func message(for error: Error, context: Context = .generic) -> String {
        // 先按 typed case 分流，避免依赖字符串匹配的不稳定文案。
        if let gemini = error as? GeminiProviderError {
            return geminiMessage(gemini, context: context)
        }
        if let failover = error as? GeminiKeyFailoverError {
            return failoverMessage(failover, context: context)
        }
        if let storeError = error as? ResultStoreError {
            return storeMessage(storeError, context: context)
        }

        // SwiftData / CoreData 持久化错误：`_GenericObjCError 0` 或
        // `NSValidation*` 等，这些 localizedDescription 都不适合直接给用户。
        let typeName = String(describing: type(of: error))
        if isPersistenceError(error, typeName: typeName) {
            return context.persistenceFailureMessage
        }

        if let cocoa = error as? CocoaError {
            return cocoaMessage(cocoa, context: context)
        }

        // 未知错误：不拼接原始 localizedDescription，只给稳定中文 + 类别提示，
        // 让用户能反馈"看到什么提示"，运维通过 log 定位真实 error。
        return "\(context.genericFailureMessage)（\(shortTypeLabel(typeName))）"
    }

    /// 上下文：同一个底层错误在不同操作下应有不同用户文案。
    enum Context {
        case generic
        case startupRecovery
        case cleanupPersistence
        case terminationConfirmation
        case speakerMapping

        var genericFailureMessage: String {
            switch self {
            case .generic:
                return "操作未能完成，请稍后重试。"
            case .startupRecovery:
                return "启动恢复未能完成，部分任务可能仍处于中间状态。"
            case .cleanupPersistence:
                return "无法保存润色状态。"
            case .terminationConfirmation:
                return "无法读取任务信息。"
            case .speakerMapping:
                return "无法更新说话人映射。"
            }
        }

        var persistenceFailureMessage: String {
            switch self {
            case .startupRecovery:
                return "无法持久化启动恢复状态，请稍后重试。"
            case .cleanupPersistence:
                return "无法保存润色状态到数据库，请稍后重试。"
            case .terminationConfirmation:
                return "无法读取任务信息，请稍后重试。"
            case .speakerMapping:
                return "无法保存说话人映射，请稍后重试。"
            case .generic:
                return "无法保存更改，请稍后重试。"
            }
        }
    }

    // MARK: - Typed branches

    private static func geminiMessage(
        _ error: GeminiProviderError,
        context: Context
    ) -> String {
        switch error {
        case .invalidURL:
            return "Gemini 服务地址无效，请检查设置。"
        case .noHTTPResponse:
            return "无法连接 Gemini 服务，请检查网络。"
        case let .httpError(statusCode, _, _, _):
            switch statusCode {
            case 401, 403:
                return "Gemini 鉴权失败：API Key 无效或权限不足，请在设置中检查。"
            case 404:
                return "Gemini 模型不存在或服务端点错误，请在设置中检查模型配置。"
            case 429:
                return "Gemini 请求过于频繁，已触发限流，请稍后再试。"
            case 500..<600:
                return "Gemini 服务暂时不可用（\(statusCode)），请稍后再试。"
            default:
                return "Gemini 返回错误（\(statusCode)），请稍后再试。"
            }
        case .parseResponseFailed:
            return "Gemini 响应格式异常，请稍后重试。"
        case .unexpectedFinishReason:
            return "Gemini 未正常完成生成，请稍后重试。"
        case .missingContentParts:
            return "Gemini 响应缺少内容，请稍后重试。"
        case .emptyText:
            return "Gemini 返回空内容，请稍后重试。"
        case .invalidParagraphsJSON:
            return "Gemini 返回内容无法解析，请稍后重试。"
        }
    }

    private static func failoverMessage(
        _ error: GeminiKeyFailoverError,
        context: Context
    ) -> String {
        switch error {
        case .allTiersExhausted:
            return "所有可用的 Gemini Key 均已失败，请检查 Key 配置或稍后再试。"
        case .noEnabledKeys:
            return "没有启用的 Gemini Key，请在「设置」中添加。"
        }
    }

    private static func storeMessage(
        _ error: ResultStoreError,
        context: Context
    ) -> String {
        switch error {
        case .resultMissing:
            return "结果文件不存在，可能已被移动或删除。"
        case .jsonRenderFailed:
            return "结果数据格式异常，无法保存。"
        }
    }

    private static func cocoaMessage(
        _ error: CocoaError,
        context: Context
    ) -> String {
        switch error.code {
        case .fileReadNoSuchFile, .fileNoSuchFile:
            return "文件不存在，可能已被移动或删除。"
        case .fileReadNoPermission, .fileWriteNoPermission:
            return "没有访问该文件的权限，请在系统设置中授权。"
        case .fileWriteOutOfSpace:
            return "磁盘空间不足，无法保存。"
        case .fileWriteVolumeReadOnly:
            return "目标卷只读，无法保存。"
        default:
            return "\(context.genericFailureMessage)"
        }
    }

    // MARK: - Helpers

    /// SwiftData/CoreData 持久化错误通常不是 typed enum，而是 NSError
    /// domain `NSCocoaErrorDomain` code 1340xx，或 Foundation._GenericObjCError。
    private static func isPersistenceError(_ error: Error, typeName: String) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain,
           (134000..<135000).contains(ns.code) {
            return true
        }
        if typeName.contains("GenericObjCError") {
            return true
        }
        return false
    }

    private static func shortTypeLabel(_ typeName: String) -> String {
        // 取类型名最后一段，避免暴露模块路径等内部信息。
        if let last = typeName.split(separator: ".").last {
            return String(last)
        }
        return typeName
    }
}
