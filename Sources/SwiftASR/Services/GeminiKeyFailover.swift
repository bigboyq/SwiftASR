import Foundation

// MARK: - Gemini Key Failover errors

public enum GeminiKeyFailoverError: Error, LocalizedError, Sendable {
    case noEnabledKeys
    /// R4-P2-2：所有 tier 均失败时的稳定 typed error，替代裸 NSError
    /// domain "GeminiKeyFailover" code -2。最后失败原因只进日志，UI 走
    /// `UserFacingErrorMapper`。
    case allTiersExhausted(lastFailureDescription: String?)

    public var errorDescription: String? {
        switch self {
        case .noEnabledKeys:
            return "没有启用的 Gemini Key。请到「设置」添加。"
        case .allTiersExhausted:
            return "所有可用的 Gemini Key 均已失败。"
        }
    }
}

// MARK: - Tier Escalation Event

/// Why a cleanup chunk moved from one key tier to another.
public enum TierEscalationReason: Sendable, Equatable {
    /// Every key in the current tier is cooling down after a 429 response.
    case rateLimitCooldown
    /// Gemini returned a retryable server-overload status such as 529 or 5xx.
    case serverOverload(statusCode: Int)

    var userFacingDescription: String {
        switch self {
        case .rateLimitCooldown:
            return "429 限流冷却"
        case let .serverOverload(statusCode):
            return "\(statusCode) 服务过载"
        }
    }
}

/// Recorded when tier exhaustion or server overload escalates the key pool cursor to a higher tier.
public struct TierEscalationEvent: Sendable, Equatable {
    public let chunkIndex: Int
    public let fromTier: Int
    public let toTier: Int
    public let fromKeyLabel: String
    public let toKeyLabel: String
    public let reason: TierEscalationReason

    public init(
        chunkIndex: Int,
        fromTier: Int,
        toTier: Int,
        fromKeyLabel: String,
        toKeyLabel: String,
        reason: TierEscalationReason = .rateLimitCooldown
    ) {
        self.chunkIndex = chunkIndex
        self.fromTier = fromTier
        self.toTier = toTier
        self.fromKeyLabel = fromKeyLabel
        self.toKeyLabel = toKeyLabel
        self.reason = reason
    }

    public var userFacingDescription: String {
        "chunk \(chunkIndex) 因 \(reason.userFacingDescription) 升至 Tier \(toTier)"
    }
}

// MARK: - Gemini Key Failover（sticky key index + retry）

/// 多 key 池：sticky (tier, priority) 优先
/// 跟 FunASR-Mac `llm_cleanup.py::GeminiProvider._clean_chunk` 行为一致
///
/// Tier 升级行为：
/// - 429 (per-key 限流) → 同 tier 内切下一个 priority
/// - 5xx / 529 (server overload) → 升 tier（用更贵的 key 兜底）
/// - 4xx / auth / schema → 直接抛，不切 key
/// 一个 cleanup run 共享的可变 key-pool 状态。
/// actor 隔离 sticky cursor、冷却时间和计数器，避免未来并发 cleanup 调用在
/// `@unchecked Sendable` class 上竞争并写出错误的 key 选择。
public actor GeminiKeyFailover {
    /// 过滤并排序后的 key 配置初始化后不再变化，允许同步读取；所有可变选择状态仍由 actor 隔离。
    public nonisolated let keys: [APIKeyConfig]
    public let model: String
    public let temperature: Double
    /// Sticky cursor：上次成功 chunk 用的 (tier, idxInTier)。失败时按规则 advance。
    public private(set) var currentTier: Int
    public private(set) var currentIdxInTier: Int
    /// 记录当前 cleanup run 中因为 529 / 5xx 升 tier 的事件列表。
    public private(set) var tierEscalations: [TierEscalationEvent] = []
    /// URLSession 注入（默认走 makeSession()）；测试时用 URLProtocol mock 接管。
    public let session: URLSession


    /// 生产用 session：走系统代理配置、waitsForConnectivity = true。
    /// 注意：每个 GeminiKeyFailover 实例持有独立 session，请勿频繁新建。
    public static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true          // 等连接就绪（不立即报 not-connected）
        config.timeoutIntervalForResource = 300     // 整个请求资源最长 5 分钟
        config.timeoutIntervalForRequest = 60       // 单次 TCP 读写 60s（配合 per-request timeout）
        // URLSession.default 默认已继承系统代理（ProxySettings），无需额外设置
        return URLSession(configuration: config)
    }

    /// 当前 chunk 成功用到的 key id（用于 LLMCleanupService 更新 lastUsedAt）
    /// 每次 callOnce 成功后会更新。chunk 间保留（sticky）。
    public private(set) var currentSuccessfulKeyId: String?

    /// 当前 chunk 内累计的 429 (per-key rate limit) 次数。
    /// 每次 `callOnce` 开始时 reset (在 walkKeyPool 顶部)。
    /// UI 在 progress 文本里展示 "429×N"，让用户看到 free tier 配额压力。
    public private(set) var rateLimitCount: Int = 0

    /// 当前 chunk 内累计的 5xx / 529 (server overload) 次数。
    /// 同上：每次 callOnce reset，UI 展示 "529×N" 反映上游压力。
    public private(set) var serverOverloadCount: Int = 0

    /// Per-key 冷却状态（in-memory）：keyId → 可重用时间。
    /// - 429 RPM/TPM：notUseBefore = now + retryDelay（约 55s）
    /// - 429 RPD（今日用尽）：notUseBefore = now + 6H
    /// App 重启自动清零（不写 settings.json）。
    private var notUseBeforeByKeyId: [String: Date] = [:]

    /// 测试 / 调试用：取某个 key 的冷却截止时间。
    public func notUseBefore(for keyId: String) -> Date? { notUseBeforeByKeyId[keyId] }

    /// 拿当前 sticky key 的完整 APIKeyConfig（debug/UI 用）
    public var currentKey: APIKeyConfig? {
        let (tier, idx) = (currentTier, currentIdxInTier)
        let bucket = bucketByTier()[tier] ?? []
        guard idx < bucket.count else { return nil }
        return bucket[idx]
    }

    /// 当前 sticky key 在排序后 pool 里的下标。给老测试和 UI 用；
    /// walkKeyPool 内部按 (tier, idxInTier) 走，不读这个字段。
    public var currentIdx: Int {
        // keys 已经按 (tier ASC, priority ASC) 排序，所以同 tier 的 keys
        // 是 contiguous 区间。idxInTier 是这个区间里的偏移。scan 一次
        // 找到匹配位置即可——只在 sticky 之后被 UI 读，开销不重要。
        var inTier = 0
        for (i, k) in keys.enumerated() {
            if k.tier == currentTier {
                if inTier == currentIdxInTier { return i }
                inTier += 1
            }
        }
        return 0
    }

    public init(
        keys: [APIKeyConfig],
        model: String = "gemini-flash-latest",
        temperature: Double = 0.2,
        session: URLSession? = nil
    ) {
        self.session = session ?? GeminiKeyFailover.makeSession()
        // 按 (tier ASC, priority ASC) 排序
        // 跟 FunASR-Mac `services/api_key_vault.py::get_key_pool_for_cleanup` 一致
        let sorted = keys
            .filter(\.isUsableGeminiKey)
            .sorted { lhs, rhs in
                if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
                return lhs.priority < rhs.priority
            }
        self.keys = sorted
        self.model = model
        self.temperature = temperature
        // 初始 cursor：最便宜 tier 的第一个 priority。
        if let first = sorted.first {
            self.currentTier = first.tier
            self.currentIdxInTier = 0
        } else {
            self.currentTier = 0
            self.currentIdxInTier = 0
        }
    }

    /// 按 tier 分桶。返回 (buckets, sortedTiers)。每个 bucket 内部按 priority 升序。
    private func bucketByTier() -> [Int: [APIKeyConfig]] {
        var buckets: [Int: [APIKeyConfig]] = [:]
        for k in keys {
            buckets[k.tier, default: []].append(k)
        }
        return buckets
    }

    /// 调一次（sticky (tier, idx) + retry + tier 升级，paragraph 模式）
    /// 行为：
    /// - 429 (per-key) → 标记当前 key 冷却 → 同 tier 内切下一个 priority
    /// - 5xx / 529 (overload) → 跳出当前 tier，**升 tier**（用更贵 key 兜底）
    /// - 4xx / auth / schema → 直接抛
    /// 成功 → 把 (currentTier, currentIdxInTier) pin 到成功的 key
    public func callOnceParagraphs(prompt: String, chunkIndex: Int = 1) async throws -> [String] {
        guard !keys.isEmpty else {
            throw GeminiKeyFailoverError.noEnabledKeys
        }
        return try await walkKeyPool(prompt: prompt, chunkIndex: chunkIndex)
    }

    /// 从指定 tier 的 fromIdx 开始，找第一个 notUseBefore 已过期（或未设置）的 key。
    /// 整个 tier 全在冷却中 → 返回 nil（调用方升 tier）。
    /// `internal` 以便测试直接验证跳过行为。
    func selectEligibleKey(
        inTier tier: Int,
        fromIdx: Int,
        buckets: [Int: [APIKeyConfig]]
    ) -> (idx: Int, key: APIKeyConfig)? {
        let now = Date()
        guard let keysInTier = buckets[tier] else { return nil }
        for i in fromIdx..<keysInTier.count {
            let key = keysInTier[i]
            if let until = notUseBeforeByKeyId[key.id], until > now {
                Logger.shared.info(
                    "GeminiKeyFailover: key[\(key.label)] 冷却中，跳过（NotUseBefore=\(until)）"
                )
                continue
            }
            return (i, key)
        }
        return nil
    }

    /// 429 时记录冷却截止时间：
    /// - isRPD → now + 6H（今日用尽，短窗口重试无意义）
    /// - 其他 → now + retryDelaySecs（RPM/TPM 窗口冷却）
    private func markKeyCoolingDown(_ key: APIKeyConfig, retryDelaySecs: Double, isRPD: Bool) {
        let cooldown: TimeInterval = isRPD ? 6 * 3_600 : retryDelaySecs
        let until = Date().addingTimeInterval(cooldown)
        notUseBeforeByKeyId[key.id] = until
        let label = isRPD ? "6H(RPD)" : "\(Int(retryDelaySecs.rounded()))s"
        Logger.shared.warn(
            "GeminiKeyFailover: key[\(key.label)] 429 冷却 \(label)，NotUseBefore=\(until)"
        )
    }

    /// 共享的 key-pool 走查（paragraph 模式）。
    /// 主循环：找可用 key → 调用 → 429 标记冷却切下一个 → 整 tier 冷却则升 tier → 5xx 直接升 tier。
    private func walkKeyPool(prompt: String, chunkIndex: Int = 1) async throws -> [String] {
        // 每次 callOnce reset per-chunk 计数。LLMCleanupService 在
        // onProgress 回调里读这两个数展示给用户（"3/12 chunks · 429×2 · 529×1"）。
        rateLimitCount = 0
        serverOverloadCount = 0

        let buckets = bucketByTier()
        let sortedTiers = buckets.keys.sorted()

        // sticky tier 失效（key 被删光了）→ 重置到最便宜 tier 的 0
        if buckets[currentTier] == nil, let first = sortedTiers.first {
            currentTier = first
            currentIdxInTier = 0
        }

        var lastError: Error?

        tierLoop: for tier in sortedTiers where tier >= currentTier {
            // 同 tier 内从 sticky idx 开始找（切 tier 时从头找）
            var startIdx = (tier == currentTier) ? currentIdxInTier : 0

            innerLoop: while true {
                // 找第一个 notUseBefore 已过的 key；整 tier 冷却 → 升 tier
                guard let (idx, key) = selectEligibleKey(inTier: tier, fromIdx: startIdx, buckets: buckets) else {
                    Logger.shared.warn(
                        "GeminiKeyFailover: tier=\(tier) 全部 key 冷却中，升 tier"
                    )
                    if let nextTier = sortedTiers.first(where: { $0 > tier }) {
                        let fromKeyLabel = buckets[tier]?.first?.label ?? "Tier \(tier)"
                        let nextKeyLabel = buckets[nextTier]?.first?.label ?? "Tier \(nextTier)"
                        let event = TierEscalationEvent(
                            chunkIndex: chunkIndex,
                            fromTier: tier,
                            toTier: nextTier,
                            fromKeyLabel: fromKeyLabel,
                            toKeyLabel: nextKeyLabel,
                            reason: .rateLimitCooldown
                        )
                        if !tierEscalations.contains(event) {
                            tierEscalations.append(event)
                        }
                    }
                    continue tierLoop
                }

                let provider = GeminiProvider(
                    apiKey: key.keyValue, model: model, temperature: temperature, session: session
                )
                do {
                    let result = try await provider.callOnceParagraphs(prompt: prompt)
                    // 成功：pin sticky cursor
                    currentTier = tier
                    currentIdxInTier = idx
                    currentSuccessfulKeyId = key.id
                    return result
                } catch is PipelineCancelled {
                    throw PipelineCancelled(stage: "cleanup")
                } catch is CleanupCancelled {
                    throw CleanupCancelled()
                } catch {
                    // URLSession 在请求进行中响应 Task.cancel() 时通常抛
                    // URLError.cancelled；它必须保持取消语义，不能被记成润色失败。
                    if Task.isCancelled || (error as NSError).code == NSURLErrorCancelled {
                        throw CleanupCancelled()
                    }
                    // 不可重试（4xx / auth / schema）→ 直接抛
                    if !GeminiProvider.isRetryable(error) {
                        throw error
                    }
                    lastError = error
                    if GeminiProvider.isRateLimit(error) {
                        // 429：标记冷却，同 tier 继续找下一个可用 key
                        // Typed-error path (GeminiProviderError.httpError carries
                        // retryDelaySecs + isRPD explicitly); NSError path
                        // (URLSession / external SDK) reads from userInfo.
                        let retryDelaySecs: Double
                        let isRPD: Bool
                        if let provider = error as? GeminiProviderError,
                           case let .httpError(_, _, delay, rpd) = provider {
                            retryDelaySecs = delay ?? 60.0
                            isRPD = rpd
                        } else {
                            let nsError = error as NSError
                            retryDelaySecs = nsError.userInfo["retryDelaySecs"] as? Double ?? 60.0
                            isRPD = nsError.userInfo["isRPD"] as? Bool ?? false
                        }
                        markKeyCoolingDown(key, retryDelaySecs: retryDelaySecs, isRPD: isRPD)
                        rateLimitCount += 1
                        startIdx = idx + 1   // 从下一个开始找
                        continue innerLoop
                    } else {
                        // 5xx / 529：升 tier
                        serverOverloadCount += 1
                        let codeForLog: Int = {
                            if let provider = error as? GeminiProviderError,
                               case let .httpError(code, _, _, _) = provider {
                                return code
                            }
                            return (error as NSError).code
                        }()
                        Logger.shared.warn(
                            "GeminiKeyFailover: tier=\(tier) key[\(key.label)] 服务端过载 (code=\(codeForLog))，升 tier"
                        )
                        if let nextTier = sortedTiers.first(where: { $0 > tier }) {
                            let nextKeyLabel = buckets[nextTier]?.first?.label ?? "Tier \(nextTier)"
                            let event = TierEscalationEvent(
                                chunkIndex: chunkIndex,
                                fromTier: tier,
                                toTier: nextTier,
                                fromKeyLabel: key.label,
                                toKeyLabel: nextKeyLabel,
                                reason: .serverOverload(statusCode: codeForLog)
                            )
                            if !tierEscalations.contains(event) {
                                tierEscalations.append(event)
                            }
                        }
                        continue tierLoop
                    }
                }
            }
        }


        // R4-P2-2：兜底走 typed error，避免裸 NSError 冒泡到 UI。最后失败
        // 原因作为 debug-only payload 保留，调用方/日志可定位，UI 走统一
        // mapper 不会展示。
        let lastDescription = (lastError as? LocalizedError)?.errorDescription
            ?? lastError.map { String(describing: type(of: $0)) }
        throw lastError.map { _ in
            GeminiKeyFailoverError.allTiersExhausted(
                lastFailureDescription: lastDescription
            )
        } ?? GeminiKeyFailoverError.allTiersExhausted(lastFailureDescription: nil)
    }
}
