import AppKit
import XCTest

@testable import Codescribe

/// Founder cut 2026-09-08 19:18 for the overlay header: the brand dot is the
/// only close control (no `xmark` glyph), Auto Paste is toggled from the
/// header, and no phase capsule ("listening" pill) renders anywhere.
///
/// The accepted chrome (agy, `b9c7e8f47`) builds these controls as SwiftUI
/// `Button`s. SwiftUI does not project its accessibility subtree into the
/// AppKit `subviews` / `accessibilityChildren()` graph under XCTest, so the
/// controls are pinned by their state seams (`OverlayState`) plus source
/// guards on `DictationOverlayView.swift` — the same pattern as
/// `OverlayStateTests`. The rendered-panel checks below cover what AppKit
/// does expose: the native hierarchy and window drag hit-testing.
@MainActor
final class OverlayChromeFounderCutTests: XCTestCase {
  func testHeaderHasNoCloseGlyph() throws {
    try withPanel(state: .previewListening()) { panel, root in
      let elements = accessibilityTree(root)
      XCTAssertFalse(elements.isEmpty, "The rendered accessibility hierarchy must be observable")
      for element in elements where element.accessibilityRole() == .image {
        XCTAssertFalse((element.accessibilityLabel() ?? "").contains("xmark"))
      }
      // SwiftUI may flatten a Button's Image out of AX; cover its symbol source too.
      XCTAssertNotEqual(OverlayIntent.close.systemImage, "xmark")
      let source = try overlaySource()
      XCTAssertFalse(source.contains("Image(systemName: \"xmark\")"))
      XCTAssertNotNil(panel.contentView)
    }
  }

  func testBrandDotClosesTheOverlay() throws {
    let state = OverlayState.previewListening()
    var closes = 0
    state.onClose = { closes += 1 }
    state.relayIntent(.close)
    XCTAssertEqual(closes, 1, "The close intent the brand dot relays must reach onClose")

    let source = try overlaySource()
    let header = try headerSource(source)
    XCTAssertTrue(
      header.contains("state.relayIntent(.close)"),
      "The brand dot must relay the close intent")
    XCTAssertTrue(
      header.contains(".accessibilityIdentifier(\"overlay-brand-close-dot\")"),
      "The brand dot must stay discoverable as the close control")
    XCTAssertTrue(
      header.contains(".accessibilityLabel(OverlayIntent.close.accessibilityLabel)"))
    XCTAssertTrue(
      header.contains("ModeDot(color: palette.statusToken(for: state.mode).color"),
      "The close control is the brand dot, not a glyph")
    XCTAssertFalse(header.contains("xmark"))
    // The brand block sits on an inert drag region so the dot answers clicks,
    // not window drags (Founder 19:18: the dot next to codescribe closes).
    XCTAssertTrue(header.contains("overlay-header-inert-drag-region"))
  }

  func testPhasePillIsGone() throws {
    let state = OverlayState.previewListening()
    try withPanel(state: state) { _, root in
      let elements = accessibilityTree(root)
      XCTAssertFalse(elements.contains { $0.accessibilityIdentifier() == "overlay-phase-status" })
    }
    let source = try overlaySource()
    XCTAssertFalse(source.contains("StatusPill("), "No phase capsule may render in the header")
    XCTAssertFalse(source.contains("StaticStatusPill("))
    XCTAssertFalse(source.contains("phaseStatus(text:"))
    // The phase survives for assistive tech only: the intent dock carries it
    // as its accessibility value, never as visible chrome.
    XCTAssertTrue(source.contains("phase: state.statusText"))
    let rail = try railSource()
    XCTAssertTrue(rail.contains(".accessibilityValue(Self.accessibilityValue(for: phase))"))
    XCTAssertFalse(rail.contains("StatusPill("))
    XCTAssertFalse(rail.contains("Text(phase"))
  }

  func testAutoPasteToggleMirrorsStateAndFlipsIt() throws {
    let engine = OverlayChromePolicyEngine()
    let state = OverlayState.previewListening()
    state.engine = engine
    XCTAssertTrue(state.autoPasteEnabled)
    XCTAssertTrue(state.autoPasteControlAvailable)

    // The header control flips the durable policy through the engine and
    // re-reads truth; it never paints an optimistic switch.
    state.setAutoPasteEnabled(!state.autoPasteEnabled)
    XCTAssertEqual(engine.writes, [false])
    XCTAssertFalse(state.autoPasteEnabled)
    state.setAutoPasteEnabled(!state.autoPasteEnabled)
    XCTAssertEqual(engine.writes, [false, true])
    XCTAssertTrue(state.autoPasteEnabled)

    // Unavailable (agent session armed): the control is disabled and writes
    // are refused, the policy stays where it was.
    state.setAutoPasteControlAvailable(false)
    XCTAssertFalse(state.autoPasteControlAvailable)
    state.setAutoPasteEnabled(false)
    XCTAssertEqual(engine.writes, [false, true])
    XCTAssertTrue(state.autoPasteEnabled)

    let source = try overlaySource()
    let header = try headerSource(source)
    XCTAssertTrue(
      header.contains("autoPasteControl"),
      "Both header widths are built by justifiedHeader and must carry the toggle")
    let control = try autoPasteControlSource(source)
    XCTAssertTrue(control.contains("state.setAutoPasteEnabled(!state.autoPasteEnabled)"))
    XCTAssertTrue(control.contains(".disabled(!state.autoPasteControlAvailable)"))
    XCTAssertTrue(control.contains(".accessibilityIdentifier(\"overlay-auto-paste\")"))
    XCTAssertTrue(control.contains(".accessibilityValue(state.autoPasteEnabled ? \"On\" : \"Off\")"))
  }

  private func withPanel(
    state: OverlayState, width: CGFloat = 470,
    _ check: (FloatingOverlayPanel, NSView) throws -> Void
  ) throws {
    let panel = try XCTUnwrap(
      DictationOverlayWindow.make(
        state: state, textScale: TextScaleController(key: "OverlayChromeFounderCutTests.scale")
      ) as? FloatingOverlayPanel)
    defer {
      panel.orderOut(nil)
      panel.invalidatePresence()
    }
    panel.setContentSize(NSSize(width: width, height: 280))
    panel.orderFrontRegardless()
    let root = try XCTUnwrap(panel.contentView)
    settle(root)
    try check(panel, root)
  }

  private func settle(_ root: NSView) {
    root.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    root.layoutSubtreeIfNeeded()
  }

  private func accessibilityTree(_ root: Any) -> [any NSAccessibilityProtocol] {
    func walk(_ object: Any) -> [any NSAccessibilityProtocol] {
      guard let element = object as? any NSAccessibilityProtocol
      else { return [] }
      // AppKit wrapper views can have no AX children while hosting a SwiftUI
      // accessibility subtree. Traverse both graphs, deduplicated by identity.
      let nativeChildren = (object as? NSView)?.subviews ?? []
      return [element] + ((element.accessibilityChildren() ?? []) + nativeChildren).flatMap(walk)
    }
    return walk(root)
  }

  private func overlaySource() throws -> String {
    try source(at: "Codescribe/Screens/Overlay/DictationOverlayView.swift")
  }

  private func railSource() throws -> String {
    try source(at: "Codescribe/Screens/Overlay/OverlayIntentRail.swift")
  }

  private func source(at relativePath: String) throws -> String {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent(relativePath)
    return try String(contentsOf: url, encoding: .utf8)
  }

  /// `justifiedHeader(compact:)` — the single builder behind fullHeader and
  /// narrowHeader, so one guard covers both widths.
  private func headerSource(_ source: String) throws -> String {
    try section(
      of: source, from: "private func justifiedHeader(compact: Bool)",
      to: "private var autoPasteControl")
  }

  private func autoPasteControlSource(_ source: String) throws -> String {
    try section(of: source, from: "private var autoPasteControl", to: "private func chromeWaveform")
  }

  private func section(of source: String, from start: String, to end: String) throws -> String {
    let lower = try XCTUnwrap(source.range(of: start), start)
    let upper = try XCTUnwrap(source.range(of: end, range: lower.upperBound..<source.endIndex), end)
    return String(source[lower.lowerBound..<upper.lowerBound])
  }
}

@MainActor
private final class OverlayChromePolicyEngine: DictationEngine {
  var writes: [Bool] = []
  var enabled = true
  func setListener(_ listener: CsTranscriptionListener) {}
  func startRecording(language: CsLanguage?) async throws {}
  func stopRecording() async throws -> String { "" }
  func isRecording() async -> Bool { false }
  func initModel() async throws {}
  func isModelLoaded() -> Bool { true }
  func currentOverlayPolicy() -> OverlayPolicySnapshot? {
    OverlayPolicySnapshot(autoPasteEnabled: enabled, autoFormatLevel: .correction)
  }
  func setAutoPasteEnabled(_ enabled: Bool) {
    writes.append(enabled)
    self.enabled = enabled
  }
  func setAutoFormatLevel(_ level: FormattingPolicyOption) {}
  func commitUserRevision(
    sessionId: String, sourceRevision: UInt64, renderedText: String
  ) async throws -> CsUserRevisionResult { throw CocoaError(.featureUnsupported) }
  func commitFormatterRevision(
    sessionId: String, sourceRevision: UInt64
  ) async throws -> CsUserRevisionResult { throw CocoaError(.featureUnsupported) }
  func pasteText(text: String) async throws -> CsPasteResult {
    throw CocoaError(.featureUnsupported)
  }
  func deferText(text: String) async throws -> CsPasteResult {
    throw CocoaError(.featureUnsupported)
  }
  func copyTaggedTranscript(text: String) async throws {}
  func pasteTargetAppName() async -> String? { nil }
  func sendAssistiveTranscript(text: String) async throws -> Bool { false }
  func transcribeFile(path: String) async throws -> CsTranscription {
    throw CocoaError(.featureUnsupported)
  }
}
