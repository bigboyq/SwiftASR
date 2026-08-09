/// Builds the non-authoritative diagnostics sidecar from immutable speaker
/// output. Keeping this outside `AudioPipeline` makes the actor responsible
/// only for pipeline orchestration and filesystem write timing.
enum SpeakerDiagnosticsArtifact {
    /// JSON has no representation for NaN or ±Inf. Missing speaker evidence
    /// is represented in memory with a non-finite score; omit those unavailable
    /// candidates at the persistence boundary instead of losing the complete
    /// diagnostics and routing artifacts.
    static func finiteScores(_ scores: [Int: Float]) -> [Int: Float] {
        scores.filter { $0.value.isFinite }
    }

    static func make(from result: SpeakerDiarizationPipeline.Result) -> SpeakerDiarizationDiagnostics {
        let directCount = result.decisions.reduce(into: 0) { count, decision in
            if case let .accepted(_, source, _) = decision.disposition, source == .direct {
                count += 1
            }
        }
        let decisionByID = Dictionary(uniqueKeysWithValues: result.decisions.map { ($0.tokenID, $0) })
        let baselineDecisionByID = Dictionary(
            uniqueKeysWithValues: result.baselineDecisions.map { ($0.tokenID, $0) }
        )
        return SpeakerDiarizationDiagnostics(
            temporalWaterfall: SpeakerTemporalWaterfallDiagnostic(
                windowCount: result.windowCount,
                profileCount: result.profileCount,
                directCount: directCount,
                otherCount: result.otherCount,
                unresolvedCount: result.unresolvedCount,
                tokenEvidence: result.timeline.tokens.compactMap { token in
                    guard let item = result.tokenEvidence.tokenEvidence[token.id] else { return nil }
                    let decision = decisionByID[token.id]
                    let baseline = baselineDecisionByID[token.id]
                    let source: String?
                    if case let .accepted(_, value, _) = decision?.disposition {
                        source = value.rawValue
                    } else {
                        source = nil
                    }
                    return SpeakerTokenEvidenceDiagnostic(
                        startMs: token.rawRangeMs.lowerBound,
                        endMs: token.rawRangeMs.upperBound,
                        scores: finiteScores(item.scores),
                        decisionLabel: decision?.knownLabel,
                        decisionSource: source,
                        baselineLabel: baseline?.knownLabel,
                        baselineRoute: routeName(baseline?.disposition)
                    )
                }
            )
        )
    }

    private static func routeName(_ disposition: TokenDisposition?) -> String? {
        guard let disposition else { return nil }
        switch disposition {
        case let .accepted(_, source, _): return source.rawValue
        case .other: return "other"
        case .deferred: return "deferred"
        case .unresolved: return "unresolved"
        }
    }
}
