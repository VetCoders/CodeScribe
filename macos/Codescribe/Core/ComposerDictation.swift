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
  ///
  /// Returns the controller-admitted identity of the take that was opened. A
  /// start that admits no capture returns no handle to stop with.
  func startComposerTurnRecording() async throws -> CsCaptureHandle
  /// Stop exactly the named capture, or refuse.
  ///
  /// The unconditional `stopRecording` is deliberately absent from this seam:
  /// between the press and this call the microphone can have changed hands, and
  /// a UI gesture may not end a take it did not open.
  func stopComposerTurnRecording(handle: CsCaptureHandle) async throws -> CsConditionalStop
}

/// Thin UI gesture adapter over the shared controller. The composer never owns
/// a recorder or transcript reducer; it requests one explicit Agent take.
@MainActor
final class RealComposerDictation: ComposerDictating {
  private let hotkeys: ComposerCaptureControlling
  private weak var store: AgentChatStore?
  private var transitioning = false
  private(set) var transitionTask: Task<Void, Never>?

  init(store: AgentChatStore, hotkeys: ComposerCaptureControlling = CodescribeHotkeys()) {
    self.store = store
    self.hotkeys = hotkeys
  }

  func toggle() {
    guard let store, !transitioning else { return }
    // A start still in flight is never replaced. A request that already spent
    // its stop permission is different: its terminal may never arrive, and this
    // press is the user asking us to reconcile — see the idle branch below.
    guard !store.hasComposerCaptureRequest || store.ownsLiveDictation
      || store.composerCaptureAwaitingTerminal
    else { return }
    let wasOwned = store.ownsLiveDictation
    let destination = store.selectedThreadID
    transitioning = true
    store.prepareDictationGesture()
    transitionTask = Task { @MainActor in
      defer { transitioning = false }
      let live = await hotkeys.isRecording()
      // Read after suspension: a terminal notification may have revoked the
      // local request while the controller query was in flight.
      let owned = store.ownsLiveDictation
      store.dictationBlocked = live && !owned
      if live && !owned {
        dictationLog.info("Agent voice capture press ignored — another surface owns the take")
        store.releaseUnownedDictationGesture()
        return
      }
      // A stop gesture invalidated during the query must not turn into a start.
      guard !wasOwned || owned else { return }
      if owned {
        // Idle does not prove pending text has been delivered. In either case
        // retire stop permission without releasing the original destination.
        store.awaitComposerCaptureTerminal()
        guard let handle = store.composerCaptureHandle else {
          // Ownership without an admitted identity is not stop permission: we
          // would have to stop "whatever is live", which is exactly the thing
          // this seam exists to refuse.
          dictationLog.error("Agent voice capture stop refused — no admitted capture identity")
          store.reconcileComposerCaptureLost()
          return
        }
        do {
          let outcome = try await hotkeys.stopComposerTurnRecording(handle: handle)
          switch outcome {
          case .stopped:
            dictationLog.info("Agent composer take stop accepted for its own capture")
          case .alreadyStopping:
            dictationLog.info("Agent composer take is already stopping; terminal still owed")
          case .foreignCapture:
            // Someone replaced our take between the press and this call. Theirs
            // keeps running; ours is over, so release without touching it.
            dictationLog.info("Agent composer stop refused — a foreign take owns the microphone")
            store.reconcileComposerCaptureLost()
          case .noLiveCapture:
            // Nothing is capturing: this take can produce no further terminal.
            dictationLog.info("Agent composer stop found no live capture; reconciling request")
            store.reconcileComposerCaptureLost()
          }
        } catch {
          // Transport failure says nothing about the take. Keep the pending
          // destination; the next press reconciles against the controller.
          store.reportDictationFailure(
            "Couldn't change recording: \(error.userFacingMessage)", preservingDelivery: true)
        }
        // The terminal projection consumer must deliver before releasing the
        // latch. No post-stop isRecording poll can establish that ordering.
        return
      }
      if store.hasComposerCaptureRequest {
        // The controller just answered that nothing is capturing, so no take of
        // ours can still produce a terminal. Release the stuck request against
        // that fact — not against a timeout — so the gesture works again.
        dictationLog.info("Agent composer request reconciled against an idle controller")
        store.reconcileComposerCaptureLost()
      }
      let requestID = store.beginComposerCaptureRequest(threadID: destination)
      do {
        let admitted = try await hotkeys.startComposerTurnRecording()
        guard store.isCurrentComposerCaptureRequest(requestID) else { return }
        let stillLive = await hotkeys.isRecording()
        store.completeComposerCaptureStart(requestID, live: stillLive, handle: admitted)
        dictationLog.info("Agent composer take start requested on shared controller")
      } catch {
        guard store.isCurrentComposerCaptureRequest(requestID) else { return }
        dictationLog.error(
          "Agent voice capture gesture failed: \(error.localizedDescription, privacy: .public)")
        store.reportDictationFailure("Couldn't change recording: \(error.userFacingMessage)")
      }
    }
  }
}

/// The production capture surface. Declared here rather than on the generated
/// binding so no generated file carries hand-written conformance.
extension CodescribeHotkeys: ComposerCaptureControlling {}
