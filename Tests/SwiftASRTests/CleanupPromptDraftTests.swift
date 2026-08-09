import Testing
@testable import SwiftASR

@Suite("Cleanup prompt draft synchronization")
struct CleanupPromptDraftTests {
    @Test func externalResetReplacesStaleDraft() {
        let replacement = CleanupPromptDraftSynchronization.replacement(
            currentDraft: "用户修改但尚未离开页面",
            externalPrompt: SettingsStore.CleanupDefaults.prompt
        )

        #expect(replacement == SettingsStore.CleanupDefaults.prompt)
    }

    @Test func localBindingEchoDoesNotReplaceDraft() {
        let replacement = CleanupPromptDraftSynchronization.replacement(
            currentDraft: "正在输入",
            externalPrompt: "正在输入"
        )

        #expect(replacement == nil)
    }
}
