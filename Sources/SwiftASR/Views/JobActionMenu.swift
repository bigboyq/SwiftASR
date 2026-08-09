import SwiftUI
import SwiftData
import AppKit

/// 在文件列表、任务队列和最近项目中复用的 job 操作菜单。
/// 页面只决定导航位置；转写、删除和 speaker 操作仍由 coordinator 统一调度。
struct JobActionMenu: View {
    let job: ASRJob
    @Binding var selectedJobId: String?
    @ObservedObject var coordinator: FileActionCoordinator
    let open: (AppSection) -> Void

    @Environment(\.modelContext) private var modelContext

    var body: some View {
        Button {
            selectedJobId = job.id
            open(job.jobStatus.belongsInResults ? .results : .transcription)
        } label: {
            Label(job.jobStatus.belongsInResults ? "查看结果" : "查看任务", systemImage: "arrow.right.circle")
        }

        Button {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: job.sourceAudioPath)])
        } label: {
            Label("在 Finder 中显示", systemImage: "folder")
        }

        Button {
            if let path = ResultStore.resolveStoredPath(job.transcriptPath) {
                NSWorkspace.shared.activateFileViewerSelecting([path])
            }
        } label: {
            Label("显示结果 JSON", systemImage: "doc.badge.gearshape")
        }
        .disabled(ResultStore.resolveStoredPath(job.transcriptPath) == nil)

        Divider()

        if job.jobStatus == .queued {
            Button {
                coordinator.startQueuedJob(
                    jobId: job.id,
                    audioPath: job.sourceAudioPath,
                    modelContext: modelContext
                )
                selectedJobId = job.id
                open(.transcription)
            } label: {
                Label("启动", systemImage: "play.fill")
            }
            .disabled(coordinator.hasRunningPipelineExcluding(currentJobId: job.id))

            Button {
                coordinator.moveQueuedJob(jobId: job.id, by: -1, modelContext: modelContext)
            } label: {
                Label("队列上移", systemImage: "arrow.up")
            }

            Button {
                coordinator.moveQueuedJob(jobId: job.id, by: 1, modelContext: modelContext)
            } label: {
                Label("队列下移", systemImage: "arrow.down")
            }
        }

        Button {
            coordinator.retranscribe(job: job, modelContext: modelContext)
            selectedJobId = job.id
            open(.transcription)
        } label: {
            Label("重新转写", systemImage: "arrow.triangle.2.circlepath")
        }
        .disabled([.processing, .running, .queued].contains(job.jobStatus))

        if [.failed, .cancelled].contains(job.jobStatus) {
            Button {
                coordinator.retryFailedJob(
                    jobId: job.id,
                    audioPath: job.sourceAudioPath,
                    modelContext: modelContext
                )
                selectedJobId = job.id
                open(.transcription)
            } label: {
                Label("重试（置顶）", systemImage: "arrow.clockwise")
            }
            .disabled(coordinator.hasRunningPipelineExcluding(currentJobId: job.id))
        }

        Button {
            coordinator.reidentifySpeakers(job: job, modelContext: modelContext)
            selectedJobId = job.id
            open(.transcription)
        } label: {
            Label("重新识别说话人", systemImage: "person.2.badge.gearshape")
        }
        .disabled(
            !([.done, .partial, .failed].contains(job.jobStatus)) ||
            ResultStore.resolveStoredPath(job.transcriptPath) == nil
        )

        Divider()

        Button(role: .destructive) {
            var selection = selectedJobId
            coordinator.deleteJob(job: job, selectedJobId: &selection, modelContext: modelContext)
            selectedJobId = selection
        } label: {
            Label("删除", systemImage: "trash")
        }
    }
}
