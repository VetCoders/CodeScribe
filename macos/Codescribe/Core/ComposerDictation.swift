import Foundation
import OSLog

/// Diagnostic breadcrumbs for Agent voice capture. Audio, STT, corrections,
/// transcript publication, and delivery are all owned by RecordingController.
private let dictationLog = Logger(
  subsystem: Bundle.main.bundleIdentifier ?? "com.vetcoders.codescribe",
  category: "composer-dictation"
)

/// The exact slice of the shared controller the composer gesture speaks to.
///
/// A protocol rather than the concrete bridge type so the gesture policy —
/// which press starts, which stops, and which must refuse — is testable against
/// the production adapter instead of a re-implemented copy of its rules.
///
/// Shape mirrors the generated `CodescribeHotkeysProtocol` (`AnyObject`,
/// `Sendable`, non-isolated) so the bridge object conforms without an adapter
/// and without pulling the FFI surface onto the main actor.
protocol ComposerCaptureControlling: AnyObject, Sendable {
  /// Is the one shared controller capturing right now (any surface)?
  func isRecording() async -> Bool
  /// Start one explicit composer take: one gesture, one turn.
  func startComposerTurnRecording() async throws
  /// Stop the take currently owned by the shared controller.
  func stopRecording() async throws
}

/// Thin UI gesture adapter over the shared controller. The composer never owns
/// a recorder or transcript reducer; it requests one explicit Agent take.
@MainActor
final class RealComposerDictation: ComposerDictating {
  private let hotkeys: ComposerCaptureControlling
  private weak var store: AgentChatStore?
  private var transitioning = false

  init(store: AgentChatStore, hotkeys: ComposerCaptureControlling = CodescribeHotkeys()) {
    self.store = store
    self.hotkeys = hotkeys
  }

  func toggle() {
    guard let store, !transitioning else { return }
    transitioning = true
    // Optimistic beat at click latency; both start and stop are non-actionable
    // while in flight, so this also swallows the double-tap.
    store.setDictationPhase(.preparing)
    Task { @MainActor in
      defer { transitioning = false }
      // Direction comes from the controller, not from the cached `dictationBlocked`
      // flag. A flag left stale by a lifecycle event that never arrived used to
      // route every press into a stop that no-ops against an idle controller —
      // a mic that looks busy forever with no way back short of a relaunch.
      let live = await hotkeys.isRecording()
      // ...but "the controller is busy" is not "this composer owns the take".
      // A live hotkey, tray or overlay dictation belongs to whoever started it;
      // the composer press must report it as busy, never end it.
      let owned = store.ownsLiveDictation
      store.dictationBlocked = live && !owned
      if live && !owned {
        dictationLog.info("Agent voice capture press ignored — another surface owns the take")
        store.releaseUnownedDictationGesture()
        return
      }
      do {
        if live {
          try await hotkeys.stopRecording()
          dictationLog.info("Agent voice capture stop requested on shared controller")
        } else {
          try await hotkeys.startComposerTurnRecording()
          dictationLog.info("Agent composer take start requested on shared controller")
        }
      } catch {
        dictationLog.error(
          "Agent voice capture gesture failed: \(error.localizedDescription, privacy: .public)")
        store.reportDictationFailure("Couldn't change recording: \(error.userFacingMessage)")
        return
      }
      // Terminal reconcile against the controller. The lifecycle hooks own the
      // happy path; this only catches a gesture that left the controller idle
      // without ever broadcasting a terminal event.
      if await hotkeys.isRecording() == false {
        store.endDictationSession()
      }
    }
  }
}

/// The production capture surface. Declared here rather than on the generated
/// binding so no generated file carries hand-written conformance.
extension CodescribeHotkeys: ComposerCaptureControlling {}
