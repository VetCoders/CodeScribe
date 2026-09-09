import AppKit
import SwiftUI
import XCTest

@testable import Codescribe

@MainActor
private final class OverlayIntentBoundaryEngine: DictationEngine {
  var onTranscribeFile: (() -> Void)?
  var receivedTranscribePath: String?
  var onFormatter: (() -> Void)?
  var formatterRequests: [(sessionId: String, sourceRevision: UInt64)] = []
  var policy = OverlayPolicySnapshot(autoPasteEnabled: true, autoFormatLevel: .correction)
  var formatLevelWrites: [FormattingPolicyOption] = []

  func setListener(_ listener: CsTranscriptionListener) {}
  func startRecording(language: CsLanguage?) async throws {}
  func stopRecording() async throws -> String { "" }
  func commitUserRevision(
    sessionId: String, sourceRevision: UInt64, renderedText: String
  ) async throws -> CsUserRevisionResult {
    return CsUserRevisionResult(
      sessionId: sessionId,
      sourceRevision: sourceRevision,
      revision: sourceRevision + 1,
      renderedText: renderedText,
      provenanceReceipt: "user-edit-intent-boundary"
    )
  }
  func commitFormatterRevision(
    sessionId: String, sourceRevision: UInt64
  ) async throws -> CsUserRevisionResult {
    formatterRequests.append((sessionId, sourceRevision))
    onFormatter?()
    return CsUserRevisionResult(
      sessionId: sessionId,
      sourceRevision: sourceRevision,
      revision: sourceRevision + 1,
      renderedText: "formatted",
      provenanceReceipt: "formatter-intent-boundary"
    )
  }
  func isRecording() async -> Bool { false }
  func initModel() async throws {}
  func isModelLoaded() -> Bool { true }
  func currentOverlayPolicy() -> OverlayPolicySnapshot? { policy }
  func setAutoPasteEnabled(_ enabled: Bool) {}
  func setAutoFormatLevel(_ level: FormattingPolicyOption) {
    formatLevelWrites.append(level)
    policy = OverlayPolicySnapshot(
      autoPasteEnabled: policy.autoPasteEnabled, autoFormatLevel: level)
  }
  func pasteText(text: String) async throws -> CsPasteResult { pasteResult() }
  func deferText(text: String) async throws -> CsPasteResult { pasteResult() }
  func copyTaggedTranscript(text: String) async throws {}
  func pasteTargetAppName() async -> String? { nil }
  func sendAssistiveTranscript(text: String) async throws -> Bool { false }
  func lastSessionAudioPath() -> String? { "/tmp/overlay-intent-boundary.wav" }
  func transcribeFile(path: String) async throws -> CsTranscription {
    receivedTranscribePath = path
    onTranscribeFile?()
    return CsTranscription(text: "retranscribed", language: "en")
  }

  private func pasteResult() -> CsPasteResult {
    CsPasteResult(
      outcome: .noop,
      targetAppName: nil,
      frontmostAppName: nil,
      deferredInsertShortcut: nil,
      deferredInsertFailure: nil
    )
  }
}

@MainActor
final class OverlayIntentRailTests: XCTestCase {
  func testEventFixturesRenderFrozenProjectionTable() {
    let rows:
      [(
        phase: String, text: String, paste: Bool, insert: Bool, copy: Bool,
        retranscribe: Bool, format: Bool, terminal: Bool, expected: [OverlayIntent]
      )] = [
        ("listening", "live", false, false, true, false, false, false, [.finish, .copy, .close]),
        ("listening", "", false, false, false, false, false, false, [.finish, .close]),
        ("finalizing", "draft", false, false, true, false, false, false, [.copy, .close]),
        (
          "formatted", "final", true, true, true, true, true, true,
          [.insertPaste, .copy, .retranscribe, .format, .close]
        ),
        ("no_speech", "", false, false, false, true, false, true, [.retranscribe, .close]),
        ("error", "draft", true, true, true, true, true, true, [.close]),
      ]

    for row in rows {
      let state = projectedState(
        phase: row.phase,
        text: row.text,
        canPaste: row.paste,
        canInsert: row.insert,
        canCopy: row.copy,
        canRetranscribe: row.retranscribe,
        canFormat: row.format,
        terminal: row.terminal
      )

      XCTAssertEqual(
        OverlayIntentRail.projectedIntents(for: state),
        row.expected,
        "event fixture for \(row.phase) did not paint the frozen action table"
      )
    }
  }

  func testDispatchUsesProductionStateRouteAndLeavesProjectionUntouched() async {
    let state = projectedState(
      phase: "formatted",
      text: "final",
      canPaste: true,
      canInsert: true,
      canCopy: true,
      canRetranscribe: true,
      canFormat: true,
      terminal: true
    )
    let engine = OverlayIntentBoundaryEngine()
    state.engine = engine
    let requested = expectation(description: "format intent reached production boundary")
    engine.onFormatter = { requested.fulfill() }
    let rail = OverlayIntentRail(
      phase: state.statusText,
      intents: OverlayIntentRail.projectedIntents(for: state),
      palette: .dark,
      onIntent: state.relayIntent
    )

    rail.dispatch(.format)
    await fulfillment(of: [requested], timeout: 1)

    XCTAssertEqual(state.mode, .formatted)
    XCTAssertEqual(state.formattedText, "final")
    XCTAssertEqual(state.revision, 1)
    XCTAssertTrue(state.canPaste)
    XCTAssertTrue(state.canInsert)
    XCTAssertTrue(state.canCopy)
    XCTAssertTrue(state.canRetranscribe)
    XCTAssertTrue(state.canFormat)
    XCTAssertTrue(state.terminal)
    XCTAssertEqual(engine.formatterRequests.count, 1)
    XCTAssertEqual(engine.formatterRequests[0].sessionId, "intent-rail-fixture")
    XCTAssertEqual(engine.formatterRequests[0].sourceRevision, 1)
    XCTAssertTrue(state.formatterCommitPending, "FFI acknowledgement is not projection")
    XCTAssertNil(state.formatterError)
  }

  func testFloatingActionsKeepProjectedOrderWithCloseInHeader() {
    let intents: [OverlayIntent] = [
      .insertPaste, .copy, .retranscribe, .format, .close,
    ]
    let layout = OverlayDockLayout(projectedIntents: intents)

    XCTAssertEqual(layout.visibleIntents, intents.filter { $0 != .close })
    XCTAssertEqual(OverlayDockLayout(projectedIntents: []).visibleIntents, [])
    XCTAssertEqual(OverlayDockLayout.minimumCanvasWidth, 320)
  }

  func testDirtyRevisionReplacesDeliveryActionsWithCommitOrDiscard() {
    let state = projectedState(
      phase: "formatted",
      text: "ledger text",
      canPaste: true,
      canInsert: true,
      canCopy: true,
      canRetranscribe: true,
      canFormat: true,
      terminal: true
    )

    state.beginTranscriptEdit()
    state.updateRevisionDraft("local draft")

    XCTAssertEqual(
      OverlayIntentRail.projectedIntents(for: state),
      [.commitRevision, .discardRevision, .close]
    )
    XCTAssertEqual(state.formattedText, "ledger text")
    XCTAssertEqual(state.canvasText, "local draft")
  }

  func testRetranscribeMenuPicksThePassAndTheBareIntentStaysLocal() async {
    let state = projectedState(
      phase: "formatted",
      text: "final",
      canPaste: true,
      canInsert: true,
      canCopy: true,
      canRetranscribe: true,
      canFormat: true,
      terminal: true
    )
    let engine = OverlayIntentBoundaryEngine()
    state.engine = engine
    // Founder 2026-09-09: the formatting level is tray quick-settings chrome,
    // never a dock control; Retranscribe is opt-in with a Local / Cloud pick.
    let rail = OverlayIntentRail(
      phase: state.statusText,
      intents: OverlayIntentRail.projectedIntents(for: state),
      palette: .dark,
      onIntent: state.relayIntent,
      onRetranscribe: { state.retranscribe(pass: $0) }
    )
    XCTAssertTrue(rail.intents.contains(.retranscribe))

    let cloud = expectation(description: "cloud pass reached the engine")
    engine.onTranscribeFile = { cloud.fulfill() }
    rail.retranscribe(.cloud)
    await fulfillment(of: [cloud], timeout: 1)
    XCTAssertEqual(engine.receivedTranscribePath, "cloud:/tmp/overlay-intent-boundary.wav")

    let local = expectation(description: "bare intent runs the local HQ pass")
    engine.onTranscribeFile = { local.fulfill() }
    rail.dispatch(.retranscribe)
    await fulfillment(of: [local], timeout: 1)
    XCTAssertEqual(engine.receivedTranscribePath, "hq:/tmp/overlay-intent-boundary.wav")
    XCTAssertTrue(engine.formatLevelWrites.isEmpty, "the dock never writes the formatting level")
  }

  func testEveryIntentHasVoiceOverCopyAndRailReportsProjectedPhase() {
    let intents: [OverlayIntent] = [
      .finish, .commitRevision, .discardRevision, .copy, .insertPaste, .retranscribe, .format,
      .close,
    ]

    XCTAssertEqual(
      intents.map(\.accessibilityLabel),
      [
        "Finish recording",
        "Commit transcript revision",
        "Discard transcript draft",
        "Copy transcript",
        "Insert transcript",
        "Retranscribe recording",
        "Format transcript",
        "Close overlay",
      ]
    )
    XCTAssertTrue(intents.allSatisfy { !$0.accessibilityHint.isEmpty })
    XCTAssertTrue(intents.allSatisfy { !$0.helpText.isEmpty })
    XCTAssertEqual(OverlayDockVisuals.hoverOpacity(isHovering: false), 0)
    XCTAssertGreaterThan(OverlayDockVisuals.hoverOpacity(isHovering: true), 0)
    XCTAssertEqual(OverlayIntentRail.accessibilityValue(for: "no speech"), "no speech")
  }

  func testProjectedRetranscribeIntentReachesInjectedEngineBoundary() async {
    let engine = OverlayIntentBoundaryEngine()
    let state = projectedState(
      phase: "formatted",
      text: "final",
      canPaste: true,
      canInsert: true,
      canCopy: true,
      canRetranscribe: true,
      canFormat: true,
      terminal: true
    )
    state.engine = engine
    let reached = expectation(description: "retranscribe reaches the engine boundary")
    engine.onTranscribeFile = { reached.fulfill() }

    state.relayIntent(.retranscribe)

    await fulfillment(of: [reached], timeout: 0.2)
    XCTAssertEqual(engine.receivedTranscribePath, "hq:/tmp/overlay-intent-boundary.wav")
    XCTAssertEqual(state.toast, "retranscribed")
  }

  func testMissingEngineSurfacesCopyAndInsertFailuresOnCanvas() {
    let state = projectedState(
      phase: "formatted",
      text: "final",
      canPaste: true,
      canInsert: true,
      canCopy: true,
      canRetranscribe: false,
      canFormat: false,
      terminal: true
    )

    state.relayIntent(.copy)
    XCTAssertEqual(state.toast, "copy unavailable")
    XCTAssertEqual(state.errorMessage, "Copy needs the recording engine")

    state.relayIntent(.insertPaste)
    XCTAssertEqual(state.toast, "insert unavailable")
    XCTAssertEqual(state.errorMessage, "Insert needs the recording engine")
  }

  func testDockRendersAtWindowFloorWithRoundedCanvasCorners() throws {
    let state = OverlayState.previewFormatted()
    let size = CGSize(
      width: OverlayDockLayout.minimumCanvasWidth,
      height: DictationOverlayWindow.minSize.height
    )
    let hostingView = NSHostingView(
      rootView: DictationOverlayView(state: state)
        .frame(width: size.width, height: size.height)
        .preferredColorScheme(.dark)
    )
    hostingView.frame = CGRect(origin: .zero, size: size)
    hostingView.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.03))

    let bitmap = try XCTUnwrap(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
    hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    let destination = FileManager.default.temporaryDirectory
      .appendingPathComponent("codescribe-expanded-bottom-dock-min-width.png")
    try png.write(to: destination)

    XCTAssertGreaterThan(png.count, 800)
    XCTAssertEqual(size.width, DictationOverlayWindow.minSize.width)
    XCTAssertLessThan(bitmap.colorAt(x: 0, y: 0)?.alphaComponent ?? 0, 0.2)
    XCTAssertLessThan(
      bitmap.colorAt(x: bitmap.pixelsWide - 1, y: 0)?.alphaComponent ?? 0,
      0.2
    )
  }

  private func projectedState(
    phase: String,
    text: String,
    canPaste: Bool,
    canInsert: Bool,
    canCopy: Bool,
    canRetranscribe: Bool,
    canFormat: Bool,
    terminal: Bool
  ) -> OverlayState {
    let state = OverlayState()
    state.applyTranscriptProjection(
      CsTranscriptProjectionEvent(
        schema: "codescribe.transcript_projection.v1",
        sequence: 1,
        emittedAt: "2026-09-04T00:00:00Z",
        sessionId: "intent-rail-fixture",
        mode: "dictation",
        reducerRevision: 1,
        reducerAction: "intent_rail_fixture",
        occurrenceSessionId: "intent-rail-fixture",
        captureEpoch: 1,
        sampleStart: 0,
        sampleEnd: 16_000,
        documentIndex: 0,
        label: phase,
        renderedText: text,
        phase: phase,
        canPaste: canPaste,
        canInsert: canInsert,
        canCopy: canCopy,
        canRetranscribe: canRetranscribe,
        canFormat: canFormat,
        terminal: terminal,
        acousticReceipts: []
      )
    )
    return state
  }
}
