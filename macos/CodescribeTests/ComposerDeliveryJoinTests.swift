import Foundation
import XCTest
import os

@testable import Codescribe

/// The delivery half of one composer turn: capture identity on the way in,
/// receiver acknowledgement on the way out.
///
/// Everything here is written against production owners — `RealComposerDictation`
/// for the gesture, `AgentChatStore` for admission and composer ownership,
/// `OverlayState` for the projection boundary. The only substituted surfaces are
/// the two process boundaries: the FFI capture object, and the chat engine whose
/// real implementation is a Rust turn. Queueing, dispatch and every ownership
/// decision stay in the production store; no policy is re-implemented in a fake.
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

  /// Reply state a turn can be suspended on, so a test can hold one thread's
  /// turn "in flight" while asserting what happens to a *different* thread's
  /// unsent composer. The lock is what makes it safe off the main actor:
  /// `streamReply` is a nonisolated protocol requirement.
  private final class HeldReplyState: Sendable {
    private struct Storage {
      var continuations: [CheckedContinuation<String, Error>] = []
      var startedTexts: [String] = []
    }

    private let storage = OSAllocatedUnfairLock(initialState: Storage())

    var startedTexts: [String] { storage.withLock { $0.startedTexts } }

    func recordStart(_ text: String) {
      storage.withLock { $0.startedTexts.append(text) }
    }

    func suspend(_ continuation: CheckedContinuation<String, Error>) {
      storage.withLock { $0.continuations.append(continuation) }
    }

    func finishNext(_ reply: String) {
      let continuation = storage.withLock {
        $0.continuations.isEmpty ? nil : $0.continuations.removeFirst()
      }
      continuation?.resume(returning: reply)
    }
  }

  private final class HeldReplyEngine: AgentChatEngine {
    let state = HeldReplyState()

    func isAvailable() -> Bool { true }
    func availabilityDetail() -> String? { nil }
    func generateThreadTitle(_ text: String) async throws -> String? { nil }

    func streamReply(
      _ text: String,
      threadId: String,
      attachmentPaths: [String],
      onDelta: @escaping @MainActor (String) -> Void,
      onReasoning: @escaping @MainActor (String) -> Void,
      onToolExecuting: @escaping @MainActor (String, String) -> Void,
      onToolResult: @escaping @MainActor (String, String, Bool, String) -> Void
    ) async throws -> String {
      state.recordStart(text)
      return try await withCheckedThrowingContinuation { state.suspend($0) }
    }

    func cancelReply(threadId: String) -> Bool { true }
  }

  // MARK: Isolation

  /// The accepted-turn queue and the attachment sidecar both live in shared
  /// defaults, so a suite that sends must leave them exactly as it found them or
  /// the next store's restart replay inherits this suite's queue and chips.
  private static let sharedDefaultsKeys = [
    AgentChatStore.acceptedTurnsDefaultsKey,
    AgentChatStore.attachmentMetadataDefaultsKey,
  ]

  override func setUp() {
    super.setUp()
    Self.sharedDefaultsKeys.forEach(UserDefaults.standard.removeObject(forKey:))
  }

  override func tearDown() {
    Self.sharedDefaultsKeys.forEach(UserDefaults.standard.removeObject(forKey:))
    super.tearDown()
  }

  private func waitUntil(
    timeout: TimeInterval = 2,
    _ message: String = "condition not met in time",
    _ condition: () -> Bool
  ) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertTrue(condition(), message)
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
    let bAttachmentIDs = f.store.pendingAttachments.map(\.id)

    let receipt = f.store.receiveDictationTranscript("words from A")

    XCTAssertEqual(receipt, .parked(threadID: f.threadA))
    XCTAssertEqual(f.store.selectedThreadID, f.threadB, "delivery never moves the rail")
    XCTAssertEqual(f.store.draft, "typed in B", "B's draft is B's")
    XCTAssertEqual(f.store.pendingAttachments.count, 1, "B keeps its staged attachments")

    f.store.select(f.threadA)
    XCTAssertEqual(f.store.draft, "words from A", "A's words surface in A")
    XCTAssertTrue(f.store.pendingAttachments.isEmpty, "B's image did not travel to A")

    // The return trip is the other half of the same claim: B's composition was
    // parked, not consumed to make A's assertion true.
    f.store.select(f.threadB)
    XCTAssertEqual(f.store.draft, "typed in B", "B is exactly as the user left it")
    XCTAssertEqual(f.store.pendingAttachments.map(\.id), bAttachmentIDs, "the same staged files")
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

  // MARK: Thread-owned composer — every thread keeps its own unsent work

  /// The full round trip with work on both sides: A is mid-sentence, B is
  /// mid-sentence with an image staged, and A's take lands while B is on screen.
  /// Both compositions must survive both directions of the switch, and A's
  /// delivered words must join *A's* sentence rather than B's.
  func testEveryThreadKeepsItsOwnComposerAcrossAFullRoundTrip() {
    let f = makeFixture(recording: [false, true])
    f.store.draft = "half a thought in A"
    _ = f.store.beginComposerCaptureRequest(threadID: f.threadA)

    f.store.select(f.threadB)
    f.store.draft = "half a thought in B"
    f.store.addAttachments([URL(fileURLWithPath: "/tmp/round-trip-b.png")])
    let bAttachmentIDs = f.store.pendingAttachments.map(\.id)

    XCTAssertEqual(f.store.receiveDictationTranscript("spoken for A"), .parked(threadID: f.threadA))

    f.store.select(f.threadA)
    XCTAssertEqual(
      f.store.draft, "half a thought in A\nspoken for A",
      "the delivery joins A's own sentence, not the one typed in B")
    XCTAssertTrue(f.store.pendingAttachments.isEmpty, "A never staged anything")

    f.store.select(f.threadB)
    XCTAssertEqual(f.store.draft, "half a thought in B")
    XCTAssertEqual(f.store.pendingAttachments.map(\.id), bAttachmentIDs)

    f.store.select(f.threadA)
    XCTAssertEqual(
      f.store.draft, "half a thought in A\nspoken for A",
      "returning a second time is not a second delivery")
  }

  /// Two takes finish for A while B is on screen. Selecting A shows each
  /// document exactly once, and selecting A again does not repeat them.
  func testRepeatedSelectionSurfacesEachDeliveredDocumentExactlyOnce() {
    let f = makeFixture(recording: [false, true])
    _ = f.store.beginComposerCaptureRequest(threadID: f.threadA)
    f.store.select(f.threadB)

    XCTAssertEqual(f.store.receiveDictationTranscript("first take"), .parked(threadID: f.threadA))
    XCTAssertEqual(f.store.receiveDictationTranscript("second take"), .parked(threadID: f.threadA))

    f.store.select(f.threadA)
    XCTAssertEqual(f.store.draft, "first take\nsecond take")
    let focusAfterFirstArrival = f.store.composerFocusRequest

    f.store.select(f.threadB)
    f.store.select(f.threadA)
    XCTAssertEqual(f.store.draft, "first take\nsecond take", "no document is delivered twice")
    XCTAssertEqual(
      f.store.composerFocusRequest, focusAfterFirstArrival,
      "an already-surfaced document does not grab the caret again")
  }

  /// A delivery for a thread the user is not reading changes nothing they can
  /// see: not the selection, not the composer, not the caret.
  func testADeliveryForAnUnselectedThreadChangesNothingOnScreen() {
    let f = makeFixture(recording: [false, true])
    _ = f.store.beginComposerCaptureRequest(threadID: f.threadA)
    f.store.select(f.threadB)
    f.store.draft = "mid-sentence in B"
    f.store.addAttachments([URL(fileURLWithPath: "/tmp/untouched-b.png")])
    let bAttachmentIDs = f.store.pendingAttachments.map(\.id)
    let focusBefore = f.store.composerFocusRequest

    XCTAssertEqual(f.store.receiveDictationTranscript("for A only"), .parked(threadID: f.threadA))

    XCTAssertEqual(f.store.selectedThreadID, f.threadB)
    XCTAssertEqual(f.store.draft, "mid-sentence in B")
    XCTAssertEqual(f.store.pendingAttachments.map(\.id), bAttachmentIDs)
    XCTAssertEqual(f.store.composerFocusRequest, focusBefore, "no caret jump for a parked take")
  }

  // MARK: Every selection entrypoint hands the composer over

  /// The rail assigns the published property directly rather than calling
  /// `select`. Ownership lives in the property observer precisely so that this
  /// path cannot be the one that forgets.
  func testDirectSelectionAssignmentHandsTheComposerOverToo() {
    let f = makeFixture(recording: [false, true])
    f.store.draft = "typed in A"
    f.store.addAttachments([URL(fileURLWithPath: "/tmp/direct-a.png")])
    let aAttachmentIDs = f.store.pendingAttachments.map(\.id)

    f.store.selectedThreadID = f.threadB

    XCTAssertEqual(f.store.draft, "", "B never had a composition")
    XCTAssertTrue(f.store.pendingAttachments.isEmpty, "A's image stays with A")

    f.store.selectedThreadID = f.threadA
    XCTAssertEqual(f.store.draft, "typed in A")
    XCTAssertEqual(f.store.pendingAttachments.map(\.id), aAttachmentIDs)
  }

  /// Starting a new conversation opens an empty composer. It must not do that by
  /// destroying the sentence in progress, and the images staged for the previous
  /// thread must not follow the user into the new one.
  func testANewThreadOpensAnEmptyComposerAndParksTheUnfinishedOne() {
    let f = makeFixture(recording: [false, true])
    f.store.draft = "unfinished in A"
    f.store.addAttachments([URL(fileURLWithPath: "/tmp/new-thread-a.png")])
    let aAttachmentIDs = f.store.pendingAttachments.map(\.id)

    f.store.newThread()

    XCTAssertNotEqual(f.store.selectedThreadID, f.threadA)
    XCTAssertEqual(f.store.draft, "", "a fresh thread starts with an empty box")
    XCTAssertTrue(f.store.pendingAttachments.isEmpty, "staged images do not follow the user")

    f.store.select(f.threadA)
    XCTAssertEqual(f.store.draft, "unfinished in A", "the sentence was parked, not deleted")
    XCTAssertEqual(f.store.pendingAttachments.map(\.id), aAttachmentIDs)
  }

  /// Negative control. A thread that has never held a composition contributes
  /// nothing on selection — the composer is empty because that thread's box is
  /// empty, not because a previous owner's text leaked in and was cleared.
  func testSelectingAThreadWithNoStoredCompositionLeavesAnEmptyComposer() {
    let f = makeFixture(recording: [false, true])

    f.store.select(f.threadB)

    XCTAssertEqual(f.store.draft, "")
    XCTAssertTrue(f.store.pendingAttachments.isEmpty)

    f.store.select(f.threadA)
    XCTAssertEqual(f.store.draft, "", "an empty thread stores nothing to hand back")
    XCTAssertTrue(f.store.pendingAttachments.isEmpty)
  }

  /// Filtering and reloading the rail rebuilds rows. Compositions are keyed by
  /// the thread's stable id, which those paths preserve, so unsent work survives
  /// a search round trip instead of following whichever row ends up selected.
  func testSearchAndRefreshRestoreReturnEachThreadToItsOwnComposition() {
    let f = makeFixture(recording: [false, true])
    f.store.draft = "written in A"
    f.store.select(f.threadB)
    f.store.draft = "written in B"
    f.store.addAttachments([URL(fileURLWithPath: "/tmp/search-b.png")])
    let bAttachmentIDs = f.store.pendingAttachments.map(\.id)

    f.store.searchThreads("Thread")
    f.store.searchThreads("")
    f.store.refreshThreads()

    XCTAssertEqual(f.store.selectedThreadID, f.threadB, "filtering is not a selection gesture")
    XCTAssertEqual(f.store.draft, "written in B")
    XCTAssertEqual(f.store.pendingAttachments.map(\.id), bAttachmentIDs)

    f.store.select(f.threadA)
    XCTAssertEqual(f.store.draft, "written in A", "A's words came back to A across the rebuild")
  }

  // MARK: Sending consumes one owner's composition

  /// Send empties the composer it was sent from and nothing else.
  func testSendConsumesOnlyTheSelectedThreadsComposition() {
    let f = makeFixture(recording: [false, true])
    f.store.select(f.threadB)
    f.store.draft = "still unsent in B"
    f.store.addAttachments([URL(fileURLWithPath: "/tmp/send-b.png")])
    let bAttachmentIDs = f.store.pendingAttachments.map(\.id)

    f.store.select(f.threadA)
    f.store.draft = "ask A"
    f.store.addAttachments([URL(fileURLWithPath: "/tmp/send-a.png")])
    f.store.send()

    XCTAssertEqual(f.store.draft, "", "A's own composer was consumed")
    XCTAssertTrue(f.store.pendingAttachments.isEmpty)
    let sent = f.store.threads.first { $0.id == f.threadA }?.messages.first { $0.role == .you }
    XCTAssertEqual(sent?.text, "ask A")
    XCTAssertEqual(sent?.attachments.count, 1, "the send carried A's staged file, not B's")

    f.store.select(f.threadB)
    XCTAssertEqual(f.store.draft, "still unsent in B", "B's message was never sent for it")
    XCTAssertEqual(f.store.pendingAttachments.map(\.id), bAttachmentIDs)
  }

  /// A turn accepted, queued behind an active one, and finally streamed in A
  /// touches no part of B's unsent composition at any point in that lifecycle.
  func testAQueuedAndStreamingTurnNeverEmptiesAnotherThreadsComposer() async {
    let engine = HeldReplyEngine()
    let store = AgentChatStore(engine: engine, threadsProvider: StubThreadsProvider())
    let threadA = store.threads.first { $0.backendId == "t_a" }!.id
    let threadB = store.threads.first { $0.backendId == "t_b" }!.id

    store.select(threadB)
    store.draft = "waiting in B"
    store.addAttachments([URL(fileURLWithPath: "/tmp/queued-b.png")])
    let bAttachmentIDs = store.pendingAttachments.map(\.id)

    store.select(threadA)
    store.draft = "first ask"
    store.send()
    await waitUntil("A's first turn should start") { engine.state.startedTexts.count == 1 }

    store.draft = "second ask"
    store.send()
    XCTAssertEqual(store.queuedTurns.map(\.text), ["second ask"], "the second ask is queued")

    engine.state.finishNext("first reply")
    await waitUntil("the queued turn should start") { engine.state.startedTexts.count == 2 }
    engine.state.finishNext("second reply")
    await waitUntil("the queue should drain") {
      store.queuedTurns.isEmpty && store.activeComposerTurn == nil
    }

    store.select(threadB)
    XCTAssertEqual(store.draft, "waiting in B", "B's sentence outlived A's whole turn lifecycle")
    XCTAssertEqual(store.pendingAttachments.map(\.id), bAttachmentIDs)
  }

  // MARK: Deletion recovers words instead of migrating them

  /// Deleting a thread the user is not looking at takes its staged files with it
  /// and leaves its words recoverable — never silently poured into whichever
  /// thread happens to be selected.
  func testDeletingAnUnselectedThreadRecoversItsWordsAndStrandsNoAttachments() {
    let f = makeFixture(recording: [false, true])
    f.store.draft = "left behind in A"
    f.store.addAttachments([URL(fileURLWithPath: "/tmp/deleted-a.png")])

    f.store.select(f.threadB)
    f.store.draft = "still typing in B"

    f.store.delete(f.store.threads.first { $0.id == f.threadA }!)

    XCTAssertEqual(f.store.retainedComposerDelivery, "left behind in A")
    XCTAssertEqual(f.store.selectedThreadID, f.threadB, "deleting elsewhere does not move the rail")
    XCTAssertEqual(f.store.draft, "still typing in B")
    XCTAssertTrue(f.store.pendingAttachments.isEmpty, "the deleted thread's image is not re-staged")
  }

  /// Deleting the thread that is on screen moves the selection. Its composition
  /// must not travel with the cursor to the next thread.
  func testDeletingTheSelectedThreadNeverMigratesItsCompositionToTheNextOne() {
    let f = makeFixture(recording: [false, true])
    f.store.draft = "about to be deleted"
    f.store.addAttachments([URL(fileURLWithPath: "/tmp/deleted-selected.png")])

    f.store.delete(f.store.threads.first { $0.id == f.threadA }!)

    XCTAssertEqual(f.store.selectedThreadID, f.threadB)
    XCTAssertEqual(f.store.draft, "", "the next thread's composer is its own, and it is empty")
    XCTAssertTrue(f.store.pendingAttachments.isEmpty)
    XCTAssertEqual(
      f.store.retainedComposerDelivery, "about to be deleted",
      "the words are recoverable, not dropped and not auto-sent")
    XCTAssertTrue(
      f.store.threads.allSatisfy { $0.messages.isEmpty }, "recovery never submits anything")
  }
}
