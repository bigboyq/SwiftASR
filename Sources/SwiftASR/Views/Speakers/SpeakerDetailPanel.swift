import SwiftUI
import SwiftData

// MARK: - 详情右栏 (B1)

struct SpeakerDetailPanel: View {
    let profile: SpeakerProfile?
    let allProfiles: [SpeakerProfile]

    /// 行内操作 callback。SpeakersTab 持有 modelContext + sheet 状态，
    /// 这里只把用户意图传回去，具体怎么处理（弹窗、删数据、NSAlert）由 parent 负责。
    let onRename: (Person) -> Void
    let onBind: (SpeakerProfile) -> Void
    let onUnbind: (SpeakerProfile) -> Void
    let onDelete: (SpeakerProfile) -> Void

    /// 当前选中 profile 的 Top 5 person-level 推荐；优先读取全局索引，索引预热期间回退即时计算。
    /// 所有 fingerprint 都显示人物分析。结果只在内存中派生，不落盘。
    @State private var analysisTop: [SpeakerMatcher.PersonMatch] = []
    @ObservedObject private var matchIndex = SpeakerMatchIndex.shared
    /// 样本句展开/收起。>3 行时默认折叠，点了"展开"才显示完整。
    @State private var sampleExpanded: Bool = false
    @State private var sampleText: String?

    private static let analysisLimit = 5
    private static let sampleLineLimit = 3

    /// 三个 box 共用的样式（padding + cornerRadius + 背景色 + 标题字体）
    /// 抽常量方便后续统一调整。
    private static let boxPadding: CGFloat = 10
    private static let boxCornerRadius: CGFloat = 8
    private static let boxBackground = Color.secondary.opacity(0.06)
    private static let boxTitleFont: Font = .subheadline.weight(.semibold)
    private static let boxContentFont: Font = .caption
    private static let boxTitleContentSpacing: CGFloat = 6
    private static let boxRowSpacing: CGFloat = 3

    var body: some View {
        Group {
            if let p = profile {
                detailContent(profile: p)
            } else {
                placeholder
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: sampleTextKey) {
            sampleExpanded = false
            sampleText = nil
            guard let p = profile else { return }
            let text = await p.sampleText()
            if Task.isCancelled { return }
            sampleText = text
        }
        .onChange(of: profile?.id) { _, _ in
            recomputeAnalysis()
        }
        .onChange(of: matchIndex.generation) { _, _ in
            recomputeAnalysis()
        }
        .onChange(of: profileCatalogKey) { _, _ in
            recomputeAnalysis()
        }
        .onAppear {
            recomputeAnalysis()
        }
    }

    private var sampleTextKey: String {
        guard let p = profile else { return "" }
        let summary = p.jobOccurrences.map { occ in
            let job = occ.job
            return "\(occ.speakerLabel)|\(job?.id ?? "")|\(job?.transcriptPath ?? "")|\(job?.status ?? "")|\(job?.createdAt.timeIntervalSince1970 ?? 0)"
        }.joined(separator: ";")
        return "\(p.id)|\(p.jobOccurrences.count)|\(summary)"
    }

    private var profileCatalogKey: [String] {
        allProfiles.map {
            "\($0.id)|\($0.fingerprintId)|\($0.person?.id ?? "")|\($0.person?.name ?? "")"
        }
    }

    private func recomputeAnalysis() {
        guard let p = profile else {
            analysisTop = []
            return
        }
        matchIndex.update(profiles: allProfiles)
        if matchIndex.hasCachedRow(for: p.id) {
            analysisTop = matchIndex.matches(
                for: p,
                limit: Self.analysisLimit,
                excludingFingerprintId: p.fingerprintId
            )
        } else {
            // 首次索引尚未完成时保留原有即时结果，避免详情面板短暂空白。
            analysisTop = SpeakerMatcher.topPersonMatches(
                unbound: p,
                boundProfiles: allProfiles,
                limit: Self.analysisLimit,
                excludingFingerprintId: p.fingerprintId
            )
        }
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "person.crop.rectangle")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("在左边选一个 profile")
                .font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func detailContent(profile: SpeakerProfile) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                // 0. 顶部 action bar
                actionBar(profile: profile)
                // 1. 身份
                identityBox(profile: profile)
                // 2. 统计
                statBox(profile: profile)
                // 3. 样本句
                sampleBox(profile: profile)
                // 4. 人物分析（所有 fingerprint 默认显示 Top 5 person-level 推荐）
                analysisBox()
            }
            .padding(12)
        }
    }

    /// 顶部行内操作按钮：让用户不必依赖右键菜单就能完成主要操作。
    /// 删除指纹改用普通 Button（不用 .destructive role），保证跟其他三个按钮尺寸一致；
    /// 视觉警示用 .foregroundStyle(.red) 保留。
    @ViewBuilder
    private func actionBar(profile: SpeakerProfile) -> some View {
        HStack(spacing: 6) {
            if let person = profile.person {
                Button {
                    onRename(person)
                } label: {
                    Label("改名", systemImage: "pencil")
                }
                .help("改名说话人「\(person.name)」")
            } else {
                Button {
                    onBind(profile)
                } label: {
                    Label("绑定到…", systemImage: "link.badge.plus")
                }
                .help("把这条 fingerprint 绑到一个已命名说话人")
            }
            if profile.person != nil {
                Button {
                    onUnbind(profile)
                } label: {
                    Label("解绑", systemImage: "link.badge.minus")
                }
                .help("解除绑定（变回「未归属」状态）")
            }
            Spacer(minLength: 4)
            Button {
                onDelete(profile)
            } label: {
                Label("删除指纹", systemImage: "trash")
            }
            .foregroundStyle(.red)
            .help("删除这条 fingerprint")
        }
        .controlSize(.small)
        .padding(Self.boxPadding)
        .background(Self.boxBackground)
        .cornerRadius(Self.boxCornerRadius)
    }

    /// 三个 box 共享的"标题 + 内容"布局 — 抽 helper 避免三处分别写
    @ViewBuilder
    private func detailBox<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Self.boxTitleContentSpacing) {
            Text(title)
                .font(Self.boxTitleFont)
            content()
                .font(Self.boxContentFont)
        }
        .padding(Self.boxPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Self.boxBackground)
        .cornerRadius(Self.boxCornerRadius)
    }

    /// 人物分析 Box：所有 fingerprint 的 Top 5 person-level 推荐。
    /// 渲染时实时计算（onChange 触发），结果不落盘。
    /// 配色复用现有 confidence 阈值（0.8 高 / 0.6 中 / 低）。
    private func analysisBox() -> some View {
        detailBox(title: "人物分析") {
            VStack(alignment: .leading, spacing: Self.boxRowSpacing) {
                HStack {
                    Text("Top \(Self.analysisLimit) 推荐人")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                if analysisTop.isEmpty {
                    Text("—")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(analysisTop, id: \.personId) { match in
                        HStack(spacing: 6) {
                            Text(match.personName)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            // 进度条代替纯数字，视觉上更直观
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(Color.secondary.opacity(0.15))
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(Self.confidenceColor(for: match.score))
                                        .frame(width: max(2, geo.size.width * CGFloat(min(1, max(0, match.score)))))
                                }
                            }
                            .frame(width: 60, height: 6)
                            Text(String(format: "%.3f", match.score))
                                .font(.caption.monospaced())
                                .foregroundStyle(Self.confidenceColor(for: match.score))
                                .frame(width: 40, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }

    private static func confidenceColor(for score: Float) -> Color {
        if score > 0.8 { return .green }
        if score > 0.6 { return .yellow }
        return .secondary
    }

    private func identityBox(profile: SpeakerProfile) -> some View {
        detailBox(title: "身份") {
            VStack(alignment: .leading, spacing: Self.boxRowSpacing) {
                LabeledContent("类型", value: profile.person == nil ? "未归属" : "说话人")
                LabeledContent("姓名", value: profile.person?.name ?? "—")
                LabeledContent("Fingerprint", value: profile.fingerprintId)
                LabeledContent("Backend", value: profile.backend)
                LabeledContent("Model version", value: "v1")
            }
        }
    }

    private func statBox(profile: SpeakerProfile) -> some View {
        detailBox(title: "统计") {
            VStack(alignment: .leading, spacing: Self.boxRowSpacing) {
                LabeledContent("发言次数", value: "\(profile.totalUtterances) 段")
                LabeledContent("总时长", value: formatProfileDuration(seconds: profile.totalDurationSeconds))
                LabeledContent("首次出现", value: formatLocalTime(profile.firstSeenAt))
                LabeledContent("最近出现", value: formatLocalTime(profile.lastSeenAt))
                if let job = profile.jobOccurrences.max(by: {
                    ($0.job?.createdAt ?? .distantPast) < ($1.job?.createdAt ?? .distantPast)
                })?.job {
                    LabeledContent("最近来源音频", value: URL(fileURLWithPath: job.sourceAudioPath).lastPathComponent)
                } else {
                    LabeledContent("最近来源音频", value: "—")
                }
            }
        }
    }

    private func sampleBox(profile: SpeakerProfile) -> some View {
        detailBox(title: "样本句") {
            VStack(alignment: .leading, spacing: 4) {
                if let sample = sampleText, !sample.isEmpty {
                    Text(sample)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(sampleExpanded ? nil : Self.sampleLineLimit)
                        .truncationMode(.tail)
                        .textSelection(.enabled)
                    // 行数超过 lineLimit 时显示"展开/收起"
                    if needsSampleExpand(sample: sample) {
                        Button {
                            sampleExpanded.toggle()
                        } label: {
                            Text(sampleExpanded ? "收起" : "展开")
                                .font(.caption2)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.tint)
                    }
                } else {
                    Text("—")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// 样本句文本行数是否超过 lineLimit — 用 SwiftUI 同步测量不可行，
    /// 用字符数 / 中文字符宽度做粗略判断（>40 字认为可能需要展开）。
    /// 不精确但足够提示用户，避免所有样本都无脑显示"展开"按钮。
    private func needsSampleExpand(sample: String) -> Bool {
        // 中文字符算 1，英文 / 标点算 0.5；>50 算长
        var visualLength = 0.0
        for scalar in sample.unicodeScalars {
            // CJK Unified Ideographs 范围
            if (0x4E00...0x9FFF).contains(scalar.value) {
                visualLength += 1.0
            } else {
                visualLength += 0.5
            }
        }
        return visualLength > 50
    }

    private func formatLocalTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: date)
    }
}
