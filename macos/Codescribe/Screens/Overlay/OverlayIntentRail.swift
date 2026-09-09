import SwiftUI

/// Action availability stays projected; chrome visibility is local presentation only.
struct OverlayDockLayout: Equatable {
  static let minimumCanvasWidth: CGFloat = 320
  let projectedIntents: [OverlayIntent]
  var visibleIntents: [OverlayIntent] { projectedIntents.filter { $0 != .close } }
}

enum OverlayChromeVisibility {
  static func actionsVisible(pointerInside: Bool, keyboardFocus: Bool, voiceOver: Bool) -> Bool {
    pointerInside || keyboardFocus || voiceOver
  }
}

enum OverlayDockVisuals {
  static func hoverOpacity(isHovering: Bool) -> Double {
    isHovering ? 0.14 : 0
  }
}

/// The overlay's sole action surface. The reducer owns action availability;
/// this view only renders the projected commands, the engine chip, the
/// transient notice and formatting level floating over the transcript.
@MainActor
struct OverlayIntentRail: View {
  @FocusState private var focusedControl: String?
  let onFocusChange: (Bool) -> Void
  let phase: String
  let intents: [OverlayIntent]
  let palette: OverlayAppearancePalette
  let footerEngineLabel: String
  let footerNotice: String?
  let footerEngineDot: Color
  let onIntent: (OverlayIntent) -> Void
  let onRetranscribe: (OverlayRetranscribePass) -> Void

  init(
    phase: String,
    intents: [OverlayIntent],
    palette: OverlayAppearancePalette,
    footerEngineLabel: String = "",
    footerNotice: String? = nil,
    footerEngineDot: Color = .clear,
    onIntent: @escaping (OverlayIntent) -> Void,
    onRetranscribe: @escaping (OverlayRetranscribePass) -> Void = { _ in },
    onFocusChange: @escaping (Bool) -> Void = { _ in }
  ) {
    self.onFocusChange = onFocusChange
    self.phase = phase
    self.intents = intents
    self.palette = palette
    self.footerEngineLabel = footerEngineLabel
    self.footerNotice = footerNotice
    self.footerEngineDot = footerEngineDot
    self.onIntent = onIntent
    self.onRetranscribe = onRetranscribe
  }

  var body: some View {
    VStack(spacing: 4) {
      HStack(spacing: CSSpace.xs) {
        engineChip
        footerNoticeText
      }
      .padding(.horizontal, 8)
      .background(.regularMaterial, in: Capsule())
      HStack(spacing: 4) {
        ForEach(intents, id: \.self) { intent in
          if intent == .retranscribe {
            retranscribeMenu
              .focused($focusedControl, equals: intent.rawValue)
          } else if intent != .close {
            OverlayDockButton(
              title: intent.accessibilityLabel,
              systemImage: intent.systemImage,
              hint: intent.accessibilityHint,
              identifier: "overlay-intent-\(intent.rawValue)",
              palette: palette
            ) {
              dispatch(intent)
            }
            .focused($focusedControl, equals: intent.rawValue)
          }
        }
      }
      .padding(6)
      .buttonStyle(.plain)
      .background(.regularMaterial, in: Capsule())
      .overlay { Capsule().strokeBorder(palette.border.color, lineWidth: 1) }
    }
    .fixedSize(horizontal: false, vertical: true)
    .frame(maxWidth: .infinity, alignment: .center)
    .onChange(of: focusedControl) { _, control in onFocusChange(control != nil) }
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
    .accessibilityElement(children: .contain)
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

  /// Retranscribe is opt-in with the pass picked here: Full HQ (local
  /// Whisper file pass) or Cloud. The formatting level is not overlay chrome;
  /// the operator sets it in the tray quick settings (Founder 2026-09-09).
  private var retranscribeMenu: some View {
    Menu {
      ForEach(OverlayRetranscribePass.allCases) { pass in
        Button(pass.visibleName) { retranscribe(pass) }
          .help(pass.help)
          .accessibilityIdentifier("overlay-retranscribe-\(pass.rawValue)")
      }
    } label: {
      Label(OverlayIntent.retranscribe.accessibilityLabel, systemImage: OverlayIntent.retranscribe.systemImage)
        .labelStyle(.iconOnly)
        .frame(width: 32, height: 28)
        .contentShape(RoundedRectangle(cornerRadius: CSRadius.chip, style: .continuous))
        .foregroundStyle(palette.primaryText.color)
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .help(OverlayIntent.retranscribe.accessibilityHint)
    .accessibilityLabel(OverlayIntent.retranscribe.accessibilityLabel)
    .accessibilityHint(OverlayIntent.retranscribe.accessibilityHint)
    .accessibilityIdentifier("overlay-intent-\(OverlayIntent.retranscribe.rawValue)")
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

  func retranscribe(_ pass: OverlayRetranscribePass) {
    onRetranscribe(pass)
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
    case .close: "circle.fill"
    }
  }
  var helpText: String { accessibilityLabel }
}
