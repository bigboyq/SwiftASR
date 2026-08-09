import SwiftUI
import SwiftData

// MARK: - 人物选择 sheet

/// 绑定 dialog：
/// - 列表 = 全部 Person（按 topMatches max sim 降序，没有 sim 的放底部灰色）
/// - 「未挂靠」放最顶（已绑定的 profile 进来用，用于"解除绑定"）
/// - 保留搜索 + 底部"新建"输入
struct PersonPickerSheet: View {
    let onPick: (Person) -> Void
    /// "未挂靠" 选项触发；nil 表示 sheet 里没显示
    var onUnbind: (() -> Void)? = nil
    @Binding var isPresented: Bool
    /// 当前 profile 跟每个 Person 的 max sim；nil 表示"没传"（按字母序）
    var topMatches: [SpeakerMatcher.PersonMatch] = []
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Person.name) private var allPersons: [Person]
    @State private var searchText: String = ""
    @State private var newName: String = ""

    /// 把 topMatches 转成 [personId: score] 方便查
    private var scoreByPerson: [String: Float] {
        Dictionary(uniqueKeysWithValues: topMatches.map { ($0.personId, $0.score) })
    }

    /// 显示顺序：未挂靠 → 按 sim 降序 → 0 sim 的 Person 放最后
    private var orderedPersons: [Person] {
        let filtered = allPersons.filter { p in
            searchText.isEmpty || p.name.lowercased().contains(searchText.lowercased())
        }
        if topMatches.isEmpty {
            return filtered.sorted { $0.name < $1.name }
        }
        let scores = scoreByPerson
        return filtered.sorted { a, b in
            let sa = scores[a.id] ?? -.infinity
            let sb = scores[b.id] ?? -.infinity
            if sa != sb { return sa > sb }   // 高分在前
            return a.name < b.name            // 同分按字母序
        }
    }

    private func scoreLabel(for person: Person) -> String {
        guard let s = scoreByPerson[person.id] else { return "—" }
        return String(format: "%.3f", s)
    }

    private func scoreColor(for person: Person) -> Color {
        guard let s = scoreByPerson[person.id] else { return .secondary }
        if s > 0.8 { return .green }
        if s > 0.6 { return .yellow }
        return .secondary
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "link")
                    .font(.title2)
                Text("绑定到说话人").font(.title2.bold())
                Spacer()
            }
            .padding(16)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("选已有").font(.subheadline.weight(.semibold))
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        // 「未挂靠」最顶：已绑定的 profile 进来时用于"解除绑定"
                        if let onUnbind = onUnbind {
                            Button {
                                onUnbind()
                            } label: {
                                HStack {
                                    Text("未挂靠").frame(maxWidth: .infinity, alignment: .leading)
                                    Text("(解除绑定)").font(.caption2).foregroundStyle(.secondary)
                                }
                                .padding(4)
                            }
                            .buttonStyle(.plain)
                            Divider()
                        }
                        if allPersons.isEmpty {
                            Text("(没有现有说话人，先在下方新建)")
                                .font(.caption).foregroundStyle(.secondary)
                                .padding(4)
                        } else {
                            ForEach(orderedPersons) { p in
                                Button {
                                    onPick(p)
                                } label: {
                                    HStack {
                                        Text(p.name).frame(maxWidth: .infinity, alignment: .leading)
                                        Text(scoreLabel(for: p))
                                            .font(.caption.monospaced())
                                            .foregroundStyle(scoreColor(for: p))
                                    }
                                    .padding(4)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .frame(maxHeight: 200)
                TextField("搜索已有", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                Divider()
                Text("或新建").font(.subheadline.weight(.semibold))
                HStack {
                    TextField("新名字", text: $newName)
                    Button("新建") {
                        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            // R4-P1-4：保存走 ModelContextSaver，错误文案统一。
                            do {
                                guard let p = try PersonRepository.getOrCreate(name: trimmed, in: modelContext) else { return }
                                let outcome = ModelContextSaver.save(modelContext, action: "新建人物")
                                guard outcome.success else {
                                    AlertHelper.showInfo(title: "无法创建人物", message: outcome.userMessage ?? "")
                                    return
                                }
                                onPick(p)
                            } catch {
                                Logger.shared.error("无法创建人物：\(error)")
                                AlertHelper.showInfo(
                                    title: "无法创建人物",
                                    message: UserFacingErrorMapper.message(for: error)
                                )
                            }
                        }
                    }
                    .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(16)
            Divider()
            HStack {
                Spacer()
                Button("取消") { isPresented = false }.keyboardShortcut(.cancelAction)
            }
            .padding(16)
        }
        .frame(minWidth: 400, minHeight: 400)
    }
}
