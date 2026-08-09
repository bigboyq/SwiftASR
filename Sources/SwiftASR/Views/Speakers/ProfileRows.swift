import SwiftUI

// MARK: - 行 view
//
// 两个 list row view 共用：BoundProfileRow（已绑 fingerprint）
// + UnboundProfileRow（未绑 fingerprint）。
// 共享 `formatProfileDuration` helper（命名空间独立，避开和 FileActionCoordinator
// / Results/JobInfoCard 内的 `formatDuration` 重载冲突），generic contextMenu
// pattern 一致。

struct BoundProfileRow<MenuItems: View>: View {
    let profile: SpeakerProfile
    let health: ProfileHealth
    @ViewBuilder let contextMenuItems: () -> MenuItems

    init(
        profile: SpeakerProfile,
        health: ProfileHealth,
        @ViewBuilder contextMenuItems: @escaping () -> MenuItems = { EmptyView() }
    ) {
        self.profile = profile
        self.health = health
        self.contextMenuItems = contextMenuItems
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: health.icon)
                    .foregroundStyle(health.color)
                    .help(health.tooltip)
                Text(profile.fingerprintId)
                    .font(.subheadline.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text("\(profile.totalUtterances) 段")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text(formatProfileDuration(seconds: profile.totalDurationSeconds))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("最近：\(profile.lastSeenAt.formatted(.relative(presentation: .named)))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .contextMenu {
            contextMenuItems()
        }
    }
}

struct UnboundProfileRow<MenuItems: View>: View {
    let profile: SpeakerProfile
    @ViewBuilder let contextMenuItems: () -> MenuItems

    init(
        profile: SpeakerProfile,
        @ViewBuilder contextMenuItems: @escaping () -> MenuItems = { EmptyView() }
    ) {
        self.profile = profile
        self.contextMenuItems = contextMenuItems
    }

    var body: some View {
        HStack {
            Image(systemName: "person.crop.circle.dashed")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.fingerprintId)
                    .font(.subheadline.monospaced())
                HStack {
                    Text("\(profile.totalUtterances) 段")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(formatProfileDuration(seconds: profile.totalDurationSeconds))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .contextMenu {
            contextMenuItems()
        }
    }
}

func formatProfileDuration(seconds: Double) -> String {
    let s = Int(seconds)
    let m = s / 60
    let sec = s % 60
    if m > 0 { return "\(m) 分 \(sec) 秒" }
    return "\(sec) 秒"
}
