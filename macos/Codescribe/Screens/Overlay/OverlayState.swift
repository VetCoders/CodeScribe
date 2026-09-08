import AppKit
import Observation
import SwiftUI

// View model for the dictation overlay, backed by the redesign hotkey/controller
// bridge (`CodescribeHotkeys` / `CsTranscriptionListener`).
//
// The view talks only to the thin `DictationEngine` protocol below, so #Preview
// renders standalone against seeded view models (`OverlayState.previewListening()`).
//
// TRANSCRIPT MODEL (one-throne bridge semantics):
//   on_transcript_projection → complete Rust-reduced document plus acoustic
//                              receipts; the sole Swift text-admission path.
//   raw preview/correction/final/patch events remain IPC diagnostics and never
//   cross the product-facing listener.
//   on_vad_active → speech start/stop → drives the WaveformView pulse.
//   on_audio_level → capture RMS per block → real waveform amplitude (U22;
//                   closes the old AMPLITUDE GAP — ambient eq is now only the
//                   fallback when no live level arrives).
//   on_no_speech → user-facing reason sideband; projection owns the phase.
//   on_error     → recovery detail sideband; projection owns the phase.

// MARK: - Engine seam (orchestrator injects the real adapter in App.swift)

/// Minimal slice of the controller-backed dictation surface the overlay needs.
/// Kept as a protocol so the view-model + preview compile without a live Rust core.
@MainActor
protocol DictationEngine: AnyObject {
  func setListener(_ listener: CsTranscriptionListener)
  func startRecording(language: CsLanguage?) async throws
  func stopRecording() async throws -> String
  func commitUserRevision(
    sessionId: String, sourceRevision: UInt64, renderedText: String
  ) async throws -> CsUserRevisionResult
  func commitFormatterRevision(
    sessionId: String, sourceRevision: UInt64
  ) async throws -> CsUserRevisionResult
  func isRecording() async -> Bool
  func initModel() async throws
  func isModelLoaded() -> Bool
  func currentOverlayPolicy() -> OverlayPolicySnapshot?
  func setAutoPasteEnabled(_ enabled: Bool)
  func setAutoFormatLevel(_ level: FormattingPolicyOption)
  func pasteText(text: String) async throws -> CsPasteResult
  func deferText(text: String) async throws -> CsPasteResult
  func copyTaggedTranscript(text: String) async throws
  func pasteTargetAppName() async -> String?
  func sendAssistiveTranscript(text: String) async throws -> Bool
  func lastSessionAudioPath() -> String?
  func transcribeFile(path: String) async throws -> CsTranscription
}

extension DictationEngine {
  func lastSessionAudioPath() -> String? { nil }
}

struct OverlayPolicySnapshot: Equatable {
  let autoPasteEnabled: Bool
  let autoFormatLevel: FormattingPolicyOption
}

/// Value-only rendering model for Rust-owned product status. It deliberately
/// contains no command, Settings route, or transcript field.
struct OverlayPresentationStatus: Equatable {
  let schema: String
  let emittedAt: String
  let sessionId: String?
  let kind: String
  let code: String
  let statusLabel: String
  let headline: String
  let message: String
  let isError: Bool
  let terminal: Bool
  let calibrationVersion: String?
}

/// Presentation phase supplied by the reducer-owned projection. Swift parses
/// the wire value but never derives a phase from text, callbacks, or seals.
enum OverlayMode: String, Equatable {
  case listening
  case finalizing
  case formatted
  case noSpeech = "no_speech"
  case error
}

/// A user command emitted by the overlay rail. The rail decides only which
/// projected commands to paint; this value crosses the view/state seam without
/// carrying a second copy of reducer or delivery policy.
enum OverlayIntent: String, Equatable, Hashable {
  case finish
  case commitRevision = "commit-revision"
  case discardRevision = "discard-revision"
  case copy
  case insertPaste = "insert-paste"
  case retranscribe
  case format
  case close
}

/// The sole cross-thread ingress into the overlay. UniFFI callbacks enqueue
/// values here; one main-actor consumer applies them in arrival order.
enum OverlayListenerEvent: Sendable {
  case transcriptProjection(CsTranscriptProjectionEvent)
  case presentationStatus(CsPresentationStatusEvent)
  case recordingPreparing
  case recordingStarted
  case recordingStopped
  case recordingFinalising
  case sessionFinalised
  case vadActive(Bool)
  case audioLevel(Float)
  case noSpeech(String)
  case error(String)
}

/// A value-only callback adapter. Its immutable continuation is Sendable, so
/// the class needs no unchecked promise about actor isolation.
final class DictationListener: CsTranscriptionListener {
  private let continuation: AsyncStream<OverlayListenerEvent>.Continuation

  init(continuation: AsyncStream<OverlayListenerEvent>.Continuation) {
    self.continuation = continuation
  }

  func onTranscriptProjection(event: CsTranscriptProjectionEvent) {
    continuation.yield(.transcriptProjection(event))
  }

  func onPresentationStatus(event: CsPresentationStatusEvent) {
    continuation.yield(.presentationStatus(event))
  }

  func onRecordingPreparing() {
    continuation.yield(.recordingPreparing)
  }
  func onRecordingStarted() {
    continuation.yield(.recordingStarted)
  }
  func onRecordingStopped() {
    continuation.yield(.recordingStopped)
  }
  func onRecordingFinalising() {
    continuation.yield(.recordingFinalising)
  }
  func onSessionFinalised(sessionId: String, layerSummary: CsLayerSummary) {
    continuation.yield(.sessionFinalised)
  }
  func onVadActive(active: Bool) {
    continuation.yield(.vadActive(active))
  }
  func onAudioLevel(rms: Float) {
    continuation.yield(.audioLevel(rms))
  }
  func onNoSpeech(reason: String) {
    // Route the reason into the dedicated no-speech OUTCOME (a persistent
    // body + Close), not a transient toast that fades and leaves an empty
    // editable FINAL behind. `applyNoSpeech` maps the reason to a user-facing
    // notice (genuine silence vs. quality-gate rejection).
    continuation.yield(.noSpeech(reason))
  }
  func onError(message: String) {
    continuation.yield(.error(message))
  }
}

@MainActor
@Observable
final class OverlayState {

  // MARK: Published state
  private(set) var transcriptMode = "dictation"
  private(set) var mode: OverlayMode = .listening
  var formattedText: String { latestTranscriptProjection?.renderedText ?? "" }
  /// View-local editor payload. It is never delivery or transcript truth; only
  /// `formattedText`, repainted from the Rust projection, feeds downstream
  /// actions. The canvas paints it while the formatted take is under review.
  var revisionDraft = ""
  /// True while the transcript canvas holds keyboard focus on the panel. The
  /// panel is key only inside this window; see `FloatingOverlayPanel`.
  private(set) var isEditingTranscript = false
  private(set) var revision: UInt64 = 0
  private(set) var revisionCommitPending = false
  private(set) var revisionCommitError: String?
  private(set) var formatterCommitPending = false
  private(set) var formatterError: String?
  private(set) var userRevisionProvenance: String?
  private(set) var canPaste = false
  private(set) var canInsert = false
  private(set) var canCopy = false
  private(set) var canRetranscribe = false
  private(set) var canFormat = false
  private(set) var terminal = false
  var vadActive: Bool = false  // drives the WaveformView pulse
  /// Live capture level for the waveform. NOT on purpose — the
  /// waveform's TimelineView reads it every frame; see `AudioLevelMeter`.
  let levelMeter = AudioLevelMeter()
  /// Distinguishes a measured microphone feed from the explicit ambient
  /// fallback used by legacy/disconnected engines before any RMS arrives.
  private(set) var hasMeasuredAudioLevel = false
  var audioReady: Bool = false  // recorder confirmed; STT/VAD may still be warming
  var warmingUp: Bool = false  // true after user intent, before audio/VAD proves life
  /// Stop is in flight. This is a controller/lifecycle guard only; visible phase
  /// and waveform presentation come from the projection's `phase` field.
  var transcribing: Bool = false
  var toast: String?  // transient error notice
  var errorMessage: String?
  private(set) var presentationStatus: OverlayPresentationStatus?
  private(set) var errorLifecycleDetail =
    "Recording stopped before a transcript was available."
  /// Prompt-free policy snapshot from C02's persisted settings owner. These
  /// values are replaced only by a fresh engine read, never by optimistic UI.
  private(set) var autoPasteEnabled = true
  private(set) var autoFormatLevel: FormattingPolicyOption = .correction
  /// Assistive sessions never expose delivery controls. The controller owns
  /// that authoritative session gate and updates this presentation fence.
  private(set) var autoPasteControlAvailable = true
  /// Serving-engine label latched once per session. Rendering never performs
  /// settings I/O or a UniFFI read.
  private(set) var engineChip = "local apple"
  /// Lifecycle evidence that the final pass is active. It never selects a
  /// presentation phase; the reducer projection owns that field.
  var isFinalPass: Bool = false
  /// Human-facing notice shown in the `.noSpeech` outcome body. Set when a
  /// session finalizes without usable text; refined by `on_no_speech`'s reason
  /// so VAD silence and quality-gate rejection read differently.
  var noSpeechNotice: String = OverlayState.defaultNoSpeechNotice
  private(set) var indicatorMode: CsIndicatorMode = .hold

  // MARK: Session capture clock (UI_DIVERGENCE_AUDIT pkt 5 — overlay timer)
  /// Monotonic uptime stamp of the moment capture began for the open session.
  /// The overlay's live `00:00` counter derives from this: the user's absolute
  /// reference for audio sync, transcription lag, and stream drift.
  private(set) var captureStartedAtUptime: TimeInterval?
  /// Freeze stamp — set when capture stops (Finish / native release / abort) so
  /// the counter halts at the session's true duration instead of ticking
  /// through the final pass.
  private(set) var captureEndedAtUptime: TimeInterval?

  // MARK: Panel placement (persisted; the window orchestrator repositions live)
  /// Anchored placement: one of six screen anchors, applied on every show().
  /// Picking an anchor exits free motion — the pick's intent is "go there".
  var placementAnchor: OverlayAnchor = OverlayPlacement.anchor {
    didSet {
      guard placementAnchor != oldValue else { return }
      OverlayPlacement.anchor = placementAnchor
      if freeMotion { freeMotion = false } else { onPlacementChanged?() }
    }
  }
  /// Free motion: the panel keeps (and restores) wherever the user dragged it.
  var freeMotion: Bool = OverlayPlacement.freeMotion {
    didSet {
      guard freeMotion != oldValue else { return }
      OverlayPlacement.freeMotion = freeMotion
      onPlacementChanged?()
    }
  }
  /// Wired by the orchestrator: re-derive the visible panel's origin now.
  var onPlacementChanged: (() -> Void)?

  /// A menu selection is an immediate positioning command, including when the
  /// user chooses the already-selected anchor to leave Free motion.
  func selectPlacementAnchor(_ anchor: OverlayAnchor) {
    if placementAnchor != anchor {
      placementAnchor = anchor
    } else if freeMotion {
      freeMotion = false
    } else {
      onPlacementChanged?()
    }
  }

  /// Free motion starts from the panel's current/restored origin; subsequent
  /// windowDidMove callbacks persist every user drag.
  func selectFreeMotion() {
    if freeMotion {
      onPlacementChanged?()
    } else {
      freeMotion = true
    }
  }

  // MARK: Injected collaborators (all optional so #Preview renders standalone)
  /// The recording core. Injected by the orchestrator. Do NOT instantiate here.
  var engine: DictationEngine?
  /// Handoff to the agent surface — wired by the orchestrator (routes the text
  /// into AgentChat, which streams it through `CodescribeAgent.streamReply`).
  var onSendToAgent: ((String) -> Void)?
  /// Dismiss the floating window — wired by the orchestrator.
  var onClose: (() -> Void)?
  var onRecordingPreparing: (() -> Void)?
  var onRecordingStarted: (() -> Void)?
  var onRecordingStopped: (() -> Void)?
  @ObservationIgnored var onPresentationStatus: (() -> Void)?
  /// Presentation-only invalidation seam. The window controller may use the
  /// already-admitted projection to grow its canvas; no transcript bytes leave
  /// this passive overlay boundary.
  @ObservationIgnored var onTranscriptPresentationChanged: (() -> Void)?
  /// Content-free success seam. No transcript crosses this callback.
  var onSuccessfulDictation: (() -> Void)?

  /// Strong refs for the one ordered Rust-callback ingress.
  @ObservationIgnored private let listener: CsTranscriptionListener
  @ObservationIgnored private let eventStream: AsyncStream<OverlayListenerEvent>
  @ObservationIgnored private var eventTask: Task<Void, Never>?

  static let defaultNoSpeechNotice = "No speech detected"

  private var recording = false
  /// Reason from `on_no_speech`, captured before the terminal stop.
  private var pendingNoSpeechMessage: String?
  /// The exact rendered text at the terminal projection.
  private var deliveredText: String = ""
  private var deliveredTextSessionId: String?
  private var qualityCapturedProvenance: String?
  private var pendingRevisionSessionId: String?
  private var pendingRevisionSource: UInt64?
  private var revisionFocusCommitTask: Task<Void, Never>?
  /// Last reducer-owned projection painted by Swift. The reducer owns ordering
  /// and finality; the overlay does not second-guess an event that reached it.
  private var finalized = false
  /// Latest immutable projection event only; Rust `TranscriptRevision` remains
  /// the document owner and Rust `AcousticSerial` remains evidence authority.
  private(set) var latestTranscriptProjection: CsTranscriptProjectionEvent?
  private var agentSessionArmed = false
  private var agentFinalTranscriptAppeared = false
  private var agentAutoSendCancelled = false
  private var agentDeliveryStarted = false
  private var toastTask: Task<Void, Never>?
  /// One-shot guard for the in-place Speech Recognition request+retry. macOS
  /// never re-prompts once the scope is determined, so a second attempt in
  /// the same app run could only loop on the terminal error.
  private var speechAuthRequestAttempted = false
  /// Belt-and-suspenders guard against an orphaned optimistic "starting" overlay.
  /// The Rust bridge now guarantees a terminal event for every preparing it shows
  /// (`compensate_orphaned_preparing`); this watchdog is the second layer: if no
  /// started/activity/stopped/finish arrives within `warmupWatchdogNanos`, the
  /// overlay dismisses itself instead of hanging on "starting" forever.
  private var warmupWatchdogTask: Task<Void, Never>?
  private static let warmupWatchdogNanos: UInt64 = 4_000_000_000

  // MARK: Activity-anchored auto-hide for terminal outcomes
  private var autoHideTask: Task<Void, Never>?
  private var autoHideDeadline: TimeInterval?
  private var isPointerHovering = false
  private let nowProvider: () -> TimeInterval
  /// Single source of truth for the Founder-dictated terminal lifetime.
  /// Five seconds is the comfortable end of the requested 3–5 second range.
  static let autoHideDelaySeconds: TimeInterval = 5

  init(nowProvider: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
    let channel = AsyncStream<OverlayListenerEvent>.makeStream()
    eventStream = channel.stream
    listener = DictationListener(continuation: channel.continuation)
    self.nowProvider = nowProvider
    eventTask = Task { @MainActor [weak self, eventStream] in
      for await event in eventStream {
        guard let self else { return }
        apply(event)
      }
    }
  }

  func attach() {
    engine?.setListener(listener)
  }

  private func apply(_ event: OverlayListenerEvent) {
    switch event {
    case .transcriptProjection(let projection): applyTranscriptProjection(projection)
    case .presentationStatus(let status): applyPresentationStatus(status)
    case .recordingPreparing: handleRecordingPreparing()
    case .recordingStarted: handleRecordingStarted()
    case .recordingStopped: finishControllerRecording()
    case .recordingFinalising: handleRecordingFinalising()
    case .sessionFinalised: applySessionFinalised()
    case .vadActive(let active): applyVad(active)
    case .audioLevel(let rms): applyAudioLevel(rms)
    case .noSpeech(let reason): applyNoSpeech(reason: reason)
    case .error(let message): handleError(message: message)
    }
  }

  // MARK: Derived display (one source of truth for the view)

  var statusText: String {
    if let presentationStatus { return presentationStatus.statusLabel }
    switch mode {
    case .listening: return "listening"
    case .finalizing: return "finalizing"
    case .formatted: return "formatted"
    case .noSpeech: return "no speech"
    case .error: return "error"
    }
  }

  /// Narrow-window projection of the same single phase truth. The full status
  /// keeps level honesty at normal widths; the live waveform carries that
  /// evidence at the 320 pt floor without forcing the pill into a vertical
  /// capsule.
  var compactStatusText: String {
    statusText
  }
  /// Only a reducer-projected listening phase may ripple.
  var statusRippling: Bool {
    mode == .listening
      && (audioReady || vadActive)
  }

  /// Footer left engine chip — last stop serving label when available, else
  /// configured preference. Never a hardcoded "local whisper" (STT_CONTRACT).
  var footerEngineLabel: String {
    engineChip
  }

  private static func displayEngineChip(_ engine: String) -> String {
    let e = engine.lowercased()
    if e.contains("apple") { return "local apple" }
    if e.contains("merged") && e.contains("whisper") { return "merged · whisper fill" }
    if e.contains("streaming") { return "streaming whisper" }
    if e.contains("whisper") { return "local whisper" }
    if e.contains("cloud") { return "cloud stt" }
    return engine
  }

  /// Timer is mandatory for any session that has started, including the
  /// frozen value after stop.
  var showsSessionTimer: Bool {
    captureStartedAtUptime != nil
  }

  /// Exact engine text shared by the canvas, sizing, copy, and delivery.
  var activeText: String {
    formattedText
  }

  /// The one transcript canvas is an editor only for a formatted, sealed take
  /// that is not mid-commit. Listening / finalizing stay read-only and the
  /// panel never takes the keyboard for them.
  var isTranscriptEditable: Bool {
    mode == .formatted && terminal && presentationStatus == nil
      && !revisionCommitPending && !formatterCommitPending
  }

  var isRevisionDraftDirty: Bool {
    mode == .formatted && terminal && revisionDraft != formattedText
  }

  /// Bytes painted on the canvas: the local draft while a formatted take is
  /// under review or awaiting its ledger projection, the Rust projection
  /// otherwise. Delivery never reads this; it reads `activeText`.
  var canvasText: String {
    isRevisionDraftDirty ? revisionDraft : formattedText
  }

  /// Post-take review owns the floating panel. The formatted / no-speech
  /// surface must not yield to an Assistive tray tick — that path calls
  /// `hide()` and arms Agent auto-send.
  var blocksAssistiveOverlayHide: Bool {
    presentationStatus != nil || mode == .formatted || mode == .noSpeech
  }

  var audioLevelAccessibilityValue: String {
    guard let gain = levelMeter.gain else { return "Waiting for measured level" }
    switch gain {
    case ..<0.12: return "Very quiet"
    case ..<0.35: return "Quiet"
    case ..<0.68: return "Good level"
    default: return "Strong level"
    }
  }

  // MARK: Recording lifecycle (engine-backed; no-op when engine is absent)

  /// Start mic dictation. Gated on `micPermissionGranted()`; requests access
  /// once when undetermined. Fires the async bridge work in a Task so the view
  /// can call it from a synchronous context (onAppear / hotkey).
  func start(language: CsLanguage? = nil) {
    guard engine != nil, !recording else { return }
    Task { @MainActor in await self.runStart(language: language) }
  }

  /// Whole seconds of capture for the open session; nil before any capture.
  /// Reads the frozen end stamp once capture stopped, so the final pass does
  /// not keep the clock ticking.
  func elapsedCaptureSeconds() -> Int? {
    guard let started = captureStartedAtUptime else { return nil }
    let end = captureEndedAtUptime ?? nowProvider()
    return max(0, Int(end - started))
  }

  /// `mm:ss` (or `h:mm:ss` past the hour) for the overlay's live counter.
  var sessionTimerText: String {
    let total = elapsedCaptureSeconds() ?? 0
    let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
    return h > 0
      ? String(format: "%d:%02d:%02d", h, m, s)
      : String(format: "%02d:%02d", m, s)
  }

  private func beginCaptureClock() {
    captureStartedAtUptime = nowProvider()
    captureEndedAtUptime = nil
  }

  private func freezeCaptureClock() {
    guard captureStartedAtUptime != nil, captureEndedAtUptime == nil else { return }
    captureEndedAtUptime = nowProvider()
  }

  /// Stop the mic and flip to the finalized transcript returned by the core.
  /// Ignored while already transcribing so a second Finish tap during the
  /// awaited `stopRecording()` cannot re-enter and hit "no active recording".
  func stop() {
    guard engine != nil, recording, !transcribing else { return }
    Task { @MainActor in await self.runStop() }
  }

  private func runStart(language: CsLanguage?) async {
    guard let engine else { return }
    guard micPermissionGranted() || requestMicPermission() else {
      presentTerminalError(
        message:
          "Microphone access is off for Codescribe. Enable it in System Settings › Privacy & Security › Microphone.",
        toast: "Microphone access denied"
      )
      return
    }
    engine.setListener(listener)
    warmingUp = true
    resetTranscript()
    errorMessage = nil
    beginCaptureClock()
    recording = true
    do {
      // Whisper is optional gap-fill when Apple is live. initModel soft-fails
      // in the bridge for that path; never treat a missing Whisper model as
      // a start refusal — recording must still run (degraded: no final gap fill).
      if !engine.isModelLoaded() {
        do {
          try await engine.initModel()
        } catch {
          // Candle-live still surfaces via startRecording / later final-pass.
          // Apple-live continues; bridge already degrades quietly when it can.
          NSLog("codescribe: optional Whisper warm skipped: \(error)")
        }
      }
      try await engine.startRecording(language: language)
    } catch {
      await handleStartFailure(error, language: language)
    }
  }

  /// A start failure caused by an undetermined Speech Recognition grant is
  /// recoverable in place: fire the TCC dialog from the main app process (so
  /// the grant lands on the app's identity, which the bridge child inherits)
  /// and retry the start once when authorized. Every other failure — and a
  /// declined dialog — funnels into the terminal error path, where
  /// `speechAuthNotice` rewrites raw `speech_auth_*` markers.
  private func handleStartFailure(_ error: Error, language: CsLanguage?) async {
    let described = "\(error)"
    if described.contains("speech_auth_not_determined"), !speechAuthRequestAttempted {
      speechAuthRequestAttempted = true
      abortRecordingSession()
      let state = await SpeechRecognitionPermission.request()
      if state == .granted {
        await runStart(language: language)
        return
      }
    }
    presentTerminalError(
      message: "Couldn't start recording: \(described)",
      toast: "Couldn't start recording"
    )
  }

  private func runStop() async {
    guard let engine else { return }
    // Prevent duplicate stops while Rust emits authoritative finalizing and
    // terminal projections. This flag never paints a phase.
    transcribing = true
    warmingUp = false
    freezeCaptureClock()
    levelMeter.reset()
    do {
      // Stop acknowledges lifecycle; transcript projections own the text.
      _ = try await engine.stopRecording()
      recording = false
      isFinalPass = false
    } catch {
      presentTerminalError(
        message: "Couldn't finalize transcript: \(error)",
        toast: "Couldn't finalize transcript"
      )
    }
  }

  // MARK: Action row

  /// Thin relay from the projection-driven rail into existing controller
  /// routes. No branch here changes phase, text, or availability optimistically;
  /// those fields move only when the next Rust projection arrives.
  func relayIntent(_ intent: OverlayIntent) {
    switch intent {
    case .finish:
      stop()
    case .commitRevision:
      commitRevisionDraft()
    case .discardRevision:
      discardRevisionDraft()
    case .copy:
      relayCopyIntent()
    case .insertPaste:
      relayInsertPasteIntent()
    case .retranscribe:
      relayRetranscribeIntent()
    case .format:
      relayFormatIntent()
    case .close:
      close()
    }
  }

  private func relayCopyIntent() {
    guard let engine else {
      presentActionFailure("Copy needs the recording engine", notice: "copy unavailable")
      return
    }
    let text = activeText
    Task { @MainActor in
      do {
        try await engine.copyTaggedTranscript(text: text)
        self.showFooterNotice("copied")
      } catch {
        self.presentActionFailure("Couldn't copy transcript: \(error)", notice: "copy failed")
      }
    }
  }

  private func relayInsertPasteIntent() {
    if engine == nil {
      presentActionFailure("Insert needs the recording engine", notice: "insert unavailable")
    }
    guard let engine else { return }
    captureQualityIfEdited(action: "paste")
    cancelAutoHide()
    showFooterNotice("inserting…", persists: true)
    let text = activeText
    let shouldDefer = insertCaretInCodescribeProbe()
    Task { @MainActor in
      defer { self.restartAutoHideCountdown() }
      do {
        let result: CsPasteResult
        if shouldDefer {
          result = try await engine.deferText(text: text)
        } else {
          result = try await engine.pasteText(text: text)
        }
        switch result.outcome {
        case .deferredInsertArmed:
          let shortcut = result.deferredInsertShortcut ?? "⌘⌥V"
          self.showFooterNotice(shortcut, persists: true)
        case .copiedToClipboard:
          self.showFooterNotice("copied")
        case .accessibilityPermissionNeeded:
          self.showFooterNotice("no ax")
        case .pasted:
          self.showFooterNotice("inserted")
        case .noop:
          self.showFooterNotice("no insert")
        }
      } catch {
        self.errorMessage = "Couldn't paste transcript: \(error)"
        self.showFooterNotice("no paste")
      }
    }
  }

  private func relayRetranscribeIntent() {
    guard let engine else {
      presentActionFailure(
        "Retranscription needs the recording engine", notice: "retranscribe unavailable")
      return
    }
    guard let path = engine.lastSessionAudioPath() else {
      presentActionFailure(
        "The previous recording is no longer available", notice: "no recording")
      return
    }
    let settings = CodescribeConfig().loadSettings()
    let asrMode = (settings.asrMode ?? "apple_only").lowercased()
    let prefix = asrMode == "cloud" ? "cloud:" : "hq:"
    let prefixedPath = "\(prefix)\(path)"

    cancelAutoHide()
    showFooterNotice("retranscribing…", persists: true)
    Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        let result = try await engine.transcribeFile(path: prefixedPath)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
          if let projection = self.latestTranscriptProjection {
            _ = try? await engine.commitUserRevision(
              sessionId: projection.sessionId,
              sourceRevision: projection.reducerRevision,
              renderedText: text
            )
          } else {
            self.revisionDraft = text
          }
          if self.mode == .noSpeech {
            self.mode = .formatted
          }
        }
        self.showFooterNotice("retranscribed")
        self.restartAutoHideCountdown()
      } catch {
        self.presentActionFailure(
          "Couldn't retranscribe recording: \(error)", notice: "retranscribe failed")
        self.restartAutoHideCountdown()
      }
    }
  }

  private func presentActionFailure(_ message: String, notice: String) {
    errorMessage = message
    showFooterNotice(notice)
  }

  func copyToPasteboard(_ pasteboard: NSPasteboard = .general) {
    // P0-D: capture user correction on FINAL for quality loop + lexicon learning.
    captureQualityIfEdited(action: "copy")
    pasteboard.clearContents()
    pasteboard.setString(activeText, forType: .string)
    restartAutoHideCountdown()
  }

  func sendToAgent() {
    // P0-D: capture user correction on FINAL for quality loop + lexicon learning.
    captureQualityIfEdited(action: "send")
    deliverAgentTranscript()
  }

  /// Caret-truth probe for the Insert self-paste guard. The overlay is a
  /// non-activating panel that can become key WITHOUT the app being
  /// frontmost (Spotlight-style), so a synthetic Cmd+V follows OUR key
  /// window whenever a Codescribe text view holds the caret — the frontmost
  /// app check on the Rust side cannot see that. Injectable so tests can
  /// simulate both worlds.
  var insertCaretInCodescribeProbe: () -> Bool = {
    guard let keyWindow = NSApp.keyWindow else { return false }
    return keyWindow.firstResponder is NSTextView
  }

  func pasteToPreviousApp() {
    relayInsertPasteIntent()
  }

  /// Whisper a short footer chip next to `local apple`. Never a floating pill
  /// over the action row. `persists` keeps the chip until the overlay hides
  /// (Paste Here chord); otherwise it fades after the usual toast window.
  func showFooterNotice(_ message: String, persists: Bool = false) {
    toast = message
    toastTask?.cancel()
    guard !persists else { return }
    toastTask = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: 2_600_000_000)
      guard !Task.isCancelled else { return }
      self?.toast = nil
    }
  }

  /// Persist through C02's single config seam, then immediately replace local
  /// state with a fresh disk-backed snapshot. A rejected write therefore snaps
  /// back to durable truth instead of leaving an optimistic switch behind.
  func setAutoPasteEnabled(_ enabled: Bool) {
    guard autoPasteControlAvailable, let engine else { return }
    engine.setAutoPasteEnabled(enabled)
    refreshOverlayPolicyTruth()
    restartAutoHideCountdown()
  }

  func setAutoPasteControlAvailable(_ available: Bool) {
    autoPasteControlAvailable = available
  }

  /// Same seam as auto-paste: write through the engine's config owner, then
  /// re-read durable truth. The picker never paints an optimistic level.
  func setAutoFormatLevel(_ level: FormattingPolicyOption) {
    guard let engine else { return }
    engine.setAutoFormatLevel(level)
    refreshOverlayPolicyTruth()
    restartAutoHideCountdown()
  }

  func close() {
    discardRevisionDraft()
    // P0-D: capture user correction on FINAL for quality loop + lexicon learning.
    captureQualityIfEdited(action: "close")
    cancelWarmupWatchdog()
    cancelAutoHide()
    toastTask?.cancel()
    if recording, let engine {
      recording = false
      Task { @MainActor in _ = try? await engine.stopRecording() }
    }
    vadActive = false
    audioReady = false
    warmingUp = false
    transcribing = false
    isFinalPass = false
    onClose?()
  }

  private func refreshOverlayPolicyTruth() {
    guard let truth = engine?.currentOverlayPolicy() else { return }
    autoPasteEnabled = truth.autoPasteEnabled
    autoFormatLevel = truth.autoFormatLevel
  }

  private var engineChipLatched = false

  private func refreshEngineChip(reset: Bool) {
    if reset { engineChipLatched = false }
    guard !engineChipLatched else { return }
    engineChipLatched = true
    if let serving = currentServingVerdict() {
      let engine = serving.engine.trimmingCharacters(in: .whitespacesAndNewlines)
      if !engine.isEmpty {
        engineChip = Self.displayEngineChip(engine)
        return
      }
    }
    let preference = CodescribeConfig().loadSettings().sttEngine?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    switch preference?.lowercased() {
    case "whisper", "candle": engineChip = "local whisper"
    case "auto": engineChip = "auto · apple-first"
    case let preference? where !preference.isEmpty: engineChip = preference
    default: engineChip = "local apple"
    }
  }

  /// Consume the canonical Rust indicator mode. Agent arm is a one-shot
  /// session latch; the accepted orange processing phase must not disarm it.
  func applyIndicatorMode(_ mode: CsIndicatorMode) {
    indicatorMode = mode
    if mode == .assistive {
      agentSessionArmed = true
      autoPasteControlAvailable = false
    }
  }

  /// AppKit reports window motion separately from SwiftUI content events.
  /// Position sticks only in Free motion; anchored mode snaps back on next show.
  func userDraggedOverlay() {
    restartAutoHideCountdown()
  }

  /// A live edge-drag resize is activity and therefore receives a fresh window.
  func userResizedOverlay() {
    restartAutoHideCountdown()
  }

  /// Hover pauses dismissal entirely; leaving starts a new full five seconds.
  func setPointerHovering(_ hovering: Bool) {
    guard hovering != isPointerHovering else { return }
    isPointerHovering = hovering
    guard isTerminalMode else { return }
    if hovering {
      cancelAutoHide()
    } else {
      restartAutoHideCountdown()
    }
  }

  // MARK: P0-D quality loop

  private func captureQualityIfEdited(action: String) {
    guard mode == .formatted else { return }
    // `commitOverlayQualityRecord` is a free FFI function, not a call on the
    // injected `engine` — so a mocked engine does NOT stop it, and the XCTest
    // suite was appending two synthetic corrections ("original delivered
    // transcript here with user fix") to the FOUNDER'S live
    // ~/.codescribe/quality/corrections.jsonl on every run. 276 of 501 rows
    // in the real store came from test runs, and they surfaced in Settings ›
    // Dictionary as if the user had made them (Founder screenshot
    // 2026-08-09 14:21, three seconds after a suite finished). The keychain
    // test-host gate landed earlier did not cover this path.
    guard !QualityCaptureHost.isRunningTests else { return }
    let delivered = deliveredText.trimmingCharacters(in: .whitespacesAndNewlines)
    let edited = formattedText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !edited.isEmpty else { return }
    let isEdited = delivered != edited
    // Unedited transcripts used to never reach the review queue — but "not
    // corrected on the overlay" means "no time right now", not "perfect"
    // (Founder, 2026-08-09). Capture them once per session, on close, so
    // Settings › Dictionary can serve as the deferred correction desk. The
    // identical delivered/edited pair teaches the lexicon nothing (word-pair
    // extraction over a zero delta yields zero rules), so this fills the
    // queue without poisoning learning.
    guard isEdited || action == "close" else { return }
    let recordedAction = isEdited ? action : "close-unreviewed"
    let editProvenance = userRevisionProvenance
    if isEdited {
      // A string difference is not sufficient evidence of a user edit. Only a
      // reducer-returned user-edit receipt may enter the learning loop.
      guard let editProvenance else { return }
      guard qualityCapturedProvenance != editProvenance else { return }
      qualityCapturedProvenance = editProvenance
    }
    // Bridge FFI (generated by uniffi) appends the quality JSONL and feeds safe
    // candidates to lexicon.custom.jsonl. That is blocking disk I/O, so it runs
    // off the main actor — Copy/Send/Close must never wait on the disk.
    // The projection exposes only rendered truth. Until its receipt carries a
    // distinct acoustic-text field, use admitted delivery bytes instead of an
    // unwritten Swift "raw" shadow.
    let rawForRecord = delivered
    // Automatic product formatting is unavailable until C15C wires the
    // occurrence-bound producer before seal; quality receipts state that truth.
    let formattingLevel = FormattingPolicyOption.off.rawValue
    // The admitted projection contract does not currently expose aggregate
    // Whisper confidence. Persist absence honestly instead of maintaining an
    // unwritten Swift confidence shadow.
    let avgLogprob: Float? = nil
    let speechPct: Float? = nil
    let confidenceFlags: [String] = []
    Task.detached(priority: .utility) { [weak self] in
      // Pass action through to meta (over-correct P2-03). try? because FFI throws on err but
      // quality write is best-effort; never block UI action.
      let result = try? commitOverlayQualityRecord(
        rawText: rawForRecord,
        deliveredText: delivered,
        editedText: edited,
        action: recordedAction,
        formattingLevel: formattingLevel,
        editProvenance: editProvenance,
        avgLogprob: avgLogprob,
        speechPct: speechPct,
        confidenceFlags: confidenceFlags
      )
      if let acknowledgement = result?.acknowledgement, !acknowledgement.isEmpty {
        await MainActor.run {
          self?.showToast(acknowledgement)
        }
      }
    }
  }

  // MARK: Edit as revision (Swift side; Rust ledger mints the revision)

  /// The canvas took keyboard focus. Review stays open while the user types.
  func beginTranscriptEdit() {
    guard isTranscriptEditable, !isEditingTranscript else { return }
    isEditingTranscript = true
    revisionCommitError = nil
    cancelAutoHide()
  }

  /// The canvas gave keyboard focus back. A dirty draft commits after a short
  /// grace so an explicit Discard / Close click can still cancel it.
  func endTranscriptEdit() {
    guard isEditingTranscript else { return }
    isEditingTranscript = false
    if isRevisionDraftDirty {
      scheduleRevisionCommitAfterFocusExit()
    } else if terminal {
      restartAutoHideCountdown()
    }
  }

  /// Canvas bytes changed under the user's caret.
  func updateRevisionDraft(_ text: String) {
    guard isTranscriptEditable else { return }
    revisionDraft = text
    noteRevisionDraftActivity()
  }

  /// User typing is local draft activity: keep the review panel alive without
  /// mutating projected text or any delivery source.
  func noteRevisionDraftActivity() {
    revisionCommitError = nil
    if isRevisionDraftDirty || isEditingTranscript {
      cancelAutoHide()
    } else if terminal {
      restartAutoHideCountdown()
    }
  }

  /// Commit on a genuine focus exit, but wait one click's worth so an explicit
  /// Discard or Close can cancel the scheduled commit before it crosses FFI.
  /// (T15 yielded once; a Discard click resigns the canvas on mouse-down and
  /// fires on mouse-up, and a bare yield ran the commit in between.)
  static let focusExitCommitGraceNanoseconds: UInt64 = 300_000_000

  func scheduleRevisionCommitAfterFocusExit() {
    revisionFocusCommitTask?.cancel()
    revisionFocusCommitTask = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: OverlayState.focusExitCommitGraceNanoseconds)
      guard !Task.isCancelled else { return }
      self?.commitRevisionDraft()
    }
  }

  func discardRevisionDraft() {
    revisionFocusCommitTask?.cancel()
    revisionFocusCommitTask = nil
    guard !revisionCommitPending, !formatterCommitPending else { return }
    revisionDraft = formattedText
    revisionCommitError = nil
    if terminal, !isEditingTranscript { restartAutoHideCountdown() }
  }

  /// Send an immutable compare-and-swap request to Rust. This method never
  /// changes `formattedText`; the draft remains pending until the matching
  /// reducer projection returns through `applyTranscriptProjection`.
  func commitRevisionDraft() {
    revisionFocusCommitTask?.cancel()
    revisionFocusCommitTask = nil
    guard mode == .formatted, terminal, isRevisionDraftDirty, !revisionCommitPending,
      !formatterCommitPending
    else {
      return
    }
    let proposed = revisionDraft
    guard !proposed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      revisionCommitError = "A transcript revision cannot be empty"
      return
    }
    guard let projection = latestTranscriptProjection, let engine else {
      revisionCommitError = "Transcript revision authority is unavailable"
      return
    }
    revisionCommitPending = true
    revisionCommitError = nil
    pendingRevisionSessionId = projection.sessionId
    pendingRevisionSource = projection.reducerRevision
    cancelAutoHide()
    Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        let receipt = try await engine.commitUserRevision(
          sessionId: projection.sessionId,
          sourceRevision: projection.reducerRevision,
          renderedText: proposed
        )
        guard receipt.sessionId == projection.sessionId,
          receipt.sourceRevision == projection.reducerRevision,
          receipt.revision > receipt.sourceRevision,
          receipt.renderedText == proposed,
          receipt.provenanceReceipt.hasPrefix("user-edit-")
        else {
          revisionCommitPending = false
          pendingRevisionSessionId = nil
          pendingRevisionSource = nil
          revisionCommitError = "Transcript revision receipt was inconsistent"
          return
        }
        // The callback can arrive before this acknowledgement. Either way,
        // projection — never this receipt — owns the visible state transition.
      } catch {
        revisionCommitPending = false
        pendingRevisionSessionId = nil
        pendingRevisionSource = nil
        revisionCommitError = "Couldn't commit transcript revision: \(error)"
      }
    }
  }

  func prepareForExternalStart() {
    handleRecordingPreparing()
  }

  func handleRecordingPreparing() {
    agentSessionArmed = indicatorMode == .assistive
    autoPasteControlAvailable = !agentSessionArmed
    finalized = false
    isFinalPass = false
    warmingUp = true
    audioReady = false
    hasMeasuredAudioLevel = false
    levelMeter.reset()
    if !recording {
      resetTranscript()
      errorMessage = nil
      beginCaptureClock()
    }
    recording = true
    refreshOverlayPolicyTruth()
    refreshEngineChip(reset: true)
    onRecordingPreparing?()
    armWarmupWatchdog()
  }

  func handleRecordingStarted() {
    cancelWarmupWatchdog()
    finalized = false
    isFinalPass = false
    warmingUp = false
    audioReady = true
    if !recording {
      hasMeasuredAudioLevel = false
      levelMeter.reset()
      resetTranscript()
      errorMessage = nil
      beginCaptureClock()
    }
    if captureStartedAtUptime == nil {
      beginCaptureClock()
    }
    recording = true
    refreshOverlayPolicyTruth()
    refreshEngineChip(reset: false)
    onRecordingStarted?()
  }

  func finishControllerRecording() {
    let shouldNotifyStopped =
      !finalized && (recording || warmingUp || transcribing || audioReady || vadActive)
    cancelWarmupWatchdog()
    recording = false
    warmingUp = false
    transcribing = false
    audioReady = false
    vadActive = false
    isFinalPass = false
    freezeCaptureClock()
    levelMeter.reset()
    hasMeasuredAudioLevel = false

    if shouldNotifyStopped {
      finalized = true
      onRecordingStopped?()
    }
  }

  /// Native hold-release / toggle-stop lifecycle evidence. It freezes capture
  /// resources and guards duplicate transitions, but never selects a visible
  /// phase; only a projection can do that.
  func handleRecordingFinalising() {
    guard recording, !finalized, !transcribing else { return }
    cancelWarmupWatchdog()
    warmingUp = false
    transcribing = true
    freezeCaptureClock()
    levelMeter.reset()
    hasMeasuredAudioLevel = false
  }

  // MARK: Warmup watchdog (orphaned "starting" overlay recovery)

  /// Arm (or re-arm) the warmup watchdog. Called every time an optimistic
  /// "preparing" overlay is shown; a re-arm cancels any prior pending fire so
  /// rapid repeated preparing events collapse to a single 4s window.
  private func armWarmupWatchdog() {
    warmupWatchdogTask?.cancel()
    warmupWatchdogTask = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: OverlayState.warmupWatchdogNanos)
      guard !Task.isCancelled else { return }
      self?.fireWarmupWatchdog()
    }
  }

  /// Cancel the pending watchdog. Called from every path that proves the session
  /// progressed (started / streaming activity / vad) or terminated (stop /
  /// finalize / close), so a genuine session never trips the fallback dismiss.
  private func cancelWarmupWatchdog() {
    warmupWatchdogTask?.cancel()
    warmupWatchdogTask = nil
  }

  /// Fallback dismiss for a stuck optimistic overlay. Only fires if we are STILL
  /// in the "starting" state (`warmingUp`, not finalized) — if any real event
  /// already progressed us, `warmingUp` is false and this is a no-op.
  private func fireWarmupWatchdog() {
    warmupWatchdogTask = nil
    guard warmingUp, !finalized else { return }
    abortRecordingSession(resetTranscript: true)
    onClose?()
  }

  private var isTerminalMode: Bool {
    terminal
  }

  private func restartAutoHideCountdown() {
    // A take under review (caret in the canvas, or an uncommitted draft) is
    // never auto-hidden out from under the user.
    guard isTerminalMode, !isPointerHovering, !isEditingTranscript, !isRevisionDraftDirty
    else {
      cancelAutoHide()
      return
    }
    cancelAutoHide()
    autoHideDeadline = nowProvider() + OverlayState.autoHideDelaySeconds
    scheduleAutoHideWake(after: OverlayState.autoHideDelaySeconds)
  }

  private func scheduleAutoHideWake(after delay: TimeInterval) {
    let nanoseconds = UInt64(max(0, delay) * 1_000_000_000)
    autoHideTask = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: nanoseconds)
      guard !Task.isCancelled else { return }
      self?.evaluateAutoHideDeadline(rescheduleIfEarly: true)
    }
  }

  private func evaluateAutoHideDeadline(rescheduleIfEarly: Bool) {
    autoHideTask = nil
    guard isTerminalMode, !isPointerHovering, let deadline = autoHideDeadline else { return }
    let remaining = deadline - nowProvider()
    if remaining > 0 {
      if rescheduleIfEarly { scheduleAutoHideWake(after: remaining) }
      return
    }
    autoHideDeadline = nil
    if agentSessionArmed, agentFinalTranscriptAppeared {
      if !agentAutoSendCancelled {
        deliverAgentTranscript()
      }
      return
    }
    onClose?()
  }

  /// Deterministic XCTest seam: tests inject a monotonic clock, advance it,
  /// and evaluate the same deadline logic without wall-clock sleeps.
  func fireAutoHideNowForTests() {
    autoHideTask?.cancel()
    autoHideTask = nil
    evaluateAutoHideDeadline(rescheduleIfEarly: false)
  }

  private func cancelAutoHide() {
    autoHideTask?.cancel()
    autoHideTask = nil
    autoHideDeadline = nil
  }

  private func deliverAgentTranscript() {
    let text = activeText.trimmingCharacters(in: .whitespacesAndNewlines)
    // No `agentSessionArmed` here: the explicit Send button is live for
    // every terminal overlay (dictation and formatting included), and the
    // controller falls back to the session trigger context when no
    // assistive context was armed (review P0-03). Auto-send remains gated
    // on the armed latch by its caller.
    guard !agentDeliveryStarted, !text.isEmpty, let engine else { return }
    agentDeliveryStarted = true
    cancelAutoHide()
    Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        if try await engine.sendAssistiveTranscript(text: text) {
          onSendToAgent?(text)
          onClose?()
        } else {
          agentDeliveryStarted = false
          showToast("Agent delivery is no longer available")
        }
      } catch {
        agentDeliveryStarted = false
        showToast("Couldn't send to Agent")
      }
    }
  }

  private func abortRecordingSession(resetTranscript shouldResetTranscript: Bool = false) {
    let shouldNotifyStopped =
      !finalized && (recording || warmingUp || transcribing || audioReady || vadActive)
    cancelWarmupWatchdog()
    cancelAutoHide()
    recording = false
    warmingUp = false
    transcribing = false
    audioReady = false
    vadActive = false
    isFinalPass = false
    freezeCaptureClock()
    levelMeter.reset()
    hasMeasuredAudioLevel = false
    if shouldResetTranscript {
      resetTranscript()
    }
    if shouldNotifyStopped {
      finalized = true
      onRecordingStopped?()
    }
  }

  func handleError(message: String) {
    // Since the bridge-side warning split (`warning_is_user_terminal`), quality
    // receipts (`tail_patch_under_commit`, `layer1_lane_degraded`,
    // `apple_final_window_overlap_normalized`, ...) never reach `on_error` —
    // they are log-only in both bridges. What lands here is a user-terminal
    // failure (`transcription_failed`, start failures): the session is over.
    //
    // The content rule survives from the 2026-08-12 incident (a mislabelled
    // warning ran `presentTerminalError` and discarded 282 already-committed
    // characters): whatever the failure, a non-empty draft is sacred. But
    // "sacred" no longer means pretending the take is alive behind an
    // "Engine warning" toast while the engine is gone — that left the overlay
    // in a zombie live-capture UI with no stop parity. A failure with a draft
    // now ENDS the session exactly like a stop: engine released best-effort
    // (the same orphan-mic guard as `ComposerDictation.handleEngineError`),
    // transcript kept on screen with the normal Copy/Format/Send surface.
    //
    // Only an already admitted Rust projection can be preserved. Listener
    // preview/final callbacks are intentionally not a fallback authority.
    if let projection = latestTranscriptProjection,
      !projection.renderedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      if let engine {
        Task { @MainActor in _ = try? await engine.stopRecording() }
      }
      abortRecordingSession()
      showToast("Dictation failed — transcript kept")
      return
    }
    presentTerminalError(message: message, toast: message)
  }

  /// User-facing rewrite for Speech Recognition TCC failures. The engine
  /// reports raw bridge markers (`speech_auth_not_determined` / `_denied` /
  /// `_restricted`); surfacing those verbatim reads as a crash, when the fix
  /// is one System Settings toggle. Returns nil for every other error.
  static func speechAuthNotice(from message: String) -> String? {
    guard message.contains("speech_auth_") else { return nil }
    if message.contains("speech_auth_not_determined") {
      return "Apple dictation needs Speech Recognition access — "
        + "grant it in Settings › Dictation or System Settings › "
        + "Privacy & Security › Speech Recognition"
    }
    if message.contains("speech_auth_denied") || message.contains("speech_auth_restricted") {
      return "Speech Recognition is off for Codescribe — enable it in "
        + "System Settings › Privacy & Security › Speech Recognition"
    }
    return "Speech Recognition access is unavailable — check System "
      + "Settings › Privacy & Security › Speech Recognition"
  }

  private func presentTerminalError(message: String, toast: String) {
    let speechNotice = OverlayState.speechAuthNotice(from: message)
    let captureHadStarted = recording
    let message = speechNotice ?? message
    let toast = speechNotice ?? toast
    abortRecordingSession()
    pendingNoSpeechMessage = nil
    noSpeechNotice = OverlayState.defaultNoSpeechNotice
    isFinalPass = false
    errorMessage = message
    errorLifecycleDetail =
      captureHadStarted
      ? "Recording stopped before a transcript was available."
      : "Recording did not start."
    finalized = true
    showToast(toast)
  }

  // MARK: Listener-driven mutations (called on the main actor by DictationListener)

  /// Paint one Rust-owned status card. This sibling projection may close a
  /// failed/preparing capture lifecycle, but it never creates transcript text,
  /// receipts, or product actions in Swift.
  func applyPresentationStatus(_ event: CsPresentationStatusEvent) {
    abortRecordingSession(resetTranscript: true)
    let status = OverlayPresentationStatus(
      schema: event.schema,
      emittedAt: event.emittedAt,
      sessionId: event.sessionId,
      kind: event.kind,
      code: event.code,
      statusLabel: event.statusLabel,
      headline: event.headline,
      message: event.message,
      isError: event.isError,
      terminal: event.terminal,
      calibrationVersion: event.calibrationVersion
    )
    presentationStatus = status
    // Status is a sibling message, not a replacement transcript document.
    // Only a subsequent transcript projection may change the displayed bytes.
    canPaste = false
    canInsert = false
    canCopy = false
    canRetranscribe = false
    canFormat = false
    mode = event.isError ? .error : .formatted
    terminal = event.terminal
    finalized = event.terminal
    errorMessage = event.isError ? event.message : nil
    onPresentationStatus?()
    showToast(event.headline)
    if event.terminal { restartAutoHideCountdown() }
  }

  /// Paint the engine document directly. An unfamiliar chrome phase must not
  /// prevent text delivery; retain the current chrome until a known phase arrives.
  func applyTranscriptProjection(_ projection: CsTranscriptProjectionEvent) {
    defer { onTranscriptPresentationChanged?() }
    let priorProjection = latestTranscriptProjection
    let isNewSession = priorProjection?.sessionId != projection.sessionId
    let draftWasDirty = isRevisionDraftDirty
    let revisionReceipt = projection.acousticReceipts
      .compactMap(\.manualEditReceipt)
      .first(where: { $0.hasPrefix("user-edit-") })
    let formatterReceipt = projection.acousticReceipts
      .compactMap(\.manualEditReceipt)
      .first(where: { $0.hasPrefix("formatter-") })
    let completesPendingRevision =
      revisionCommitPending
      && projection.reducerAction == "apply_manual_edit"
      && projection.terminal
      && projection.sessionId == pendingRevisionSessionId
      && projection.reducerRevision > (pendingRevisionSource ?? UInt64.max)
      && revisionReceipt != nil
    let completesPendingFormatter =
      formatterCommitPending
      && projection.reducerAction == "apply_manual_edit"
      && projection.terminal
      && projection.sessionId == pendingRevisionSessionId
      && projection.reducerRevision > (pendingRevisionSource ?? UInt64.max)
      && formatterReceipt != nil
    let signalsFirstSuccessfulTerminal =
      !terminal && projection.terminal && projection.phase == OverlayMode.formatted.rawValue
    if projection.terminal {
      // Release capture before flipping `finalized`; abort uses the previous
      // value to decide whether the app-level stopped callback is still owed.
      abortRecordingSession()
    }
    latestTranscriptProjection = projection
    if !projection.terminal {
      markTranscriptActivity()
    }
    transcriptMode = projection.mode
    mode = OverlayMode(rawValue: projection.phase) ?? mode
    revision = projection.reducerRevision
    canPaste = projection.canPaste
    canInsert = projection.canInsert
    canCopy = projection.canCopy
    canRetranscribe = projection.canRetranscribe
    canFormat = projection.canFormat
    terminal = projection.terminal
    finalized = projection.terminal

    if isNewSession {
      deliveredText = ""
      deliveredTextSessionId = nil
      qualityCapturedProvenance = nil
      userRevisionProvenance = nil
      revisionCommitPending = false
      formatterCommitPending = false
      pendingRevisionSessionId = nil
      pendingRevisionSource = nil
      revisionCommitError = nil
      formatterError = nil
      revisionFocusCommitTask?.cancel()
      revisionFocusCommitTask = nil
    }

    userRevisionProvenance = revisionReceipt
    if completesPendingRevision {
      revisionCommitPending = false
      pendingRevisionSessionId = nil
      pendingRevisionSource = nil
      revisionCommitError = nil
      revisionDraft = projection.renderedText
    } else if completesPendingFormatter {
      formatterCommitPending = false
      pendingRevisionSessionId = nil
      pendingRevisionSource = nil
      formatterError = nil
      revisionDraft = projection.renderedText
      showFooterNotice("formatted")
    } else if !draftWasDirty || isNewSession {
      revisionDraft = projection.renderedText
    }

    if projection.terminal {
      if deliveredTextSessionId != projection.sessionId {
        deliveredText = projection.renderedText
        deliveredTextSessionId = projection.sessionId
      }
      agentFinalTranscriptAppeared = projection.phase == OverlayMode.formatted.rawValue
      if signalsFirstSuccessfulTerminal {
        onSuccessfulDictation?()
      }
      if projection.phase == OverlayMode.noSpeech.rawValue {
        noSpeechNotice = pendingNoSpeechMessage ?? OverlayState.defaultNoSpeechNotice
      }
      restartAutoHideCountdown()
      if revisionReceipt != nil {
        captureQualityIfEdited(action: "revision")
      }
    }
  }

  private func relayFormatIntent() {
    guard mode == .formatted, terminal, canFormat, !isRevisionDraftDirty,
      !revisionCommitPending, !formatterCommitPending
    else { return }
    guard let projection = latestTranscriptProjection, let engine else {
      formatterError = "Transcript formatter authority is unavailable"
      showFooterNotice("format unavailable")
      return
    }
    formatterCommitPending = true
    formatterError = nil
    pendingRevisionSessionId = projection.sessionId
    pendingRevisionSource = projection.reducerRevision
    cancelAutoHide()
    showFooterNotice("formatting…", persists: true)
    Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        let receipt = try await engine.commitFormatterRevision(
          sessionId: projection.sessionId,
          sourceRevision: projection.reducerRevision
        )
        guard receipt.sessionId == projection.sessionId,
          receipt.sourceRevision == projection.reducerRevision,
          receipt.revision > receipt.sourceRevision,
          !receipt.renderedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          receipt.provenanceReceipt.hasPrefix("formatter-")
        else {
          formatterCommitPending = false
          pendingRevisionSessionId = nil
          pendingRevisionSource = nil
          formatterError = "Formatter revision receipt was inconsistent"
          showFooterNotice("format failed")
          restartAutoHideCountdown()
          return
        }
        // Projection can arrive before acknowledgement. It is still the only
        // path that may repaint `formattedText` or the local editor draft.
      } catch {
        formatterCommitPending = false
        pendingRevisionSessionId = nil
        pendingRevisionSource = nil
        formatterError = "Couldn't format transcript: \(error)"
        showFooterNotice("format failed")
        restartAutoHideCountdown()
      }
    }
  }

  func applySessionFinalised() {
    guard !finalized else { return }
    markTranscriptActivity()
    // Lifecycle-only evidence that formatting is running. Presentation remains
    // whatever the latest reducer projection says.
    isFinalPass = true
    transcribing = false
  }

  /// `on_no_speech` — the engine adjudicated the session with no usable speech.
  /// Fires BEFORE the terminal `on_recording_stopped`, so we only record the
  /// user-facing reason here. If it arrives after an empty terminal outcome,
  /// upgrade the notice in place.
  func applyNoSpeech(reason: String) {
    let message: String
    switch reason {
    case "all_speech_rejected_by_quality_gate":
      message = "Speech too quiet or short — adjust the mic and try again"
    default:
      message = OverlayState.defaultNoSpeechNotice
    }
    pendingNoSpeechMessage = message
    noSpeechNotice = message
  }

  private func resetTranscript() {
    deliveredText = ""
    pendingNoSpeechMessage = nil
    noSpeechNotice = OverlayState.defaultNoSpeechNotice
    presentationStatus = nil
    errorLifecycleDetail = "Recording stopped before a transcript was available."
    finalized = false
    agentFinalTranscriptAppeared = false
    agentAutoSendCancelled = false
    agentDeliveryStarted = false
    transcribing = false
    isFinalPass = false
    // A hidden panel may not emit a pointer-exit event. Never carry a paused
    // hover latch into the next recording session.
    isPointerHovering = false
    cancelAutoHide()
  }

  private func markTranscriptActivity() {
    cancelWarmupWatchdog()
    warmingUp = false
    audioReady = true
  }

  /// `on_audio_level` — capture RMS per audio block. Only feeds the meter
  /// during live capture: once the session is transcribing/finalised the
  /// waveform is frozen or gone, and a late block must not wiggle it.
  func applyAudioLevel(_ rms: Float) {
    guard recording,
      warmingUp || audioReady || vadActive,
      !finalized,
      !transcribing,
      !isFinalPass,
      mode == .listening
    else { return }
    levelMeter.push(rms: rms)
    if levelMeter.gain != nil { hasMeasuredAudioLevel = true }
  }

  func applyVad(_ active: Bool) {
    // Drop late VAD toggles after finalize: the waveform is gone in Idle and a
    // stray `vadActive` flip is just another needless invalidation.
    guard !finalized else { return }
    vadActive = active
    if active {
      cancelWarmupWatchdog()
      warmingUp = false
      audioReady = true
    }
  }

  func showToast(_ message: String) {
    toast = message
    toastTask?.cancel()
    toastTask = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: 2_600_000_000)
      guard !Task.isCancelled else { return }
      self?.toast = nil
    }
  }

  // MARK: Preview / mock helpers (no engine required)

  /// Seeded view model for #Preview in the listening state.
  static func previewListening() -> OverlayState {
    let s = OverlayState()
    s.applyTranscriptProjection(
      previewProjection(
        "add a rate limiter to the login route and write a test for it",
        phase: .listening,
        terminal: false
      )
    )
    s.vadActive = true
    return s
  }

  /// Seeded view model for #Preview in the post-capture transcribing phase.
  static func previewTranscribing() -> OverlayState {
    let s = OverlayState()
    s.applyTranscriptProjection(
      previewProjection(
        "add a rate limiter to the login route and write a test for it",
        phase: .finalizing,
        terminal: false
      )
    )
    s.audioReady = true
    return s
  }

  /// Seeded view model for #Preview in the no-speech outcome (session ended
  /// without any usable text).
  static func previewNoSpeech() -> OverlayState {
    let s = OverlayState()
    s.applyTranscriptProjection(previewProjection("", phase: .noSpeech, terminal: true))
    s.noSpeechNotice = OverlayState.defaultNoSpeechNotice
    return s
  }

  /// Seeded view model for #Preview in the finalized state.
  static func previewFormatted() -> OverlayState {
    let s = OverlayState()
    s.applyTranscriptProjection(
      previewProjection(
        "Add a rate limiter to the login route and write a test that covers the throttle window. Keep the existing error shape.",
        phase: .formatted,
        terminal: true
      )
    )
    return s
  }

  /// Seeded view model for the terminal error phase.
  static func previewError() -> OverlayState {
    let s = OverlayState()
    s.applyTranscriptProjection(
      previewProjection("", phase: .error, terminal: true)
    )
    s.errorMessage = "The transcription engine could not finish this take."
    return s
  }

  private static func previewProjection(
    _ renderedText: String,
    phase: OverlayMode,
    terminal: Bool
  ) -> CsTranscriptProjectionEvent {
    let isFormatted = phase == .formatted
    return CsTranscriptProjectionEvent(
      schema: "preview", sequence: 1, emittedAt: "preview", sessionId: "preview", mode: "dictation",
      reducerRevision: 1, reducerAction: "preview_fixture",
      occurrenceSessionId: "preview",
      captureEpoch: 0, sampleStart: 0, sampleEnd: 0, documentIndex: 0, label: renderedText,
      renderedText: renderedText, phase: phase.rawValue, canPaste: isFormatted, canInsert: isFormatted,
      canCopy: !renderedText.isEmpty, canRetranscribe: phase == .noSpeech || isFormatted,
      canFormat: isFormatted,
      terminal: terminal, acousticReceipts: [])
  }
}

/// Adapter for the redesign hotkey/controller path. This is the product path:
/// one `RecordingController`, one event stream, one Swift overlay surface.
@MainActor
final class ControllerDictationEngine: DictationEngine {
  private let hotkeys = CodescribeHotkeys()
  private let config = CodescribeConfig()

  func setListener(_ listener: CsTranscriptionListener) {
    hotkeys.setListener(listener: listener)
  }
  func startRecording(language: CsLanguage?) async throws {
    try await hotkeys.startRecording()
  }
  func stopRecording() async throws -> String {
    try await hotkeys.stopRecording()
    return ""
  }
  func commitUserRevision(
    sessionId: String, sourceRevision: UInt64, renderedText: String
  ) async throws -> CsUserRevisionResult {
    try await hotkeys.commitUserRevision(
      sessionId: sessionId,
      sourceRevision: sourceRevision,
      renderedText: renderedText
    )
  }
  func commitFormatterRevision(
    sessionId: String, sourceRevision: UInt64
  ) async throws -> CsUserRevisionResult {
    try await hotkeys.commitFormatterRevision(
      sessionId: sessionId,
      sourceRevision: sourceRevision
    )
  }
  func isRecording() async -> Bool {
    await hotkeys.isRecording()
  }
  func initModel() async throws {}
  func isModelLoaded() -> Bool { true }
  func currentOverlayPolicy() -> OverlayPolicySnapshot? {
    let toggles = config.trayToggles()
    guard let formatLevel = FormattingPolicyOption(rawValue: toggles.formattingLevel) else {
      return nil
    }
    return OverlayPolicySnapshot(
      autoPasteEnabled: toggles.autoPasteEnabled,
      autoFormatLevel: formatLevel
    )
  }
  func setAutoPasteEnabled(_ enabled: Bool) {
    _ = try? config.setAutoPasteEnabled(enabled: enabled)
  }
  func setAutoFormatLevel(_ level: FormattingPolicyOption) {
    _ = try? config.setAutoFormatLevel(level: level.rawValue)
  }
  func pasteText(text: String) async throws -> CsPasteResult {
    try await hotkeys.pasteText(text: text)
  }
  func deferText(text: String) async throws -> CsPasteResult {
    try await hotkeys.deferText(text: text)
  }
  func copyTaggedTranscript(text: String) async throws {
    try await hotkeys.copyTextTagged(text: text)
  }
  func pasteTargetAppName() async -> String? {
    await hotkeys.pasteTargetAppName()
  }
  func sendAssistiveTranscript(text: String) async throws -> Bool {
    try await hotkeys.sendAssistiveTranscript(text: text)
  }
  func lastSessionAudioPath() -> String? {
    hotkeys.lastSessionAudioPath()
  }
  func transcribeFile(path: String) async throws -> CsTranscription {
    try await hotkeys.transcribeFile(path: path)
  }
}
