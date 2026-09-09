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
  private(set) var transitionTask: Task<Void, Never>?

  init(store: AgentChatStore, hotkeys: ComposerCaptureControlling = CodescribeHotkeys()) {
    self.store = store
    self.hotkeys = hotkeys
  }

  func toggle() {
    guard let store, !transitioning else { return }
    // A previous request awaiting terminal delivery cannot be replaced by a
    // new start (or used to stop a foreign take that has since appeared).
    guard !store.hasComposerCaptureRequest || store.ownsLiveDictation else { return }
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
        guard live else { return }
        do {
          try await hotkeys.stopRecording()
          dictationLog.info("Agent voice capture stop requested on shared controller")
        } catch {
          store.reportDictationFailure(
            "Couldn't change recording: \(error.userFacingMessage)", preservingDelivery: true)
        }
        // The terminal projection consumer must deliver before releasing the
        // latch. No post-stop isRecording poll can establish that ordering.
        return
      }
      let requestID = store.beginComposerCaptureRequest(threadID: destination)
      do {
        try await hotkeys.startComposerTurnRecording()
        guard store.isCurrentComposerCaptureRequest(requestID) else { return }
        let stillLive = await hotkeys.isRecording()
        store.completeComposerCaptureStart(requestID, live: stillLive)
        dictationLog.info("Agent composer take start requested on shared controller")
      } catch {
        guard store.isCurrentComposerCaptureRequest(requestID) else { return }
        dictationLog.error(
          "Agent voice capture gesture failed: \(error.localizedDescription, privacy: .public)")
        store.reportDictationFailure("Couldn't change recording: \(error.userFacingMessage)")
      }
      // BOUNDARY: the bridge returns Void and stopRecording takes no capture
      // identity. A replacement take between query and stop cannot be rejected
      // here. Controller admission and an identity-checked stop must close it.
    }
  }
}

/// The production capture surface. Declared here rather than on the generated
/// binding so no generated file carries hand-written conformance.
extension CodescribeHotkeys: ComposerCaptureControlling {}
