# Delivery route — one throne for destination

> Founder 2026-08-15: the stop path was a fight for the throne. This file is
> the destination axis only. Mic lock, transcript truth, and agent-chain
> memory stay other thrones.

## Law

1. **Intent is frozen at session start** (or at an explicit overlay click).
   OS focus at stop time is not an input.
2. **`resolve_delivery_route` is the only function that picks a destination.**
   Auto-paste, overlay Insert, and To Agent consult it. They do not invent a
   second king.
3. **The Codescribe overlay canvas is never a legal Cmd+V target.** Its caret
   parks Paste Here. A positively latched Agent composer, Alacritty/Zellij
   (vc-terminal), Notes, or another foreign caret is legal; choosing the Agent
   route remains an explicit action. Assistive delivers as a first-class Agent
   message rather than synthesizing a focus-derived paste.
4. **Clipboard is borrowed, never stolen.** On release we snapshot the user's
   pasteboard, Cmd+V into the latched caret, then restore. The overlay must
   resign key first. The foreign target must then be observed as frontmost;
   Codescribe remaining frontmost is a veto. If Cmd+V cannot land, park ⌘⌥V
   and leave the user's pasteboard alone. Explicit overlay **Copy** is the only
   verb that writes the pasteboard on purpose and leaves it.

## Intent → route

| Intent            | Typical gesture                      | Route                                                                                                                |
| ----------------- | ------------------------------------ | -------------------------------------------------------------------------------------------------------------------- |
| `AgentVoice`      | Double Right Option / assistive hold | `AgentComposer`                                                                                                      |
| `OverlayToAgent`  | overlay **To Agent**                 | `AgentComposer`                                                                                                      |
| `OrientDictation` | Hold Fn / Globe                      | `ClipboardPaste` if auto-paste; `OrientCanvas` if overlay caret / no auto-paste                                      |
| `OrientFormat`    | Double Left Option                   | same as dictation                                                                                                    |
| `OverlayInsert`   | overlay Insert / defer               | `ClipboardPaste` into a latched foreign caret (Alacritty, Notes, …); `DeferredInsert` when Codescribe owns the caret |
| `NotesOnly`       | save-only notes                      | `ArchiveOnly`                                                                                                        |

Vetoes that keep Orient off the paste gun: empty / no-speech, live-stream
session, quality-commit pending, overlay canvas holds the caret.

### Stop path (restored 2026-09-08)

The W0 authority demolition (`ac6d399b3`, 2026-08-24) removed the stop-path
intents together with the old transcript cone, and with them auto-paste on
release. Restored by `delivery_intent_from_session(assistive, force_ai, notes_save_only)` → `resolve_delivery_route` on both stop paths (toggle
Finish and hold release):

- `OrientCanvas` from the table is `ArchiveOnly` with
  `reason=auto_paste_disabled`: the overlay canvas already shows the
  committed document, nothing else moves.
- `AgentVoice` resolves to `AgentComposer` with
  `reason=assistive_first_class`; the stop path never pastes it.
- `live_stream_session` and `commit_required` have no producer on the stop
  path today; both are false by construction until one returns.
- Transport is `execute_clipboard_paste`, shared with overlay Insert:
  activate the latched target, confirm focus (bounded wait **or** the target
  observed frontmost afterwards), preflight the event tap, borrow the
  clipboard for one Cmd+V. Anything else parks Paste Here. A latched target
  that confirmed neither never yields to whoever happens to be frontmost
  (`clipboard_paste_may_post`); only an Insert with no latch may follow the
  external frontmost app.
- Exactly once per take (`claim_take_delivery`): a second stop of the same
  take id archives only.
- **Seal refused (degraded delivery).** When the ledger refuses the terminal
  seal, `TerminalSealRefused` carries the committed live document and the
  controller still delivers it with `seal_refused=true` on the same
  `delivery_route:` line. History keeps its `failed` verdict, the ledger and
  the coverage threshold are untouched, and no witness is minted: the user
  gets the words the overlay already shows. Claude's call 2026-09-08, not a
  Founder decision — revert is one match arm in `process_recording` and
  `stop_toggle_and_adjudicate_inner`.

Explicit overlay clicks do **not** inherit the live-stream or quality-commit
vetoes. The user asked to insert now. Any Codescribe caret still refuses Cmd+V
and arms Paste Here instead. Alacritty and other confirmed foreign targets get
Cmd+V; Agent requires the explicit Agent route.

`paste_text_from_overlay` and `defer_text_from_overlay` consult
`resolve_delivery_route`. They do not pick a destination on their own.

The target is latched before the recording overlay takes focus and survives
the terminal transition back to Idle. Start failure and explicit recovery
clear it. This ordering matters: Insert happens after the terminal transition,
so clearing the target as ordinary recording state makes every finished take
degrade to DeferredInsert even when the foreign caret was known.

## Composer Stop settlement (W2 source checkpoint, unverified)

The admitted capture handle, produced inside the controller start lock, is the
composer's Stop authority. Owned Stop goes directly to its named endpoint;
`isRecording` is telemetry and neither authorizes Stop nor acknowledges delivery.
The store keeps the initiating thread while settlement is owed. It reuses the
existing preparing presentation for pending settlement, including after a failure
banner expires. Delayed replies address both request ID and capture ID.

`RecordingController` retains one capture-addressed task/result slot. A caller
waits at most the existing `STOP_TIMEOUT` (currently 120 seconds, an existing
engineering budget, not a Founder-selected latency target). Expiry returns
`Pending`; it does not cancel recorder drain, formatting, delivery or terminal
reset. The task holds the existing serialization lock from identity admission
through its terminal side effects. Duplicate Stop observes that same result;
completed retention is one slot, replaced only after its task exits. This is a
bounded caller outcome, not a finite settlement guarantee for an indefinitely
stalled dependency. A pending take still owes a terminal receipt or recoverable
failure and prevents another composer capture.

`CsConditionalStop` distinguishes `Stopped`, `AlreadyStopping`, `Pending`,
`ForeignCapture`, `NoLiveCapture` and `AdmissionUnavailable`. The first three
leave terminal/delivery ownership in place until the identity-aware consumer
finishes. Foreign/absent capture releases only that request; its capture-to-thread
delivery receipt survives for queued text. Admission unavailable means no task
was accepted; keep the same handle available for an explicit Stop retry. A
transport error preserves the pending destination. An expired banner is never a
terminal event. Early terminal text is retained until the start reply supplies
its authenticated handle, then joined to the initiating thread exactly once.

Named toggle captures use the existing toggle terminal processor even in
Assistive mode, so it reads the recorder's `CaptureTurnIntent` and preserves the
one-turn formatter/delivery route. No hands-free configuration is changed.

**Open boundary:** `core/audio/streaming_recorder.rs::stop` keeps a successful
WAV path only in a local variable before awaiting the transcription task. A join
failure propagates without that path, although the file exists. The controller
cannot associate/archive that file from the returned error. This checkpoint
therefore does not claim recovery of audio on every failure. Core is outside the
Stop worker's writable fence. No raw text seal or replacement reducer repairs
this gap.

Generated bindings remain unchanged under W2. W3 must regenerate from
`bridge/src/recording.rs` and `bridge/src/hotkeys.rs` with `make app-bindings`,
then run the actual controller/bridge suites, Swift ownership/delivery suites,
and full `make check`, `make verify`, `make test-swift`. All newly authored tests
are UNRUN. Installed Stop latency, retained audio and exact real delivery remain
W4 obligations.

## Telemetry

One INFO line per stop / To Agent / overlay Insert / defer:

```text
delivery_route: intent=overlay_insert route=clipboard_paste reason=explicit_insert target=Ghostty
delivery_route: intent=orient_dictation route=clipboard_paste reason=auto_paste target=Ghostty
delivery_route: intent=orient_dictation route=archive_only reason=auto_paste_disabled target=Ghostty
```

The stop path adds a `seal_refused` field to that line and follows it with
`stop-path delivery finished delivery=Pasted …` or a `warn` naming why the
paste was parked.

`reason=refuse_paste_into_self` is the smoking gun for "Codescribe owned focus,
so the transcript was parked instead of being pasted into an unknown internal
caret".

## Terminal and CLI consumers

An overlay Insert into a positively latched terminal/editor uses one borrowed
clipboard swap and one Cmd+V. The terminal emulator owns bracketed-paste
handling; Codescribe never types the transcript character by character.
Alternate-screen confirmation remains a product walk-around, especially for
vc-frame and zellij key-routing combinations.

The CLI reads the same committed Transcript Bus. `codescribe transcribe live`
owns the canonical Rust wake/projection path; `bus-demux.py` is a named-agent
routing adapter, not another transcript reducer. For an editable shell prompt,
`scripts/codescribe.zsh` inserts `codescribe transcribe last` literally through
ZLE without appending Enter. That explicit line-editor path complements UI
Insert and does not create a second text authority.

## What this cut does not do

- It does not pick the transcript (Apple / Whisper / final-pass). That is
  `adjudicate_recording_truth`.
- It does not lock the microphone. That is still a missing `RecordingSessionOwner`.
- It does not make the agent chain mandatory. `previous_response_id` stays
  best-effort until that throne is cut.

Stacked on `fix/engine-routing`.
