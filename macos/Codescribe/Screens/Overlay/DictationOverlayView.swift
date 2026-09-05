import SwiftUI

// Slim evidence-first dictation overlay.
//
// Layout (top → bottom):
//   header   brand · ONE projection phase · compact waveform · timer
//   body     transcript is the product surface (listening / formatted / terminal)
//   footer   ● engine chip · transient actionable notice
//
// Removed on purpose: duplicate RECORDING/modeMeta row, full bottom Finish/Close
// action layer, and decorative body-top waveform competing with words.
//
// Authority: this view only visualizes OverlayState / projection receipts. It
// never invents transcript truth, seals, or a second recorder. Future AoT mode
// attaches to AgentChatStore (same thread owner) via existing sendToAgent — not
// a parallel chat window.
struct DictationOverlayView: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorScheme) private var colorScheme
  @FocusState private var transcriptEditorFocused: Bool
  @Bindable var state: OverlayState
  var dockInitiallyExpanded = false

  // Geometry constants local to this surface. The window is user-resizable;
  // content fills the frame and never goes narrower than `windowMinWidth`.
  // `DictationOverlayWindow.minSize.height` MUST stay ≥ chrome + `bodyMinHeight`
  // or GlassPanel paints past the window rect and squares the corners.
  private let windowMinWidth: CGFloat = 320
  private let bodyMinHeight: CGFloat = 130
  private let transcriptMinHeight: CGFloat = 96
  private let headerChromeInset: CGFloat = 46
  private var palette: OverlayAppearancePalette {
    OverlayAppearancePalette.resolve(colorScheme)
  }

  var body: some View {
    OverlayCanvasSurface(palette: palette) {
      sharedChromeContainer
    }
    .csFocusPolicy()
    .frame(minWidth: windowMinWidth, maxWidth: .infinity, maxHeight: .infinity)
    // Terminal corner clip (U22): GlassPanel paints its background from the
    // CONTENT column's size, not the window's. Whenever the column outgrows
    // the window frame — a mid-edge-drag beat, a stale persisted size below
    // the chrome+body sum — that background used to spill past the window
    // rect and surface as a SQUARE corner under the rounded glass. Clipping
    // the whole panel to the window-frame rounded rect closes that class of
    // regression regardless of the height arithmetic. The GlassPanel shadow
    // already falls outside the borderless window (never rendered), so this
    // clip costs nothing visually.
    .clipShape(RoundedRectangle(cornerRadius: CSRadius.window, style: .continuous))
    .developerPowerCorner(padding: 10)
    .animation(reduceMotion ? nil : CSMotion.floatIn, value: state.toast)
    .onHover { inside in
      state.setPointerHovering(inside)
    }
    .onAppear {
      FontLoader.register()
    }
  }

  @ViewBuilder
  private var sharedChromeContainer: some View {
    if #available(macOS 26.0, *) {
      GlassEffectContainer(spacing: 0) {
        canvasStack
      }
    } else {
      canvasStack
    }
  }

  private var canvasStack: some View {
    ZStack {
      bodySection

      VStack(alignment: .leading, spacing: 0) {
        header
        hairline(0.06)
        Spacer(minLength: 0)
          .allowsHitTesting(false)
        hairline(0.05)
        OverlayIntentRail(
          phase: state.statusText,
          intents: OverlayIntentRail.projectedIntents(for: state),
          palette: palette,
          footerEngineLabel: state.footerEngineLabel,
          footerNotice: state.toast,
          footerEngineDot: footerEngineDot,
          initiallyExpanded: dockInitiallyExpanded,
          onIntent: state.relayIntent
        )
        .background { OverlayWindowDragRegion() }
      }
    }
  }

  /// 1px separator matching the mock's hairline borders.
  private func hairline(_ alpha: Double) -> some View {
    palette.border.color.opacity(alpha / max(palette.border.alpha, 0.001)).frame(height: 1)
  }

  // MARK: Header

  private var header: some View {
    ViewThatFits(in: .horizontal) {
      fullHeader
      narrowHeader
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .modifier(OverlayHeaderChrome(palette: palette))
    .background { OverlayWindowDragRegion() }
  }

  private var fullHeader: some View {
    HStack(spacing: 10) {
      // Brand block stays inert. The trailing intent rail is the overlay's
      // one control surface, including its projected Close command.
      HStack(spacing: 9) {
        ModeDot(color: CSColor.terracotta, size: 9)
          .accessibilityHidden(true)
        Text("codescribe")
          .font(CSFont.ui(15, .bold))
          .tracking(-0.3)
          .foregroundStyle(palette.primaryText.color)
          .allowsHitTesting(false)
      }
      .allowsHitTesting(false)
      phaseStatus(text: state.statusText)

      if state.mode == .listening || state.mode == .finalizing {
        chromeWaveform(barCount: 18)
      }

      Spacer(minLength: 4)

      sessionTimer
        .allowsHitTesting(false)

      OverlayPlacementMenu(state: state, palette: palette)
    }
    .fixedSize(horizontal: true, vertical: false)
  }

  /// Essential chrome only at the supported 320 pt window floor. Close, one
  /// projected phase, real level evidence, and time never collapse vertically.
  private var narrowHeader: some View {
    HStack(spacing: 7) {
      ModeDot(color: CSColor.terracotta, size: 9)
        .accessibilityHidden(true)
      phaseStatus(text: state.compactStatusText)
      if state.mode == .listening || state.mode == .finalizing {
        chromeWaveform(barCount: 10)
      }
      Spacer(minLength: 0)
      sessionTimer
        .allowsHitTesting(false)
      OverlayPlacementMenu(state: state, palette: palette)
    }
    .fixedSize(horizontal: true, vertical: false)
  }

  @ViewBuilder
  private func phaseStatus(text: String) -> some View {
    // One phase pill only — do not also paint RECORDING/tag/meta rows. Swap the
    // whole view type on live vs idle so repeatForever tears down after capture.
    if state.statusRippling {
      StatusPill(text: text, color: palette.statusToken(for: state.mode).color, rippling: true)
        .fixedSize(horizontal: true, vertical: false)
        .allowsHitTesting(false)
        .accessibilityLabel(state.statusText)
        .accessibilityIdentifier("overlay-phase-status")
    } else {
      StaticStatusPill(text: text, color: palette.statusToken(for: state.mode).color)
        .fixedSize(horizontal: true, vertical: false)
        .allowsHitTesting(false)
        .accessibilityLabel(state.statusText)
        .accessibilityIdentifier("overlay-phase-status")
    }
  }

  /// Audio-evidence strip in the primary bar. Amplitude/VAD only — word/PCM
  /// synchronized scrolling needs authenticated sample spans from projection
  /// receipts and is intentionally not invented here.
  private func chromeWaveform(barCount: Int) -> some View {
    WaveformView(
      barCount: barCount,
      active: state.mode == .listening && (state.audioReady || state.vadActive),
      transcribing: state.mode == .finalizing,
      indicatorMode: state.indicatorMode,
      meter: state.levelMeter,
      inactiveColor: palette.border.color,
      compact: true
    )
    .accessibilityIdentifier("overlay-chrome-waveform")
    .accessibilityLabel("Live audio level")
    .accessibilityValue(state.audioLevelAccessibilityValue)
    .allowsHitTesting(false)
  }

  /// Live `00:00` session counter — absolute reference for audio sync and lag.
  /// Lives in the primary chrome (not a second status row). Capture end freezes
  /// the stamp so the displayed value is the session's true length.
  @ViewBuilder
  private var sessionTimer: some View {
    if state.showsSessionTimer {
      TimelineView(.periodic(from: .now, by: 1)) { _ in
        Text(state.sessionTimerText)
          .csMono(11, .semibold)
          .foregroundStyle(palette.mutedText.color)
          .monospacedDigit()
      }
      .accessibilityIdentifier("overlay-session-timer")
      .accessibilityLabel("Recording time")
      .accessibilityValue(state.sessionTimerText)
    }
  }

  // MARK: Body

  private var bodySection: some View {
    Group {
      if let status = state.presentationStatus {
        presentationStatusBody(status)
          .transition(reduceMotion ? .identity : .opacity.combined(with: .offset(y: 8)))
      } else {
        switch state.mode {
        case .listening, .finalizing:
          listeningBody
            .transition(reduceMotion ? .identity : .opacity.combined(with: .offset(y: 8)))
        case .formatted:
          formattedBody
        case .noSpeech:
          noSpeechBody
            .transition(reduceMotion ? .identity : .opacity.combined(with: .offset(y: 8)))
        case .error:
          errorBody
            .transition(reduceMotion ? .identity : .opacity.combined(with: .offset(y: 8)))
        }
      }
    }
    .frame(
      maxWidth: .infinity, minHeight: bodyMinHeight, maxHeight: .infinity, alignment: .topLeading
    )
    .padding(.horizontal, 20)
    .padding(.top, 4)
    .padding(.bottom, 10)
    .background { OverlayWindowDragRegion() }
    // Transcript content must never paint into the footer during live resize.
    .clipped()
    .animation(reduceMotion ? nil : CSMotion.floatIn, value: state.mode)
  }

  private var listeningBody: some View {
    // Transcript is the product. Audio evidence lives in the primary chrome
    // waveform; do not restack a decorative strip above the words.
    transcriptScroll
      .padding(.top, headerChromeInset)
      .padding(.bottom, OverlayDockLayout.height)
  }

  /// Native live transcript: follows the newest words until the user clicks or
  /// selects an older phrase. The `NSTextView` keeps that selection stable across
  /// ongoing stream updates, so drag selection, Cmd-C and context-menu Copy work
  /// during recording without stopping capture. A `minHeight` reserves ~2–3 lines
  /// at the window floor.
  private var transcriptScroll: some View {
    VStack(alignment: .leading, spacing: 0) {
      LiveTranscriptTextView(
        text: state.listeningDisplay,
        appearance: palette.appearance
      )
      .overlay(alignment: .bottomTrailing) {
        BlinkingCaret()
          .padding(.trailing, 3)
          .allowsHitTesting(false)
      }
      .frame(minHeight: transcriptMinHeight)
      .accessibilityIdentifier("overlay-transcript-area")
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var formattedBody: some View {
    VStack(alignment: .leading, spacing: CSSpace.sm) {
      HStack(spacing: CSSpace.xs) {
        if state.formatterCommitPending {
          ProgressView()
            .controlSize(.small)
          Text("Formatting revision…")
        } else if state.revisionCommitPending {
          ProgressView()
            .controlSize(.small)
          Text("Committing revision…")
        } else if state.isRevisionDraftDirty {
          Image(systemName: "pencil.line")
          Text("Draft · not committed")
        } else {
          Image(systemName: "checkmark.seal")
          Text("Ledger projection")
        }
      }
      .csMono(10, .semibold)
      .foregroundStyle(
        state.isRevisionDraftDirty ? CSColor.terracotta : palette.mutedText.color
      )
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier("overlay-revision-status")

      TextField(
        "Edit final transcript",
        text: $state.revisionDraft,
        axis: .vertical
      )
      .textFieldStyle(.plain)
      .csFont(19, .medium)
      .foregroundStyle(palette.primaryText.color)
      .lineSpacing(6)
      .lineLimit(3...12)
      .focused($transcriptEditorFocused)
      .disabled(state.revisionCommitPending || state.formatterCommitPending)
      .accessibilityLabel("Final transcript revision draft")
      .accessibilityHint("Edits stay local until committed to the transcript ledger")
      .accessibilityIdentifier("overlay-transcript-editor")
      .onChange(of: state.revisionDraft) { _, _ in
        state.noteRevisionDraftActivity()
      }
      .onChange(of: transcriptEditorFocused) { wasFocused, isFocused in
        if wasFocused && !isFocused {
          state.scheduleRevisionCommitAfterFocusExit()
        }
      }
      .onExitCommand {
        state.discardRevisionDraft()
        transcriptEditorFocused = false
      }

      if let error = state.revisionCommitError {
        Label(error, systemImage: "exclamationmark.triangle")
          .csMono(10, .medium)
          .foregroundStyle(CSColor.terracotta)
          .accessibilityIdentifier("overlay-revision-error")
      }
    }
    .frame(
      maxWidth: .infinity, minHeight: bodyMinHeight, maxHeight: .infinity,
      alignment: .topLeading
    )
    .clipped()
    .padding(.top, headerChromeInset)
    .padding(.bottom, OverlayDockLayout.height)
    .accessibilityLabel("Final transcript")
    .accessibilityValue(state.revisionDraft)
    .accessibilityIdentifier("overlay-transcript-formatted")
  }

  /// Terminal outcome for a session that captured no usable speech. Replaces
  /// the empty editable FINAL with a calm, non-alarming notice (mic glyph +
  /// message). No Copy/Insert/Send — there is nothing to act on; the intent
  /// rail follows the projection table and keeps Retranscribe/Close only.
  private var noSpeechBody: some View {
    HStack(spacing: 12) {
      CSIconView(icon: .mic, size: 18, weight: .regular)
        .foregroundStyle(palette.mutedText.color)
      VStack(alignment: .leading, spacing: 2) {
        Text(state.noSpeechNotice)
          .csFont(15, .medium)
          .foregroundStyle(palette.bodyText.color)
          .fixedSize(horizontal: false, vertical: true)
        Text("Nothing was captured this session.")
          .csMono(11, .medium)
          .foregroundStyle(palette.mutedText.color)
      }
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, minHeight: bodyMinHeight, alignment: .leading)
    .padding(.top, headerChromeInset)
    .padding(.bottom, OverlayDockLayout.height)
  }

  /// Terminal outcome for a recording/transcription failure. Unlike a toast, this
  /// persists after the session aborts so the overlay does not falsely report
  /// "no speech" when the engine actually failed.
  private var errorBody: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 12) {
        CSIconView(icon: .error, size: 18, weight: .regular)
          .foregroundStyle(CSColor.terracotta)
        VStack(alignment: .leading, spacing: 2) {
          Text(state.errorMessage ?? "Transcription failed")
            .csFont(15, .medium)
            .foregroundStyle(palette.bodyText.color)
            .fixedSize(horizontal: false, vertical: true)
          Text(state.errorLifecycleDetail)
            .csMono(11, .medium)
            .foregroundStyle(palette.mutedText.color)
        }
        Spacer(minLength: 0)
      }
    }
    .frame(maxWidth: .infinity, minHeight: bodyMinHeight, alignment: .leading)
    .padding(.top, headerChromeInset)
    .padding(.bottom, OverlayDockLayout.height)
  }

  /// Rust supplies every word and classification. The canvas only paints the
  /// status and intentionally exposes no repair button or Settings command.
  private func presentationStatusBody(_ status: OverlayPresentationStatus) -> some View {
    HStack(spacing: 12) {
      CSIconView(icon: status.isError ? .error : .success, size: 18, weight: .regular)
        .foregroundStyle(status.isError ? CSColor.terracotta : CSColor.oliveLight)
      VStack(alignment: .leading, spacing: 4) {
        Text(status.headline)
          .csFont(15, .medium)
          .foregroundStyle(CSColor.textBody)
          .fixedSize(horizontal: false, vertical: true)
        Text(status.message)
          .csMono(11, .medium)
          .foregroundStyle(CSColor.textFaint)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, minHeight: bodyMinHeight, alignment: .leading)
    .padding(.top, headerChromeInset)
    .padding(.bottom, OverlayDockLayout.height)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("overlay-presentation-status")
  }

  private var footerEngineDot: Color {
    let label = state.footerEngineLabel.lowercased()
    if label.contains("apple") { return CSColor.oliveLight }
    if label.contains("whisper") { return CSColor.olive }
    return CSColor.amber
  }
}

private struct OverlayHeaderChrome: ViewModifier {
  let palette: OverlayAppearancePalette

  @ViewBuilder
  func body(content: Content) -> some View {
    if #available(macOS 26.0, *) {
      content.glassEffect(
        .regular,
        in: RoundedRectangle(cornerRadius: CSRadius.input, style: .continuous)
      )
    } else {
      content.background(
        palette.surfaceTint.color,
        in: RoundedRectangle(cornerRadius: CSRadius.input, style: .continuous)
      )
    }
  }
}

private struct OverlayScrollEdgeEffects: ViewModifier {
  @ViewBuilder
  func body(content: Content) -> some View {
    if #available(macOS 26.0, *) {
      content.scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
    } else {
      content
    }
  }
}

#if DEBUG
  @ViewBuilder
  private func overlayPreviewCanvas<Content: View>(
    width: CGFloat? = nil,
    height: CGFloat? = nil,
    @ViewBuilder content: () -> Content
  ) -> some View {
    content()
      .frame(width: width, height: height)
      .padding(CSSpace.previewInset)
      .background(CSColor.windowWash)
  }

  @ViewBuilder
  private func dockPreviewRow(
    _ title: String,
    collapsedLight: OverlayState,
    expandedLight: OverlayState,
    collapsedDark: OverlayState,
    expandedDark: OverlayState
  ) -> some View {
    Text(title)
      .font(.headline)
    overlayPreviewCanvas(width: 320, height: 260) {
      DictationOverlayView(state: collapsedLight)
    }
    .preferredColorScheme(.light)
    overlayPreviewCanvas(width: 320, height: 260) {
      DictationOverlayView(state: expandedLight, dockInitiallyExpanded: true)
    }
    .preferredColorScheme(.light)
    overlayPreviewCanvas(width: 320, height: 260) {
      DictationOverlayView(state: collapsedDark)
    }
    .preferredColorScheme(.dark)
    overlayPreviewCanvas(width: 320, height: 260) {
      DictationOverlayView(state: expandedDark, dockInitiallyExpanded: true)
    }
    .preferredColorScheme(.dark)
  }

  #Preview("Dock matrix · 320 pt") {
    ScrollView {
      VStack(spacing: CSSpace.section) {
        dockPreviewRow(
          "Listening",
          collapsedLight: .previewListening(), expandedLight: .previewListening(),
          collapsedDark: .previewListening(), expandedDark: .previewListening()
        )
        dockPreviewRow(
          "Finalizing",
          collapsedLight: .previewTranscribing(), expandedLight: .previewTranscribing(),
          collapsedDark: .previewTranscribing(), expandedDark: .previewTranscribing()
        )
        dockPreviewRow(
          "Formatted",
          collapsedLight: .previewFormatted(), expandedLight: .previewFormatted(),
          collapsedDark: .previewFormatted(), expandedDark: .previewFormatted()
        )
        dockPreviewRow(
          "No speech",
          collapsedLight: .previewNoSpeech(), expandedLight: .previewNoSpeech(),
          collapsedDark: .previewNoSpeech(), expandedDark: .previewNoSpeech()
        )
        dockPreviewRow(
          "Error",
          collapsedLight: .previewError(), expandedLight: .previewError(),
          collapsedDark: .previewError(), expandedDark: .previewError()
        )
      }
      .padding()
    }
  }

  #Preview("Listening") {
    Group {
      overlayPreviewCanvas {
        DictationOverlayView(state: .previewListening())
      }
      .preferredColorScheme(.light)

      overlayPreviewCanvas {
        DictationOverlayView(state: .previewListening())
      }
      .preferredColorScheme(.dark)
    }
  }

  #Preview("Transcribing") {
    // Pinned to the window's min content size so this preview doubles as the
    // min-size regression check: "transcribing…" fills the main status slot and
    // the transcript reserves ~2–3 lines instead of collapsing at the floor.
    overlayPreviewCanvas(width: 320, height: 260) {
      DictationOverlayView(state: .previewTranscribing())
    }
  }

  #Preview("No speech") {
    // Session ended without usable text: dedicated notice body, no
    // Copy/Format/Send, only Close. Pinned to the min content size so it also
    // guards the floor layout for this outcome.
    overlayPreviewCanvas(width: 320, height: 260) {
      DictationOverlayView(state: .previewNoSpeech())
    }
  }

  #Preview("Formatted") {
    overlayPreviewCanvas {
      DictationOverlayView(state: .previewFormatted())
    }
  }

  #Preview("Formatted · compact chrome") {
    overlayPreviewCanvas(width: 340, height: 260) {
      DictationOverlayView(state: .previewFormatted())
    }
  }

  #Preview("Listening · scaled 1.4x") {
    // Exercises `\.csTextScale`: transcript + status render 40% larger while the
    // window chrome and paddings keep their intrinsic geometry (transcript scrolls
    // rather than forcing the panel taller).
    overlayPreviewCanvas(width: 470, height: 280) {
      DictationOverlayView(state: .previewListening())
        .environment(\.csTextScale, 1.4)
    }
  }
#endif
