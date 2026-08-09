import SwiftUI

/// 结果页顶部 header 块（2026-07-22 从 `ResultsContent.contentView` 抽出）：
/// 1. 文件名（小字，跟 sidebar 选中的对得上）
/// 2. `JobInfoCard`（ASR / 合并 / LLM 三行结构信息卡）
/// 3. Speaker 重新识别失败的橘色 banner（仅 `.done` 状态 + 最近一次操作是
///    `speakerReidentification` 且 status = `.failed` 时显示）
///
/// 抽出来让 `contentView` 退到只有工具栏 + HSplit 主体，header 的视觉迭代
/// 不再跟主内容改在一起。
struct ResultsContentHeader: View {
    let payload: ResultPayload
    let currentJob: ASRJob?
    let uniqueNamedSpeakers: Int

    var body: some View {
        VStack(spacing: 0) {
            fileNameRow
            JobInfoCard(
                payload: payload,
                job: currentJob,
                uniqueNamedSpeakers: uniqueNamedSpeakers
            )
            if let reidentifyError = reidentifyErrorMessage {
                reidentifyErrorBanner(message: reidentifyError)
            }
        }
    }

    private var fileNameRow: some View {
        HStack {
            Text(URL(fileURLWithPath: payload.audioPath).lastPathComponent)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    private func reidentifyErrorBanner(message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("说话人重新识别失败；已保留原有结果")
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
    }

    private var reidentifyErrorMessage: String? {
        guard let job = currentJob,
              job.jobStatus == .done,
              job.latestOperationKind == .speakerReidentification,
              job.latestOperationStatus == .failed,
              let operationError = job.lastOperationMessage else {
            return nil
        }
        return operationError
    }
}
