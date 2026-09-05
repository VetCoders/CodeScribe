import XCTest

@testable import Codescribe

final class OverlayResizeHitTests: XCTestCase {
  private let bounds = NSRect(x: 0, y: 0, width: 400, height: 300)
  private let band = OverlayResizeHit.band

  func testInteriorIsNotAResizeHit() {
    XCTAssertNil(OverlayResizeHit.edge(at: NSPoint(x: 200, y: 150), in: bounds))
  }

  @MainActor
  func testRealOverlayHierarchyRoutesDragControlsAndTranscriptIndependently() throws {
    let state = OverlayState.previewListening()
    let panel = DictationOverlayWindow.make(
      state: state,
      textScale: TextScaleController(key: "OverlayResizeHitTests.textScale")
    )
    defer {
      panel.orderOut(nil)
      (panel as? FloatingOverlayPanel)?.invalidatePresence()
    }
    panel.setContentSize(NSSize(width: 470, height: 280))
    panel.orderFrontRegardless()

    let root = try XCTUnwrap(panel.contentView)
    root.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    root.layoutSubtreeIfNeeded()

    let dragPoints = [
      ("header", NSPoint(x: 28, y: root.bounds.maxY - 22)),
      ("body margin", NSPoint(x: 18, y: root.bounds.midY)),
      ("footer", NSPoint(x: 28, y: 14)),
    ]
    for (region, point) in dragPoints {
      let hit = try XCTUnwrap(root.hitTest(point))
      XCTAssertTrue(
        hasGestureRecognizer(named: "NSPanGestureRecognizer", from: hit),
        "\(region) exposed no native drag recognizer: \(hitChain(from: hit))"
      )
      XCTAssertFalse(
        hitChain(from: hit).contains("OverlayDragHandleView"),
        "the obsolete AppKit drag layer still owns \(region): \(hitChain(from: hit))"
      )
    }

    // The collapsed production rail is trailing/vertically centred. Use the
    // real window coordinate instead of manufacturing an NSButton sibling.
    let actionPoint = NSPoint(x: root.bounds.maxX - 24, y: root.bounds.midY)
    let actionHit = try XCTUnwrap(root.hitTest(actionPoint))
    XCTAssertFalse(
      hitChain(from: actionHit).contains("OverlayDragHandleView"),
      "the action control was stolen by \(hitChain(from: actionHit))"
    )

    let transcript = try XCTUnwrap(descendant(of: LiveTranscriptNativeTextView.self, in: root))
    let transcriptPoint = root.convert(
      NSPoint(x: transcript.bounds.midX, y: transcript.bounds.midY),
      from: transcript
    )
    let transcriptHit = try XCTUnwrap(root.hitTest(transcriptPoint))
    XCTAssertTrue(
      transcriptHit === transcript || transcriptHit.isDescendant(of: transcript),
      "the transcript was stolen by \(hitChain(from: transcriptHit))"
    )
    XCTAssertTrue(transcript.isSelectable)
  }

  func testPersistedContentSizeRoundTripsThroughDefaults() throws {
    let suiteName = "OverlayResizeHitTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let expected = NSSize(width: 612, height: 377)
    DictationOverlayWindow.persist(size: expected, defaults: defaults)

    XCTAssertEqual(
      DictationOverlayWindow.restoredContentSize(for: nil, defaults: defaults),
      expected
    )
  }

  func testEdgesAndCornersUseTheFatBand() {
    XCTAssertEqual(OverlayResizeHit.band, 16)
    XCTAssertEqual(OverlayResizeHit.edge(at: NSPoint(x: 2, y: 150), in: bounds), .left)
    XCTAssertEqual(OverlayResizeHit.edge(at: NSPoint(x: 398, y: 150), in: bounds), .right)
    XCTAssertEqual(OverlayResizeHit.edge(at: NSPoint(x: 200, y: 298), in: bounds), .top)
    XCTAssertEqual(OverlayResizeHit.edge(at: NSPoint(x: 200, y: 2), in: bounds), .bottom)
    XCTAssertEqual(OverlayResizeHit.edge(at: NSPoint(x: 2, y: 298), in: bounds), .topLeft)
    XCTAssertEqual(OverlayResizeHit.edge(at: NSPoint(x: 398, y: 298), in: bounds), .topRight)
    XCTAssertEqual(OverlayResizeHit.edge(at: NSPoint(x: 2, y: 2), in: bounds), .bottomLeft)
    XCTAssertEqual(OverlayResizeHit.edge(at: NSPoint(x: 398, y: 2), in: bounds), .bottomRight)
  }

  func testJustInsideTheBandIsStillInterior() {
    let inset = band + 1
    XCTAssertNil(OverlayResizeHit.edge(at: NSPoint(x: inset, y: 150), in: bounds))
    XCTAssertNil(OverlayResizeHit.edge(at: NSPoint(x: 200, y: inset), in: bounds))
  }

  func testApplyKeepsMinSizeWhenDraggingInward() {
    let start = NSRect(x: 100, y: 80, width: 400, height: 320)
    let minSize = DictationOverlayWindow.minSize
    let crushed = OverlayResizeHit.apply(
      edge: .right,
      start: start,
      dx: -200,
      dy: 0,
      minSize: minSize
    )
    XCTAssertEqual(crushed.width, minSize.width)
    XCTAssertEqual(crushed.origin.x, start.origin.x)
  }

  func testLeftAndBottomKeepTheOppositeEdgePinned() {
    let start = NSRect(x: 100, y: 80, width: 400, height: 320)
    let minSize = DictationOverlayWindow.minSize
    let left = OverlayResizeHit.apply(
      edge: .left,
      start: start,
      dx: 20,
      dy: 0,
      minSize: minSize
    )
    XCTAssertEqual(left.maxX, start.maxX)
    XCTAssertEqual(left.width, 380)
    let bottom = OverlayResizeHit.apply(
      edge: .bottom,
      start: start,
      dx: 0,
      dy: 20,
      minSize: minSize
    )
    XCTAssertEqual(bottom.maxY, start.maxY)
    XCTAssertEqual(bottom.height, 300)
  }

  @MainActor
  private func descendant<View: NSView>(of type: View.Type, in root: NSView) -> View? {
    if let root = root as? View { return root }
    return root.subviews.lazy.compactMap { self.descendant(of: type, in: $0) }.first
  }

  @MainActor
  private func hasGestureRecognizer(named name: String, from view: NSView) -> Bool {
    var candidate: NSView? = view
    while let current = candidate {
      if current.gestureRecognizers.contains(where: {
        String(describing: type(of: $0)) == name
      }) {
        return true
      }
      candidate = current.superview
    }
    return false
  }

  @MainActor
  private func hitChain(from view: NSView) -> String {
    var chain: [String] = []
    var candidate: NSView? = view
    while let current = candidate {
      let rawIdentifier = current.accessibilityIdentifier()
      let identifier = rawIdentifier.isEmpty ? "" : "#\(rawIdentifier)"
      let recognizers = current.gestureRecognizers
        .map { String(describing: type(of: $0)) }
        .joined(separator: ",")
      let recognizerDetail = recognizers.isEmpty ? "" : "{\(recognizers)}"
      chain.append("\(String(describing: type(of: current)))\(identifier)\(recognizerDetail)")
      candidate = current.superview
    }
    return chain.joined(separator: " <- ")
  }
}
