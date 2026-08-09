import Foundation

/// Settings schema and defaults kept apart from the persistence façade.
extension SettingsStore {
    /// 润色设置默认值（跟 FunASR-Mac `services/llm_cleanup.py::_default_prompt` 一致）
    public enum CleanupDefaults {
        public static let model: String = "gemini-flash-latest"
        /// chunk 字符数。UI 用 Slider 选，范围 2000-12000、step 500、默认 6000。
        /// 过大导致 Gemini 生成时间过长 / 响应体卡住超时；过小则片段碎、重写上下文丢失。
        public static let chunkChars: Int = 6000
        public static let temperature: Double = 0.2
        public static let prompt: String = """
        你是中文语音转写稿的精校助手。请逐段清理：
        1. 删除口水词（啊/嗯/呃/那个/就是说 等无意义助词）
        2. 修正明显的同音错字（结合上下文）
        3. 优先采用术语表中的标准写法，尤其是人名、项目名、多音字、多义词
        4. 保留说话人标签和段落顺序
        5. 保守改写，不要补全说话人没说过的内容
        """
    }

    /// 润色配置（Phase 4 / A4）
    public struct CleanupSettings: Codable, Equatable, Sendable {
        public var model: String
        public var chunkChars: Int
        public var temperature: Double
        public var prompt: String

        public init(
            model: String = CleanupDefaults.model,
            chunkChars: Int = CleanupDefaults.chunkChars,
            temperature: Double = CleanupDefaults.temperature,
            prompt: String = CleanupDefaults.prompt
        ) {
            self.model = model
            self.chunkChars = chunkChars
            self.temperature = temperature
            self.prompt = prompt
        }

        private enum CodingKeys: String, CodingKey {
            case model, chunkChars, temperature, prompt
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                model: (try? c.decode(String.self, forKey: .model)) ?? CleanupDefaults.model,
                chunkChars: (try? c.decode(Int.self, forKey: .chunkChars)) ?? CleanupDefaults.chunkChars,
                temperature: (try? c.decode(Double.self, forKey: .temperature)) ?? CleanupDefaults.temperature,
                prompt: (try? c.decode(String.self, forKey: .prompt)) ?? CleanupDefaults.prompt
            )
        }
    }

    /// 转写队列的产品策略；顺序存于 SwiftData job，暂停/自动继续存于 settings。
    public struct QueueSettings: Codable, Equatable, Sendable {
        public var isPaused: Bool
        public var automaticallyStartNext: Bool

        public init(isPaused: Bool = false, automaticallyStartNext: Bool = true) {
            self.isPaused = isPaused
            self.automaticallyStartNext = automaticallyStartNext
        }

        private enum CodingKeys: String, CodingKey {
            case isPaused, automaticallyStartNext
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                isPaused: (try? c.decode(Bool.self, forKey: .isPaused)) ?? false,
                automaticallyStartNext:
                    (try? c.decode(Bool.self, forKey: .automaticallyStartNext)) ?? true
            )
        }
    }

    /// On-disk schema with lossy decoding for individual legacy entries.
    struct SettingsBlob: Codable {
        private struct Lossy<Element: Decodable>: Decodable {
            let value: Element?

            init(from decoder: Decoder) throws {
                value = try? Element(from: decoder)
            }
        }

        var apiKeys: [APIKeyConfig] = []
        var glossary: [String] = []
        var cleanup: CleanupSettings?
        var queue: QueueSettings?

        private enum CodingKeys: String, CodingKey {
            case apiKeys, glossary, cleanup, queue
        }

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            apiKeys = ((try? c.decode([Lossy<APIKeyConfig>].self, forKey: .apiKeys)) ?? [])
                .compactMap(\.value)
            glossary = ((try? c.decode([Lossy<String>].self, forKey: .glossary)) ?? [])
                .compactMap(\.value)
            cleanup = try? c.decodeIfPresent(CleanupSettings.self, forKey: .cleanup)
            queue = try? c.decodeIfPresent(QueueSettings.self, forKey: .queue)
        }
    }
}
