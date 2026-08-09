import SwiftUI

// MARK: - Job 信息卡（3 行：ASR / 合并 / LLM）

/// 替换原来"大文件名 + 段数"的 Header，显示 result.json 的 3 类结构信息
/// 与 ASR / 说话人 / LLM 各自实际处理耗时（不包含排队或用户等待）。
///
/// 视觉：3 行水平布局，左边 icon + 标签，中间主数据，右边时间/元信息
struct JobInfoCard: View {
    let payload: ResultPayload
    let job: ASRJob?
    /// 合并行"说话人"按 person.name unique 计数。
    /// （说话人 2 和说话人 4 都绑"雅冬" → 算 1 个 = 3 而非 4。）
    /// ResultsContent 算好后传进来，JobInfoCard 不持有 modelContext。
    let uniqueNamedSpeakers: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            asrRow
            mergedRow
            llmRow
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.06))
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    // MARK: - ASR 行

    private var asrRow: some View {
        return HStack(spacing: 8) {
            infoIcon(systemName: "waveform", tint: .blue)
            Text("ASR").font(.system(size: 12, weight: .semibold)).frame(width: 40, alignment: .leading)
            statusMark(hasContent: !payload.segments.isEmpty)
            // mainText 把段数 + speaker 数放主文本；VAD 有效时长是
            // "信息密度更高"的一手数据（跟原始时长比一眼能看出 VAD
            // 切了多少静音），拼在 secondary 里。
            let effective = ResultsPresentation.effectiveAudioSeconds(in: payload)
            mainText(primary: "\(payload.segments.count) 段",
                     secondary: " · \(payload.speakers.count) speaker · 有效 \(formatDuration(seconds: effective))")
            Spacer()
            metaText(asrMeta)
        }
        .help(asrTooltip)
    }

    private var asrMeta: String {
        processingDurationText(job?.asrProcessingSeconds ?? 0)
    }

    private var asrTooltip: String {
        guard let j = job else { return "" }
        return "添加：\(formatTimestamp(j.createdAt))\n" +
            (j.finishedAt.map { "完成：\(formatTimestamp($0))" } ?? "完成：—")
    }

    // MARK: - 合并 行

    private var mergedRow: some View {
        // The card is a summary of the *current preview*. A Split Set owns
        // fresh operation-layer merge units, so checking baseline
        // `payload.mergedResults` here would falsely leave this row pending.
        let mergedResults = ResultsPresentation.activeMergedResults(in: payload)
        let activeSegments = ResultsPresentation.activeSegments(in: payload)
        return HStack(spacing: 8) {
            infoIcon(systemName: "link", tint: .purple)
            Text("合并").font(.system(size: 12, weight: .semibold)).frame(width: 40, alignment: .leading)
            if mergedResults.isEmpty {
                statusMark(hasContent: false, pending: true)
                Text("未生成（切换到\"合并原文\"时生成）")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                statusMark(hasContent: true)
                // 主色：合并后的 Speaker 段数（"519 段"——是 speaker 合并的
                // 颗粒度，不是 ASR 颗粒度）。
                // 副色：跟 ASR 行的 secondary 风格对齐——
                //   · N 说话人    — unique 命名说话人数（一晨/雅冬/樊璠 = 3）
                //                    说话人 2 和说话人 4 都绑"雅冬"算 1 个
                //   · ASR 段 N    — 合并前 ASR 段数，让用户一眼看到合并比
                //   · 跨度 X      — Speaker 段覆盖的时间区间
                //   · 平均 Ys/段  — 每段平均时长
                // 跟旧版相比，"说话人"从 Set(speakerLabel) unique（=ID 字符串
                // 数 4）改为按 person.name unique（=3）。两个说话人 4 = 雅冬
                // 跟说话人 2 = 雅冬 合并计 1。
                let asrCount = activeSegments.count
                let spanMs = (mergedResults.last?.endMs ?? 0) - (mergedResults.first?.startMs ?? 0)
                let spanSeconds = max(spanMs / 1000, 0)
                let avg = Double(spanSeconds) / Double(max(mergedResults.count, 1))
                mainText(
                    primary: "\(mergedResults.count) 段",
                    secondary: String(
                        format: " · %d 说话人 · ASR 段 %d · 跨度 %@ · 平均 %.1fs/段",
                        uniqueNamedSpeakers, asrCount,
                        formatDuration(seconds: spanSeconds), avg
                    )
                )
            }
            Spacer()
            metaText(processingDurationText(job?.speakerProcessingSeconds ?? 0))
        }
    }

    // MARK: - LLM 行

    private var llmRow: some View {
        let mergedResults = ResultsPresentation.activeMergedResults(in: payload)
        return HStack(spacing: 8) {
            infoIcon(systemName: "sparkles", tint: .orange)
            Text("LLM").font(.system(size: 12, weight: .semibold)).frame(width: 40, alignment: .leading)
            let cleanedCount = mergedResults.filter { !$0.cleanedContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
            let model = payload.cleanedModel ?? job?.cleanedModel
            if cleanedCount == 0 {
                statusMark(hasContent: false, pending: true)
                Text(model.map { "\($0) 配置了但未润色" } ?? "未润色")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                statusMark(hasContent: true)
                mainText(primary: model ?? "已编辑",
                         secondary: " · \(cleanedCount) 段已润色")
                Spacer()
                metaText(llmMeta(cleanedCount: cleanedCount))
            }
        }
        .help(llmTooltip)
    }

    private func llmMeta(cleanedCount: Int) -> String {
        guard cleanedCount > 0 else { return "" }
        return processingDurationText(job?.llmProcessingSeconds ?? 0)
    }

    private var llmTooltip: String {
        guard let j = job, let cleaned = j.cleanedAt else { return "未润色" }
        return "润色完成：\(formatTimestamp(cleaned))"
    }

    // MARK: - helpers

    @ViewBuilder
    private func infoIcon(systemName: String, tint: Color) -> some View {
        Image(systemName: systemName)
            .foregroundStyle(tint)
            .font(.system(size: 12))
            .frame(width: 16)
    }

    @ViewBuilder
    private func statusMark(hasContent: Bool, pending: Bool = false) -> some View {
        if pending {
            Image(systemName: "circle.dashed")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
        } else {
            Image(systemName: hasContent ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(hasContent ? .green : .red)
                .font(.system(size: 12))
        }
    }

    @ViewBuilder
    private func mainText(primary: String, secondary: String) -> some View {
        HStack(spacing: 0) {
            Text(primary).font(.system(size: 12, weight: .medium))
            Text(secondary).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func metaText(_ s: String) -> some View {
        if !s.isEmpty {
            Text(s).font(.system(size: 11)).foregroundStyle(.tertiary)
        }
    }

    private func formatTimestamp(_ d: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MM-dd HH:mm"
        return fmt.string(from: d)
    }

    private func formatDuration(seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)秒" }
        if seconds < 3600 { return "\(seconds / 60)分\(seconds % 60)秒" }
        return "\(seconds / 3600)时\((seconds % 3600) / 60)分"
    }

    private func processingDurationText(_ seconds: Double) -> String {
        guard seconds > 0 else { return "" }
        return "处理 \(formatDuration(seconds: max(Int(seconds.rounded()), 1)))"
    }
}
