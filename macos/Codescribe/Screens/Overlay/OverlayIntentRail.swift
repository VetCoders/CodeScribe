import SwiftUI

/// Value-only rendering contract for the dock. Tests assert this model rather
/// than reconstructing a second SwiftUI hierarchy or looking for source text.
///
/// The dock is always the toolbar. The collapsed handle / hover-reveal / pin
/// states are gone (Founder 2026-09-08: the buttons exist so the transcript
/// can sit flush, not as decoration — keep them visible).
struct OverlayDockLayout: Equatable {
  static let height: CGFloat = 42
  static let minimumCanvasWidth: CGFloat = 320

  let projectedIntents: [OverlayIntent]

  var visibleIntents: [OverlayIntent] { projectedIntents }
  var showsToolbar: Bool { true }
}

enum OverlayDockVisuals {
  static func hoverOpacity(isHovering: Bool) -> Double {
    isHovering ? 0.14 : 0
  }
}

/// The overlay's sole action surface. The reducer owns action availability;
/// this view only renders the projected commands, the engine chip, the
/// transient notice and the formatting-level control in one fixed-height slot.
@MainActor
struct OverlayIntentRail: View {
  let phase: String
  let intents: [OverlayIntent]
  let palette: OverlayAppearancePalette
  let footerEngineLabel: String
  let footerNotice: String?
  let footerEngineDot: Color
  let formatLevel: FormattingPolicyOption
  let onIntent: (OverlayIntent) -> Void
  let onFormatLevel: (FormattingPolicyOption) -> Void

  init(
    phase: String,
    intents: [OverlayIntent],
    palette: OverlayAppearancePalette,
    footerEngineLabel: String = "",
    footerNotice: String? = nil,
    footerEngineDot: Color = .clear,
    formatLevel: FormattingPolicyOption = .correction,
    onIntent: @escaping (OverlayIntent) -> Void,
    onFormatLevel: @escaping (FormattingPolicyOption) -> Void = { _ in }
  ) {
    self.phase = phase
    self.intents = intents
    self.palette = palette
    self.footerEngineLabel = footerEngineLabel
    self.footerNotice = footerNotice
    self.footerEngineDot = footerEngineDot
    self.formatLevel = formatLevel
    self.onIntent = onIntent
    self.onFormatLevel = onFormatLevel
  }

  var body: some View {
    OverlayDockSurface(palette: palette) {
      HStack(spacing: CSSpace.xs) {
        engineChip
        Spacer(minLength: CSSpace.xxs)
        footerNoticeText
        formatLevelButton
        ForEach(intents, id: \.self) { intent in
          if intent == .close {
            Divider()
              .frame(height: CSSpace.lg)
              .overlay(palette.border.color)
              .padding(.horizontal, 2)
              .accessibilityHidden(true)
          }
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
      }
      .padding(.horizontal, CSSpace.sm)
      .buttonStyle(.plain)
      .frame(maxWidth: .infinity)
      .frame(height: OverlayDockLayout.height)
      // Everything in the dock that is not a control (engine chip, notice,
      // spacer) drags the window. Buttons sit above this region and keep
      // their clicks.
      .background {
        OverlayWindowDragRegion(identifier: "overlay-dock-inert-drag-region")
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Overlay actions")
    .accessibilityValue(Self.accessibilityValue(for: phase))
    .accessibilityIdentifier("overlay-intent-dock")
  }

  /// Serving-engine evidence, inert. Truncates first when the window sits at
  /// its 320 pt floor so the commands never do.
  private var engineChip: some View {
    HStack(spacing: CSSpace.xxs) {
      Text("●")
        .foregroundStyle(footerEngineDot)
      Text(footerEngineLabel)
        .foregroundStyle(palette.mutedText.color)
        .lineLimit(1)
        .truncationMode(.tail)
    }
    .csMono(10, .medium)
    .layoutPriority(-1)
    .allowsHitTesting(false)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("overlay-footer-engine")
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

  /// Off → Correction → Smart → Max → Off, the same cycle as the tray. The
  /// label is durable engine truth; a click writes through the engine and the
  /// state re-reads before this repaints.
  private var formatLevelButton: some View {
    Button(action: cycleFormatLevel) {
      Text(formatLevel.visibleName)
        .csMono(10, .semibold)
        .foregroundStyle(
          formatLevel == .off ? palette.mutedText.color : palette.primaryText.color
        )
        .lineLimit(1)
        .padding(.horizontal, CSSpace.xs)
        .frame(height: 24)
        .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .background {
      Capsule().strokeBorder(palette.border.color, lineWidth: 1)
    }
    .help("Formatting level: \(formatLevel.visibleName). Click to cycle.")
    .accessibilityLabel("Formatting level")
    .accessibilityValue(formatLevel.visibleName)
    .accessibilityHint("Cycles the automatic formatting level")
    .accessibilityIdentifier("overlay-format-level")
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

  static func accessibilityValue(for phase: String) -> String {
    phase
  }

  func dispatch(_ intent: OverlayIntent) {
    onIntent(intent)
  }

  func cycleFormatLevel() {
    onFormatLevel(formatLevel.next)
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
