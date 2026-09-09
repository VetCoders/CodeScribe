import XCTest

@testable import Codescribe

/// Falsifier for the 2026-09-06 12:06:09 hang of build 773 (pid 95323).
///
/// Evidence (`logs/codescribe-run-2026_0906_crash.log`, 1 ms `sample`,
/// `codescribe.log` 10:06:09Z): a 174 s listening take (14 projection
/// revisions) was refused at stop (`terminal transcript refused: seal coverage
/// incomplete`). The controller emitted `transcription_failed`, which reaches
/// the overlay as `handleError(message:)`. With a non-empty projection that
/// path keeps `.listening`, aborts the capture (`onRecordingStopped`), and
/// shows the "Dictation failed — transcript kept" toast. The main thread never
/// returned from
/// `NSHostingView.layout → preferencesDidChange → FocusBridge.invalidateKeyViewLoop
/// → updateDefaultKeyViewLoop → FocusNavigationSequence.next()`
/// (98 % CPU for ≥ 6 min, 31 hang reports). A 22 s refused take at 09:54 did
/// not hang the app.
///
/// Run 6 (2026-09-06 12:36) replayed the WRONG transition — a Rust status card
/// (`applyPresentationStatus`) swapping the transcript out — and returned in
/// 0.22 s for both lengths. These tests replay the production transition on
/// the real panel and hosting hierarchy: a revision stream ticking the
/// timeline, then `handleError`, then the toast clearing. The witness is the
/// layout pass returning, not a name in a view tree. The status-card case is
/// kept as the control that is already known to return.
final class OverlayRefusalLayoutHangTests: XCTestCase {
  private let sentence =
    "Zajrzyj z powrotem, zobacz, dowiedz się co to jest sesja, skąd ona się bierze, bo jest losowa, i sprawdź czy są dostosowane do naszego nowego kontraktu. "
  private let refusal =
    "transcription_failed: terminal transcript refused: seal coverage incomplete (1291264/2473472 samples covered; max gap 416768 > threshold 12000)"

  @MainActor
  func testProductionRefusalAfterLongRevisionStreamReturnsFromLayout() throws {
    // 14 growing revisions ≈ the 12:03–12:06 take that hung build 773.
    try assertProductionRefusalLayoutReturns(revisions: 14, label: "long")
  }

  @MainActor
  func testProductionRefusalAfterShortTakeReturnsFromLayout() throws {
    // One revision ≈ the 22 s take (09:54) that the app survived.
    try assertProductionRefusalLayoutReturns(revisions: 1, label: "short")
  }

  @MainActor
  func testStatusCardRefusalControlReturnsFromLayout() throws {
    try assertStatusCardLayoutReturns(revisions: 14, label: "control")
  }

  // MARK: Production transition (handleError → abort → toast)

  @MainActor
  private func assertProductionRefusalLayoutReturns(revisions: Int, label: String) throws {
    let harness = try mountListeningPanel(revisions: revisions, label: label)
    defer { harness.tearDown() }
    let state = harness.state
    let root = harness.root

    // AppModel.markStopped mirrors: the stopped beat re-enters the state
    // through `finishControllerRecording` (idempotent once finalized).
    var stoppedBeats = 0
    state.onRecordingStopped = { [weak state] in
      stoppedBeats += 1
      state?.finishControllerRecording()
    }

    state.handleError(message: refusal)
    XCTAssertEqual(state.mode, .listening, "a refusal with a draft keeps the transcript on screen")
    XCTAssertEqual(state.toast, "Dictation failed — transcript kept")
    XCTAssertEqual(stoppedBeats, 1)

    let refusalElapsed = measureLayout(root)
    print(
      "W5_T18_REFUSAL_LAYOUT transition=production label=\(label) chars=\(harness.chars) elapsed_s=\(refusalElapsed)"
    )
    XCTAssertLessThan(
      refusalElapsed, 2.0,
      "\(label): production refusal layout pass took \(refusalElapsed)s — key-view loop rebuild is not bounded"
    )

    // Second preference change of the same beat: the toast clears after 2.6 s.
    RunLoop.main.run(until: Date().addingTimeInterval(3.0))
    XCTAssertNil(state.toast, "toast must have cleared before measuring its removal")
    let toastElapsed = measureLayout(root)
    print(
      "W5_T18_REFUSAL_LAYOUT transition=toast-clear label=\(label) chars=\(harness.chars) elapsed_s=\(toastElapsed)"
    )
    XCTAssertLessThan(toastElapsed, 2.0, "\(label): toast removal layout pass took \(toastElapsed)s")
  }

  // MARK: Control (Rust status card swaps the transcript out)

  @MainActor
  private func assertStatusCardLayoutReturns(revisions: Int, label: String) throws {
    let harness = try mountListeningPanel(revisions: revisions, label: label)
    defer { harness.tearDown() }
    harness.state.applyPresentationStatus(refusedTerminalSeal())
    XCTAssertEqual(harness.state.mode, .error)
    let elapsed = measureLayout(harness.root)
    print(
      "W5_T18_REFUSAL_LAYOUT transition=status-card label=\(label) chars=\(harness.chars) elapsed_s=\(elapsed)"
    )
    XCTAssertLessThan(elapsed, 2.0, "\(label): status-card layout pass took \(elapsed)s")
  }

  // MARK: Harness

  private struct Harness {
    let state: OverlayState
    let panel: FloatingOverlayPanel
    let root: NSView
    let chars: Int

    @MainActor func tearDown() {
      panel.orderOut(nil)
      panel.invalidatePresence()
    }
  }

  /// Real panel + hosting hierarchy in `.listening`, fed `revisions` growing
  /// Rust-owned projections with the run loop ticking between them (timeline
  /// timer, NSTextView updates, waveform) — the shape of the 174 s take.
  @MainActor
  private func mountListeningPanel(revisions: Int, label: String) throws -> Harness {
    let state = OverlayState()
    state.handleRecordingPreparing()
    state.handleRecordingStarted()

    let panel = try XCTUnwrap(
      DictationOverlayWindow.make(
        state: state,
        textScale: TextScaleController(key: "OverlayRefusalLayoutHangTests.\(label).textScale")
      ) as? FloatingOverlayPanel
    )
    panel.setContentSize(NSSize(width: 470, height: 560))
    panel.orderFrontRegardless()
    let root = try XCTUnwrap(panel.contentView)
    root.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))

    var text = ""
    for revision in 1...max(revisions, 1) {
      text = String(repeating: sentence, count: revision)
      state.applyTranscriptProjection(listeningProjection(text, sequence: UInt64(revision)))
      root.layoutSubtreeIfNeeded()
      RunLoop.main.run(until: Date().addingTimeInterval(0.15))
    }
    XCTAssertEqual(state.mode, .listening)
    XCTAssertEqual(state.activeText, text)
    root.layoutSubtreeIfNeeded()
    return Harness(state: state, panel: panel, root: root, chars: text.count)
  }

  @MainActor
  private func measureLayout(_ root: NSView) -> TimeInterval {
    let started = Date()
    root.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    root.layoutSubtreeIfNeeded()
    return Date().timeIntervalSince(started)
  }

  /// Rust-owned projection admitted through the production boundary, shaped
  /// like the 12:03–12:06 take: one growing live document, not terminal.
  private func listeningProjection(_ text: String, sequence: UInt64) -> CsTranscriptProjectionEvent {
    let sampleEnd = UInt64(7_680 + 595_000 * sequence)
    let receipt = CsProjectedAcousticReceipt(
      acousticSerialVersion: 1,
      acousticSerial: "hang-acoustic-\(sequence)",
      sessionId: "hang-session",
      captureEpoch: 1,
      sampleStart: 7_680,
      sampleEnd: sampleEnd,
      durationMs: UInt64(sampleEnd / 48),
      energyIntegral: 1,
      meanRmsDbfs: -20,
      peakDbfs: -6,
      vadOpenSample: 7_680,
      vadCloseSample: sampleEnd,
      evidenceCalibrationVersion: "cal2-macbook-pro-microphone-1",
      wordEvidenceReceipts: ["hang-word-evidence-\(sequence)"],
      layerDecisionReceipts: ["hang-layer-decision-\(sequence)"],
      sealReceipt: nil,
      manualEditReceipt: nil
    )
    return CsTranscriptProjectionEvent(
      schema: "codescribe.transcript_projection.v1",
      sequence: sequence,
      emittedAt: "2026-09-06T10:04:06Z",
      sessionId: "hang-session",
      mode: "dictation",
      reducerRevision: 3 + sequence,
      reducerAction: "record_ledger_projection",
      occurrenceSessionId: "hang-session",
      captureEpoch: 1,
      sampleStart: 7_680,
      sampleEnd: sampleEnd,
      documentIndex: 0,
      label: "live",
      renderedText: text,
      phase: "listening",
      canPaste: false,
      canInsert: false,
      canCopy: true,
      canRetranscribe: false,
      canFormat: false,
      terminal: false,
      lifecycleTerminal: false,
      delivery: .unattempted,
      acousticReceipts: [receipt]
    )
  }

  private func refusedTerminalSeal() -> CsPresentationStatusEvent {
    CsPresentationStatusEvent(
      schema: "codescribe.presentation-status.v1",
      emittedAt: "2026-09-06T10:06:09Z",
      sessionId: "hang-session",
      kind: "terminal_refused",
      code: "terminal_seal_coverage_incomplete",
      statusLabel: "transcript refused",
      headline: "Transcript refused",
      message:
        "terminal transcript refused: seal coverage incomplete (1291264/2473472 samples covered; max gap 416768 > threshold 12000)",
      isError: true,
      terminal: true,
      calibrationVersion: nil
    )
  }
}
