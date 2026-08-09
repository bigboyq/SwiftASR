import Foundation
import SwiftData

/// Job 状态机（pipeline + cleanup 共用）。原始值直接对应 SwiftData 列里的字符串，
/// 这样换 enum 不需要 SwiftData migration。
/// - pipeline 状态用 `ASRJob.status` (String) + `ASRJob.jobStatus` (enum) 双重接口。
/// - cleanup 状态用 `ASRJob.cleanupStatus` (String?) + `ASRJob.cleanupJobStatus` (enum?) 双重接口。
public enum JobStatus: String, Sendable, Hashable {
    case queued
    case running
    case processing
    case done
    case failed
    case cancelled
    /// ASR + Punc 完结、Speaker 失败的 partial 状态。
    /// 此时 result.json 已派生（segments 用 ASR 句子，speaker 标 "Speaker1" 占位），
    /// UI 能看到 ASR 结果。点 "重新识别说话人" 重跑 speaker 阶段即可补完。
    case partial

    /// 未知值 → nil，让调用方显式选 fallback 行为。
    public init?(rawValueString: String) {
        self.init(rawValue: rawValueString)
    }
}

/// 可恢复的用户可见操作。它与 pipeline 的 jobStatus 分离：例如 speaker-only
/// 重识别失败时，原 result.json 仍是 `.done`，但最近一次操作必须能准确呈现失败。
public enum JobOperationKind: String, Sendable, Hashable {
    case transcription
    case speakerReidentification
}

public enum JobOperationStatus: String, Sendable, Hashable {
    case running
    case succeeded
    case failed
    case cancelled
}

/// 持久化在队列里的用户意图。`jobStatus == .queued` 只能说明任务在等待，
/// 还需要这个字段区分完整转写、覆盖式重新转写和 speaker-only 重跑。
public enum QueuedJobOperationKind: String, Sendable, Hashable {
    case transcription
    case retranscription
    case speakerReidentification
}

@Model
public final class ASRJob {
    @Attribute(.unique) public var id: String
    public var sourceAudioPath: String
    public var sourceAudioHash: String
    public var durationSeconds: Double
    public var mode: String
    public var asrBackend: String
    public var speakerBackend: String
    public var device: String
    public var status: String
    /// LLM 润色状态：nil = 未润色，`JobStatus` 之一。
    /// 跟 `status`（pipeline 状态）独立：转写完后再点润色才有 cleanupStatus。
    /// 启动时若发现 `.running`（app 中断）→ 视为未润色，重置为 nil。
    public var cleanupStatus: String?
    public var errorMessage: String?
    /// Job 加入系统时间（用户添加文件 / 创建 job 的时刻，SwiftData row insert 时间）。
    /// 内部字段名 `createdAt`（跟 SwiftData 习惯一致，不改名以避免 lightweight migration 误判为
    /// "新增 mandatory 字段"），UI 显示叫"添加时间"以区分 finishedAt / cleanedAt。
    public var createdAt: Date
    /// 整个 pipeline（含 ASR + speaker）完成时间。失败/取消时为 nil。
    public var finishedAt: Date?
    /// LLM 润色完成时间。cleanup 没跑过 / 失败时为 nil。
    public var cleanedAt: Date? = nil

    /// 各阶段的实际 wall time（秒）。不包含排队、用户等待或任务间隔；旧任务默认 0。
    /// - asr: PCM 解码 + fbank + VAD/ASR 流水线 + 标点
    /// - speaker: 说话人 embedding、聚类和边界细化
    /// - llm: 一次或多次实际润色运行的累计 wall time
    public var asrProcessingSeconds: Double = 0
    public var speakerProcessingSeconds: Double = 0
    public var llmProcessingSeconds: Double = 0

    // Pipeline 实时进度（5 阶段：load/vad/asr/punc/speaker；空串=未开始，"done"=已完成）
    // FileActionCoordinator 接收 onProgress 后更新内存状态；JobLifecycleStore
    // 会按阶段/进度阈值节流持久化，UI 端读这 3 个字段画 5 步 checklist。
    // SwiftData 给非 optional 字段补默认值是 safe migration（旧库自动获得空值）。
    public var pipelineStage: String = ""
    public var pipelineFraction: Double = 0.0
    public var pipelineMessage: String = ""

    /// 排队顺序：数值越小越先运行。旧任务默认 0，首次排队时会自动归一化。
    public var queueOrder: Int = 0

    /// 队列任务真正启动时要执行的操作。旧版本任务为空时按完整转写兼容。
    public var queuedOperationKind: String? = nil
    /// speaker-only 排队操作失败时恢复到入队前的 pipeline 状态。
    public var queuedRestoreStatus: String? = nil
    public var queuedRestoreFinishedAt: Date? = nil

    /// 最近一次独立操作的结构化结果，不能再从 pipelineMessage 的展示文案推断。
    public var lastOperationKind: String? = nil
    public var lastOperationStatus: String? = nil
    public var lastOperationMessage: String? = nil
    public var lastOperationAt: Date? = nil

    // result.json 路径（stage/<hash[:2]>/<hash[2:4]>/<hash>.result.json）。
    // job 跑完时由 FileActionCoordinator 写入；文件与结果工作区直接展示这些持久化字段。
    public var transcriptPath: String? = nil

    // 派生统计在 pipeline 完成时写回，避免工作区列表为了显示状态反复读取 result.json。
    // done 的 job 必有；processing/queued/failed 必为 0 / nil。
    public var namedSpeakers: Int = 0
    public var totalSpeakers: Int = 0
    public var cleanedModel: String? = nil
    /// Last cross-medium result replacement committed with this row. Startup
    /// recovery compares it with a result transaction manifest to close the
    /// filesystem/SwiftData crash window.
    public var resultTransactionID: String? = nil
    /// Last artifact-deletion transaction committed with this row. This is
    /// mainly used by retranscription, where the job survives artifact
    /// removal; deleting a job is represented by the row being absent.
    public var artifactDeletionTransactionID: String? = nil

    /// Job-local contributions to the global speaker library. Deleting a job
    /// removes these rows, but never removes the global profiles themselves.
    @Relationship(deleteRule: .cascade, inverse: \JobSpeakerProfileOccurrence.job)
    public var speakerOccurrences: [JobSpeakerProfileOccurrence] = []

    public init(
        id: String = UUID().uuidString,
        sourceAudioPath: String,
        sourceAudioHash: String,
        durationSeconds: Double,
        mode: String = "turbo",
        asrBackend: String = "paraformer",
        speakerBackend: String = "eres2netv2",
        device: String = "auto",
        status: String = JobStatus.queued.rawValue,
        cleanupStatus: String? = nil,
        errorMessage: String? = nil,
        createdAt: Date = Date(),
        finishedAt: Date? = nil,
        cleanedAt: Date? = nil,
        asrProcessingSeconds: Double = 0,
        speakerProcessingSeconds: Double = 0,
        llmProcessingSeconds: Double = 0,
        pipelineStage: String = "",
        pipelineFraction: Double = 0.0,
        pipelineMessage: String = "",
        queueOrder: Int = 0,
        queuedOperationKind: String? = nil,
        queuedRestoreStatus: String? = nil,
        queuedRestoreFinishedAt: Date? = nil,
        lastOperationKind: String? = nil,
        lastOperationStatus: String? = nil,
        lastOperationMessage: String? = nil,
        lastOperationAt: Date? = nil,
        transcriptPath: String? = nil,
        namedSpeakers: Int = 0,
        totalSpeakers: Int = 0,
        cleanedModel: String? = nil,
        resultTransactionID: String? = nil,
        artifactDeletionTransactionID: String? = nil
    ) {
        self.id = id
        self.sourceAudioPath = sourceAudioPath
        self.sourceAudioHash = sourceAudioHash
        self.durationSeconds = durationSeconds
        self.mode = mode
        self.asrBackend = asrBackend
        self.speakerBackend = speakerBackend
        self.device = device
        self.status = status
        self.cleanupStatus = cleanupStatus
        self.errorMessage = errorMessage
        self.createdAt = createdAt
        self.finishedAt = finishedAt
        self.cleanedAt = cleanedAt
        self.asrProcessingSeconds = asrProcessingSeconds
        self.speakerProcessingSeconds = speakerProcessingSeconds
        self.llmProcessingSeconds = llmProcessingSeconds
        self.pipelineStage = pipelineStage
        self.pipelineFraction = pipelineFraction
        self.pipelineMessage = pipelineMessage
        self.queueOrder = queueOrder
        self.queuedOperationKind = queuedOperationKind
        self.queuedRestoreStatus = queuedRestoreStatus
        self.queuedRestoreFinishedAt = queuedRestoreFinishedAt
        self.lastOperationKind = lastOperationKind
        self.lastOperationStatus = lastOperationStatus
        self.lastOperationMessage = lastOperationMessage
        self.lastOperationAt = lastOperationAt
        self.transcriptPath = transcriptPath
        self.namedSpeakers = namedSpeakers
        self.totalSpeakers = totalSpeakers
        self.cleanedModel = cleanedModel
        self.resultTransactionID = resultTransactionID
        self.artifactDeletionTransactionID = artifactDeletionTransactionID
    }
}

public extension ASRJob {
    /// `status: String` 的 enum 视图。解析失败（历史数据 / 未来加新值）→ 兜底为 `.failed`。
    /// 写新代码时优先用这个，避免直接比较字符串字面量。
    var jobStatus: JobStatus {
        get { JobStatus(rawValue: status) ?? .failed }
        set { status = newValue.rawValue }
    }

    /// `cleanupStatus: String?` 的 enum 视图。nil = 没润色过。
    /// 通过 setter 写入可以 `job.cleanupJobStatus = .running`，
    /// 避免调用方手写 `.rawValue` 转换。
    var cleanupJobStatus: JobStatus? {
        get { cleanupStatus.flatMap(JobStatus.init(rawValue:)) }
        set { cleanupStatus = newValue?.rawValue }
    }

    /// 当前 result 的润色完成标记。单独的 cleanupStatus 可能残留于旧版本或
    /// 重跑过程，因此必须同时存在完成时间才允许列表显示“已润色”。
    var hasCleanupCompletion: Bool {
        cleanupJobStatus == .done && cleanedAt != nil
    }

    var latestOperationKind: JobOperationKind? {
        lastOperationKind.flatMap(JobOperationKind.init(rawValue:))
    }

    var latestOperationStatus: JobOperationStatus? {
        lastOperationStatus.flatMap(JobOperationStatus.init(rawValue:))
    }

    var queuedOperation: QueuedJobOperationKind {
        queuedOperationKind.flatMap(QueuedJobOperationKind.init(rawValue:)) ?? .transcription
    }

    var queuedRestoreJobStatus: JobStatus? {
        queuedRestoreStatus.flatMap(JobStatus.init(rawValue:))
    }

    /// UI 排序用的"最近一次活动"时间戳。
    ///
    /// 取所有持久化时间戳的最大值（max 链 `lastOperationAt → cleanedAt → finishedAt → createdAt`）。
    /// - 重新转写 / 重新识别说话人 时 `lastOperationAt` 刷新 → 列表立即冒到顶
    /// - LLM 润色 完成时 `cleanedAt` 刷新 → 同样会冒到顶
    /// - pipeline 首次跑完时 `finishedAt` 刷新 → 完成历史冒到顶
    /// - 未跑过任何操作的 job 退回到 `createdAt`（添加时间）作为兜底
    ///
    /// UI 层（Sidebar / FilesWorkspace / ResultHistoryQuery）应该统一用这个字段做"最近项目"
    /// 排序,不要再用 `createdAt`（添加时间不会因重新转写/润色/重识别而更新 → 排序不响应）。
    var mostRecentActivity: Date {
        var latest = createdAt
        if let v = finishedAt, v > latest { latest = v }
        if let v = cleanedAt, v > latest { latest = v }
        if let v = lastOperationAt, v > latest { latest = v }
        return latest
    }
}
