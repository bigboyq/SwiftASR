/// Result-file persistence and manual merged-text editing. Keeping these
/// mutations together gives the main view a single editing boundary while the
/// presentation extension remains read-only.
extension ResultsContent {
    @discardableResult
    func persist(_ payload: ResultPayload, action: String) -> Bool {
        guard viewState.activeJobID == jobId, payload.jobId == jobId else {
            persistenceError = "\(action)失败：结果所属任务与当前页面不一致"
            Logger.shared.error(
                "\(action)被拒绝：页面 job=\(jobId)，payload job=\(payload.jobId)，" +
                "state job=\(viewState.activeJobID ?? "nil")"
            )
            return false
        }
        do {
            try ResultStore.write(
                payload,
                to: ResultStore.writePath(jobId: jobId, storedPath: currentJob?.transcriptPath)
            )
            persistenceError = nil
            return true
        } catch {
            // R4-P1-6：错误文案走统一 mapper，不直接拼 localizedDescription。
            persistenceError = "\(action)失败：" + UserFacingErrorMapper.message(for: error)
            Logger.shared.error("\(action)失败：\(error)")
            return false
        }
    }

    @discardableResult
    func saveModelChanges(action: String) -> Bool {
        // R4-P1-4：保存逻辑收敛到 ModelContextSaver，错误文案走统一 mapper。
        let outcome = ModelContextSaver.save(modelContext, action: action)
        persistenceError = outcome.userMessage
        return outcome.success
    }

    func beginManualEdit(mergeId: Int) {
        guard let result = activeMergedResults(payload).first(where: { $0.mergeId == mergeId }) else { return }
        editingMergedResult = result
    }

    @discardableResult
    func restoreManualSpeakerAssignments(mergeIDs: [Int]) -> Bool {
        guard let payload else { return false }
        let targetIDs = Set(mergeIDs)
        let automaticLabels = activeMergedResults(payload).compactMap {
            targetIDs.contains($0.mergeId) && $0.manualSpeakerLabel != nil
                ? $0.speakerLabel
                : nil
        }
        guard let working = ResultEditingService.clearingManualSpeakerAssignments(
            from: payload,
            mergeIDs: mergeIDs
        ) else { return false }
        guard persist(working, action: "还原说话人") else { return false }
        self.payload = working
        inScopeLabels.formUnion(automaticLabels)
        showMerged = true
        showRawText = !ResultsPresentation.hasCompleteCleanedResults(in: working)
        previewContentVersion &+= 1
        return true
    }

    @discardableResult
    func saveManualEdit(resultId: Int, text: String, speakerLabel: String) -> Bool {
        guard let payload,
              let working = ResultEditingService.applyingManualEdit(
                  to: payload,
                  mergeId: resultId,
                  text: text,
                  speakerLabel: speakerLabel
              ) else { return false }
        guard persist(working, action: "保存人工编辑") else { return false }
        self.payload = working
        inScopeLabels.insert(speakerLabel)
        showMerged = true
        showRawText = !ResultsPresentation.hasCompleteCleanedResults(in: working)
        previewContentVersion &+= 1
        return true
    }
}
