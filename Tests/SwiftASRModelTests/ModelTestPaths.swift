import Foundation

/// Repository-local paths shared by model contract tests.
/// Keeping discovery relative to the source file makes the tests portable
/// across checkouts instead of binding them to one developer's home path.
enum ModelTestPaths {
    static let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static let modelsRoot = projectRoot.appendingPathComponent("Resources/Models", isDirectory: true)
    static let shortFixture = projectRoot.appendingPathComponent(
        "Tests/Fixtures/zhongkelu_20260629_head10m.wav"
    )

    static func requiredEnvironmentPath(_ key: String) throws -> String {
        guard let value = ProcessInfo.processInfo.environment[key], !value.isEmpty else {
            throw NSError(
                domain: "SwiftASRModelTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Set (key) before running this opt-in diagnostic."]
            )
        }
        return value
    }
}

/// Real-audio diagnostics write reports and can run for minutes. They are
/// intentionally excluded from the model-contract regression target unless
/// explicitly requested.
enum ModelTestDiagnosticGate {
    static let isEnabled = ProcessInfo.processInfo.environment[
        "SWIFTASR_RUN_MODEL_DIAGNOSTICS"
    ] == "1"
}
