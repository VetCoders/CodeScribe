import SwiftUI

/// Value-only rendering contract for the dock. Tests assert this model rather
/// than reconstructing a second SwiftUI hierarchy or looking for source text.
struct OverlayDockLayout: Equatable {
  static let height: CGFloat = 42
  static let minimumCanvasWidth: CGFloat = 320

  let isExpanded: Bool
  let projectedIntents: [OverlayIntent]

  var visibleIntents: [OverlayIntent] {
    isExpanded ? projectedIntents : []
  }

  var showsCollapsedFooter: Bool { !isExpanded }
  var showsHandleOnly: Bool { !isExpanded }
  var showsToolbar: Bool { isExpanded }
}

struct OverlayDockInteraction: Equatable {
  var isExpanded: Bool
  var isPinned: Bool

  mutating func pointerEntered() {
    isExpanded = true
  }

  mutating func pointerExited() {
    if !isPinned { isExpanded = false }
  }

  mutating func pin() {
    isPinned = true
    isExpanded = true
  }

  mutating func collapse() {
    isPinned = false
    isExpanded = false
  }
}

enum OverlayDockVisuals {
  static func hoverOpacity(isHovering: Bool) -> Double {
    isHovering ? 0.14 : 0
  }
}

/// The overlay's sole action surface. The reducer owns action availability;
/// this view owns only transient reveal/pin state and renders the footer or the
/// toolbar in the same fixed-height slot.
@MainActor
struct OverlayIntentRail: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var interaction: OverlayDockInteraction

  let phase: String
  let intents: [OverlayIntent]
  let palette: OverlayAppearancePalette
  let footerEngineLabel: String
  let footerNotice: String?
  let footerEngineDot: Color
  let onIntent: (OverlayIntent) -> Void

  init(
    phase: String,
    intents: [OverlayIntent],
    palette: OverlayAppearancePalette,
    footerEngineLabel: String = "",
    footerNotice: String? = nil,
    footerEngineDot: Color = .clear,
    initiallyExpanded: Bool = false,
    onIntent: @escaping (OverlayIntent) -> Void
  ) {
    self.phase = phase
    self.intents = intents
    self.palette = palette
    self.footerEngineLabel = footerEngineLabel
    self.footerNotice = footerNotice
    self.footerEngineDot = footerEngineDot
    self.onIntent = onIntent
    _interaction = State(
      initialValue: OverlayDockInteraction(
        isExpanded: initiallyExpanded,
        isPinned: initiallyExpanded
      ))
  }

  var body: some View {
    OverlayDockSurface(palette: palette) {
      ZStack {
        if interaction.isExpanded {
          expandedToolbar
            .transition(reduceMotion ? .identity : .opacity)
        } else {
          collapsedFooter
            .transition(reduceMotion ? .identity : .opacity)
        }
      }
      .frame(maxWidth: .infinity)
      .frame(height: OverlayDockLayout.height)
    }
    .animation(Self.revealAnimation(reduceMotion: reduceMotion), value: interaction.isExpanded)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Overlay actions")
    .accessibilityValue(Self.accessibilityValue(for: phase))
    .accessibilityIdentifier("overlay-intent-dock")
  }

  private var collapsedFooter: some View {
    ZStack(alignment: .bottom) {
      HStack(spacing: CSSpace.sm) {
        HStack(spacing: CSSpace.xs) {
          Text("●")
            .foregroundStyle(footerEngineDot)
          Text(footerEngineLabel)
            .foregroundStyle(palette.mutedText.color)
          footerNoticeText
        }
        Spacer(minLength: 0)
      }
      .csMono(10, .medium)
      .padding(.horizontal, 16)
      .padding(.vertical, 7)
      .allowsHitTesting(false)

      OverlayDockButton(
        title: "Show overlay actions",
        systemImage: "chevron.up",
        hint: "Reveals and pins the overlay action toolbar",
        identifier: "overlay-intent-dock-toggle",
        palette: palette,
        action: pinExpanded
      )
      .frame(width: 46, height: 24)
      .background(
        palette.surfaceTint.color,
        in: UnevenRoundedRectangle(
          topLeadingRadius: CSRadius.input,
          bottomLeadingRadius: 0,
          bottomTrailingRadius: 0,
          topTrailingRadius: CSRadius.input,
          style: .continuous
        )
      )
      .overlay(alignment: .top) {
        Capsule()
          .fill(palette.border.color)
          .frame(width: 18, height: 1)
          .allowsHitTesting(false)
      }
      .onHover(perform: setHovering)
    }
  }

  private var expandedToolbar: some View {
    HStack(spacing: CSSpace.xs) {
      OverlayDockButton(
        title: "Hide overlay actions",
        systemImage: "chevron.down",
        hint: "Collapses the overlay action toolbar",
        identifier: "overlay-intent-dock-collapse",
        palette: palette,
        action: collapse
      )

      ForEach(nonCloseIntents, id: \.self) { intent in
        intentButton(intent)
      }

      Spacer(minLength: CSSpace.xxs)
      footerNoticeText

      if intents.contains(.close) {
        Divider()
          .frame(height: CSSpace.lg)
          .overlay(palette.border.color)
          .padding(.horizontal, 2)
          .accessibilityHidden(true)
        intentButton(.close)
      }
    }
    .padding(.horizontal, CSSpace.sm)
    .buttonStyle(.plain)
    .onHover(perform: setHovering)
  }

  @ViewBuilder
  private var footerNoticeText: some View {
    if let footerNotice, !footerNotice.isEmpty {
      Text(footerNotice)
        .csMono(10, .medium)
        .foregroundStyle(palette.mutedText.color)
        .lineLimit(1)
        .truncationMode(.tail)
        .accessibilityIdentifier("overlay-footer-notice")
    }
  }

  private var nonCloseIntents: [OverlayIntent] {
    intents.filter { $0 != .close }
  }

  private func intentButton(_ intent: OverlayIntent) -> some View {
    OverlayDockButton(
      title: intent.accessibilityLabel,
      systemImage: intent.systemImage,
      hint: intent.accessibilityHint,
      identifier: "overlay-intent-\(intent.rawValue)",
      palette: palette
    ) {
      dispatch(intent)
    }
  }

  static func projectedIntents(for state: OverlayState) -> [OverlayIntent] {
    if state.revisionCommitPending || state.formatterCommitPending {
      return []
    }
    if state.isRevisionDraftDirty {
      return [.commitRevision, .discardRevision, .close]
    }
    return projectedIntents(
      phase: state.mode,
      canPaste: state.canPaste,
      canInsert: state.canInsert,
      canCopy: state.canCopy,
      canRetranscribe: state.canRetranscribe,
      canFormat: state.canFormat
    )
  }

  /// Frozen `overlay-canvas-v1` projection table. A false bit omits its
  /// command; the dock never reconstructs delivery legality from local state.
  static func projectedIntents(
    phase: OverlayMode,
    canPaste: Bool,
    canInsert: Bool,
    canCopy: Bool,
    canRetranscribe: Bool,
    canFormat: Bool
  ) -> [OverlayIntent] {
    switch phase {
    case .listening:
      [.finish] + (canCopy ? [.copy] : []) + [.close]
    case .finalizing:
      (canCopy ? [.copy] : []) + [.close]
    case .formatted:
      ((canPaste || canInsert) ? [.insertPaste] : [])
        + (canCopy ? [.copy] : [])
        + (canRetranscribe ? [.retranscribe] : [])
        + (canFormat ? [.format] : [])
        + [.close]
    case .noSpeech:
      (canRetranscribe ? [.retranscribe] : []) + [.close]
    case .error:
      [.close]
    }
  }

  static func revealAnimation(reduceMotion: Bool) -> Animation? {
    reduceMotion ? nil : CSMotion.floatIn
  }

  static func accessibilityValue(for phase: String) -> String {
    phase
  }

  func dispatch(_ intent: OverlayIntent) {
    onIntent(intent)
  }

  private func pinExpanded() {
    interaction.pin()
  }

  private func collapse() {
    interaction.collapse()
  }

  private func setHovering(_ hovering: Bool) {
    if hovering {
      interaction.pointerEntered()
    } else {
      interaction.pointerExited()
    }
  }
}

@MainActor
private struct OverlayDockButton: View {
  @State private var isHovering = false

  let title: String
  let systemImage: String
  let hint: String
  let identifier: String
  let palette: OverlayAppearancePalette
  let action: () -> Void

  var body: some View {
    Button(title, systemImage: systemImage, action: action)
      .buttonStyle(.plain)
      .labelStyle(.iconOnly)
      .frame(width: 32, height: 28)
      .contentShape(RoundedRectangle(cornerRadius: CSRadius.chip, style: .continuous))
      .foregroundStyle(palette.primaryText.color)
      .background {
        RoundedRectangle(cornerRadius: CSRadius.chip, style: .continuous)
          .fill(
            palette.primaryText.color.opacity(
              OverlayDockVisuals.hoverOpacity(isHovering: isHovering)))
      }
      .onHover { isHovering = $0 }
      .help(title)
      .accessibilityLabel(title)
      .accessibilityHint(hint)
      .accessibilityIdentifier(identifier)
  }
}

private struct OverlayDockSurface<Content: View>: View {
  let palette: OverlayAppearancePalette
  @ViewBuilder let content: Content

  var body: some View {
    if #available(macOS 26.0, *) {
      content
        .glassEffect(
          .regular.interactive(),
          in: RoundedRectangle(cornerRadius: CSRadius.input, style: .continuous)
        )
    } else {
      content
        .background(
          palette.surfaceTint.color,
          in: RoundedRectangle(cornerRadius: CSRadius.input, style: .continuous)
        )
    }
  }
}

extension OverlayIntent {
  var accessibilityLabel: String {
    switch self {
    case .finish: "Finish recording"
    case .commitRevision: "Commit transcript revision"
    case .discardRevision: "Discard transcript draft"
    case .copy: "Copy transcript"
    case .insertPaste: "Insert transcript"
    case .retranscribe: "Retranscribe recording"
    case .format: "Format transcript"
    case .close: "Close overlay"
    }
  }

  var accessibilityHint: String {
    switch self {
    case .finish: "Stops capture and requests the final projection"
    case .commitRevision: "Commits this draft through the transcript ledger"
    case .discardRevision: "Restores the latest projected transcript"
    case .copy: "Copies the projected transcript"
    case .insertPaste: "Sends the projected transcript to the selected destination"
    case .retranscribe: "Requests another transcription of this recording"
    case .format: "Requests formatting between takes"
    case .close: "Closes the dictation overlay"
    }
  }

  var systemImage: String {
    switch self {
    case .finish: "stop.circle"
    case .commitRevision: "checkmark.circle"
    case .discardRevision: "arrow.uturn.backward.circle"
    case .copy: "doc.on.doc"
    case .insertPaste: "arrow.down.doc"
    case .retranscribe: "arrow.clockwise"
    case .format: "textformat"
    case .close: "xmark"
    }
  }
  var helpText: String { accessibilityLabel }
}
