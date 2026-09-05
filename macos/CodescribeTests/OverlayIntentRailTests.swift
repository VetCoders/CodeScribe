import AppKit
import SwiftUI
import XCTest

@testable import Codescribe

@MainActor
private final class OverlayIntentBoundaryEngine: DictationEngine {
  var onTranscribeFile: (() -> Void)?
  var receivedTranscribePath: String?

  func setListener(_ listener: CsTranscriptionListener) {}
  func startRecording(language: CsLanguage?) async throws {}
  func stopRecording() async throws -> String { "" }
  func isRecording() async -> Bool { false }
  func initModel() async throws {}
  func isModelLoaded() -> Bool { true }
  func currentOverlayPolicy() -> OverlayPolicySnapshot? { nil }
  func setAutoPasteEnabled(_ enabled: Bool) {}
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

  func testDispatchUsesProductionStateRouteAndLeavesProjectionUntouched() {
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
    let rail = OverlayIntentRail(
      phase: state.statusText,
      intents: OverlayIntentRail.projectedIntents(for: state),
      palette: .dark,
      onIntent: state.relayIntent
    )

    rail.dispatch(.format)

    XCTAssertEqual(state.mode, .formatted)
    XCTAssertEqual(state.formattedText, "final")
    XCTAssertEqual(state.revision, 1)
    XCTAssertTrue(state.canPaste)
    XCTAssertTrue(state.canInsert)
    XCTAssertTrue(state.canCopy)
    XCTAssertTrue(state.canRetranscribe)
    XCTAssertTrue(state.canFormat)
    XCTAssertTrue(state.terminal)
    XCTAssertEqual(state.toast, "format unavailable")
    XCTAssertEqual(state.errorMessage, "Formatting is not connected to the transcript reducer")
  }

  func testCollapsedDockHasOnlyHandleAndExpandedDockSwapsInProjection() {
    let intents: [OverlayIntent] = [
      .insertPaste, .copy, .retranscribe, .format, .close,
    ]
    let collapsed = OverlayDockLayout(isExpanded: false, projectedIntents: intents)
    let expanded = OverlayDockLayout(isExpanded: true, projectedIntents: intents)

    XCTAssertTrue(collapsed.showsHandleOnly)
    XCTAssertTrue(collapsed.showsCollapsedFooter)
    XCTAssertFalse(collapsed.showsToolbar)
    XCTAssertEqual(collapsed.visibleIntents, [])
    XCTAssertFalse(expanded.showsCollapsedFooter)
    XCTAssertTrue(expanded.showsToolbar)
    XCTAssertEqual(expanded.visibleIntents, intents)
    XCTAssertEqual(OverlayDockLayout.minimumCanvasWidth, 320)
  }

  func testEveryIntentHasVoiceOverCopyAndRailReportsProjectedPhase() {
    let intents: [OverlayIntent] = [
      .finish, .copy, .insertPaste, .retranscribe, .format, .close,
    ]

    XCTAssertEqual(
      intents.map(\.accessibilityLabel),
      [
        "Finish recording",
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

  func testHoverRevealAndPinnedClickUseOneInteractionState() {
    var interaction = OverlayDockInteraction(isExpanded: false, isPinned: false)

    interaction.pointerEntered()
    XCTAssertTrue(interaction.isExpanded)
    interaction.pointerExited()
    XCTAssertFalse(interaction.isExpanded)

    interaction.pin()
    interaction.pointerExited()
    XCTAssertTrue(interaction.isExpanded)
    interaction.collapse()
    XCTAssertEqual(
      interaction,
      OverlayDockInteraction(isExpanded: false, isPinned: false)
    )
  }

  func testReduceMotionDisablesRailAnimation() {
    XCTAssertNil(OverlayIntentRail.revealAnimation(reduceMotion: true))
    XCTAssertNotNil(OverlayIntentRail.revealAnimation(reduceMotion: false))
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
    XCTAssertEqual(engine.receivedTranscribePath, "/tmp/overlay-intent-boundary.wav")
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

  func testExpandedDockRendersAtWindowFloorWithRoundedCanvasCorners() throws {
    let state = OverlayState.previewFormatted()
    let size = CGSize(
      width: OverlayDockLayout.minimumCanvasWidth,
      height: DictationOverlayWindow.minSize.height
    )
    let hostingView = NSHostingView(
      rootView: DictationOverlayView(state: state, dockInitiallyExpanded: true)
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
