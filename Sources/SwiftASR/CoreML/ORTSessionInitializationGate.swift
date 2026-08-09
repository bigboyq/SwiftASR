import Foundation
import OnnxRuntimeBindings

/// ONNX Runtime's session planner has process-global initialization state that
/// is not safe to enter concurrently on the runtime version bundled here.
/// Session construction is rare (prewarm/model reload); inference remains
/// fully concurrent after this gate is released.
enum ORTSessionInitializationGate {
    private static let lock = NSLock()

    static func create(
        env: ORTEnv,
        modelPath: String,
        options: ORTSessionOptions
    ) throws -> ORTSession {
        lock.lock()
        defer { lock.unlock() }
        return try ORTSession(env: env, modelPath: modelPath, sessionOptions: options)
    }
}
