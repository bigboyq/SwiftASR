import Testing
import Foundation
@testable import SwiftASR

// MARK: - ResultStore 全面测试

@Test func resultStoreHashStabilityAcrossCase() {
    // macOS APFS case-insensitive：funasr-Mac 的 hash 应该大小写无关
    // SwiftASR 的 hash 内部已 .lowercased()
    let h1 = ResultStore.hashAudioPath("/Users/q/Desktop/A.wav")
    let h2 = ResultStore.hashAudioPath("/Users/q/Desktop/a.wav")
    #expect(h1 == h2, "should be case-insensitive")
}

@Test func resultStoreHashIgnoresTrailingSlash() {
    let h1 = ResultStore.hashAudioPath("/Users/q/Desktop/file.wav")
    let h2 = ResultStore.hashAudioPath("/Users/q/Desktop/file.wav/")
    #expect(h1 == h2)
}

@Test func resultStoreHashHex() {
    // SHA256 hex 64 字符
    let h = ResultStore.hashAudioPath("/x.wav")
    #expect(h.count == 64)
    #expect(h.allSatisfy { $0.isHexDigit })
}

@Test func resultStoreHashResolvesRelativeSymbolicLinks() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("SwiftASR-hash-symlink-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let targetDirectory = root.appendingPathComponent("target", isDirectory: true)
    let linkDirectory = root.appendingPathComponent("links", isDirectory: true)
    try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: linkDirectory, withIntermediateDirectories: true)
    let target = targetDirectory.appendingPathComponent("audio.wav")
    #expect(FileManager.default.createFile(atPath: target.path, contents: Data()))
    let relativeLink = linkDirectory.appendingPathComponent("audio-link.wav")
    try FileManager.default.createSymbolicLink(
        atPath: relativeLink.path,
        withDestinationPath: "../target/audio.wav"
    )

    #expect(ResultStore.hashAudioPath(relativeLink.path) == ResultStore.hashAudioPath(target.path))
}

@Test func resultStoreHashKeepsNonexistentPathStandardizationStable() {
    let root = "/tmp/SwiftASR-missing-path-\(UUID().uuidString)"
    let pathWithDotDot = root + "/future/../audio.wav"
    let standardizedPath = root + "/audio.wav"

    #expect(ResultStore.hashAudioPath(pathWithDotDot) == ResultStore.hashAudioPath(standardizedPath))
}

@Test func resultStorePathBucketingForJobId() {
    // Phase 7 修 double-stage bug：stageRoot 已经是 stage 根（不再 append stage）。
    // jobId="abcd..." 应落 <stageRoot>/ab/cd/abcd1234.result.json
    let url = ResultStore.stageResultPath(jobId: "abcd1234", stageRoot: "/tmp/sr_test")
    #expect(url.path.hasSuffix("/sr_test/ab/cd/abcd1234.result.json"))
    #expect(!url.path.contains("/stage/stage/"), "不应该出现双 stage")
}

@Test func resultStorePayloadJSONStableFieldOrder() {
    let p = ResultPayload(
        jobId: "j1",
        audioPath: "/x.wav",
        segments: [
            ResultSegment(segmentId: 2, startMs: 1000, endMs: 2000, speakerLabel: "S2", rawText: "hi"),
            ResultSegment(segmentId: 1, startMs: 0, endMs: 1000, speakerLabel: "S1", rawText: "hello"),
        ]
    )
    let data = try? JSONEncoder().encode(p)
    let s = String(data: data ?? Data(), encoding: .utf8) ?? ""
    #expect(s.contains("\"job_id\":\"j1\""))
    // Swift JSONEncoder 默认 escape slashes：/x.wav → \/x.wav
    #expect(s.contains("audio_path") && s.contains("x.wav"))
}

@Test func resultStoreSegmentEquality() {
    let s1 = ResultSegment(segmentId: 1, startMs: 0, endMs: 1000, speakerLabel: "S1", rawText: "hi")
    let s2 = ResultSegment(segmentId: 1, startMs: 0, endMs: 1000, speakerLabel: "S1", rawText: "hi")
    #expect(s1 == s2)
    let s3 = ResultSegment(segmentId: 1, startMs: 0, endMs: 1000, speakerLabel: "S2", rawText: "hi")
    #expect(s1 != s3)
}

@Test func resultStoreNowIso() {
    let s = ResultStore.nowIso()
    #expect(s.contains("T"))
    #expect(s.contains("Z"))
}

@Test func resultStoreWriteReadFingerprint() throws {
    // fingerprint：相同 payload 写两次后读出来 fingerprint_id 必须一致
    let tmpDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("result_fp_\(UUID())")
    defer { try? FileManager.default.removeItem(at: tmpDir) }
    let jobId = ResultStore.hashAudioPath("/x.wav")
    let path = ResultStore.stageResultPath(jobId: jobId, stageRoot: tmpDir.path)

    let p = ResultPayload(jobId: jobId, audioPath: "/x.wav", segments: [
        ResultSegment(segmentId: 1, startMs: 0, endMs: 1000, speakerLabel: "S1", rawText: "hello")
    ])
    try ResultStore.write(p, to: path)
    let reloaded = try ResultStore.read(from: path)
    #expect(reloaded.segments[0].speakerLabel == "S1")
    #expect(reloaded.jobId == jobId)
}

@Test func resultPayloadFromEmptyUtterances() {
    let payload = ResultPayload.from(utterances: [], audioPath: "/x.wav", jobId: "j1")
    #expect(payload.segments.isEmpty)
    #expect(payload.finishedAt != nil)
}

@Test func resultPayloadFromSkipsEmptyText() {
    let utterances = [
        UtteranceData(startMs: 0, endMs: 1000, rawText: "   ", speakerLabel: "S1"),  // 空白被跳过
        UtteranceData(startMs: 1000, endMs: 2000, rawText: "hello", speakerLabel: "S1"),
    ]
    let payload = ResultPayload.from(utterances: utterances, audioPath: "/x.wav", jobId: "j1")
    #expect(payload.segments.count == 1, "blank should be skipped")
    #expect(payload.segments[0].rawText == "hello")
}

@Test func resultPayloadValidationRejectsDuplicateAndInvalidBoundaries() {
    let duplicate = ResultPayload(
        jobId: "job",
        audioPath: "/x.wav",
        segments: [
            ResultSegment(segmentId: 1, startMs: 0, endMs: 100, speakerLabel: "S1", rawText: "a"),
            ResultSegment(segmentId: 1, startMs: 100, endMs: 50, speakerLabel: "S2", rawText: "b")
        ]
    )

    #expect(throws: ResultPayloadValidationError.duplicateSegmentID(1)) {
        try duplicate.validate()
    }

    let invalidTime = ResultPayload(
        jobId: "job",
        audioPath: "/x.wav",
        segments: [
            ResultSegment(segmentId: 2, startMs: 100, endMs: 50, speakerLabel: "S1", rawText: "a")
        ]
    )
    #expect(throws: ResultPayloadValidationError.invalidSegmentTime(
        segmentID: 2, startMs: 100, endMs: 50
    )) {
        try invalidTime.validate()
    }
}

@Test func resultPayloadValidationRejectsWrongJobID() {
    let payload = ResultPayload(jobId: "actual", audioPath: "/x.wav", segments: [])
    #expect(throws: ResultPayloadValidationError.jobIDMismatch(
        expected: "expected", actual: "actual"
    )) {
        try payload.validate(expectedJobID: "expected")
    }
}
