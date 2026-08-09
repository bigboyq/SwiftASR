import SwiftUI
import SwiftData
import AppKit

/// 说话人 tab：跨 job speaker 库（Person + SpeakerProfile）
/// + 健康度（drift）tooltip + 右侧详情面板
///
/// 历史：Phase 2 计划里的 `🤖 自动归档` 入口在 Phase 11 移除，未补回。
/// 跨 job 批量归档工具（`AutoArchiver` 类）于 2026-07-12 同步清理，
/// 用户需通过 `PersonPickerSheet` 手工逐条绑定。
///
/// 2026-07-12 重构：
/// - 删 `jobId` 参数（唯一调用方 `MainSplitView` 永远传 nil）
/// - 删 `SpeakerSummary` / `jobSpeakers` / `reload()` 死代码
/// - 删 `refreshTrigger` UUID（无 setter 触发的 setState）
/// - 详情右栏注入 4 个 callback（改名 / 改绑 / 解除 / 删除），不再依赖右键菜单
public struct SpeakersTab: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SpeakerProfile.fingerprintId) private var allProfiles: [SpeakerProfile]
    @Query(sort: \Person.name) private var allPersons: [Person]

    @State private var searchText: String = ""
    @State private var selectedProfileId: String?

    @State private var personEditMode: PersonEditSheet.Mode?
    @State private var bindPickerTarget: SpeakerProfile?
    @State private var persistenceError: String?
    /// R4-P1-3：PersonPickerSheet 的推荐匹配缓存。sheet 内容闭包以前直接
    /// 调 `SpeakerMatcher.topPersonMatches(...)`，每次 @State 变化都重跑一次
    /// 余弦相似度比较，阻塞主线程。这里把计算结果缓存，只在 picker target
    /// 变化时通过 `.task(id:)` 重算一次。
    @State private var pickerMatches: [SpeakerMatcher.PersonMatch] = []

    public init() {}

    /// 当前选中的 profile（用 id 查表，避免 selection 类型推断坑）
    private var selectedProfile: SpeakerProfile? {
        guard let id = selectedProfileId else { return nil }
        return allProfiles.first { $0.id == id }
    }

    // MARK: - body

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                WorkspaceHeader("说话人", subtitle: "管理本地声纹与人员命名") {
                    HStack(spacing: AppLayout.itemSpacing) {
                        Button {
                            cleanUnreferencedProfiles()
                        } label: {
                            Label("清理无引用指纹", systemImage: "broom.fill")
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("自动清理无引用 fingerprint")
                        .help("自动清理不再被任何任务结果引用的 fingerprint")

                        HStack(spacing: 6) {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(.secondary)
                            TextField("搜索人名 / fingerprint", text: $searchText)
                                .textFieldStyle(.plain)
                                .accessibilityLabel("搜索人名或 fingerprint")
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                        .frame(width: 260)

                        Button {
                            showCreatePersonSheet()
                        } label: {
                            Label("新增说话人", systemImage: "plus")
                        }
                        .help("新增说话人")
                    }
                }
                Divider()
                if let persistenceError {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text(persistenceError)
                            .font(.callout)
                            .foregroundStyle(.red)
                        Spacer()
                        Button("关闭") { self.persistenceError = nil }
                            .buttonStyle(.borderless)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.errorBackgroundTint)
                    Divider()
                }
                statsBanner
                Divider()
                if allProfiles.isEmpty {
                    emptyView
                } else {
                    HSplitView {
                        VStack(spacing: 0) {
                            contentList
                                .frame(minWidth: 240, idealWidth: 320)
                        }
                        SpeakerDetailPanel(
                            profile: selectedProfile,
                            allProfiles: allProfiles,
                            onRename: { person in showRenamePersonSheet(person: person) },
                            onBind: { profile in showBindPickerForProfile(profile) },
                            onUnbind: { profile in unbindProfile(profile) },
                            onDelete: { profile in deleteProfile(profile) }
                        )
                        .frame(minWidth: 280, idealWidth: 360, maxWidth: 480)
                    }
                }
            }
            .onAppear {
                if selectedProfileId == nil {
                    selectedProfileId = allProfiles.first?.id
                }
            }
            .onChange(of: allProfiles.map(\.id)) { _, ids in
                if selectedProfileId.map({ !ids.contains($0) }) == true {
                    selectedProfileId = ids.first
                }
            }
            .sheet(item: $personEditMode) { mode in
                PersonEditSheet(
                    isPresented: Binding(
                        get: { personEditMode != nil },
                        set: { newValue in if !newValue { personEditMode = nil } }
                    ),
                    mode: mode,
                    onSave: { name in
                        switch mode {
                        case .creating:
                            createPerson(name: name)
                        case .renaming(let p):
                            renamePerson(p, to: name)
                        }
                    }
                )
            }
            .sheet(item: $bindPickerTarget) { profile in
                PersonPickerSheet(
                    onPick: { person in
                        bindProfile(profile, to: person)
                        bindPickerTarget = nil
                    },
                    onUnbind: {
                        unbindProfile(profile)
                        bindPickerTarget = nil
                    },
                    isPresented: Binding(
                        get: { bindPickerTarget != nil },
                        set: { if !$0 { bindPickerTarget = nil } }
                    ),
                    topMatches: pickerMatches
                )
                .task(id: PickerMatchKey(profile: profile, allProfileIds: allProfiles.map(\.id))) {
                    // R4-P1-3：把余弦相似度比较移出 sheet body 闭包。target
                    // profile 或候选集变化时才重算，搜索/点击不会重复触发。
                    pickerMatches = SpeakerMatcher.topPersonMatches(
                        unbound: profile,
                        boundProfiles: allProfiles,
                        limit: 99
                    )
                }
            }
        }
    }

    // MARK: - 子视图

    private var emptyView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "person.2")
                .font(.system(size: 60))
                .foregroundStyle(.tertiary)
            Text("还没有任何说话人")
                .font(.title3)
            Text("转写一个音频文件后，这里会列出所有识别出的说话人。")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
    }

    /// 顶部统计 banner：每个数字一颗小 chip
    private var statsBanner: some View {
        HStack(spacing: 8) {
            statChip(icon: "person.2.fill", value: allPersons.count, label: "说话人", tint: .accentColor)
            statChip(icon: "waveform.path.ecg", value: allProfiles.count, label: "fingerprint", tint: .secondary)
            let unbound = allProfiles.filter { $0.person == nil }.count
            if unbound > 0 {
                statChip(icon: "circle.dashed", value: unbound, label: "未归属", tint: .secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.05))
    }

    @ViewBuilder
    private func statChip(icon: String, value: Int, label: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).imageScale(.small).foregroundStyle(tint)
            Text("\(value)").font(.caption.weight(.medium))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(tint.opacity(0.10))
        .cornerRadius(6)
    }

    @ViewBuilder
    private var contentList: some View {
        List(selection: $selectedProfileId) {
            // 命名库：Person 是主表；即使尚未挂 fingerprint 也必须可见。
            Section {
                if allPersons.isEmpty {
                    Text("还没有命名说话人，点 ➕ 新增")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                } else {
                    ForEach(filteredBoundProfilesByPerson, id: \.person.id) { group in
                        DisclosureGroup {
                            if group.profiles.isEmpty {
                                Text("暂无 fingerprint；可从「未归属」选择一条后挂靠到此人。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.vertical, 4)
                            } else {
                                ForEach(group.profiles, id: \.id) { profile in
                                    BoundProfileRow(
                                        profile: profile,
                                        health: profileHealth(for: profile),
                                        contextMenuItems: { boundProfileContextMenu(profile: profile) }
                                    )
                                    .tag(Optional(profile.id))
                                    // contextMenu 必须放在 row struct 内部；
                                    // 外面加的 .contextMenu 在 macOS DisclosureGroup 里会被 label 的 menu 吞掉
                                }
                            }
                        } label: {
                            HStack {
                                Text(group.person.name)
                                    .font(.headline)
                                Text("(\(group.profiles.count))")
                                    .font(.caption).foregroundStyle(.secondary)
                                Spacer()
                            }
                            // contextMenu 必须放在 HStack 内部（label 内容上），
                            // 不能放在外面 DisclosureGroup 上——
                            // macOS List + DisclosureGroup 里外层 contextMenu 会吞掉所有子 row 的右键事件，
                            // 导致 fingerprint row 弹的是 Person 菜单而不是 fingerprint 菜单
                            .contentShape(Rectangle())
                            .contextMenu {
                                personContextMenu(person: group.person)
                            }
                        }
                    }
                }
            } header: {
                HStack(spacing: 6) {
                    Image(systemName: "person.2.fill")
                        .foregroundStyle(.tint)
                    Text("命名库（\(allPersons.count)）")
                        .font(.headline)
                    Spacer()
                    Button {
                        showCreatePersonSheet()
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(.tint)
                    }
                    .buttonStyle(.borderless)
                    .help("新增说话人")
                }
            }

            // 未归属（unbound）profiles
            let unbound = filteredUnboundProfiles()
            if !unbound.isEmpty {
                Section {
                    ForEach(unbound, id: \.id) { profile in
                        UnboundProfileRow(profile: profile) {
                            unboundProfileContextMenu(profile: profile)
                        }
                        .tag(Optional(profile.id))
                    }
                } header: {
                    HStack(spacing: 6) {
                        Image(systemName: "circle.dashed")
                            .foregroundStyle(.secondary)
                        Text("未归属（\(unbound.count)）")
                            .font(.headline)
                    }
                }
            }
        }
    }

    // MARK: - 右键菜单

    @ViewBuilder
    private func personContextMenu(person: Person) -> some View {
        Button {
            showRenamePersonSheet(person: person)
        } label: {
            Label("更名", systemImage: "pencil")
        }
        Button(role: .destructive) {
            confirmDeletePerson(person)
        } label: {
            Label("删除说话人", systemImage: "trash")
        }
    }

    @ViewBuilder
    private func boundProfileContextMenu(profile: SpeakerProfile) -> some View {
        Button {
            showBindPickerForProfile(profile)
        } label: {
            Label("改绑指纹", systemImage: "link")
        }
        Button {
            unbindProfile(profile)
        } label: {
            Label("解除绑定", systemImage: "link.badge.minus")
        }
        Divider()
        Button(role: .destructive) {
            deleteProfile(profile)
        } label: {
            Label("删除指纹", systemImage: "trash")
        }
    }

    @ViewBuilder
    private func unboundProfileContextMenu(profile: SpeakerProfile) -> some View {
        Button {
            showBindPickerForProfile(profile)
        } label: {
            Label("绑定指纹", systemImage: "link")
        }
        Divider()
        Button(role: .destructive) {
            deleteProfile(profile)
        } label: {
            Label("删除指纹", systemImage: "trash")
        }
    }

    // MARK: - Sheet / Dialog state

    private func showCreatePersonSheet() {
        personEditMode = .creating
    }

    private func showRenamePersonSheet(person: Person) {
        personEditMode = .renaming(person)
    }

    private func showBindPickerForProfile(_ profile: SpeakerProfile) {
        selectedProfileId = profile.id
        bindPickerTarget = profile
    }

    // MARK: - Person handlers

    private func createPerson(name: String) {
        do {
            _ = try PersonRepository.create(name: name, in: modelContext)
        } catch {
            AlertHelper.showInfo(
                title: "无法新增说话人",
                message: error.localizedDescription,
                buttonTitle: "好",
                style: .warning
            )
            return
        }
        _ = saveModelChanges(action: "新增说话人")
    }

    private func renamePerson(_ person: Person, to newName: String) {
        guard newName != person.name else { return }
        let boundCount = allProfiles.filter { $0.person?.id == person.id }.count
        if boundCount > 0 {
            let confirmed = AlertHelper.confirm(
                title: "重命名说话人「\(person.name)」→「\(newName)」？",
                message: "此说话人名下有 \(boundCount) 条 fingerprint，\n改名后所有相关页面的显示名会跟着更新。",
                confirmTitle: "重命名",
                style: .informational
            )
            if !confirmed { return }
        }
        do {
            try PersonRepository.rename(person, to: newName, in: modelContext)
        } catch {
            AlertHelper.showInfo(
                title: "无法重命名说话人",
                message: error.localizedDescription,
                buttonTitle: "好",
                style: .warning
            )
            return
        }
        _ = saveModelChanges(action: "重命名说话人")
    }

    private func confirmDeletePerson(_ person: Person) {
        let boundCount = allProfiles.filter { $0.person?.id == person.id }.count
        var lines: [String] = []
        if boundCount > 0 {
            lines.append("此说话人名下的 \(boundCount) 条 fingerprint 会变成「未归属」状态。")
        } else {
            lines.append("此说话人当前没有绑定任何 fingerprint。")
        }
        lines.append("结果页显示的人名来自当前说话人库；删除后相关结果会显示原始 speaker label。")
        let confirmed = AlertHelper.confirm(
            title: "删除说话人「\(person.name)」？",
            message: lines.joined(separator: "\n"),
            confirmTitle: "删除"
        )
        if !confirmed { return }
        modelContext.delete(person)
        _ = saveModelChanges(action: "删除说话人")
    }

    // MARK: - 过滤

    private func filteredUnboundProfiles() -> [SpeakerProfile] {
        SpeakerLibraryPresentation.filteredUnboundProfiles(profiles: allProfiles, query: searchText)
    }

    // MARK: - 分组

    private var filteredBoundProfilesByPerson: [(person: Person, profiles: [SpeakerProfile])] {
        SpeakerLibraryPresentation.filteredBoundGroups(
            persons: allPersons,
            profiles: allProfiles,
            query: searchText
        )
    }

    // MARK: - 健康度

    private func profileHealth(for profile: SpeakerProfile) -> ProfileHealth {
        // 抽到 ProfileHealth.evaluate 是为了让单测能直接调,不在 view 层级挡测试。
        ProfileHealth.evaluate(for: profile, allProfiles: allProfiles)
    }

    // MARK: - 绑定操作

    private func bindProfile(_ profile: SpeakerProfile?, to person: Person) {
        guard let profile = profile else { return }
        profile.person = person
        profile.lastSeenAt = Date()
        _ = saveModelChanges(action: "绑定 fingerprint")
    }

    private func unbindProfile(_ profile: SpeakerProfile?) {
        guard let profile = profile else { return }
        profile.person = nil
        _ = saveModelChanges(action: "解除 fingerprint 绑定")
    }

    private func deleteProfile(_ profile: SpeakerProfile?) {
        guard let profile = profile else { return }
        let referencingJobs: [ASRJob]
        do {
            referencingJobs = try SpeakerProfileRepository.referencingJobs(
                profile: profile,
                in: modelContext
            )
        } catch {
            Logger.shared.error("无法检查 fingerprint 引用：\(error.localizedDescription)")
            AlertHelper.showInfo(
                title: "无法删除 fingerprint",
                message: "无法确认历史 result.json 是否仍引用这条 fingerprint。为避免破坏历史结果，本次删除已取消。",
                style: .warning
            )
            return
        }
        guard referencingJobs.isEmpty else {
            AlertHelper.showInfo(
                title: "无法删除 fingerprint",
                message: "这条 fingerprint 仍被 \(referencingJobs.count) 个历史结果引用。请先删除对应任务，或保留该 fingerprint 以确保历史结果正常显示。",
                style: .informational
            )
            return
        }
        let confirmed = AlertHelper.confirm(
            title: "确认删除 fingerprint",
            message: "删除 \(profile.fingerprintId)？\n该指纹样本将从说话人库中移除（不会出现在「未归属」中）。\n当前没有已保存的 result.json 引用它。",
            confirmTitle: "删除"
        )
        if !confirmed { return }
        modelContext.delete(profile)
        guard saveModelChanges(action: "删除 fingerprint") else { return }
        if selectedProfileId == profile.id { selectedProfileId = nil }
    }

    private func cleanUnreferencedProfiles() {
        let profiles: [SpeakerProfile]
        do {
            profiles = try SpeakerProfileRepository.unreferencedProfiles(in: modelContext)
        } catch {
            Logger.shared.error("无法扫描无引用 fingerprint：\(error.localizedDescription)")
            AlertHelper.showInfo(
                title: "无法自动清理 fingerprint",
                message: "无法确认所有历史 result.json 的引用关系。为避免误删，本次未删除任何 fingerprint。\n\n\(error.localizedDescription)",
                style: .warning
            )
            return
        }

        guard !profiles.isEmpty else {
            AlertHelper.showInfo(
                title: "没有可清理的 fingerprint",
                message: "所有 fingerprint 仍被现存任务的 result.json 引用。",
                style: .informational
            )
            return
        }

        let confirmed = AlertHelper.confirm(
            title: "清理 \(profiles.count) 条无引用 fingerprint？",
            message: "这些 fingerprint 已不再被任何现存任务的 result.json 引用，通常来自重新识别说话人或删除任务后的历史残留。\n\n此操作不会删除任务、结果文件或说话人名称。",
            confirmTitle: "清理"
        )
        guard confirmed else { return }

        let selectedWasRemoved = profiles.contains { $0.id == selectedProfileId }
        for profile in profiles {
            modelContext.delete(profile)
        }
        guard saveModelChanges(action: "自动清理 fingerprint") else { return }
        if selectedWasRemoved { selectedProfileId = nil }
        AlertHelper.showInfo(
            title: "已清理 fingerprint",
            message: "已移除 \(profiles.count) 条不再被任务引用的 fingerprint。",
            style: .informational
        )
    }

    @discardableResult
    private func saveModelChanges(action: String) -> Bool {
        // R4-P1-4：保存逻辑收敛到 ModelContextSaver，错误文案走统一 mapper。
        let outcome = ModelContextSaver.save(modelContext, action: action)
        persistenceError = outcome.userMessage
        return outcome.success
    }
}

/// `.task(id:)` 的 identity key：picker 目标 profile + 候选 profile id 集
/// 一起决定是否重算推荐匹配（R4-P1-3）。
private struct PickerMatchKey: Equatable {
    let profileId: String
    let allProfileIds: [String]

    init(profile: SpeakerProfile, allProfileIds: [String]) {
        self.profileId = profile.id
        self.allProfileIds = allProfileIds
    }
}
