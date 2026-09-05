import AppKit
import SwiftUI

/// A deliberately inert piece of overlay chrome that moves its owning window.
/// Controls and the native transcript remain sibling content above this region,
/// so they keep their ordinary click, scroll, and selection behavior.
struct OverlayWindowDragRegion: View {
  var body: some View {
    Group {
      if #available(macOS 15.0, *) {
        Color.clear
          .contentShape(Rectangle())
          .gesture(WindowDragGesture())
          .allowsWindowActivationEvents(true)
      } else {
        LegacyWindowDragRegion()
      }
    }
    .accessibilityHidden(true)
  }
}

/// macOS 14 compatibility edge. Modern systems use `WindowDragGesture`; the
/// bridge exists only inside each explicit inert region, never behind the whole
/// hosting hierarchy.
private struct LegacyWindowDragRegion: NSViewRepresentable {
  func makeNSView(context: Context) -> DragView { DragView() }

  func updateNSView(_ nsView: DragView, context: Context) {}

  final class DragView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  }
}
