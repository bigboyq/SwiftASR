import Foundation

// MARK: - GeminiProviderError

/// Caller-facing errors from `callOnceParagraphs`. Replaces a 6-site
/// `NSError(domain: "GeminiProvider", code: -N, ...)` template.
///
/// Distinct cases so `isRateLimit` / `isServerOverload` can switch on
/// the case without sniffing `userInfo["retryable"]`, and so
/// `GeminiKeyFailover` can recover the 429-specific cooldown hints
/// (`retryDelaySecs`, `isRPD`) without going through `userInfo`.
public enum GeminiProviderError: Error, LocalizedError, Sendable {
    case invalidURL
    case noHTTPResponse
    /// HTTP error from Gemini. `retryable` is the prior
    /// `userInfo["retryable"]` flag (5xx/429 → true, other → false);
    /// `retryDelaySecs` + `isRPD` are the 429-specific cooldown hints
    /// previously stored in userInfo. nil for non-429 cases.
    /// Response bodies are deliberately not retained in the typed error:
    /// proxy/server responses may echo prompt content or other sensitive text.
    case httpError(statusCode: Int, retryable: Bool, retryDelaySecs: Double?, isRPD: Bool)
    case parseResponseFailed
    case unexpectedFinishReason(reason: String)
    case missingContentParts
    case emptyText
    case invalidParagraphsJSON

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL"
        case .noHTTPResponse:
            return "no http response"
        case let .httpError(statusCode, _, _, _):
            // R4-P2-3：错误描述不携带响应体，避免 prompt 回显或敏感内容
            // 进入 UI/普通日志。响应体只在显式 debug 日志里出现。
            return "Gemini \(statusCode)"
        case .parseResponseFailed:
            return "Failed to parse Gemini response"
        case let .unexpectedFinishReason(reason):
            return "Gemini response did not finish normally: \(reason)"
        case .missingContentParts:
            return "Gemini response has no content parts"
        case .emptyText:
            return "Gemini response contains no text"
        case .invalidParagraphsJSON:
            return "Gemini text is not valid JSON paragraphs"
        }
    }
}

// MARK: - Gemini 单 key 实现（paragraph 模式）

public final class GeminiProvider: @unchecked Sendable {
    public let name = "gemini"
    private let apiKey: String
    private let model: String
    private let endpoint: String
    private let temperature: Double
    /// URLSession 可注入。默认 `URLSession.shared` 用于生产。
    /// 历史注：之前曾尝试给本类加 `fetcher: (URLRequest, URLSession) async throws -> (Data, URLResponse)`
    /// 注入点以避开 main runloop 死锁（详见 `Tests/SwiftASRTests/PhaseTierFailoverTests.swift` 顶部
    /// 注释和 SWIFTASR_PARITY.md "已知问题" 段），但 Foundation `URLSession.data(for:)` 在 Swift
    /// Concurrency 下死锁的根因不在 fetcher，而在 `await session.data` 本身被 main runloop 阻塞。
    /// 注入 fetcher 不会解决问题，反而是死代码分支，所以回退。
    private let session: URLSession

    public init(apiKey: String, model: String = "gemini-flash-latest", endpoint: String = "https://generativelanguage.googleapis.com/v1beta", temperature: Double = 0.2, session: URLSession = URLSession.shared) {
        self.apiKey = apiKey
        self.model = model
        self.endpoint = endpoint
        self.temperature = temperature
        self.session = session
    }

    /// 调一次 Gemini（paragraph 模式）：返回 `[String]`，每项对应一个 MergedResult 的润色结果。
    /// 使用更简单的 `{"paragraphs":["...",...]}` schema，Gemini 生成更快、响应体更小。
    public func callOnceParagraphs(prompt: String) async throws -> [String] {
        let urlString = "\(endpoint)/models/\(model):generateContent"
        guard let url = URL(string: urlString) else {
            throw GeminiProviderError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            forHTTPHeaderField: "x-goog-api-key"
        )
        // 90s per-chunk；6000 字符 chunk 远小于此值
        request.timeoutInterval = 90

        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "paragraphs": [
                    "type": "array",
                    "items": ["type": "string"]
                ]
            ],
            "required": ["paragraphs"]
        ]

        let body: [String: Any] = [
            "contents": [["parts": [["text": prompt]]]],
            "generationConfig": [
                "temperature": temperature,
                "responseMimeType": "application/json",
                "responseSchema": schema
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GeminiProviderError.noHTTPResponse
        }
        if http.statusCode != 200 {
            let retryable = (500..<600).contains(http.statusCode) || http.statusCode == 429
            if http.statusCode == 429 {
                let (delaySecs, isRPD) = GeminiProvider.parse429Details(from: data)
                throw GeminiProviderError.httpError(
                    statusCode: http.statusCode,
                    retryable: retryable,
                    retryDelaySecs: delaySecs,
                    isRPD: isRPD
                )
            }
            throw GeminiProviderError.httpError(
                statusCode: http.statusCode,
                retryable: retryable,
                retryDelaySecs: nil,
                isRPD: false
            )
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let first = candidates.first else {
            throw GeminiProviderError.parseResponseFailed
        }
        guard let finishReason = first["finishReason"] as? String,
              finishReason == "STOP" else {
            let reason = first["finishReason"] as? String ?? "missing"
            throw GeminiProviderError.unexpectedFinishReason(reason: reason)
        }
        guard let content = first["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            throw GeminiProviderError.missingContentParts
        }
        let text = parts.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else {
            throw GeminiProviderError.emptyText
        }
        guard let jsonData = text.data(using: .utf8),
              let parsed = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let arr = parsed["paragraphs"] as? [String] else {
            throw GeminiProviderError.invalidParagraphsJSON
        }
        return arr
    }

    /// 为 MergedResult 列表构建 prompt（段落级别，上下文更完整）。
    static func buildPrompt(
        mergedResults: [MergedResult],
        speakerNames: [String: String],
        glossary: [String],
        promptText: String = SettingsStore.CleanupDefaults.prompt
    ) -> String {
        let glossaryText = glossary.isEmpty ? "(无)" : glossary.map { "- \($0)" }.joined(separator: "\n")
        let segsText = mergedResults.enumerated()
            .map { index, result in
                let label = result.effectiveSpeakerLabel
                let name = speakerNames[label] ?? label
                return "[\(index)] \(name): \(result.rawContent)"
            }
            .joined(separator: "\n")
        let trimmed = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        let system = trimmed.isEmpty ? SettingsStore.CleanupDefaults.prompt : promptText
        return """
        \(system)

        术语表中的内容是"优先标准写法"，不是逐字替换规则。
        如果原文里出现相近发音、同音词、上下文明显对应的写法，请优先收敛到术语表里的表达。

        优先术语表：
        \(glossaryText)

        原文（按段，每段是同一说话人的连续内容）：
        \(segsText)

        请逐段润色，保持原有段数和顺序，输出格式：JSON 对象 {"paragraphs":["段落0润色结果","段落1润色结果",...]}
        `paragraphs` 的每一项只能包含润色后的正文：绝对不要包含编号、说话人姓名、speaker label 或任何冒号前缀。
        """
    }

    /// 公开版 stripSpeakerPrefix (跟 private 版逻辑一致). 让
    /// LLMCleanupService.cleanupMergedChunk 在不抛错路径下也能复用
    /// prefix 剥离逻辑 (用于 ⚠️原文 占位判断).
    static func stripSpeakerPrefixPublic(_ text: String, displayName: String, speakerLabel: String) -> String {
        stripSpeakerPrefix(text, displayName: displayName, speakerLabel: speakerLabel)
    }

    static func stripSpeakerPrefix(_ text: String, displayName: String, speakerLabel: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = ["\(displayName):", "\(displayName)：", "\(speakerLabel):", "\(speakerLabel)："]
        if let prefix = prefixes.first(where: { trimmed.hasPrefix($0) }) {
            trimmed = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    /// 解析 429 响应体里的 `RetryInfo.retryDelay` 和 `QuotaFailure.violations[].quotaId`。
    /// 返回 (retryDelaySecs, isRPD)：
    /// - retryDelaySecs：`retryDelay` 字段解析出的秒数（格式 "55s" / "1m30s"），解析失败兜底 60.0
    /// - isRPD：任意 violation 的 quotaId 包含 "PerDay" → true（今日用尽）
    static func parse429Details(from data: Data) -> (retryDelaySecs: Double, isRPD: Bool) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let errorObj = json["error"] as? [String: Any],
              let details = errorObj["details"] as? [[String: Any]] else {
            return (60.0, false)
        }
        var retryDelaySecs: Double = 60.0
        var isRPD = false
        for detail in details {
            let type_ = detail["@type"] as? String ?? ""
            if type_.hasSuffix("RetryInfo"),
               let delayStr = detail["retryDelay"] as? String {
                retryDelaySecs = parseRetryDelayString(delayStr) ?? 60.0
            }
            if type_.hasSuffix("QuotaFailure"),
               let violations = detail["violations"] as? [[String: Any]] {
                for v in violations {
                    if let quotaId = v["quotaId"] as? String, quotaId.contains("PerDay") {
                        isRPD = true
                    }
                }
            }
        }
        return (retryDelaySecs, isRPD)
    }

    /// "55s" / "1m30s" / "2m" 等格式解析为秒数。
    /// 不认识的格式返回 nil，调用方兜底 60.0。
    static func parseRetryDelayString(_ s: String) -> Double? {
        var remaining = s
        var total: Double = 0
        // 分钟部分
        if let mRange = remaining.range(of: #"(\d+)m"#, options: .regularExpression) {
            let token = String(remaining[mRange]).dropLast() // 去掉 "m"
            if let mins = Double(token) { total += mins * 60 }
            remaining = String(remaining[mRange.upperBound...])
        }
        // 秒部分
        if let sRange = remaining.range(of: #"(\d+\.?\d*)s"#, options: .regularExpression) {
            let token = String(remaining[sRange]).dropLast() // 去掉 "s"
            if let secs = Double(token) { total += secs }
        }
        return total > 0 ? total : nil
    }

    private static func normalizedErrorText(_ error: NSError) -> (normalized: String, collapsed: String) {
        let raw = (
            error.localizedDescription + " "
            + (error.userInfo[NSLocalizedDescriptionKey] as? String ?? "")
        ).lowercased()
        return (
            raw.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "  ", with: " "),
            raw.replacingOccurrences(of: "_", with: "").replacingOccurrences(of: " ", with: "")
        )
    }

    /// 错误是否可重试（429 / 5xx / 网络层超时 / 连接失败）
    ///
    /// * `isRateLimit(_:)` 命中 → 在同 tier 内切下一个 priority
    /// * `isServerOverload(_:)` 命中 → 升 tier（用更贵的 key 兜底）
    /// `isRetryable` = 两者并集，给"是否要换 key"的总判断。
    static func isRetryable(_ error: Error) -> Bool {
        return isRateLimit(error) || isServerOverload(error)
    }

    /// 429 (per-key rate limit) 检测。命中后 GeminiKeyFailover 在同 tier 内切
    /// 下一个 priority——换一把 key 大概率能解（每把 key 有自己的 quota）。
    /// 也包含 keyword fallback：SDK 不暴露 numeric code 时，message 里
    /// 看到 "rate limit" / "resource exhausted" 也算。
    static func isRateLimit(_ error: Error) -> Bool {
        // Typed error path: GeminiProviderError.httpError with code 429
        // is the canonical rate-limit signal.
        if let provider = error as? GeminiProviderError {
            switch provider {
            case .httpError(let statusCode, _, _, _):
                return statusCode == 429
            default:
                return false
            }
        }
        let nsError = error as NSError
        // 显式标记优先
        if let explicit = nsError.userInfo["retryable"] as? Bool, !explicit {
            return false
        }
        // URLError：网络层抖动也归 429 同档处理（retry 下一把 key 不会让事情
        // 变糟）。但只有 timedOut / connectionLost 这类"还能继续"的，不能
        // 把 auth failure 也算进去（那个走 4xx 不重试）。
        if nsError.domain == NSURLErrorDomain {
            let recoverableURLCodes: Set<Int> = [
                NSURLErrorTimedOut,                  // -1001
                NSURLErrorNetworkConnectionLost,     // -1005
                NSURLErrorCannotConnectToHost,       // -1004
                NSURLErrorDNSLookupFailed,           // -1006
            ]
            return recoverableURLCodes.contains(nsError.code)
        }
        // HTTP 层：429 严格归属 per-key 限流。
        if nsError.code == 429 { return true }
        // keyword fallback：少数 SDK 不带 code 但 message 里有 "rate limit"
        // 把空格 / 下划线归一化掉，"ResourceExhausted" / "resource_exhausted"
        // / "Resource Exhausted" 三种写法都能命中。
        let (normalized, collapsed) = normalizedErrorText(nsError)
        // 同时也支持压缩版本（无空格无下划线）以匹配 "ResourceExhausted: 429" 这种。
        let tokens = ["rate limit", "resource exhausted", "too many requests", "quota exceeded"]
        let collapsedTokens = ["ratelimit", "resourceexhausted", "toomanyrequests", "quotaexceeded"]
        return tokens.contains(where: { normalized.contains($0) })
            || collapsedTokens.contains(where: { collapsed.contains($0) })
    }

    /// 5xx / 529 (server-side overload) 检测。命中后 GeminiKeyFailover **升 tier**
    /// ——同一个 tier 里换 key 没意义（都是同上游），直接花钱用付费 key 兜底。
    /// 包含 5xx + 529 + "site is overloaded" / "high demand" / "service unavailable"
    /// 等 keyword fallback（Cloudflare / Anthropic / Gemini 各自会返回不同的
    /// status code，但语义都相同）。
    static func isServerOverload(_ error: Error) -> Bool {
        // Typed error path: GeminiProviderError.httpError with 5xx/529 is
        // the canonical server-overload signal.
        if let provider = error as? GeminiProviderError {
            switch provider {
            case .httpError(let statusCode, _, _, _):
                return (500..<600).contains(statusCode) || statusCode == 529
            default:
                return false
            }
        }
        let nsError = error as NSError
        // 显式标记优先
        if let explicit = nsError.userInfo["retryable"] as? Bool, !explicit {
            return false
        }
        // HTTP 层：5xx + 529
        let code = nsError.code
        if (500..<600).contains(code) { return true }
        if code == 529 { return true }
        // keyword fallback：把空格 / 下划线归一化。
        let (normalized, _) = normalizedErrorText(nsError)
        let tokens = [
            "unavailable", "high demand", "site is overloaded", "server overloaded",
            "service unavailable", "503", "502", "500", "529",
        ]
        return tokens.contains(where: { normalized.contains($0) })
    }

    /// Gemini/proxy error bodies are untrusted and can echo request
    /// credentials. Never surface the configured key in UI errors or logs.
    static func redactingSecret(_ secret: String, from text: String) -> String {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }
        return text.replacingOccurrences(of: trimmed, with: "<redacted>")
    }

    // MARK: - testConnection

    /// 调 Gemini /v1beta/models 验证 key 是否有效。
    /// 返回 (ok, message)：ok=true 表示 200 + 解析出至少一个 model；message 给 UI 显示。
    /// 调一次小请求（GET models 列表），不消耗 token。
    public static func testConnection(
        apiKey: String,
        endpoint: String = "https://generativelanguage.googleapis.com/v1beta",
        modelName: String? = nil,
        session: URLSession = URLSession.shared
    ) async -> (ok: Bool, message: String) {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return (false, "API Key 不能为空")
        }
        // 优先用 cleanupSettings 的 model（用户可能改了）；fallback 到 gemini-flash-latest。
        let probeModel = modelName ?? "gemini-flash-latest"

        let urlString = "\(endpoint)/models/\(probeModel)"
        guard let url = URL(string: urlString) else {
            return (false, "endpoint URL 格式错误：\(endpoint)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(trimmed, forHTTPHeaderField: "x-goog-api-key")
        req.timeoutInterval = 15

        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                return (false, "网络异常：无 HTTP 响应")
            }
            if http.statusCode == 200 {
                // 解析 model 名称回显
                var modelName = probeModel
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let name = json["name"] as? String {
                    modelName = name.hasPrefix("models/") ? String(name.dropFirst("models/".count)) : name
                }
                return (true, "✅ 连接成功（\(modelName)）")
            }
            let body = redactingSecret(
                trimmed,
                from: String(data: data, encoding: .utf8) ?? ""
            )
            // 常见错误码说明
            switch http.statusCode {
            case 400, 403:
                return (false, "❌ \(http.statusCode): Key 无效或权限不足\n\(body.prefix(200))")
            case 404:
                return (false, "❌ 404: 模型 \(probeModel) 不存在或 endpoint 错误\n\(body.prefix(200))")
            case 429:
                return (false, "❌ 429: Key 限流，等几秒再试")
            default:
                return (false, "❌ HTTP \(http.statusCode)\n\(body.prefix(200))")
            }
        } catch {
            return (false, "❌ 网络异常：\(error.localizedDescription)")
        }
    }
}

/// Bug fix 2026-07-12/13: Gemini 段落对齐错误. 静默跳过空 paragraph
/// (老 `if !trimmed.isEmpty` 逻辑) 会让 LLM 输出质量问题逃过写盘, 跑到
/// 前端 `cleanupCheckpoint.allSatisfy` 才被发现. 改 fail-loud:
///   - countMismatch: Gemini 返回的 paragraphs 数跟原始 mergedResults
///     数不匹配 (LLM 跳过段 / 合并段 / 切分错位)
///   - consecutiveEmptyParagraphs: >=2 段连续空 (LLM 输出质量差, 当
///     失败处理, 让用户重跑而不是静默 fallback)
/// 外层 catch 走 `cleanupError` 提示用户, 不会重试 (LLM 输出质量
/// 问题 retry 同样 prompt 同样问题, 浪费 quota).
///
/// speakerLabel 字段格式: 直接是 MergeResult.speakerLabel 原始值, 可能
/// 已经是 "说话人 1" / "Speaker1" 等带前缀形式. errorDescription 不要再
/// 拼 "说话人" 前缀避免 "说话人 说话人 4" 重复.
enum GeminiParagraphAlignmentError: LocalizedError {
    case countMismatch(original: Int, returned: Int)
    case consecutiveEmptyParagraphs(indexes: [Int])

    var errorDescription: String? {
        switch self {
        case .countMismatch(let original, let returned):
            return "Gemini 润色段落数不匹配：原始 \(original) 段，返回 \(returned) 段。"
        case .consecutiveEmptyParagraphs(let indexes):
            return "Gemini 润色后连续 \(indexes.count) 段内容为空（indexes: \(indexes.prefix(10))），LLM 输出质量差, 请重跑。"
        }
    }
}
