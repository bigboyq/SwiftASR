import Foundation
import Accelerate

#if DEBUG
/// Opt-in diagnostic helpers for `ASRDecoder`. These implementations compile
/// only in Debug builds and are gated on environment variables. An unset
/// environment keeps the hooks lightweight, but still incurs the Debug-only
/// environment checks. Release builds compile the no-op stubs below, which
/// optimize away at their call sites.
///
/// - `SWIFTASR_FILTER_COMPARE=1` activates the
///   `[filter-compare]` log lines that show every position where the
///   pre-`ae440e8` and post-`ae440e8` repeat filters disagree, with
///   ±8 token context, per-token α / frame gap / probability.
///   Used by `CJKOnlyFilterRegressionTests` to validate the
///   `punc-repetition-protection` branch on real audio before merge.
///
/// - `SWIFTASR_EMIT_TRACE_FILE=/path/to.tsv` writes one TSV line per
///   emitted token to that file (`t seg id text alpha prob`). All VAD
///   segments in a single pipeline run append to the same file. Used
///   with `scripts/analyze_emit_trace.py` / `scripts/scan_repeat_emits.py`
///   to compute per-token durations and validate the filter on real
///   audio before merge.
///
/// This file is intentionally separate from `ASRDecoder.swift` so that
/// the production decode loop carries no diagnostic state and no
/// diagnostic code path — every opt-in feature in here is reachable
/// only through the env-var-gated entry points below.
extension ASRDecoder {

    // MARK: - Filter compare

    /// Pre-`ae440e8` filter behavior: drop ANY repeat of the prior token id,
    /// regardless of token shape. Kept for diagnostic side-by-side
    /// comparison only — production paths use `shouldSkipForRepeat`.
    /// - Old behavior: "PPT" subword `p` `p` `t` → second `p` dropped, output `pt`.
    /// - Old behavior: "service service" → second `service` dropped.
    /// - Old behavior: "我我" → second `我` dropped (this is the only case
    ///   where old and new agree, intentionally).
    static func oldShouldSkipForRepeat(
        prev: (id: Int, text: String)?,
        prevPrev: (id: Int, text: String)?,
        current: (id: Int, text: String)
    ) -> Bool {
        if let prev, prev.id == current.id { return true }
        if let prevPrev, prevPrev.id == current.id, prev != nil { return true }
        return false
    }

    /// `true` when `SWIFTASR_FILTER_COMPARE=1` is set in the process
    /// environment. Evaluated on every decode call so the cost of the
    /// check is one `ProcessInfo` lookup per VAD segment (cheap; no
    /// per-token overhead — the inner loop only consults the result of
    /// this call once at the top of `decode`).
    static var filterCompareEnabled: Bool {
        ProcessInfo.processInfo.environment["SWIFTASR_FILTER_COMPARE"] == "1"
    }

    // MARK: - Emit trace

    /// Path of the TSV file to which every emit is logged when
    /// `SWIFTASR_EMIT_TRACE_FILE` is set. `nil` (the default) means
    /// the trace is disabled.
    static var emitTraceFilePath: String? {
        ProcessInfo.processInfo.environment["SWIFTASR_EMIT_TRACE_FILE"]
    }

    /// Lazy-cached file handle for emit-trace writes.  Appended across
    /// multiple decode calls (one per VAD segment) within a single
    /// pipeline run.  Caller-side cleanup happens via `flushEmitTrace()`
    /// after the pipeline finishes.
    nonisolated(unsafe) private static var _emitTraceHandle: FileHandle?
    nonisolated(unsafe) private static var _emitTraceSegmentIndex: Int = 0
    nonisolated(unsafe) private static var _emitTraceNextSegmentIndex: Int = 0
    private static let _emitTraceLock = NSLock()

    /// Reset the per-run VAD segment counter.  Call this once at the
    /// top of a pipeline run so the trace indexes from 0.
    static func resetEmitTraceSegmentCounter() {
        _emitTraceLock.lock()
        defer { _emitTraceLock.unlock() }
        _emitTraceNextSegmentIndex = 0
    }

    private static func consumeNextSegmentIndex() -> Int {
        _emitTraceLock.lock()
        defer { _emitTraceLock.unlock() }
        let i = _emitTraceNextSegmentIndex
        _emitTraceNextSegmentIndex += 1
        return i
    }

    /// Open (or create) the emit-trace file.  Called once per
    /// `ASRDecoder.decode` invocation when `emitTraceFilePath` is set;
    /// the first call writes the TSV header, subsequent calls just
    /// bump the per-decode segment index.
    fileprivate static func openEmitTrace(segmentIndex: Int) {
        guard let path = emitTraceFilePath else { return }
        _emitTraceLock.lock()
        defer { _emitTraceLock.unlock() }
        let fm = FileManager.default
        if _emitTraceHandle == nil {
            if fm.fileExists(atPath: path) {
                try? fm.removeItem(atPath: path)
            }
            fm.createFile(atPath: path, contents: nil)
            _emitTraceHandle = FileHandle(forWritingAtPath: path)
            _emitTraceHandle?.write(
                "# emit-trace: t\tseg\tid\ttext\talpha\tprob\n".data(using: .utf8)!
            )
        }
        _emitTraceSegmentIndex = segmentIndex
    }

    /// Append one row to the emit-trace TSV.  No-op when the env var
    /// is unset (the static file handle is `nil`).
    fileprivate static func appendEmitTrace(t: Int, id: Int, text: String, alpha: Float, prob: Float) {
        _emitTraceLock.lock()
        defer { _emitTraceLock.unlock() }
        guard let h = _emitTraceHandle else { return }
        let line = "\(t)\t\(_emitTraceSegmentIndex)\t\(id)\t\(text)\t\(String(format: "%.4f", alpha))\t\(String(format: "%.4f", prob))\n"
        if let d = line.data(using: .utf8) { h.write(d) }
    }

    /// Close the emit-trace file handle.  Call once at the end of a
    /// pipeline run; no-op when the env var was never set.
    static func flushEmitTrace() {
        _emitTraceLock.lock()
        defer { _emitTraceLock.unlock() }
        try? _emitTraceHandle?.close()
        _emitTraceHandle = nil
        if let p = emitTraceFilePath {
            Logger.shared.info("emit-trace written to \(p)")
        }
        _emitTraceSegmentIndex = 0
    }

    // MARK: - Math helpers (shared by filter-compare + emit-trace)

    /// Computes the argmax probability for a single frame's logits.
    /// Used by the filter-compare + emit-trace diagnostic logs.
    /// The argmax is already known to clear the `0.2` softmax gate by
    /// the time this is called, so the returned probability is always
    /// in `[0.2, 1.0]`.  Pulled into a static helper so the
    /// filter-compare log and the per-emit trace stay in sync.
    static func maxProb(
        logitsBase: UnsafePointer<Float>,
        offset: Int,
        vocabSize: Int,
        vLen: vDSP_Length
    ) -> Float {
        let frameLogits = logitsBase.advanced(by: offset)
        var maxLogit: Float = 0
        vDSP_maxv(frameLogits, 1, &maxLogit, vLen)
        var sumExp: Float = 0
        var eBuf = [Float](repeating: 0, count: vocabSize)
        eBuf.withUnsafeMutableBufferPointer { ePtr in
            var negMax = -maxLogit
            vDSP_vsadd(frameLogits, 1, &negMax, ePtr.baseAddress!, 1, vLen)
            var count = Int32(vocabSize)
            vvexpf(ePtr.baseAddress!, ePtr.baseAddress!, &count)
            vDSP_sve(ePtr.baseAddress!, 1, &sumExp, vLen)
        }
        return sumExp > 0 ? 1.0 / sumExp : 0
    }

    // MARK: - Per-token hooks (no-op when diagnostics are disabled)

    /// Called once at the start of each VAD-segment decode. Allocates
    /// the per-segment index, opens the emit-trace file if needed.
    /// No-op when neither env var is set.
    static func beginDecodeSegment() {
        guard emitTraceFilePath != nil else { return }
        openEmitTrace(segmentIndex: consumeNextSegmentIndex())
    }

    /// Called once per argmax token (before the production skip gate).
    /// Compares the pre-`ae440e8` and current filter decisions and,
    /// when they disagree, emits a `[filter-compare]` log line with
    /// ±8 token context, per-token α / frame gap / probability.
    /// No-op when `SWIFTASR_FILTER_COMPARE` is unset.
    static func recordFilterDecision(
        t: Int,
        logitsBase: UnsafePointer<Float>,
        offset: Int,
        vocabSize: Int,
        vLen: vDSP_Length,
        usAlphas: [Float],
        token: String,
        current: (id: Int, text: String),
        prev: (id: Int, text: String)?,
        prevPrev: (id: Int, text: String)?,
        newSkip: Bool
    ) {
        guard filterCompareEnabled else { return }
        let oldSkip = oldShouldSkipForRepeat(prev: prev, prevPrev: prevPrev, current: current)
        guard oldSkip != newSkip else { return }
        let prevStr = prev.map { "id=\($0.id)'\($0.text)'" } ?? "nil"
        let prevPrevStr = prevPrev.map { "id=\($0.id)'\($0.text)'" } ?? "nil"
        let currentAlpha = alphaFromUsAlphas(usAlphas, frame: t)
        let ctx = compareContextString()
        let frameGap = compareFrameGap(toFrame: t)
        let prob = maxProb(
            logitsBase: logitsBase, offset: offset,
            vocabSize: vocabSize, vLen: vLen
        )
        Logger.shared.info(
            "[filter-compare] t=\(t) old=\(oldSkip ? "SKIP" : "KEEP") " +
            "new=\(newSkip ? "SKIP" : "KEEP") token='\(token)' " +
            "α=\(String(format: "%.3f", currentAlpha)) " +
            "p=\(String(format: "%.3f", prob)) " +
            "gap=\(frameGap)frames " +
            "prev=\(prevStr) prevPrev=\(prevPrevStr) " +
            "ctx=`\(ctx)`"
        )
    }

    /// Called once per emitted token (after the production skip gate).
    /// Appends one TSV row to the emit-trace file when
    /// `SWIFTASR_EMIT_TRACE_FILE` is set, and updates the filter-compare
    /// ring buffer (used by `recordFilterDecision`) when
    /// `SWIFTASR_FILTER_COMPARE` is set.
    static func recordEmit(
        t: Int,
        id: Int,
        text: String,
        logitsBase: UnsafePointer<Float>,
        offset: Int,
        vocabSize: Int,
        vLen: vDSP_Length,
        usAlphas: [Float]
    ) {
        let traceEnabled = emitTraceFilePath != nil
        let compareEnabled = filterCompareEnabled
        guard traceEnabled || compareEnabled else { return }
        let alpha = alphaFromUsAlphas(usAlphas, frame: t)
        if traceEnabled {
            let prob = maxProb(
                logitsBase: logitsBase, offset: offset,
                vocabSize: vocabSize, vLen: vLen
            )
            appendEmitTrace(t: t, id: id, text: text, alpha: alpha, prob: prob)
        }
        if compareEnabled {
            compareRingPush(t: t, display: text, alpha: alpha)
        }
    }

    // MARK: - Private per-segment state (filter-compare only)

    /// Per-decode-call state: 8-token ring of `(text, frame, alpha)` for
    /// the filter-compare context line.  Allocated on demand the first
    /// time `filterCompareEnabled` is true during a pipeline run; stays
    /// empty otherwise.
    nonisolated(unsafe) private static var _compareRing: [(text: String, frame: Int, alpha: Float)] = []
    nonisolated(unsafe) private static var _compareLastEmittedFrame: Int? = nil
    private static let _compareRingCapacity = 8
    private static let _compareLock = NSLock()

    /// Look up the CIF alpha for a single frame.  The decoder stores
    /// `usAlphas` at 3x the frame rate; we sample the middle of each
    /// 3-sample window.  Out-of-range access returns `-1` so log lines
    /// are obviously broken if a decoder ever passes a bad frame index.
    fileprivate static func alphaFromUsAlphas(_ usAlphas: [Float], frame: Int) -> Float {
        let usIdx = frame * 3 + 1
        guard usIdx < usAlphas.count else { return -1 }
        return usAlphas[usIdx]
    }

    fileprivate static func compareContextString() -> String {
        _compareLock.lock()
        defer { _compareLock.unlock() }
        let ring = _compareRing
        return ring.suffix(_compareRingCapacity).map { entry in
            "\(entry.text)[f=\(entry.frame),α=\(String(format: "%.3f", entry.alpha))]"
        }.joined(separator: " ")
    }

    fileprivate static func compareFrameGap(toFrame t: Int) -> Int {
        _compareLock.lock()
        defer { _compareLock.unlock() }
        let lastFrame = _compareLastEmittedFrame
        return lastFrame.map { t - $0 } ?? -1
    }

    fileprivate static func compareRingPush(t: Int, display: String, alpha: Float) {
        _compareLock.lock()
        defer { _compareLock.unlock() }
        if _compareRing.count >= _compareRingCapacity {
            _compareRing.removeFirst()
        }
        _compareRing.append((text: display, frame: t, alpha: alpha))
        _compareLastEmittedFrame = t
    }
}
#else
/// Release builds deliberately exclude environment-controlled transcript
/// diagnostics and all shared mutable diagnostic state. These signature-only
/// stubs keep `ASRDecoder` source identical across configurations and are
/// eliminated by Release optimization.
extension ASRDecoder {
    static func resetEmitTraceSegmentCounter() {}
    static func flushEmitTrace() {}
    static func beginDecodeSegment() {}

    static func recordFilterDecision(
        t: Int,
        logitsBase: UnsafePointer<Float>,
        offset: Int,
        vocabSize: Int,
        vLen: vDSP_Length,
        usAlphas: [Float],
        token: String,
        current: (id: Int, text: String),
        prev: (id: Int, text: String)?,
        prevPrev: (id: Int, text: String)?,
        newSkip: Bool
    ) {}

    static func recordEmit(
        t: Int,
        id: Int,
        text: String,
        logitsBase: UnsafePointer<Float>,
        offset: Int,
        vocabSize: Int,
        vLen: vDSP_Length,
        usAlphas: [Float]
    ) {}
}
#endif
