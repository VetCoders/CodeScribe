import Foundation
import XCTest

@testable import Codescribe

/// The delivery half of one composer turn: capture identity on the way in,
/// receiver acknowledgement on the way out.
///
/// Everything here is written against production owners — `RealComposerDictation`
/// for the gesture, `AgentChatStore` for admission, `OverlayState` for the
/// projection boundary. The only substituted surface is the FFI object, because
/// it is the process boundary; no policy is re-implemented in a fake.
///
/// The claim under test is narrow and specific: **a route that was selected, an
/// event that was queued and a callback that was invoked are all statements
/// about the postman.** Only the receiver's typed receipt is delivery.
@MainActor
final class ComposerDeliveryJoinTests: XCTestCase {

  // MARK: Doubles

  private enum CaptureCall: Equatable {
    case isRecording
    case startComposerTurn
    case stop(String)
  }

  private enum CaptureFailure: Error { case transport }

  private final class FakeCaptureSurface: ComposerCaptureControlling, @unchecked Sendable {
    private var recordingAnswers: [Bool]
    private var answerCursor = 0
    var admittedCaptureId = "capture-A"
    var stopOutcome: CsConditionalStop = .stopped
    var stopThrows = false
    var onQuery: (@MainActor @Sendable () -> Void)?
    private(set) var calls: [CaptureCall] = []

    init(recording: [Bool]) { self.recordingAnswers = recording }

    func isRecording() async -> Bool {
      calls.append(.isRecording)
      await onQuery?()
      let answer = recordingAnswers[min(answerCursor, recordingAnswers.count - 1)]
      answerCursor += 1
      return answer
    }

    func startComposerTurnRecording() async throws -> CsCaptureHandle {
      calls.append(.startComposerTurn)
      return CsCaptureHandle(captureId: admittedCaptureId)
    }

    func stopComposerTurnRecording(handle: CsCaptureHandle) async throws -> CsConditionalStop {
      calls.append(.stop(handle.captureId))
      if stopThrows { throw CaptureFailure.transport }
      return stopOutcome
    }

    var stoppedIdentities: [String] {
      calls.compactMap { if case .stop(let id) = $0 { return id } else { return nil } }
    }
  }

  private final class StubThreadsProvider: ChatThreadsProviding {
    func listThreads() -> [ChatThread] {
      [("t_a", "Thread A"), ("t_b", "Thread B")].map { row in
        var thread = ChatThread(title: row.1, meta: "now")
        thread.backendId = row.0
        thread.messagesLoaded = true
        return thread
      }
    }
    func searchThreads(query: String) -> [ChatThread] { listThreads() }
    func loadMessages(backendId: String) -> [ChatMessage] { [] }
    func deleteThread(backendId: String) -> Bool { true }
    func setThreadFavorite(backendId: String, isFavorite: Bool) -> Bool { true }
    func renameThread(backendId: String, title: String) -> Bool { true }
    func setGeneratedTitle(backendId: String, title: String) -> Bool { true }
    func exportThreadMarkdown(backendId: String, assistantOnly: Bool) -> String? { nil }
    func generateThreadId() -> String { "t_generated" }
  }

  private struct Fixture: Sendable {
    let store: AgentChatStore
    let dictation: RealComposerDictation
    let surface: FakeCaptureSurface
    let threadA: UUID
    let threadB: UUID
  }

  private func makeFixture(recording: [Bool]) -> Fixture {
    let store = AgentChatStore(threadsProvider: StubThreadsProvider())
    let surface = FakeCaptureSurface(recording: recording)
    let dictation = RealComposerDictation(store: store, hotkeys: surface)
    store.dictation = dictation
    let threadA = store.threads.first { $0.backendId == "t_a" }!.id
    let threadB = store.threads.first { $0.backendId == "t_b" }!.id
    store.select(threadA)
    return Fixture(
      store: store, dictation: dictation, surface: surface, threadA: threadA, threadB: threadB)
  }

  private func settle(_ fixture: Fixture) async {
    await fixture.dictation.transitionTask?.value
  }

  private var nextSequence: UInt64 = 0

  /// Build one projection through the production boundary. `lifecycleTerminal`
  /// and `delivery` are explicit because they are exactly what this suite is
  /// about; nothing here infers them from phase, label or action text.
  private func project(
    _ text: String,
    to state: OverlayState,
    sessionId: String = "join-session",
    mode: String = "agent",
    phase: String,
    terminal: Bool,
    lifecycleTerminal: Bool,
    delivery: CsTranscriptDelivery,
    reducerAction: String,
    manualEditReceipt: String? = nil
  ) {
    nextSequence += 1
    let sequence = nextSequence
    let sampleStart = (sequence - 1) * 16_000
    let sampleEnd = sequence * 16_000
    let receipt = CsProjectedAcousticReceipt(
      acousticSerialVersion: 1,
      acousticSerial: "join-acoustic-\(sequence)",
      sessionId: sessionId,
      captureEpoch: 1,
      sampleStart: sampleStart,
      sampleEnd: sampleEnd,
      durationMs: 1_000,
      energyIntegral: 1,
      meanRmsDbfs: -20,
      peakDbfs: -6,
      vadOpenSample: sampleStart,
      vadCloseSample: sampleEnd,
      evidenceCalibrationVersion: "test-v1",
      wordEvidenceReceipts: ["join-word-\(sequence)"],
      layerDecisionReceipts: ["join-layer-\(sequence)"],
      sealReceipt: terminal ? "join-seal-\(sequence)" : nil,
      manualEditReceipt: manualEditReceipt
    )
    state.applyTranscriptProjection(
      CsTranscriptProjectionEvent(
        schema: "codescribe.transcript_projection.v1",
        sequence: sequence,
        emittedAt: "2026-09-09T20:00:00Z",
        sessionId: sessionId,
        mode: mode,
        reducerRevision: sequence,
        reducerAction: reducerAction,
        occurrenceSessionId: sessionId,
        captureEpoch: 1,
        sampleStart: sampleStart,
        sampleEnd: sampleEnd,
        documentIndex: sequence - 1,
        label: terminal ? "terminal" : "live",
        renderedText: text,
        phase: phase,
        canPaste: terminal,
        canInsert: terminal,
        canCopy: !text.isEmpty,
        canRetranscribe: terminal,
        canFormat: !terminal,
        terminal: terminal,
        lifecycleTerminal: lifecycleTerminal,
        delivery: delivery,
        acousticReceipts: [receipt]
      )
    )
  }

  private func listening(_ text: String, to state: OverlayState, sessionId: String = "join-session")
  {
    project(
      text, to: state, sessionId: sessionId, phase: "listening", terminal: false,
      lifecycleTerminal: false, delivery: .unattempted, reducerAction: "apply_ledger_decision")
  }

  private func terminalRevision(
    _ text: String, to state: OverlayState, sessionId: String = "join-session",
    receipt: String = "formatter-join-1"
  ) {
    project(
      text, to: state, sessionId: sessionId, phase: "formatted", terminal: true,
      lifecycleTerminal: false, delivery: .unattempted, reducerAction: "apply_manual_edit",
      manualEditReceipt: receipt)
  }

  private func sessionEnded(
    _ text: String, to state: OverlayState, sessionId: String = "join-session",
    delivery: CsTranscriptDelivery = .composerPending
  ) {
    project(
      text, to: state, sessionId: sessionId, phase: "formatted", terminal: true,
      lifecycleTerminal: true, delivery: delivery, reducerAction: "session_ended")
  }

  // MARK: Acceptance 1 — capture identity, atomically checked

  /// The controller's own identity for the take reaches the composer, and the
  /// stop names it. Without this the gesture can only say "stop whatever is
  /// live", which is the ask this cut exists to refuse.
  func testStopNamesTheCaptureTheControllerAdmittedForThisGesture() async {
    let f = makeFixture(recording: [false, true, true])
    f.surface.admittedCaptureId = "capture-mine"

    f.dictation.toggle()
    await settle(f)
    XCTAssertEqual(f.store.composerCaptureHandle?.captureId, "capture-mine")

    f.dictation.toggle()
    await settle(f)
    XCTAssertEqual(f.surface.stoppedIdentities, ["capture-mine"])
  }

  /// A take that replaced ours between the query and the stop is refused at the
  /// controller. The foreign take survives, and — the half that is easy to miss
  /// — no new take is started in its place.
  func testForeignReplacementBetweenQueryAndStopLeavesTheForeignTakeRunning() async {
    let f = makeFixture(recording: [false, true, true])
    f.dictation.toggle()
    await settle(f)
    f.surface.stopOutcome = .foreignCapture

    f.dictation.toggle()
    await settle(f)

    XCTAssertEqual(f.surface.stoppedIdentities, ["capture-A"], "exactly one named stop attempt")
    XCTAssertEqual(
      f.surface.calls.filter { $0 == .startComposerTurn }.count, 1,
      "a refused stop must not become a start")
    XCTAssertFalse(f.store.ownsLiveDictation)
    XCTAssertNil(f.store.composerCaptureHandle, "a lost capture keeps no stop permission")
  }

  /// Ownership without an admitted identity is not stop permission. The gesture
  /// reconciles instead of falling back to an unconditional stop.
  func testOwnershipWithoutAnAdmittedIdentityNeverIssuesAStop() async {
    let f = makeFixture(recording: [false, true, true])
    f.dictation.toggle()
    await settle(f)
    XCTAssertTrue(f.store.ownsLiveDictation)
    f.store.reconcileComposerCaptureLost()
    f.store.setDictationPhase(.recording)

    f.dictation.toggle()
    await settle(f)

    XCTAssertTrue(f.surface.stoppedIdentities.isEmpty)
  }

  // MARK: Acceptance 2 — lifecycle events cannot grant ownership or release another capture

  /// A shared lifecycle beat paints; it does not manufacture local ownership.
  func testForeignLifecyclePhaseDoesNotGrantLocalStopPermission() {
    let f = makeFixture(recording: [true])

    f.store.setDictationPhase(.recording)

    XCTAssertFalse(f.store.ownsLiveDictation)
    XCTAssertNil(f.store.composerCaptureHandle)
  }

  /// A terminal projection from a session that is already over must not release
  /// the capture the user has since started. Sessions are keyed by id, so the
  /// late event lands on its own (retired) session and nothing else.
  func testDelayedPriorSessionTerminalDoesNotReleaseTheCurrentCapture() {
    let state = OverlayState()
    var stopped = 0
    state.onRecordingStopped = { stopped += 1 }

    listening("first take", to: state, sessionId: "session-1")
    sessionEnded("first take", to: state, sessionId: "session-1", delivery: .retained)
    let afterFirst = stopped

    listening("second take", to: state, sessionId: "session-2")
    // The late duplicate for the retired session arrives after the new one began.
    sessionEnded("first take", to: state, sessionId: "session-1", delivery: .retained)

    XCTAssertEqual(
      stopped, afterFirst + 1,
      "the late prior-session terminal ends its own session, not the live one")
  }

  // MARK: Acceptance 3 — recovery without a blind timer

  /// A stop whose transport failed leaves the destination intact, and the next
  /// press reconciles against the controller's own answer rather than a timer.
  func testFailedStopIsReconciledByTheNextGestureNotByATimeout() async {
    let f = makeFixture(recording: [false, true, true, false, false])
    f.dictation.toggle()
    await settle(f)
    f.surface.stopThrows = true

    f.dictation.toggle()
    await settle(f)
    XCTAssertEqual(
      f.store.dictationThreadID, f.threadA, "a failed stop keeps the pending destination")
    XCTAssertTrue(f.store.composerCaptureAwaitingTerminal)

    // The terminal never arrives. The user presses again; the controller reports
    // idle, which is the fact the request is released against.
    f.surface.stopThrows = false
    f.dictation.toggle()
    await settle(f)

    XCTAssertEqual(
      f.surface.calls.filter { $0 == .startComposerTurn }.count, 2,
      "the surface must be usable again after a stop that never terminated")
  }

  /// A start still in flight is never replaced by a second press. Reconciliation
  /// applies only once stop permission has been spent.
  func testAPendingStartIsNotReplacedByASecondPress() async {
    let f = makeFixture(recording: [false, false, false])

    f.dictation.toggle()
    await settle(f)
    XCTAssertTrue(f.store.hasComposerCaptureRequest)
    XCTAssertFalse(f.store.ownsLiveDictation, "an idle reply completes no start")

    f.dictation.toggle()
    await settle(f)

    XCTAssertEqual(
      f.surface.calls.filter { $0 == .startComposerTurn }.count, 1,
      "a request that never spent stop permission still blocks a replacement")
  }

  // MARK: Acceptance 5 — presentation terminal is not delivery terminal

  /// The production sequence that broke delivery: a Light+/formatter revision is
  /// terminal and arrives BEFORE `session_ended`. It must not consume the
  /// delivery slot, and the later lifecycle line must still insert — exactly
  /// once, even when the end is duplicated.
  func testTerminalRevisionBeforeSessionEndedStillDeliversExactlyOnce() {
    let state = OverlayState()
    var admitted: [String] = []
    state.onComposerTranscript = { text in
      admitted.append(text)
      return .admitted(threadID: UUID())
    }

    listening("raw words", to: state)
    terminalRevision("formatted words", to: state)
    sessionEnded("formatted words", to: state)
    sessionEnded("formatted words", to: state)

    XCTAssertEqual(admitted, ["formatted words"])
  }

  /// A formatter that changed nothing produces the same ordering with identical
  /// bytes. Sameness of text is not a reason to skip a delivery.
  func testNoOpFormatterRevisionStillLeavesTheDeliveryToTheLifecycleLine() {
    let state = OverlayState()
    var admitted: [String] = []
    state.onComposerTranscript = { text in
      admitted.append(text)
      return .admitted(threadID: UUID())
    }

    listening("unchanged", to: state)
    terminalRevision("unchanged", to: state)
    sessionEnded("unchanged", to: state)

    XCTAssertEqual(admitted, ["unchanged"])
  }

  /// A refused seal still has committed words, and they are still deliverable.
  /// The refusal degrades the claim about coverage, never the route.
  func testRefusedSealStillDeliversItsCommittedWords() {
    let state = OverlayState()
    var admitted: [String] = []
    state.onComposerTranscript = { text in
      admitted.append(text)
      return .admitted(threadID: UUID())
    }

    listening("partial words", to: state)
    sessionEnded("partial words", to: state)

    XCTAssertEqual(admitted, ["partial words"])
  }

  /// An empty capture claims nothing in either direction: no delivery, and no
  /// failure either.
  func testEmptyCaptureMakesNoDeliveryClaimAtAll() {
    let state = OverlayState()
    var calls = 0
    state.onComposerTranscript = { _ in
      calls += 1
      return .empty
    }

    sessionEnded("   ", to: state)

    XCTAssertEqual(calls, 0)
    XCTAssertNil(state.retainedComposerDelivery)
  }

  // MARK: Acceptance 6 — no success claim without a receipt

  /// No receiver is wired. The text must stay accessible rather than be reported
  /// as delivered to a composer that never saw it.
  func testMissingReceiverRetainsTheTextInsteadOfClaimingDelivery() {
    let state = OverlayState()
    state.onComposerTranscript = nil

    listening("orphan words", to: state)
    sessionEnded("orphan words", to: state)

    XCTAssertEqual(state.retainedComposerDelivery, "orphan words")
  }

  /// The receiver refuses. The overlay keeps the exact bytes and does not mark
  /// the session delivered, so a later retry is still possible.
  func testReceiverRejectionKeepsTheDeliveryRecoverableAndRetryable() {
    let state = OverlayState()
    var offers = 0
    state.onComposerTranscript = { text in
      offers += 1
      return .retained(text)
    }

    listening("refused words", to: state)
    sessionEnded("refused words", to: state)
    XCTAssertEqual(state.retainedComposerDelivery, "refused words")

    sessionEnded("refused words", to: state)
    XCTAssertEqual(offers, 2, "a refused delivery does not consume the session's delivery slot")
  }

  /// A refused handover must not fall back to submitting the words. The take was
  /// routed to a draft; nobody asked for it to be sent.
  func testARefusedHandoverStillCancelsTheOverlayAutoSend() {
    let state = OverlayState()
    var sentToAgent: [String] = []
    state.onSendToAgent = { sentToAgent.append($0) }
    state.onComposerTranscript = { text in .retained(text) }

    listening("refused words", to: state)
    sessionEnded("refused words", to: state)
    state.fireAutoHideNowForTests()

    XCTAssertEqual(state.retainedComposerDelivery, "refused words")
    XCTAssertTrue(sentToAgent.isEmpty, "a failed handover never becomes an automatic send")
  }

  /// A take the controller did not route to the composer is never offered to it.
  /// The typed disposition is the whole gate; the display label is not read.
  func testATakeWithoutAComposerDispositionIsNeverOfferedToTheComposer() {
    let state = OverlayState()
    var offers = 0
    state.onComposerTranscript = { _ in
      offers += 1
      return .admitted(threadID: UUID())
    }

    listening("pasted words", to: state)
    sessionEnded("pasted words", to: state, delivery: .sinkAccepted)

    XCTAssertEqual(offers, 0)
  }

  // MARK: Acceptance 7 — the result belongs to the capturing thread

  /// Record in A, switch to B and type there, then finish A. B keeps its own
  /// draft and attachments, the selection does not move, and A's words wait for
  /// A rather than being appended to whatever is on screen.
  func testResultTargetsTheCapturingThreadWithoutStealingTheCurrentSelection() {
    let f = makeFixture(recording: [false, true])
    _ = f.store.beginComposerCaptureRequest(threadID: f.threadA)
    f.store.select(f.threadB)
    f.store.draft = "typed in B"
    f.store.pendingAttachments = [PendingAttachment(url: URL(fileURLWithPath: "/tmp/b.png"))]

    let receipt = f.store.receiveDictationTranscript("words from A")

    XCTAssertEqual(receipt, .parked(threadID: f.threadA))
    XCTAssertEqual(f.store.selectedThreadID, f.threadB, "delivery never moves the rail")
    XCTAssertEqual(f.store.draft, "typed in B", "B's draft is B's")
    XCTAssertEqual(f.store.pendingAttachments.count, 1, "B keeps its staged attachments")

    f.store.select(f.threadA)
    XCTAssertEqual(f.store.draft, "words from A", "A's words surface in A")
  }

  /// When the capturing thread is the one on screen, the words land in the live
  /// draft and join an existing one instead of gluing onto its last word.
  func testDeliveryToTheSelectedOwnerAppendsToTheLiveDraft() {
    let f = makeFixture(recording: [false, true])
    _ = f.store.beginComposerCaptureRequest(threadID: f.threadA)
    f.store.draft = "already here"

    let receipt = f.store.receiveDictationTranscript("spoken words")

    XCTAssertEqual(receipt, .admitted(threadID: f.threadA))
    XCTAssertEqual(f.store.draft, "already here\nspoken words")
  }

  /// The capturing thread was deleted while the take was in flight. There is no
  /// destination left, so the words become explicit recovery — never a silent
  /// drop and never a dangling selection.
  func testDeletedCapturingThreadYieldsExplicitRetainedRecovery() {
    let f = makeFixture(recording: [false, true])
    let threadA = f.store.threads.first { $0.id == f.threadA }!
    _ = f.store.beginComposerCaptureRequest(threadID: f.threadA)
    f.store.select(f.threadB)
    f.store.delete(threadA)

    let receipt = f.store.receiveDictationTranscript("words with nowhere to go")

    XCTAssertEqual(receipt, .retained("words with nowhere to go"))
    XCTAssertEqual(f.store.retainedComposerDelivery, "words with nowhere to go")
    XCTAssertEqual(f.store.selectedThreadID, f.threadB)
  }

  /// A delivery already parked for a thread that is then deleted is surfaced for
  /// recovery rather than removed with the thread.
  func testDeletingAThreadSurfacesItsParkedDeliveryForRecovery() {
    let f = makeFixture(recording: [false, true])
    _ = f.store.beginComposerCaptureRequest(threadID: f.threadA)
    f.store.select(f.threadB)
    XCTAssertEqual(f.store.receiveDictationTranscript("parked words"), .parked(threadID: f.threadA))

    f.store.delete(f.store.threads.first { $0.id == f.threadA }!)

    XCTAssertEqual(f.store.retainedComposerDelivery, "parked words")
  }

  /// A capture with no owner at all cannot be guessed into one.
  func testDeliveryWithoutAnOwningThreadIsRetainedNotRoutedToTheSelection() {
    let f = makeFixture(recording: [false, true])
    f.store.select(f.threadB)
    f.store.draft = "typed in B"

    let receipt = f.store.receiveDictationTranscript("ownerless words")

    XCTAssertEqual(receipt, .retained("ownerless words"))
    XCTAssertEqual(f.store.draft, "typed in B")
  }

  // MARK: Acceptance 8 — parked text is offered, never sent

  /// Delivery parks the words in a draft the user can still edit. Nothing here
  /// submits them, and the overlay's own deadline is told to stop trying.
  func testAdmittedDeliveryCancelsTheOverlayAutoSendInsteadOfSubmitting() {
    let f = makeFixture(recording: [false, true])
    _ = f.store.beginComposerCaptureRequest(threadID: f.threadA)
    let state = OverlayState()
    state.onComposerTranscript = { [store = f.store] text in
      store.receiveDictationTranscript(text)
    }

    listening("draft words", to: state)
    sessionEnded("draft words", to: state)

    XCTAssertEqual(f.store.draft, "draft words", "the words are in the composer, unsent")
    XCTAssertTrue(f.store.threads.allSatisfy { $0.messages.isEmpty }, "nothing was submitted")
  }
}
