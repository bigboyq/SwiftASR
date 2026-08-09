import Foundation
import Combine

/// Owns the asynchronous, read-only preview used by the speaker split button.
///
/// A preview is only valid for one immutable routing snapshot and one Split
/// Set.  Keeping the task, generation and cache here makes that contract
/// explicit instead of leaving detached work owned by `ResultsContent`.
@MainActor
final class ProfileSplitPreviewCoordinator: ObservableObject {
    typealias Output = [String: String]
    typealias Compute = @Sendable (Input) -> Output

    struct Input: Sendable {
        struct Identity: Hashable, Sendable {
            let jobID: String
            let routingSnapshotIdentity: String
            let splitProfileLabels: [String]
        }

        let identity: Identity
        let speakerInput: SpeakerRecognitionInput
        let routingSnapshot: SpeakerRoutingSnapshot
        let currentOperation: SpeakerSplitOperation?
        let profileLabels: [String]

        init(
            jobID: String,
            speakerInput: SpeakerRecognitionInput,
            routingSnapshot: SpeakerRoutingSnapshot,
            currentOperation: SpeakerSplitOperation?
        ) {
            let splitProfileLabels = Array(
                Set(currentOperation?.splitProfileLabels ?? [])
            ).sorted()
            self.identity = Identity(
                jobID: jobID,
                routingSnapshotIdentity: routingSnapshot.stableIdentity,
                splitProfileLabels: splitProfileLabels
            )
            self.speakerInput = speakerInput
            self.routingSnapshot = routingSnapshot
            self.currentOperation = currentOperation
            self.profileLabels = Array(
                Set(routingSnapshot.profileMappings.map(\.speakerLabel))
            ).sorted()
        }
    }

    @Published private(set) var tooltips: Output = [:]

    private let compute: Compute
    private var previewTask: Task<Void, Never>?
    private var generation = 0
    private var activeIdentity: Input.Identity?
    private var cache: [Input.Identity: Output] = [:]
    private var cacheOrder: [Input.Identity] = []

    /// Hard upper bound on the coordinator's preview cache.  The result page
    /// can browse across many jobs without bound; without an eviction policy
    /// the cache would grow with every distinct (job, routing snapshot, split
    /// set) tuple. 32 covers a generous interactive session while keeping the
    /// per-coordinator footprint bounded.
    static let maxCacheEntries = 32

    init() {
        self.compute = Self.makeTooltips
    }

    init(compute: @escaping Compute) {
        self.compute = compute
    }

    deinit {
        previewTask?.cancel()
    }

    /// Replaces the in-flight calculation.  A cancelled or superseded task
    /// can never publish: both its generation and its full input identity are
    /// checked again on the main actor before state changes.
    func refresh(_ input: Input?) {
        generation &+= 1
        previewTask?.cancel()
        previewTask = nil
        activeIdentity = input?.identity
        tooltips = [:]

        guard let input else { return }
        if let cached = cache[input.identity] {
            tooltips = cached
            return
        }

        let expectedGeneration = generation
        let expectedIdentity = input.identity
        let compute = compute
        previewTask = Task.detached(priority: .utility) { [weak self] in
            let output = compute(input)
            guard !Task.isCancelled else { return }
            await self?.accept(
                output,
                generation: expectedGeneration,
                identity: expectedIdentity
            )
        }
    }

    func cancel() {
        generation &+= 1
        previewTask?.cancel()
        previewTask = nil
        activeIdentity = nil
        tooltips = [:]
    }

    private func accept(
        _ output: Output,
        generation: Int,
        identity: Input.Identity
    ) {
        guard generation == self.generation,
              identity == activeIdentity
        else { return }
        recordCache(output, for: identity)
        tooltips = output
        previewTask = nil
    }

    private func recordCache(_ output: Output, for identity: Input.Identity) {
        if cache[identity] == nil {
            cacheOrder.append(identity)
        }
        cache[identity] = output
        while cacheOrder.count > Self.maxCacheEntries {
            guard let oldest = cacheOrder.first else { break }
            cacheOrder.removeFirst()
            cache.removeValue(forKey: oldest)
        }
    }

    nonisolated private static func makeTooltips(_ input: Input) -> Output {
        let splitSet = Set(input.identity.splitProfileLabels)
        var output: Output = [:]
        for label in input.profileLabels {
            guard !Task.isCancelled else { return [:] }
            let operation: SpeakerSplitOperation?
            if splitSet.contains(label) {
                operation = input.currentOperation
            } else {
                operation = try? ProfileSplitReassignmentService.derive(
                    input: input.speakerInput,
                    snapshot: input.routingSnapshot,
                    splitProfileLabels: splitSet.union([label])
                )
            }
            guard let operation else { continue }
            let preview = ProfileSplitReassignmentService.preview(
                operation: operation,
                sourceProfileLabel: label,
                snapshot: input.routingSnapshot
            )
            output[label] = ProfileSplitPreviewText.message(
                preview,
                includesCaution: preview.requiresSplitConfirmation
            )
        }
        return output
    }
}

/// The split icon tooltip and the click-time alert deliberately share this
/// formatter so the user can inspect the exact same evidence before clicking.
enum ProfileSplitPreviewText {
    static func message(
        _ preview: ProfileSplitReassignmentService.SplitPreview,
        includesCaution: Bool
    ) -> String {
        let details = preview.destinations.map {
            "\($0.sentenceCount) → \($0.speakerLabel)"
        }.joined(separator: "\n")
        let cohesion = preview.cohesion.map { String(format: "聚集度：%.0f%%", $0 * 100) } ?? "聚集度：—"
        let header: String
        if includesCaution,
           let dominant = preview.dominantDestination,
           let ratio = preview.dominantRatio {
            header = "\(dominant.speakerLabel) 重合度 \(Int((ratio * 100).rounded()))%，\(cohesion)，谨慎分拆"
        } else if includesCaution {
            header = "\(cohesion)，谨慎分拆"
        } else {
            header = cohesion
        }
        return "\(header)\n\n分拆预览：\n\(details)"
    }
}
