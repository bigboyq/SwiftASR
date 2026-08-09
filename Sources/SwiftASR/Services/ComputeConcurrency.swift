import Foundation
import Darwin

/// Shared CPU worker budget for DSP-style work. Apple Silicon exposes its
/// performance-core cluster through hw.perflevel0.physicalcpu; using that
/// count avoids flooding efficiency cores with latency-sensitive FFT work.
public enum ComputeConcurrency {
    public static let performanceCoreCount: Int = {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let status = sysctlbyname(
            "hw.perflevel0.physicalcpu",
            &value,
            &size,
            nil,
            0
        )
        if status == 0, value > 0 {
            return Int(value)
        }
        return max(1, ProcessInfo.processInfo.activeProcessorCount)
    }()
}

/// ASR keeps its established two independent sessions.
public enum ASRCPUConcurrency {
    public static let workerCount = 2

    public static func intraOpThreads(performanceCoreCount: Int) -> Int {
        max(1, max(1, performanceCoreCount) / workerCount)
    }

    public static let performanceCoreHalfIntraOpThreads = intraOpThreads(
        performanceCoreCount: ComputeConcurrency.performanceCoreCount
    )
}
