import Testing
import Foundation
import AVFoundation
@testable import SwiftASR

// MARK: - AudioConverter 全面测试

@Test func converter16kHzMonoPassthrough() {
    // 已经是 16kHz mono Int16 的 wav → 转换后采样数应等于帧数
    guard let src = ProcessInfo.processInfo.environment["SWIFTASR_TEST_AUDIO_16K"],
          !src.isEmpty else { return }
    guard FileManager.default.fileExists(atPath: src) else {
        return
    }
    let c = AudioConverter()
    do {
        let pcm = try c.loadAndResample(path: src)
        // 10 分钟 16kHz mono 应该 ≈ 9.6M 采样（容许 ±4096 偏差：AVAudioFile 内部 buffer 边界）
        let expected = 10 * 60 * 16000
        #expect(abs(pcm.count - expected) < 4096, "got \(pcm.count) samples, expected ~\(expected)")
        #expect(pcm.allSatisfy { $0 >= -1.0 && $0 <= 1.0 }, "PCM should be in [-1, 1] range")
    } catch {
        Issue.record("conversion failed: \(error)")
    }
}

@Test func converter48kHzInputKeepsWallClockDuration() throws {
    let sampleRate = 48_000
    let durationSeconds = 3
    let pcm = (0..<(sampleRate * durationSeconds)).map { index in
        Float(sin(2.0 * .pi * 440.0 * Double(index) / Double(sampleRate)) * 0.25)
    }
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("converter_48k_\(UUID()).wav")
    try writeWav(path: tmp.path, pcm: pcm, sampleRate: sampleRate)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let converted = try AudioConverter().loadAndResample(path: tmp.path)

    // 48 kHz -> 16 kHz must preserve the 3-second wall-clock duration.
    // The previous input block returned the same source buffer repeatedly,
    // producing roughly 144,000 samples here instead of 48,000.
    #expect(abs(converted.count - 48_000) <= 128, "got \(converted.count) samples")
}

@Test func converterM4aFixtureKeepsMetadataDuration() throws {
    guard let src = ProcessInfo.processInfo.environment["SWIFTASR_TEST_AUDIO_COMPRESSED"],
          !src.isEmpty,
          FileManager.default.fileExists(atPath: src) else { return }

    let source = try AVAudioFile(forReading: URL(fileURLWithPath: src))
    let expected = Int((Double(source.length) * 16_000.0 / source.processingFormat.sampleRate).rounded())
    let converted = try AudioConverter().loadAndResample(path: src)

    // The primary regression fixture is 48 kHz AAC. Its 2,285-second duration
    // used to become 6,855 seconds after conversion, exactly three times long.
    #expect(abs(converted.count - expected) <= 1_024, "got \(converted.count), expected \(expected)")
}

@Test func converterEmptyFile() {
    // 写一个 0 字节 wav → 应该报错或返回空
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("empty_\(UUID()).wav")
    try? Data().write(to: tmp)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let c = AudioConverter()
    do {
        let pcm = try c.loadAndResample(path: tmp.path)
        #expect(pcm.isEmpty)
    } catch {
        // 也可以：AVAudioFile 打开失败 → 抛错；都算通过
    }
}

@Test func converterNonExistentFile() {
    let c = AudioConverter()
    do {
        _ = try c.loadAndResample(path: "/nonexistent/audio/file.wav")
        Issue.record("should have thrown for non-existent file")
    } catch {
        // expected
    }
}

@Test func converterCanCancelBeforeOpeningFile() {
    do {
        _ = try AudioConverter().loadAndResample(
            path: "/nonexistent/audio/file.wav",
            shouldCancel: { true }
        )
        Issue.record("cancelled conversion should stop before opening the file")
    } catch is AudioConverterError {
        // expected
    } catch {
        Issue.record("unexpected cancellation error: \(error)")
    }
}
