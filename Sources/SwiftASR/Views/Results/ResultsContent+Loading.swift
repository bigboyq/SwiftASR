import Foundation

/// Result loading and legacy-payload preparation for the results workspace.
///
/// Disk decoding and replay-sidecar loading run off the main actor. SwiftData
/// profile hydration stays on the main actor and is committed only after the
/// view's load token confirms that the same job is still active.
extension ResultsContent {
    func reload() {
        let requestedJobID = jobId
        let storedPath = currentJob?.transcriptPath
        let token = viewState.beginLoad(jobID: requestedJobID)
        let task = Task { @MainActor in
            let loaded = await Task.detached(priority: .userInitiated) {
                let outcome = ResultsPayloadLoader.load(
                    jobID: requestedJobID,
                    storedPath: storedPath
                )
                let replayContext = ResultsSplitReplayLoader.load(
                    jobID: requestedJobID,
                    storedPath: storedPath
                )
                return (outcome, replayContext)
            }.value
            guard isCurrentLoad(token) else { return }
            defer { viewState.finishLoad(token) }

            switch loaded.0 {
            case .failure(let message, let diagnostic):
                clearLoadedResult(
                    message: message,
                    diagnostic: diagnostic,
                    requestedJobID: requestedJobID,
                    storedPath: storedPath
                )
                return

            case .success(let decodedPayload):
                guard installLoadedPayload(
                    decodedPayload,
                    replayContext: loaded.1,
                    token: token,
                    requestedJobID: requestedJobID,
                    storedPath: storedPath
                ) else { return }
            }
            cleanupError = nil
            syncBanner = nil
            infoBanner = nil
        }
        viewState.installLoadTask(task, for: token)
    }

    /// Applies the main-actor portion of a decoded result load. Keeping the
    /// replay migration and stale-token checks together makes `reload()` a
    /// short lifecycle wrapper while preserving the existing early-return
    /// semantics for superseded jobs and failed fallback transactions.
    @discardableResult
    private func installLoadedPayload(
        _ decodedPayload: ResultPayload,
        replayContext: ResultsSplitReplayContext,
        token: ResultsViewState.LoadToken,
        requestedJobID: String,
        storedPath: String?
    ) -> Bool {
        var resolvedPayload = decodedPayload
        let profiles = loadProfilesForPresentation()
        let preparation = ResultsPayloadPresentationPreparer.prepare(
            payload: resolvedPayload,
            currentJob: currentJob,
            profiles: profiles
        )
        resolvedPayload = preparation.payload
        viewState.speakerNames = preparation.speakerNames
        if preparation.requiresPersistence {
            guard isCurrentLoad(token),
                  persist(resolvedPayload, action: "迁移历史结果")
            else { return false }
        }

        guard isCurrentLoad(token) else { return false }
        persistenceError = nil
        let replayInstallation = splitCoordinator.installReplayContext(
            replayContext,
            payload: resolvedPayload,
            jobID: requestedJobID,
            storedPath: storedPath
        )
        if let replayInstallation {
            if replayInstallation.recovery != nil {
                do {
                    guard isCurrentLoad(token) else { return false }
                    try splitCoordinator.persistInvalidReplayFallback(
                        replayInstallation,
                        jobID: requestedJobID,
                        storedPath: storedPath,
                        currentJob: currentJob,
                        modelContext: modelContext
                    )
                } catch {
                    clearLoadedResult(
                        message: "无法安全保存基线回退：\(error.localizedDescription)",
                        diagnostic: "speaker split replay fallback transaction failed: \(error)",
                        requestedJobID: requestedJobID,
                        storedPath: storedPath
                    )
                    return false
                }
            }
            guard isCurrentLoad(token) else { return false }
            resolvedPayload = replayInstallation.payload
            profileCohesions = replayInstallation.profileCohesions
            persistenceError = replayInstallation.validationMessage
        } else {
            profileCohesions = [:]
        }
        payload = resolvedPayload

        inScopeLabels = defaultInScopeLabels(for: resolvedPayload)
        refreshSuggestions(profiles: profiles)
        return true
    }

    private func isCurrentLoad(_ token: ResultsViewState.LoadToken) -> Bool {
        !Task.isCancelled && viewState.isCurrent(token)
    }

    private func clearLoadedResult(
        message: String,
        diagnostic: String,
        requestedJobID: String,
        storedPath: String?
    ) {
        payload = nil
        inScopeLabels = []
        suggestions = [:]
        viewState.speakerNames = [:]
        persistenceError = message
        _ = splitCoordinator.installReplayContext(
            nil,
            payload: nil,
            jobID: requestedJobID,
            storedPath: storedPath
        )
        profileCohesions = [:]
        Logger.shared.error("无法加载任务 \(requestedJobID) 的结果：\(diagnostic)")
    }
}

/// Pure payload migration result used by `ResultsContent.reload()`.
struct ResultsPayloadPresentationPreparation {
    let payload: ResultPayload
    let speakerNames: [String: String]
    let requiresPersistence: Bool
}

/// Owns compatibility migrations that prepare a decoded payload for display.
/// Keeping this outside the SwiftUI view makes migration ordering explicit:
/// hydrate profile IDs, restore visible LLM fallback markers, resolve names,
/// then strip legacy speaker prefixes.
@MainActor
enum ResultsPayloadPresentationPreparer {
    static func prepare(
        payload: ResultPayload,
        currentJob: ASRJob?,
        profiles: [SpeakerProfile]
    ) -> ResultsPayloadPresentationPreparation {
        var payload = payload
        let didHydrate = ResultSpeakerMappingService.hydrateProfileMappings(
            &payload,
            activeSegments: ResultsPresentation.activeSegments(in: payload),
            currentJob: currentJob,
            profiles: profiles
        )
        let names = ResultsPresentation.speakerNameMap(
            payload: payload,
            profiles: profiles
        )
        let didNormalizeFallbacks = normalizeLLMFailureFallbacks(&payload)
        let didNormalize = normalizeCleanedSpeakerPrefixes(
            &payload,
            speakerNames: names
        )
        return ResultsPayloadPresentationPreparation(
            payload: payload,
            speakerNames: names,
            requiresPersistence: didHydrate || didNormalizeFallbacks || didNormalize
        )
    }

    /// Early builds persisted raw text without the visible warning prefix even
    /// though `wasLLMFailure` was true. Restore the field-level contract so
    /// preview, export and result.json all expose `⚠️原文`.
    @discardableResult
    static func normalizeLLMFailureFallbacks(_ payload: inout ResultPayload) -> Bool {
        if payload.speakerSplitOperation != nil {
            return normalizeLLMFailureFallbacks(
                &payload.speakerSplitOperation!.derivedMergedResults
            )
        }
        return normalizeLLMFailureFallbacks(&payload.mergedResults)
    }

    private static func normalizeLLMFailureFallbacks(
        _ results: inout [MergedResult]
    ) -> Bool {
        var changed = false
        for index in results.indices where results[index].wasLLMFailure {
            let expected = MergedResult.llmFailureFallbackContent(
                rawContent: results[index].rawContent
            )
            if results[index].cleanedContent != expected {
                results[index].cleanedContent = expected
                changed = true
            }
        }
        return changed
    }

    /// Repairs legacy Gemini responses that included "speaker:" in
    /// `cleanedContent`, preventing duplicate names in preview and export.
    @discardableResult
    static func normalizeCleanedSpeakerPrefixes(
        _ payload: inout ResultPayload,
        speakerNames names: [String: String]
    ) -> Bool {
        if payload.speakerSplitOperation != nil {
            return normalize(
                &payload.speakerSplitOperation!.derivedMergedResults,
                speakerNames: names
            )
        }
        return normalize(&payload.mergedResults, speakerNames: names)
    }

    private static func normalize(
        _ results: inout [MergedResult],
        speakerNames names: [String: String]
    ) -> Bool {
        var changed = false
        for index in results.indices {
            let result = results[index]
            guard !result.cleanedContent.isEmpty else { continue }
            let effectiveLabel = result.effectiveSpeakerLabel
            let effectiveName = names[effectiveLabel] ?? effectiveLabel
            var normalized = GeminiProvider.stripSpeakerPrefix(
                result.cleanedContent,
                displayName: effectiveName,
                speakerLabel: effectiveLabel
            )
            if normalized == result.cleanedContent, effectiveLabel != result.speakerLabel {
                let automaticName = names[result.speakerLabel] ?? result.speakerLabel
                normalized = GeminiProvider.stripSpeakerPrefix(
                    result.cleanedContent,
                    displayName: automaticName,
                    speakerLabel: result.speakerLabel
                )
            }
            if normalized != result.cleanedContent {
                results[index].cleanedContent = normalized
                changed = true
            }
        }
        return changed
    }
}
