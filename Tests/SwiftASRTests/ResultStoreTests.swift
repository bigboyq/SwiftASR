import Testing
import Foundation
@testable import SwiftASR

@Test func resultPayloadFromUtterances() {
    let utterances = [
        UtteranceData(startMs: 0, endMs: 2000, rawText: "你好", speakerLabel: "说话人 1"),
        UtteranceData(startMs: 2000, endMs: 4000, rawText: "世界", speakerLabel: "说话人 1"),
        UtteranceData(startMs: 4000, endMs: 6000, rawText: "换人了", speakerLabel: "说话人 2"),
    ]
    let payload = ResultPayload.from(utterances: utterances, audioPath: "/x.wav", jobId: "abc")
    #expect(payload.segments.count == 3, "atomic turns must not be merged")
    #expect(payload.segments[0].rawText == "你好")
    #expect(payload.segments[1].rawText == "世界")
    #expect(payload.segments[2].rawText == "换人了")
}

@Test func resultWriteTransactionRestoresPreviousArtifactOnRollback() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("result_write_transaction_\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("job.result.json")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("previous".utf8).write(to: path)

    let payload = ResultPayload.from(
        utterances: [UtteranceData(startMs: 0, endMs: 100, rawText: "new", speakerLabel: "Speaker")],
        audioPath: "/tmp/audio.wav",
        jobId: "job"
    )
    let transaction = try ResultWriteTransaction(payload: payload, to: path)
    try transaction.commit()
    #expect(try String(contentsOf: path, encoding: .utf8).contains("new"))

    try transaction.rollback()
    #expect(try String(contentsOf: path, encoding: .utf8) == "previous")
}

@Test func resultWriteRejectsPayloadForDifferentCanonicalJobPath() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "result_job_identity_\(UUID().uuidString)"
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let pathJobID = String(repeating: "a", count: 64)
    let payloadJobID = String(repeating: "b", count: 64)
    let path = root.appendingPathComponent("\(pathJobID).result.json")
    let payload = ResultPayload(
        jobId: payloadJobID,
        audioPath: "/tmp/audio.wav",
        segments: []
    )

    #expect(throws: ResultPayloadValidationError.self) {
        try ResultStore.write(payload, to: path)
    }
    #expect(!FileManager.default.fileExists(atPath: path.path))
}

@Test func resultPayloadSpeakerOnlyRebuildsTurnsAndClearsDownstreamState() {
    var payload = ResultPayload(
        jobId: "job",
        audioPath: "/x.wav",
        segments: [
            ResultSegment(
                segmentId: 1,
                startMs: 0,
                endMs: 1_000,
                speakerLabel: "说话人 1",
                includedInPreview: false,
                rawText: "甲乙"
            )
        ],
        cleanedModel: "gemini"
    )

    let rebuilt = payload.replaceSegmentsWithSpeakerTurns(from: [
        UtteranceData(startMs: 0, endMs: 400, rawText: "甲", speakerLabel: "说话人 1"),
        UtteranceData(startMs: 400, endMs: 1_000, rawText: "乙", speakerLabel: "说话人 2"),
    ])

    #expect(rebuilt)
    #expect(payload.segments.map(\.rawText) == ["甲", "乙"])
    #expect(payload.segments.map(\.speakerLabel) == ["说话人 1", "说话人 2"])
    #expect(payload.segments.map(\.segmentId) == [1, 2])
    #expect(payload.segments.allSatisfy { $0.includedInPreview })
    #expect(payload.cleanedModel == nil)
}

@Test func resultPayloadSpeakerOnlyRejectsTextMismatch() {
    var payload = ResultPayload(
        jobId: "job",
        audioPath: "/x.wav",
        segments: [
            ResultSegment(
                segmentId: 1,
                startMs: 0,
                endMs: 1_000,
                speakerLabel: "说话人 1",
                rawText: "甲乙"
            )
        ]
    )

    let rebuilt = payload.replaceSegmentsWithSpeakerTurns(from: [
        UtteranceData(startMs: 0, endMs: 400, rawText: "甲", speakerLabel: "说话人 1"),
        UtteranceData(startMs: 400, endMs: 1_000, rawText: "丙", speakerLabel: "说话人 2"),
    ])

    #expect(!rebuilt)
    #expect(payload.segments.count == 1)
    #expect(payload.segments[0].rawText == "甲乙")
}

@Test func speakerRecognitionInputRoundTrip() throws {
    let tmpDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("speaker_input_\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tmpDir) }
    let path = ResultStore.speakerInputPath(jobId: "abcd", stageRoot: tmpDir.path)
    let input = SpeakerRecognitionInput(
        audioPath: "/x.wav",
        sentences: [ASRSentence(
            text: "甲。",
            startMs: 0,
            endMs: 1_000,
            tokens: [ASRToken(text: "甲", startMs: 0, endMs: 800), ASRToken(text: "。", startMs: 800, endMs: 1_000)]
        )]
    )

    try ResultStore.writeSpeakerInput(input, to: path)
    let restored = try ResultStore.readSpeakerInput(from: path)
    #expect(restored.version == 1)
    #expect(restored.sentences[0].tokens[1].text == "。")
    #expect(ResultStore.locateSpeakerInputPath(jobId: "abcd", stageRoot: tmpDir.path) == path)
}

@Test func speakerRecognitionInputRejectsUnsupportedVersion() throws {
    let input = SpeakerRecognitionInput(
        version: SpeakerRecognitionInput.currentVersion + 1,
        audioPath: "/x.wav",
        sentences: []
    )
    #expect(throws: SpeakerRecognitionInputValidationError.self) {
        try input.validate()
    }
}

@Test func resultPayloadValidationRejectsCorruptSplitLayer() {
    let duplicate = SpeakerSplitDerivedSegment(
        segmentId: 1,
        startMs: 0,
        endMs: 10,
        baselineSpeakerLabel: "说话人 1",
        speakerLabel: "说话人 2",
        rawText: "测试"
    )
    let payload = ResultPayload(
        jobId: "job",
        audioPath: "/x.wav",
        segments: [],
        speakerSplitOperation: SpeakerSplitOperation(
            splitProfileLabels: ["说话人 1"],
            routingSnapshotVersion: 1,
            routingSnapshotIdentity: "snapshot",
            derivedAt: ResultStore.nowIso(),
            derivedSegments: [duplicate, duplicate],
            derivedMergedResults: []
        )
    )

    #expect(throws: ResultPayloadValidationError.self) {
        try payload.validate()
    }
}

@Test func resultPayloadValidationRejectsUnknownMergedSpeakerAndManualOverride() {
    let segment = ResultSegment(
        segmentId: 1,
        startMs: 0,
        endMs: 1_000,
        speakerLabel: "S1",
        rawText: "原文"
    )
    let unknownAutomatic = ResultPayload(
        jobId: "job",
        audioPath: "/tmp/audio.wav",
        segments: [segment],
        mergedResults: [MergedResult(
            mergeId: 1,
            startMs: 0,
            endMs: 1_000,
            speakerLabel: "S9",
            rawContent: "原文"
        )]
    )
    #expect(throws: ResultPayloadValidationError.invalidMergedResultSpeakerLabel(
        mergeID: 1,
        label: "S9"
    )) {
        try unknownAutomatic.validate()
    }

    let invalidManual = ResultPayload(
        jobId: "job",
        audioPath: "/tmp/audio.wav",
        segments: [segment],
        mergedResults: [MergedResult(
            mergeId: 1,
            startMs: 0,
            endMs: 1_000,
            speakerLabel: "S1",
            manualSpeakerLabel: " S1 ",
            rawContent: "原文"
        )]
    )
    #expect(throws: ResultPayloadValidationError.invalidManualSpeakerLabel(
        mergeID: 1,
        label: " S1 "
    )) {
        try invalidManual.validate()
    }

    let unknownManual = ResultPayload(
        jobId: "job",
        audioPath: "/tmp/audio.wav",
        segments: [segment],
        mergedResults: [MergedResult(
            mergeId: 1,
            startMs: 0,
            endMs: 1_000,
            speakerLabel: "S1",
            manualSpeakerLabel: "S9",
            rawContent: "原文"
        )]
    )
    #expect(throws: ResultPayloadValidationError.invalidManualSpeakerLabel(
        mergeID: 1,
        label: "S9"
    )) {
        try unknownManual.validate()
    }
}

@Test func resultPayloadValidationAcceptsDerivedMergedManualSpeakerFromActiveLabels() throws {
    let derived = [SpeakerSplitDerivedSegment(
        segmentId: 1,
        startMs: 0,
        endMs: 300,
        baselineSpeakerLabel: "说话人 1",
        speakerLabel: "说话人 2",
        rawText: "甲乙丙"
    )]
    var payload = makeSplitValidationPayload(derivedSegments: derived)
    payload.speakerSplitOperation?.derivedMergedResults[0].manualSpeakerLabel = "说话人 1"

    try payload.validate()
}

@Test func resultPayloadValidationAcceptsOneToManySplitAndLegalMergedGroups() throws {
    let derived = [
        SpeakerSplitDerivedSegment(
            segmentId: 1,
            startMs: 0,
            endMs: 100,
            baselineSpeakerLabel: "说话人 1",
            speakerLabel: "说话人 2",
            rawText: "甲"
        ),
        SpeakerSplitDerivedSegment(
            segmentId: 2,
            startMs: 100,
            endMs: 200,
            baselineSpeakerLabel: "说话人 1",
            speakerLabel: "说话人 2",
            rawText: "乙"
        ),
        SpeakerSplitDerivedSegment(
            segmentId: 3,
            startMs: 200,
            endMs: 300,
            baselineSpeakerLabel: "说话人 1",
            speakerLabel: "说话人 3",
            rawText: "丙"
        ),
    ]
    let payload = makeSplitValidationPayload(derivedSegments: derived)

    try payload.validate()

    #expect(payload.speakerSplitOperation?.derivedMergedResults.count == 2)
    #expect(payload.speakerSplitOperation?.derivedMergedResults[0].rawContent == "甲，乙。")
}

@Test func resultPayloadValidationMatchesLargeInterleavedOneToManySplitLinearly() throws {
    let baselineCount = 500
    var baseline: [ResultSegment] = []
    var derived: [SpeakerSplitDerivedSegment] = []
    baseline.reserveCapacity(baselineCount)
    derived.reserveCapacity(baselineCount * 2)

    for index in 0..<baselineCount {
        let baselineLabel = index.isMultiple(of: 2) ? "说话人 1" : "说话人 2"
        let effectiveLabel = baselineLabel == "说话人 1" ? "说话人 3" : baselineLabel
        let startMs = index * 20
        baseline.append(ResultSegment(
            segmentId: index + 1,
            startMs: startMs,
            endMs: startMs + 20,
            speakerLabel: baselineLabel,
            rawText: "甲乙"
        ))
        derived.append(SpeakerSplitDerivedSegment(
            segmentId: index * 2 + 1,
            startMs: startMs,
            endMs: startMs + 10,
            baselineSpeakerLabel: baselineLabel,
            speakerLabel: effectiveLabel,
            rawText: "甲"
        ))
        derived.append(SpeakerSplitDerivedSegment(
            segmentId: index * 2 + 2,
            startMs: startMs + 10,
            endMs: startMs + 20,
            baselineSpeakerLabel: baselineLabel,
            speakerLabel: effectiveLabel,
            rawText: "乙"
        ))
    }
    let payload = ResultPayload(
        jobId: "large-split-validation-job",
        audioPath: "/tmp/large-split-validation.wav",
        segments: baseline,
        speakerSplitOperation: SpeakerSplitOperation(
            splitProfileLabels: ["说话人 1"],
            routingSnapshotVersion: 1,
            routingSnapshotIdentity: "snapshot",
            derivedAt: ResultStore.nowIso(),
            derivedSegments: derived,
            derivedMergedResults: SegmentMerger().buildMergedResults(
                segments: derived.map(\.effectiveSegment)
            )
        )
    )

    try payload.validate()
}

@Test func resultPayloadValidationRejectsEmptyActiveSplitLayer() {
    let payload = makeSplitValidationPayload(derivedSegments: [])

    #expect(throws: ResultPayloadValidationError.emptyDerivedSegments) {
        try payload.validate()
    }
}

@Test func resultPayloadValidationRejectsSplitProfileOutsideBaseline() {
    var payload = makeSplitValidationPayload(derivedSegments: [
        SpeakerSplitDerivedSegment(
            segmentId: 1,
            startMs: 0,
            endMs: 300,
            baselineSpeakerLabel: "说话人 1",
            speakerLabel: "说话人 2",
            rawText: "甲乙丙"
        )
    ])
    payload.speakerSplitOperation?.splitProfileLabels = ["说话人 9"]

    #expect(throws: ResultPayloadValidationError.splitProfileLabelNotInBaseline(
        "说话人 9"
    )) {
        try payload.validate()
    }
}

@Test func resultPayloadValidationRejectsSplitLayerThatDropsRawText() {
    let derived = [SpeakerSplitDerivedSegment(
        segmentId: 1,
        startMs: 0,
        endMs: 300,
        baselineSpeakerLabel: "说话人 1",
        speakerLabel: "说话人 2",
        rawText: "甲乙"
    )]
    let payload = makeSplitValidationPayload(derivedSegments: derived)

    #expect(throws: ResultPayloadValidationError.derivedSegmentRawTextMismatch(
        segmentID: 1
    )) {
        try payload.validate()
    }
}

@Test func resultPayloadValidationRejectsIncompleteSplitTimelineCoverage() {
    let derived = [SpeakerSplitDerivedSegment(
        segmentId: 1,
        startMs: 10,
        endMs: 300,
        baselineSpeakerLabel: "说话人 1",
        speakerLabel: "说话人 2",
        rawText: "甲乙丙"
    )]
    let payload = makeSplitValidationPayload(derivedSegments: derived)

    #expect(throws: ResultPayloadValidationError.incompleteDerivedBaselineSegment(
        segmentID: 1
    )) {
        try payload.validate()
    }
}

@Test func resultPayloadValidationRejectsOverlappingSplitSegments() {
    let derived = [
        SpeakerSplitDerivedSegment(
            segmentId: 1,
            startMs: 0,
            endMs: 200,
            baselineSpeakerLabel: "说话人 1",
            speakerLabel: "说话人 2",
            rawText: "甲乙"
        ),
        SpeakerSplitDerivedSegment(
            segmentId: 2,
            startMs: 150,
            endMs: 300,
            baselineSpeakerLabel: "说话人 1",
            speakerLabel: "说话人 3",
            rawText: "丙"
        ),
    ]
    let payload = makeSplitValidationPayload(derivedSegments: derived)

    #expect(throws: ResultPayloadValidationError.overlappingDerivedSegments(
        previousSegmentID: 1,
        segmentID: 2
    )) {
        try payload.validate()
    }
}

@Test func resultPayloadValidationRejectsInvalidDerivedMergedStructure() {
    let derived = [SpeakerSplitDerivedSegment(
        segmentId: 1,
        startMs: 0,
        endMs: 300,
        baselineSpeakerLabel: "说话人 1",
        speakerLabel: "说话人 2",
        rawText: "甲乙丙"
    )]
    let invalidMerged = [MergedResult(
        mergeId: 1,
        startMs: 0,
        endMs: 300,
        speakerLabel: "说话人 2",
        rawContent: "被改写的原文"
    )]
    let payload = makeSplitValidationPayload(
        derivedSegments: derived,
        derivedMergedResults: invalidMerged
    )

    #expect(throws: ResultPayloadValidationError.invalidDerivedMergedStructure) {
        try payload.validate()
    }
}

@Test func speakerInputLookupPrefersHistoricalResultDirectory() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("speaker_input_historical_\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let jobId = "abcdef"
    let stored = root
        .appendingPathComponent("stage/stage/ab/cd/\(jobId).result.json")
    let historicalSidecar = stored.deletingLastPathComponent()
        .appendingPathComponent("\(jobId).speaker-input.json")
    try FileManager.default.createDirectory(
        at: historicalSidecar.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data("{}".utf8).write(to: historicalSidecar)

    let located = ResultStore.locateSpeakerInputPath(
        jobId: jobId, storedPath: stored.path, stageRoot: root.appendingPathComponent("canonical").path
    )
    #expect(located?.path == historicalSidecar.path)
}

@Test func speakerDiagnosticsRoundTrip() throws {
    let tmpDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("speaker_diagnostics_\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tmpDir) }
    let path = ResultStore.speakerDiagnosticsPath(jobId: "abcd", stageRoot: tmpDir.path)
    let diagnostics = SpeakerDiarizationDiagnostics(
        temporalWaterfall: SpeakerTemporalWaterfallDiagnostic(
            windowCount: 2,
            profileCount: 2,
            directCount: 1,
            otherCount: 0,
            unresolvedCount: 0,
            tokenEvidence: [SpeakerTokenEvidenceDiagnostic(
                startMs: 1_000,
                endMs: 1_500,
                scores: [0: 0.81, 1: 0.75],
                decisionLabel: 0,
                decisionSource: "temporal",
                baselineRoute: "deferred"
            )]
        )
    )

    try ResultStore.writeSpeakerDiagnostics(diagnostics, to: path)
    let restored = try ResultStore.readSpeakerDiagnostics(from: path)
    #expect(restored.version == 7)
    #expect(restored.temporalWaterfall.windowCount == 2)
    #expect(restored.temporalWaterfall.tokenEvidence[0].decisionLabel == 0)
}

@Test func speakerRoutingSnapshotRoundTripAndLookup() throws {
    let tmpDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("speaker_routing_snapshot_\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tmpDir) }
    let path = ResultStore.speakerRoutingSnapshotPath(jobId: "abcd", stageRoot: tmpDir.path)
    let snapshot = SpeakerRoutingSnapshot(
        profileMappings: [.init(acousticLabel: 0, speakerLabel: "说话人 1", cohesion: 0.62)],
        tokens: [.init(
            sentenceIndex: 2, tokenIndex: 3, text: "好", startMs: 1_000, endMs: 1_200,
            scores: [0: 0.81, 1: 0.75], supportFrames: 12,
            baselineAcousticLabel: 0, finalAcousticLabel: 1
        )],
        pauseCandidates: [.init(
            leftSentenceIndex: 2, leftTokenIndex: 3,
            rightSentenceIndex: 2, rightTokenIndex: 4,
            candidateGapMs: 900, confirmedSilenceMs: nil
        )]
    )

    try ResultStore.writeSpeakerRoutingSnapshot(snapshot, to: path)
    let restored = try ResultStore.readSpeakerRoutingSnapshot(from: path)
    #expect(restored.version == SpeakerRoutingSnapshot.currentVersion)
    #expect(restored.stableIdentity == snapshot.stableIdentity)
    #expect(restored.profileMappings[0].cohesion == 0.62)
    #expect(restored.tokens[0].supportFrames == 12)
    #expect(restored.tokens[0].finalAcousticLabel == 1)
    #expect(restored.pauseCandidates[0].confirmedSilenceMs == nil)
    #expect(restored.routingPolicy == .production)
    #expect(ResultStore.locateSpeakerRoutingSnapshotPath(jobId: "abcd", stageRoot: tmpDir.path) == path)
}

@Test func resultStoreRoundTrip() throws {
    let tmpDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("result_store_\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let jobId = ResultStore.hashAudioPath("/tmp/test.wav")
    let path = ResultStore.stageResultPath(jobId: jobId, stageRoot: tmpDir.path)
    let payload = ResultPayload(
        jobId: jobId,
        audioPath: "/tmp/test.wav",
        segments: [
            ResultSegment(segmentId: 1, startMs: 0, endMs: 1000, speakerLabel: "说话人 1", rawText: "你好"),
            ResultSegment(segmentId: 2, startMs: 1000, endMs: 2000, speakerLabel: "说话人 2", rawText: "世界"),
        ],
        finishedAt: "2026-07-08T10:00:00.000Z"
    )
    try ResultStore.write(payload, to: path)
    #expect(FileManager.default.fileExists(atPath: path.path))
    let reloaded = try ResultStore.read(from: path)
    #expect(reloaded.jobId == jobId)
    #expect(reloaded.segments.count == 2)
    #expect(reloaded.mergedResults.isEmpty)
}

@Test func resultPayloadDecodesLegacyMissingOptionalFields() throws {
    let json = """
    {
      "job_id": "legacy-job",
      "audio_path": "/tmp/legacy.wav",
      "segments": [
        {"segment_id": 1, "start_ms": 0, "end_ms": 1000, "speaker_label": "Speaker1", "raw_text": "你好"}
      ]
    }
    """.data(using: .utf8)!

    let payload = try JSONDecoder().decode(ResultPayload.self, from: json)
    #expect(payload.segments.count == 1)
    #expect(payload.segments[0].includedInPreview)
    #expect(payload.speakers.isEmpty)
    #expect(payload.mergedResults.isEmpty)
}

@Test func resultPayloadRoundTripsSplitBaselineCleanup() throws {
    let baseline = SpeakerSplitBaselineCleanup(
        status: JobStatus.done.rawValue,
        completedAt: Date(timeIntervalSince1970: 123),
        model: "gemini-2.5-pro",
        processingSeconds: 42
    )
    let payload = ResultPayload(
        jobId: "split-baseline",
        audioPath: "/tmp/split.wav",
        segments: [ResultSegment(
            segmentId: 1,
            startMs: 0,
            endMs: 1_000,
            speakerLabel: "说话人 1",
            rawText: "测试"
        )],
        speakerSplitOperation: SpeakerSplitOperation(
            splitProfileLabels: ["说话人 1"],
            routingSnapshotVersion: 1,
            routingSnapshotIdentity: "snapshot",
            derivedAt: "2026-07-26T00:00:00Z",
            derivedSegments: [],
            derivedMergedResults: [],
            baselineCleanup: baseline
        )
    )

    let restored = try JSONDecoder().decode(
        ResultPayload.self,
        from: JSONEncoder().encode(payload)
    )
    #expect(restored.speakerSplitOperation?.baselineCleanup == baseline)
}

@Test func resultStoreUsesExistingHistoricalPathForReadAndWrite() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("result_path_\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let jobId = "abcdef"
    let stored = root
        .appendingPathComponent("stage/stage/ab/cd/\(jobId).result.json")
    let payload = ResultPayload(jobId: jobId, audioPath: "/tmp/legacy.wav", segments: [])
    try ResultStore.write(payload, to: stored)

    let readPath = try ResultStore.readPath(jobId: jobId, storedPath: stored.path)
    let writePath = ResultStore.writePath(jobId: jobId, storedPath: stored.path)
    #expect(readPath.path == stored.path)
    #expect(writePath.path == stored.path)
}

@Test func resultArtifactDeletionCanRestoreAfterDatabaseFailure() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("result_artifacts_restore_" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let jobId = "abcdef"
    let stored = root.appendingPathComponent("stage/stage/ab/cd/" + jobId + ".result.json")
    try FileManager.default.createDirectory(at: stored.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("result".utf8).write(to: stored)

    let transaction = try ResultArtifactDeletionTransaction(
        jobId: jobId,
        storedPath: stored.path,
        stageRoot: root.path
    )
    #expect(!FileManager.default.fileExists(atPath: stored.path))
    try transaction.restore()
    #expect(FileManager.default.fileExists(atPath: stored.path))
    #expect(String(data: try Data(contentsOf: stored), encoding: .utf8) == "result")
}

@Test func resultSpeakerPersistsProfileReferenceAndOptionalPipelineFingerprint() throws {
    let payload = ResultPayload(
        jobId: "job",
        audioPath: "/tmp/x.wav",
        segments: [ResultSegment(segmentId: 1, startMs: 0, endMs: 1_000, speakerLabel: "Speaker0", rawText: "你好")],
        speakers: [ResultSpeaker(
            speakerLabel: "Speaker0",
            speakerProfileId: "profile-123",
            fingerprintId: "fp_system_speaker"
        )]
    )
    let encoded = try JSONEncoder().encode(payload)
    let json = String(decoding: encoded, as: UTF8.self)
    #expect(json.contains("speaker_profile_id"))
    #expect(json.contains("fingerprint_id"))
    #expect(!json.contains("speaker_name"))
    let decoded = try JSONDecoder().decode(ResultPayload.self, from: encoded)
    #expect(decoded.speakerProfileId(for: "Speaker0") == "profile-123")
    #expect(decoded.fingerprintId(for: "Speaker0") == "fp_system_speaker")
}

private func makeSplitValidationPayload(
    derivedSegments: [SpeakerSplitDerivedSegment],
    derivedMergedResults: [MergedResult]? = nil
) -> ResultPayload {
    let merged = derivedMergedResults ?? SegmentMerger().buildMergedResults(
        segments: derivedSegments.map(\.effectiveSegment)
    )
    return ResultPayload(
        jobId: "split-validation-job",
        audioPath: "/tmp/split-validation.wav",
        segments: [ResultSegment(
            segmentId: 1,
            startMs: 0,
            endMs: 300,
            speakerLabel: "说话人 1",
            rawText: "甲乙丙"
        )],
        speakerSplitOperation: SpeakerSplitOperation(
            splitProfileLabels: ["说话人 1"],
            routingSnapshotVersion: 1,
            routingSnapshotIdentity: "snapshot",
            derivedAt: ResultStore.nowIso(),
            derivedSegments: derivedSegments,
            derivedMergedResults: merged
        )
    )
}

@Test func resultStoreAtomicOverwrite() throws {
    let tmpDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("result_store_\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let jobId = ResultStore.hashAudioPath("/tmp/overwrite.wav")
    let path = ResultStore.stageResultPath(jobId: jobId, stageRoot: tmpDir.path)

    // 写第一次
    let p1 = ResultPayload(jobId: jobId, audioPath: "/tmp/overwrite.wav",
        segments: [ResultSegment(segmentId: 1, startMs: 0, endMs: 1000, speakerLabel: "S1", rawText: "v1")])
    try ResultStore.write(p1, to: path)
    // 写第二次（应该覆盖）
    let p2 = ResultPayload(jobId: jobId, audioPath: "/tmp/overwrite.wav",
        segments: [
            ResultSegment(segmentId: 1, startMs: 0, endMs: 1000, speakerLabel: "S1", rawText: "v2"),
            ResultSegment(segmentId: 2, startMs: 1000, endMs: 2000, speakerLabel: "S2", rawText: "v2b"),
        ])
    try ResultStore.write(p2, to: path)

    let reloaded = try ResultStore.read(from: path)
    #expect(reloaded.segments.count == 2)
    #expect(reloaded.segments[0].rawText == "v2")
}

