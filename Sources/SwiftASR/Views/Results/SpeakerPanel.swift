import SwiftUI

// MARK: - SpeakerSuggestion

struct SpeakerSuggestion: Equatable {
    enum Confidence { case high, medium, low }
    let personName: String
    let personId: String
    let score: Float
    let confidence: Confidence
    /// 按指纹排序后聚合的前三名人物；主行只显示第一名，悬浮提示显示完整列表。
    let matches: [SpeakerMatcher.PersonMatch]
    /// 浮窗专用候选；通常剔除了相似度过高的自指纹。
    let hoverMatches: [SpeakerMatcher.PersonMatch]?

    init(
        personName: String,
        personId: String,
        score: Float,
        confidence: Confidence,
        matches: [SpeakerMatcher.PersonMatch] = [],
        hoverMatches: [SpeakerMatcher.PersonMatch]? = nil
    ) {
        self.personName = personName
        self.personId = personId
        self.score = score
        self.confidence = confidence
        self.matches = matches
        self.hoverMatches = hoverMatches
    }

    var hoverText: String {
        let displayMatches = hoverMatches ?? matches
        if displayMatches.isEmpty {
            return hoverMatches == nil
                ? "参考: \(personName)(\(Self.format(score)))"
                : "没有其他可参考的指纹"
        }
        return displayMatches.enumerated().map { index, match in
            "\(index + 1). \(match.personName)（\(Self.formatRange(min: match.minScore, max: match.maxScore))）指纹\(match.fingerprintCount)个"
        }.joined(separator: "\n")
    }

    private static func format(_ score: Float) -> String {
        String(format: "%.2f", score)
    }

    private static func formatRange(min: Float, max: Float) -> String {
        abs(max - min) < 0.005 ? format(max) : "\(format(min))~\(format(max))"
    }
}

// MARK: - SpeakerPanel (左侧命名面板)

struct SpeakerPanel: View {
    let distinctSpeakers: [String]
    @Binding var inScopeLabels: Set<String>
    let speakerNames: [String: String]
    let suggestions: [String: SpeakerSuggestion]
    let allPersonNames: [String]
    let speakerDurations: [String: Int]  // speaker label → 该 speaker 所有 segment 累计 ms
    /// 当前 job 的 Split Set。仅作用于 result.json 的操作层，绝不修改声纹库。
    let splitProfileLabels: Set<String>
    /// Only labels backed by an acoustic profile in speaker-routing.json can
    /// be replayed. The system `Speaker` sentinel is intentionally excluded.
    let splittableProfileLabels: Set<String>
    /// Packed-window 到 profile centroid 的均值余弦。缺失表示历史 snapshot
    /// 没有该元数据，不显示质量颜色。
    let profileCohesions: [String: Float]
    /// 同一次 prospective Split Set replay 生成的 hover 文案；与点击后的
    /// 分拆预检弹窗共用同一格式。
    let splitPreviewTooltips: [String: String]
    let onToggleIncluded: (String, Bool) -> Void
    /// Bulk include/exclude every speaker in one batch (avoids N full-JSON
    /// writes when "全选/全不选" toggles many speakers).
    let onSetAllIncluded: (Bool) -> Void
    /// 已在 Split Set 的 Profile 不可作为有效 speaker 勾选；点击 checkbox
    /// 时由 ResultsContent 说明必须先取消混合标记。
    let onAttemptToggleSplitProfileIncluded: (String) -> Void
    let onToggleSplitProfile: (String) -> Void
    let onSelectPerson: (String, String?) -> Void
    /// 从结果页直接新增人物，并把新人物绑定给当前 speaker。
    let onRequestCreatePerson: (String) -> Void
    /// 点击 speaker 行的 chevron 时触发：滚到该 speaker 下一个匹配位置。
    let onJumpToNext: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(distinctSpeakers, id: \.self) { label in
                        SpeakerRow(
                            label: label,
                            isIncluded: inScopeLabels.contains(label),
                            selectedPersonName: speakerNames[label],
                            suggestion: suggestions[label],
                            personNames: allPersonNames,
                            durationMs: speakerDurations[label] ?? 0,
                            isMarkedMixed: splitProfileLabels.contains(label),
                            canSplitProfile: splittableProfileLabels.contains(label),
                            cohesion: profileCohesions[label],
                            splitPreviewTooltip: splitPreviewTooltips[label],
                            onToggle: { included in
                                onToggleIncluded(label, included)
                            },
                            onAttemptToggleMarkedMixed: {
                                onAttemptToggleSplitProfileIncluded(label)
                            },
                            onToggleMixed: {
                                onToggleSplitProfile(label)
                            },
                            onSelectPerson: { name in
                                onSelectPerson(label, name)
                            },
                            onRequestCreatePerson: {
                                onRequestCreatePerson(label)
                            },
                            onJumpToNext: {
                                onJumpToNext(label)
                            }
                        )
                    }
                }
                // SpeakerRow 自身左右各 6pt；面板宽度正好是菜单宽度 + 12pt。
                .padding(.vertical, 8)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("说话人", systemImage: "person.2")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(inScopeLabels.count)/\(distinctSpeakers.count)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("全选") { onSetAllIncluded(true) }
                    .controlSize(.mini).buttonStyle(.borderless)
                Button("全不选") { onSetAllIncluded(false) }
                    .controlSize(.mini).buttonStyle(.borderless)
            }
            .font(.caption)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08))
    }
}

struct SpeakerRow: View {
    let label: String
    let isIncluded: Bool
    let selectedPersonName: String?
    let suggestion: SpeakerSuggestion?
    let personNames: [String]
    let durationMs: Int
    let isMarkedMixed: Bool
    let canSplitProfile: Bool
    let cohesion: Float?
    let splitPreviewTooltip: String?
    let onToggle: (Bool) -> Void
    let onAttemptToggleMarkedMixed: () -> Void
    let onToggleMixed: () -> Void
    let onSelectPerson: (String?) -> Void
    let onRequestCreatePerson: () -> Void
    /// 点击 chevron 时触发；ResultsContent 负责把右侧 preview 滚到该 speaker
    /// 下一个匹配位置。每个 speaker 独立 cursor，到底 wrap 回第一个。
    let onJumpToNext: () -> Void

    /// "1分23秒" / "1时23分"（按 durationMs 自动选）
    private var durationText: String {
        let totalSec = max(durationMs, 0) / 1000
        if totalSec < 60 { return "\(totalSec)秒" }
        if totalSec < 3600 {
            return "\(totalSec / 60)分\(totalSec % 60)秒"
        }
        let h = totalSec / 3600
        let m = (totalSec % 3600) / 60
        let s = totalSec % 60
        return s > 0 ? "\(h)时\(m)分\(s)秒" : "\(h)时\(m)分"
    }

    private var isHighCohesion: Bool {
        guard let cohesion else { return false }
        return cohesion >= 0.65
    }

    private var splitHelp: String {
        if let splitPreviewTooltip, !splitPreviewTooltip.isEmpty {
            return splitPreviewTooltip
        }
        if isMarkedMixed { return "取消混合标记并按当前集合重新计算" }
        if !canSplitProfile { return "系统兜底 Speaker 不对应声学 Profile，不能执行分拆" }
        if isHighCohesion { return "聚集度达到 65%，该 Profile 较稳定；分拆前会要求确认" }
        return "正在准备分拆预览…"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Toggle("", isOn: Binding(
                    get: { isMarkedMixed ? false : isIncluded },
                    set: { value in
                        if isMarkedMixed {
                            onAttemptToggleMarkedMixed()
                        } else {
                            onToggle(value)
                        }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.checkbox)
                Text(label)
                    .font(.subheadline)
                // 该 speaker 所有 segment 累计时长（mm:ss 或 hh:mm:ss）
                Text(durationText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                // 同一行紧邻跳转箭头；不额外占用“名字”行，避免说话人
                // 编号、时长和分拆状态被拆成两行。
                Button {
                    onToggleMixed()
                } label: {
                    Image(systemName: isMarkedMixed ? "arrow.uturn.backward" : "exclamationmark.triangle")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isHighCohesion ? Color.red : Color.secondary)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(!isMarkedMixed && !canSplitProfile)
                .help(splitHelp)
                .accessibilityLabel(isMarkedMixed ? "取消\(label)的混合标记" : "标记\(label)为混合")
                // 跳到下一个匹配位置：方便用户在 SpeakersTab 命名时快速定位
                // 这个 speaker 到底说了什么。chevron 暗示"前进一个"。
                // 每个 speaker 独立 cursor，到底 wrap 回第一个。
                // 放最右边用 Spacer 推到末尾——跟 macOS 列表行的"进入/展开"
                // 控件统一在最右的视觉习惯一致。
                Button {
                    onJumpToNext()
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("滚到下一个\(label)说的位置")
                .accessibilityLabel("跳到下一个\(label)说的位置")
            }
            Picker("名字", selection: Binding(
                get: { selectedPersonName ?? "" },
                set: { selection in
                    if selection == Self.createPersonMenuValue {
                        onRequestCreatePerson()
                    } else {
                        onSelectPerson(selection.isEmpty ? nil : selection)
                    }
                }
            )) {
                Text("未挂靠").tag("")
                ForEach(personNames, id: \.self) { name in
                    Text(name).tag(name)
                }
                Divider()
                Label("新增说话人…", systemImage: "plus")
                    .tag(Self.createPersonMenuValue)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: AppLayout.resultsSpeakerPickerWidth, alignment: .leading)
            .accessibilityLabel("\(label) 的说话人姓名")
            // 建议 hint
            if let s = suggestion {
                HStack(spacing: 4) {
                    Image(systemName: s.confidence == .high ? "checkmark.circle.fill" : (s.confidence == .medium ? "questionmark.circle" : "info.circle"))
                        .foregroundStyle(s.confidence == .high ? Color.green : (s.confidence == .medium ? Color.yellow : Color.secondary))
                    Text("参考: \(s.personName)(\(String(format: "%.2f", s.score)))")
                        .font(.caption2)
                        .foregroundStyle(s.confidence == .high ? Color.green : (s.confidence == .medium ? Color.yellow : Color.secondary))
                }
                // macOS 原生 hover tooltip：主行保持简洁，移上去查看前三名人物的
                // fingerprint 分数范围和数量。相同人物即使有多条指纹也只占一个名次。
                .help(s.hoverText)
            }
        }
        .padding(6)
        .background(Color.secondary.opacity(0.04))
        .cornerRadius(4)
    }

    /// 仅用作 Picker 的瞬时动作值，不会写入 Person.name 或 result.json。
    private static let createPersonMenuValue = "__swiftasr_create_person__"
}
