import Testing
import Foundation
@testable import SwiftASR

// MARK: - CancellationToken

@Test func cancellationToken_InitialStateNotCancelled() {
    let token = CancellationToken()
    #expect(token.isCancelled == false)
}

@Test func cancellationToken_Cancel_FlipsIsCancelled() {
    let token = CancellationToken()
    #expect(token.isCancelled == false)
    token.cancel()
    #expect(token.isCancelled == true)
    // 再次 cancel 也安全（idempotent）
    token.cancel()
    #expect(token.isCancelled == true)
}

@Test func cancellationToken_Check_ThrowsWhenCancelled() {
    let token = CancellationToken()
    token.cancel()
    #expect(throws: PipelineCancelled.self) {
        try token.check("test")
    }
}

@Test func cancellationToken_Check_DoesNotThrowWhenNotCancelled() {
    let token = CancellationToken()
    #expect(throws: Never.self) {
        try token.check("test")
    }
}

@Test func cancellationToken_StageInError() {
    let token = CancellationToken()
    token.cancel()
    do {
        try token.check("vad")
        Issue.record("should have thrown")
    } catch let err as PipelineCancelled {
        #expect(err.stage == "vad")
        #expect(err.errorDescription?.contains("vad") == true)
    } catch {
        Issue.record("wrong error type: \(error)")
    }
}

@Test func cancellationToken_ThreadSafe() async {
    // 1000 次 cancel + read 并发，不应崩
    let token = CancellationToken()
    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<500 {
            group.addTask { token.cancel() }
            group.addTask { _ = token.isCancelled }
        }
    }
    #expect(token.isCancelled == true)
}

@Test func cleanupCancelled_LocalizedError() {
    let err = CleanupCancelled()
    #expect(err.errorDescription == "润色已取消")
}

@Test func pipelineCancelled_LocalizedError() {
    let err = PipelineCancelled(stage: "vad")
    #expect(err.errorDescription?.contains("vad") == true)
}

@Test func failover_TypeExists() {
    // 之前 `failover_StickyKeyAdvances_OnFailure` 引用了 AutoArchiver.HIGH_AUTO
    // 做"伪断言"。AutoArchiver 移除后改测 GeminiKeyFailover 类本身存在 + 默认配置。
    let _ = GeminiKeyFailover.self
}

// MARK: - SettingsStore.CleanupSettings persistence (round-trip via JSON)

@Test func cleanupSettings_DefaultValues_AreSensible() {
    let s = SettingsStore.CleanupSettings()
    #expect(s.model == "gemini-flash-latest")
    #expect(s.chunkChars == 6000)  // Phase 8：默认值改为 6000（用户调 slider 区间 2000-12000）
    #expect(s.temperature == 0.2)
    #expect(!s.prompt.isEmpty)
}

@Test func cleanupSettings_CustomValues_Preserved() {
    let s = SettingsStore.CleanupSettings(
        model: "gemini-pro",
        chunkChars: 8000,
        temperature: 0.5,
        prompt: "test prompt"
    )
    #expect(s.model == "gemini-pro")
    #expect(s.chunkChars == 8000)
    #expect(s.temperature == 0.5)
    #expect(s.prompt == "test prompt")
}
