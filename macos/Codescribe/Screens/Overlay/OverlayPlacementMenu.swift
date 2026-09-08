import SwiftUI

/// Compact window-position affordance. It exposes the existing six anchors and
/// free-motion mode without reviving the old inline Picker/dropdown treatment.
@MainActor
struct OverlayPlacementMenu: View {
  @Bindable var state: OverlayState
  let palette: OverlayAppearancePalette

  var body: some View {
    Menu {
      Section("Anchor") {
        ForEach(OverlayAnchor.allCases) { anchor in
          Button {
            state.selectPlacementAnchor(anchor)
          } label: {
            Label(anchor.label, systemImage: menuImage(for: anchor))
          }
        }
      }

      Divider()

      Button {
        state.selectFreeMotion()
      } label: {
        Label(
          "Free motion",
          systemImage: state.freeMotion
            ? "checkmark"
            : "arrow.up.and.down.and.arrow.left.and.right"
        )
      }
    } label: {
      Label("Position overlay", systemImage: "location.viewfinder")
        .labelStyle(.iconOnly)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(palette.mutedText.color)
        .frame(width: 24, height: 24)
        .contentShape(Rectangle())
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .fixedSize()
    .help("Position overlay")
    .accessibilityLabel("Position overlay")
    .accessibilityValue(state.freeMotion ? "Free motion" : state.placementAnchor.label)
    .accessibilityHint("Choose a screen anchor or allow free dragging")
    .accessibilityIdentifier("overlay-placement-menu")
  }

  private func menuImage(for anchor: OverlayAnchor) -> String {
    guard !state.freeMotion, state.placementAnchor == anchor else {
      return anchor.systemImage
    }
    return "checkmark"
  }
}
