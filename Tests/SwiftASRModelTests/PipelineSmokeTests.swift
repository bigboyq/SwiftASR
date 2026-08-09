import Foundation
import Testing
@testable import SwiftASR

/// One short real-audio pipeline smoke test.  It combines the former fixture,
/// speaker-profile, and punctuation tests so model initialization and the
/// frontend are paid for only once during routine model regression.
@Test func pipelineSmokeCoversProfilesPunctuationAndStableFingerprint() async throws {
    let sourcePath = ModelTestPaths.shortFixture.path
    #expect(FileManager.default.fileExists(atPath: sourcePath), "model fixture is missing")

    let pcm = try AudioConverter().loadAndResample(path: sourcePath)
    let cut = Array(pcm.prefix(30 * 16_000))
    let cutURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("pipeline_smoke_\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: cutURL) }
    try writePipelineSmokeWav(cut, to: cutURL)

    let pipeline = try AudioPipeline(modelsRoot: ModelTestPaths.modelsRoot.path)
    let (utterances, profiles, _) = try await pipeline.runPipelineWithProfiles(
        audioPath: cutURL.path
    ) { _, _, _ in }

    #expect(!utterances.isEmpty, "pipeline should produce at least one utterance")
    #expect(!profiles.isEmpty, "pipeline should produce at least one speaker profile")

    let punctuation: Set<Character> = ["，", "。", "？", "、"]
    #expect(
        utterances.contains { utterance in
            utterance.rawText.contains(where: punctuation.contains)
        },
        "pipeline should restore punctuation in at least one segment"
    )

    for profile in profiles {
        #expect(profile.fingerprintId.hasPrefix("fp_"))
        #expect(profile.centroidEmbedding.count == 192)
        #expect(profile.embeddingData.count == 192 * MemoryLayout<Float>.size)
        #expect(profile.speakerLabel.hasPrefix("说话人"))
        #expect(profile.chunkCount > 0)
        #expect(
            SpeakerFingerprint.makeId(embedding: profile.centroidEmbedding) == profile.fingerprintId
        )
    }
}

private func writePipelineSmokeWav(_ pcm: [Float], to url: URL) throws {
    let sampleRate = 16_000
    let bytesPerSample = MemoryLayout<Float>.size
    let dataSize = pcm.count * bytesPerSample
    let totalSize = 36 + dataSize
    var data = Data()
    data.append(Data("RIFF".utf8))
    data.append(littleEndian(UInt32(totalSize)))
    data.append(Data("WAVE".utf8))
    data.append(Data("fmt ".utf8))
    data.append(littleEndian(UInt32(16)))
    data.append(littleEndian(UInt16(3)))
    data.append(littleEndian(UInt16(1)))
    data.append(littleEndian(UInt32(sampleRate)))
    data.append(littleEndian(UInt32(sampleRate * bytesPerSample)))
    data.append(littleEndian(UInt16(bytesPerSample)))
    data.append(littleEndian(UInt16(32)))
    data.append(Data("data".utf8))
    data.append(littleEndian(UInt32(dataSize)))
    var samples = pcm
    data.append(Data(bytes: &samples, count: dataSize))
    try data.write(to: url, options: .atomic)
}

private func littleEndian(_ value: UInt32) -> Data {
    var value = value.littleEndian
    return Data(bytes: &value, count: MemoryLayout<UInt32>.size)
}

private func littleEndian(_ value: UInt16) -> Data {
    var value = value.littleEndian
    return Data(bytes: &value, count: MemoryLayout<UInt16>.size)
}
