import Foundation
import Testing
@testable import SwiftASR

@Test func audioPipelineInitializationFailsForMissingModels() {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("swiftasr_missing_models_\(UUID().uuidString)")

    #expect(throws: Error.self) {
        _ = try AudioPipeline(modelsRoot: root.path)
    }
}

@Test func prewarmedStorePropagatesModelInitializationFailure() async {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("swiftasr_missing_models_\(UUID().uuidString)")
    let store = PrewarmedAudioPipelineStore()

    await #expect(throws: Error.self) {
        _ = try await store.acquire(modelsRoot: root.path)
    }
    #expect(store.readiness(for: root.path) == .idle)
    store.release()
}
