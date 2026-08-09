import Foundation

/// Writes non-authoritative speaker sidecars after diarization succeeds.
///
/// The pipeline owns when a run has produced valid speaker evidence; this
/// writer owns translating that evidence into diagnostics and replay artifacts.
/// Sidecar failures stay visible in logs but never invalidate the completed
/// transcription result.
enum SpeakerArtifactWriter {
    static func write(
        result: SpeakerDiarizationPipeline.Result,
        policy: SpeakerTemporalPolicy,
        audioPath: String,
        diagnosticsURL: URL?
    ) {
        writeDiagnostics(result: result, audioPath: audioPath, diagnosticsURL: diagnosticsURL)
        writeRoutingSnapshot(
            result: result, policy: policy,
            audioPath: audioPath, diagnosticsURL: diagnosticsURL
        )
    }

    private static func writeRoutingSnapshot(
        result: SpeakerDiarizationPipeline.Result,
        policy: SpeakerTemporalPolicy,
        audioPath: String,
        diagnosticsURL: URL?
    ) {
        let finalByID = Dictionary(uniqueKeysWithValues: result.decisions.map { ($0.tokenID, $0) })
        let baselineByID = Dictionary(uniqueKeysWithValues: result.baselineDecisions.map { ($0.tokenID, $0) })
        let pauseCandidates = SpeakerRoutingArtifact.pauseCandidates(
            timeline: result.timeline,
            tokenIndicesBySentence: result.routingContext.tokenIndicesBySentence,
            evidence: result.routingContext.acousticPauseEvidence,
            policy: policy
        )
        let snapshot = SpeakerRoutingSnapshot(
            profileMappings: result.tokenEvidence.profileLabels.map {
                SpeakerRoutingSnapshot.ProfileMapping(
                    acousticLabel: $0, speakerLabel: "说话人 \($0 + 1)",
                    // Spec: non-finite scores must be stripped at the JSON
                    // persistence boundary. Cohesion is usually finite here
                    // (upstream cosine filtering), but guard the boundary so a
                    // stray NaN/Inf cannot make the whole snapshot encode fail.
                    cohesion: result.profileCohesions[$0].flatMap {
                        $0.isFinite ? $0 : nil
                    }
                )
            },
            tokens: result.timeline.tokens.map { token in
                let evidence = result.tokenEvidence.tokenEvidence[token.id]
                return SpeakerRoutingSnapshot.Token(
                    sentenceIndex: token.id.sentenceIndex, tokenIndex: token.id.tokenIndex,
                    text: token.text, startMs: token.rawRangeMs.lowerBound, endMs: token.rawRangeMs.upperBound,
                    scores: SpeakerDiagnosticsArtifact.finiteScores(evidence?.scores ?? [:]),
                    supportFrames: evidence?.supportFrames ?? 0,
                    baselineAcousticLabel: baselineByID[token.id]?.knownLabel,
                    finalAcousticLabel: finalByID[token.id]?.knownLabel
                )
            },
            pauseCandidates: pauseCandidates, routingPolicy: policy
        )
        do {
            try ResultStore.writeSpeakerRoutingSnapshot(
                snapshot,
                to: SpeakerRoutingArtifact.snapshotPath(diagnosticsURL: diagnosticsURL, audioPath: audioPath)
            )
        } catch {
            Logger.shared.warn("无法保存 speaker routing snapshot：\(error)")
        }
    }

    private static func writeDiagnostics(
        result: SpeakerDiarizationPipeline.Result,
        audioPath: String,
        diagnosticsURL: URL?
    ) {
        do {
            try ResultStore.writeSpeakerDiagnostics(
                SpeakerDiagnosticsArtifact.make(from: result),
                to: diagnosticsURL ?? ResultStore.speakerDiagnosticsPath(jobId: ResultStore.hashAudioPath(audioPath))
            )
        } catch {
            Logger.shared.warn("无法保存 speaker diagnostics：\(error)")
        }
    }
}
