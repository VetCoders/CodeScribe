import Foundation
import XCTest

@testable import Codescribe

/// One composer gesture, one explicit take — proved against the production
/// adapter, not against a re-implementation of its rules.
///
/// `RealComposerDictation` is the owner under test. The only substituted
/// boundary is the shared controller itself (`ComposerCaptureControlling`),
/// which is the FFI object; every decision — which press starts, which press
/// stops, which press must refuse, and which entry point a start uses — stays in
/// production code.
///
/// The incident this pins (Founder take ca23c06b, 2026-09-09): the composer mic
/// called `startAssistiveRecording`, i.e. the hands-free lane, so the take
/// inherited silence epochs. It also read "the controller is recording" as "I am
/// recording" and would end a dictation another surface owned.
@MainActor
final class ComposerTurnOwnershipTests: XCTestCase {
  /// Every call the composer gesture makes on the shared controller, in order.
  private enum CaptureCall: Equatable {
    case isRecording
    case startComposerTurn
    case stop
  }

  private enum CaptureFailure: Error { case refused }

  private final class FakeCaptureSurface: ComposerCaptureControlling, @unchecked Sendable {
    /// Answers handed to successive `isRecording()` calls; the last one repeats.
    private var recordingAnswers: [Bool]
    private var answerCursor = 0
    var startFails = false
    var stopFails = false
    private(set) var calls: [CaptureCall] = []

    init(recording: [Bool]) {
      self.recordingAnswers = recording
    }

    func isRecording() async -> Bool {
      calls.append(.isRecording)
      let answer = recordingAnswers[min(answerCursor, recordingAnswers.count - 1)]
      answerCursor += 1
      return answer
    }

    func startComposerTurnRecording() async throws {
      calls.append(.startComposerTurn)
      if startFails { throw CaptureFailure.refused }
    }

    func stopRecording() async throws {
      calls.append(.stop)
      if stopFails { throw CaptureFailure.refused }
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

  private struct Fixture {
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

  /// Let the adapter's detached `Task { @MainActor in ... }` run to completion.
  private func settle() async {
    for _ in 0..<8 {
      await Task.yield()
    }
  }

  // MARK: The entry point itself

  func testIdleComposerPressUsesTheOneTurnEntryPointNotTheHandsFreeLane() async {
    let f = makeFixture(recording: [false, false])

    f.dictation.toggle()
    await settle()

    XCTAssertTrue(
      f.surface.calls.contains(.startComposerTurn),
      "the composer must open its own one-turn take"
    )
  }

  // MARK: Ownership

  func testAForeignLiveCaptureIsReportedBusyAndNeverStopped() async {
    let f = makeFixture(recording: [true])
    // Nothing latched: the live take was started by a hotkey/tray/overlay.
    XCTAssertFalse(f.store.ownsLiveDictation)

    f.dictation.toggle()
    await settle()

    XCTAssertFalse(
      f.surface.calls.contains(.stop),
      "a composer press must never end a capture another surface owns"
    )
    XCTAssertFalse(
      f.surface.calls.contains(.startComposerTurn),
      "and it must not open a second take on top of it either"
    )
    XCTAssertTrue(f.store.dictationBlocked, "the mic reads busy while a foreign take is live")
    XCTAssertEqual(
      f.store.dictationPhase, .idle,
      "the optimistic press must not strand the mic in a non-actionable state"
    )
    XCTAssertNil(f.store.dictationThreadID, "a refused gesture owns nothing")
  }

  func testOwnLiveCaptureIsStoppedByTheSecondPress() async {
    let f = makeFixture(recording: [true, false])
    // The latch the composer's own start would have set.
    f.store.setDictationPhase(.recording)
    XCTAssertTrue(f.store.ownsLiveDictation)

    f.dictation.toggle()
    await settle()

    XCTAssertTrue(f.surface.calls.contains(.stop), "the owning surface ends its own take")
  }

  func testThreadAKeepsTheCaptureAfterSelectingThreadB() async {
    let f = makeFixture(recording: [false, true])

    f.dictation.toggle()
    await settle()
    XCTAssertEqual(f.store.dictationThreadID, f.threadA)

    f.store.select(f.threadB)

    XCTAssertEqual(
      f.store.dictationThreadID, f.threadA,
      "ownership is decided at the gesture and not re-decided by browsing"
    )
    XCTAssertFalse(
      f.store.dictationOwnsSelectedThread,
      "thread B must see the mic as busy, not as its own live capture"
    )
  }

  // MARK: Recoverable lifecycle

  func testDoubleClickWhileInFlightIssuesOneStartOnly() async {
    let f = makeFixture(recording: [false, false])

    f.dictation.toggle()
    f.dictation.toggle()
    await settle()

    XCTAssertEqual(
      f.surface.calls.filter { $0 == .startComposerTurn }.count, 1,
      "the in-flight guard swallows the second press"
    )
  }

  func testStartFailureLeavesTheMicPressableAgain() async {
    let f = makeFixture(recording: [false, false])
    f.surface.startFails = true

    f.dictation.toggle()
    await settle()

    guard case .failed = f.store.dictationPhase else {
      return XCTFail("a refused start must surface as a recoverable failure")
    }
    XCTAssertNil(f.store.dictationThreadID, "a take that never began owns nothing")
  }

  func testStopFailureLeavesTheMicPressableAgain() async {
    let f = makeFixture(recording: [true, false])
    f.store.setDictationPhase(.recording)
    f.surface.stopFails = true

    f.dictation.toggle()
    await settle()

    guard case .failed = f.store.dictationPhase else {
      return XCTFail("a refused stop must surface as a recoverable failure")
    }
  }
}
