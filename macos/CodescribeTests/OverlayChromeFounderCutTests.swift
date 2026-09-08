import AppKit
import XCTest

@testable import Codescribe

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
    for width: CGFloat in [320, 470] {
      let state = OverlayState.previewListening()
      var closes = 0
      state.onClose = { closes += 1 }
      try withPanel(state: state, width: width) { panel, root in
        let dot = try element("overlay-brand-close", in: root)
        XCTAssertEqual(dot.accessibilityLabel(), "Close")
        XCTAssertEqual(dot.accessibilityRole(), .button)
        let point = try controlPoint(dot, panel: panel, root: root)
        XCTAssertLessThan(point.x, root.bounds.midX, "Close belongs beside the brand")
        XCTAssertGreaterThan(point.y, root.bounds.maxY - 60)
        XCTAssertFalse(panel.isWindowDragHit(at: point), "The brand drag region stole the dot")
        try XCTUnwrap(dot as? NSButton).performClick(nil)
        XCTAssertEqual(closes, 1)
      }
    }
  }

  func testPhasePillIsGone() throws {
    let state = OverlayState.previewListening()
    try withPanel(state: state) { _, root in
      let elements = accessibilityTree(root)
      XCTAssertFalse(elements.contains { $0.accessibilityIdentifier() == "overlay-phase-status" })
      let source = try overlaySource()
      XCTAssertTrue(source.contains(".accessibilityLabel(state.statusText)"))
      XCTAssertFalse(source.contains("StatusPill("), "No phase capsule may render in the header")
      XCTAssertFalse(source.contains("phaseStatus(text:"))
    }
  }

  func testAutoPasteToggleMirrorsStateAndFlipsIt() throws {
    for width: CGFloat in [320, 470] {
      let engine = OverlayChromePolicyEngine()
      let state = OverlayState.previewListening()
      state.engine = engine
      try withPanel(state: state, width: width) { panel, root in
        let toggle = try element("overlay-auto-paste", in: root)
        XCTAssertEqual(toggle.accessibilityLabel(), "Auto Paste")
        XCTAssertEqual(toggle.accessibilityValue() as? String, "On")
        let point = try controlPoint(toggle, panel: panel, root: root)
        XCTAssertFalse(panel.isWindowDragHit(at: point))
        try XCTUnwrap(toggle as? NSButton).performClick(nil)
        settle(root)
        XCTAssertEqual(engine.writes, [false])
        XCTAssertFalse(state.autoPasteEnabled)
        XCTAssertEqual(
          try element("overlay-auto-paste", in: root).accessibilityValue() as? String, "Off")
        try XCTUnwrap(element("overlay-auto-paste", in: root) as? NSButton).performClick(nil)
        settle(root)
        XCTAssertEqual(engine.writes, [false, true])
        XCTAssertTrue(state.autoPasteEnabled)
        state.setAutoPasteControlAvailable(false)
        settle(root)
        XCTAssertFalse(
          accessibilityTree(root).contains {
            $0.accessibilityIdentifier() == "overlay-auto-paste"
          })
      }
    }
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
    var visited: Set<ObjectIdentifier> = []
    func walk(_ object: Any) -> [any NSAccessibilityProtocol] {
      guard let element = object as? any NSAccessibilityProtocol,
        visited.insert(ObjectIdentifier(element)).inserted
      else { return [] }
      // AppKit wrapper views can have no AX children while hosting a SwiftUI
      // accessibility subtree. Traverse both graphs, deduplicated by identity.
      let nativeChildren = (object as? NSView)?.subviews ?? []
      return [element] + ((element.accessibilityChildren() ?? []) + nativeChildren).flatMap(walk)
    }
    return walk(root)
  }

  private func element(_ identifier: String, in root: NSView) throws -> any NSAccessibilityProtocol
  {
    try XCTUnwrap(
      accessibilityTree(root).first { $0.accessibilityIdentifier() == identifier }, identifier)
  }

  private func controlPoint(
    _ element: any NSAccessibilityProtocol, panel: FloatingOverlayPanel, root: NSView
  ) throws -> NSPoint {
    let frame = element.accessibilityFrame()
    XCTAssertGreaterThan(frame.width, 0)
    XCTAssertGreaterThan(frame.height, 0)
    let windowPoint = panel.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
    let point = root.convert(windowPoint, from: nil)
    XCTAssertTrue(root.bounds.contains(point), "Control must be visible at the window floor")
    let hit = try XCTUnwrap(root.hitTest(point))
    var chain: [String] = []
    var candidate: NSView? = hit
    while let current = candidate {
      chain.append("\(type(of: current))#\(current.accessibilityIdentifier())")
      candidate = current.superview
    }
    print("F1_CONTROL_HIT \(element.accessibilityIdentifier() ?? "") \(point) \(chain)")
    let control = try XCTUnwrap(hit as? NSButton, "Hit must resolve to the real native control")
    XCTAssertEqual(control.accessibilityIdentifier(), element.accessibilityIdentifier())
    return point
  }

  private func overlaySource() throws -> String {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Codescribe/Screens/Overlay/DictationOverlayView.swift")
    return try String(contentsOf: url, encoding: .utf8)
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
