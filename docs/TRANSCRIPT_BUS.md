# Clean Transcript Bus

Codescribe publishes one private, append-only NDJSON stream. The Bus observes
session lifecycle plus occurrence-authenticated `TranscriptRevision` entries;
it does not own a transcript document and accepts no arbitrary product text.
Dictation, Agent, and Assistive share the same capture and ledger authority.
Mode changes only the downstream delivery consumer.

This Bus never opens a microphone, scrapes SwiftUI, re-transcribes audio,
folds raw engine events, or reconstructs text from overlay deltas. It can copy
the ledger's seal-coverage receipt and historical optional comparison
receipts; neither gives the Bus mutation authority. Under the
[2026-09-08 amendment](SEAL_COVERAGE_AMENDMENT_2026-09-08.md), current normal
stop repairs exact uncovered PCM from the owned archive, drains newly scheduled
occurrence formatter work, then publishes final coverage and the terminal seal.
It does not produce an automatic whole-document comparison.

## Path contract

Resolution order:

1. `CODESCRIBE_TRANSCRIPT_BUS_PATH`
2. `$XDG_STATE_HOME/codescribe/transcript-events.jsonl`
3. `$CODESCRIBE_DATA_DIR/transcript-events.jsonl`, with the normal default of
   `~/.codescribe/transcript-events.jsonl`

The parent directory is created when needed. On Unix the file is forced to
mode `0600`. Each attempted append includes a flush before publication returns.
No host, date, room, or control-plane path is embedded in Codescribe.

### Persistence loss and live publication

The file is an observability sink, not admission authority for live text.
Production `TranscriptBus::open` retains a functional Bus even when opening the
file fails. `open_at` remains the explicit fallible file-opening API; production
uses its result through the same `open_with_path` fallback exercised by the local
failure fixtures. Start, authenticated revision and end publication advance live
state independently of append success. Failed revision writes still return every
authenticated entry and replace the existing last-projection snapshot. Failed end
writes still return exactly one lifecycle terminal with the exact committed bytes,
occurrence receipts and controller-owned delivery disposition. A duplicate end
returns no projection, including after persistence recovers.

`sequence` orders in-process publication within one Bus session. It advances for
attempted lifecycle and evidence publication, including failed persistence. On the
successful path persisted rows carry these same numbers. A callback's sequence
does **not** prove a matching file row, receiver admission or durable storage.
Even successful `File::flush` is not an fsync/power-loss durability receipt.
`ComposerPending` remains pending; file success or failure never manufactures
`SinkAccepted`. The existing composer receipt/recovery path receives the same
terminal payload; the Bus adds no second delivery authority.

On the first open, serialization, append or flush failure, persistence is disabled
for that Bus's lifetime. The existing tracing diagnostic records the session,
filename, error and `persistence=disabled_for_session`. Live projection continues.
There is no retry queue, payload journal, second reducer or fallback transcript
file: retention is the existing single last-projection snapshot, replaced by the
next committed projection. Process exit can lose unpersisted text. The UI has no
typed persistence indicator in the current bridge contract; failure is discoverable
in logs, and the visible document is live reducer truth, not a saved-file claim.
A dedicated UI persistence warning would require an explicit bridge/status and
Swift consumer extension; neither a display label nor delivery state encodes it.

An append may leave a prefix; a failed flush may leave a complete row. The Bus
never retries either and never reuses its sequence. A later session attempts a new
open with fresh lifecycle and no prior document. If the existing nonempty file
does not end in a newline, opening it fails explicitly and the new live Bus remains
usable without appending to that incomplete row. It neither truncates evidence nor
adds a newline that would pretend the partial row was valid. After explicit
external repair/rotation, a subsequent session can persist normally. A complete
row left by uncertain flush needs no replay; a later session may append after it.
This is not cross-process append locking or automatic damaged-log repair.

External tailers can therefore have an incomplete prefix of a session, an
unterminated final row, or no rows for a live session. They cannot reconstruct
missing bytes or infer successful delivery/idle state from that absence. Existing
install guards may conservatively refuse a stale unmatched start; this Bus cut
does not change installation or repair an external consumer's lifecycle policy.

## Event families

App `codescribe.transcript.v1` rows carry lifecycle only. `publish_started` emits
one empty `session_started` event for the controller-owned session, and
`publish_ended` emits one empty `session_ended` event when the controller
leaves that session (every path back to Idle, including zero-seal takes and
stop-timeout recovery). Neither can publish document text. The terminal row
does carry the already-resolved projection phase and action availability so a
file tailer can combine it with the last authenticated render without inventing
UI policy.

CLI file rows use the same schema with `source=cli_file_verdict`. Draft rows
retain per-segment `text` and supply an engine-assembled `rendered_text` snapshot;
seals supply the exact final document. Readers copy snapshots without joining
segments. Legacy CLI seals already carry the full document in `text`.
`session_ended` preserves the preceding document. CLI projections retain their
source and never claim occurrence or acoustic ledger receipts.

One microphone: the live app take is the most recently started app session
that has no later `session_ended` (or legacy `transcript_sealed`) for that
same `session_id`. Historical `session_started` rows without terminals are
abandoned takes — crash residue or buses written before the controller
always published an end — not a live recording.
`scripts/install-if-idle.sh` keys on that current pair, plus any unpaired
`source=cli_file_verdict` session (the CLI does not hold the install flock),
and on the agent-turn lease (`~/.codescribe/agent-turn.lock`, held shared by
the app for the whole turn). A merely running app does not refuse install
(Founder, 2026-09-08); the process-lifetime runtime lock only stops a _new_
app start while an idle-time install is copying the bundle. Never tear down
the app mid-take or mid-turn; never refuse install forever because an old
session lacked an end line.

`session_ended` carries one typed `end_reason` (`TranscriptSessionEndReason`):
`completed` for a take whose serialized stop and transcript processing succeeded,
`start_superseded` when a key-up or reschedule invalidated a hold start after
`session_started` and before the take became an active recording, and
`start_failed` when the recorder could not be started after the session was
announced. App refusal, stop timeout, and forced recovery use
`transcription_failed`; returning the recorder to Idle does not imply transcript
success. CLI file sessions use `transcription_failed` when decoding or
stream output fails after publishing a draft; the partial text is never sealed
as a completed document. The controller has exactly one terminal publisher
(`end_transcript_bus`); the delayed hold start unwinds every pre-active exit
through `unwind_hold_start`, so no started session is left without its
terminal publication. Persistence failure can omit its file line as described
above. The first terminal publication wins; later calls are no-ops.

A product recording can only begin after **acoustic admission**: the
controller resolves the input device without opening it, requires a measured
`EnergyCalibration` profile for that device from the immutable settings
snapshot (`energy-calibration.json` beside `settings.json`, see
`core/config/energy_calibration.rs`) and an armed Silero seal lane
(`audio.seal_lane_armed`, default `true`). The optional power-user
`CODESCRIBE_SILERO_FUSION` env value overrides that field when present in
either direction. A refused start writes nothing to the Bus and opens no
microphone. It reaches the overlay as a typed
`codescribe.presentation-status.v1` projection with kind
`admission_refused`, one actionable `admission_*` code, and Rust-owned display
copy. Guided calibration publishes `calibration_succeeded` (including the new
profile version) or `calibration_failed` through the same IPC/listener lane.
These passive status cards are not Bus rows and carry no occurrence, reducer,
or acoustic receipt fields.

`codescribe.transcript-evidence.v1` is the committed projection family. Every
line is created only by `TranscriptBus::publish_revision(revision, ledger)` and
contains:

- Bus `sequence` and `emitted_at` metadata;
- controller `session_id` and `mode`;
- reducer revision, action, document index, complete `rendered_text`, and the
  entry label;
- exact occurrence identity: session, capture epoch, sample start, sample end;
- the matching acoustic serial plus word-evidence, layer-decision, seal, and
  manual-edit receipts copied from the ledger-owned reducer entry;
- optional per-entry `presentation_receipt` for new **and retained** Light+
  shapes, separate from acoustic decisions and human-edit receipts. It carries
  receipt/provenance/session, source and resulting revision, occurrence PCM
  coordinates, occurrence seal ID, source label, exact left context, its SHA-256,
  and shaped bytes. No field claims word-level timing for the shaped text.
- optional additive `seal_coverage` evidence: measured speech/covered sample
  counts, uncovered PCM ranges, ratio, threshold, and `complete|incomplete`;
- optional additive `comparison`: SHA-256, character count, and rendered text
  for the pre-repair Apple-lane document and the whole-session local Whisper
  pass (historical/diagnostic; absent on the current normal stop path).
  These fields remain inside `codescribe.transcript-evidence.v1`; older
  readers may ignore them and Rust decoding defaults them to absent.
- the complete canvas contract: `phase`, `can_paste`, `can_insert`,
  `can_copy`, `can_retranscribe`, `can_format`, and `terminal`.
- additive `lifecycle_terminal` and typed `delivery` on evidence projections.
  Revision rows use `false` and `unattempted`. The in-process `session_ended`
  projection uses `true` and the controller's disposition (`unattempted`,
  `composer_pending`, `sink_accepted`, or `retained`). Its text-free persisted
  lifecycle row remains `codescribe.transcript.v1` and does not carry these two
  fields. Reading that row is not proof of composer admission.

The projection contract is one snapshot, not a bag of Swift inputs:

| Field                               | Source of truth                                                                                                                                                                                                                                         |
| ----------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `reducer_revision`, `rendered_text` | Exact committed reducer revision                                                                                                                                                                                                                        |
| `phase`                             | `listening` for open book revisions, `finalizing` after a terminal ledger seal, then `formatted` or `no_speech` from `session_ended` plus the last committed render; a terminal user revision remains `formatted`; failed/superseded starts are `error` |
| `can_paste`                         | The delivery throne selects `ClipboardPaste`, a latched target exists, and the take has ended                                                                                                                                                           |
| `can_insert`                        | The delivery throne selects `ClipboardPaste` or `DeferredInsert`, and the take has ended                                                                                                                                                                |
| `can_copy`                          | The committed render is non-empty                                                                                                                                                                                                                       |
| `can_retranscribe`                  | The session WAV exists and the take has ended                                                                                                                                                                                                           |
| `can_format`                        | The take has ended and the committed render is non-empty                                                                                                                                                                                                |
| `terminal`                          | A terminal document revision or the controller's unique `session_ended` transition; a user/formatter revision can precede lifecycle end |
| `lifecycle_terminal`                | Only the controller's unique `session_ended` projection; document revisions never release capture ownership or consume the delivery obligation |

`resolve_delivery_route(OverlayInsert, ...)` remains the only destination
decision. The projection layer queries its result; it does not create another
paste policy. The controller snapshots the target before overlay focus can
replace it, and checks the session-owned WAV only after the stop path has had a
chance to retain it.

The Bus refuses the **whole revision** before any row or sequence mutation if
the reducer's publication validator rejects it. Validation binds the exact ordered
entries, action, rendered bytes and other snapshot fields to the private reducer
capability, then checks session, current ledger labels, seal references, and full
current/retained shaping receipts with their source revisions and left contexts.
Missing, fabricated, stale or altered evidence cannot authorize shaped bytes.
An older/equal reducer revision cannot republish rows. The Bus does not admit an
occurrence, choose a label, infer identity, perform text-tail matching, mint a
seal or render another document. `seal_coverage` is emitted before terminal finality. A terminal
`LedgerSeal` reducer action marks the writer sealed only when the latest
coverage is not incomplete. No arbitrary string can close committed Bus truth.

### Presentation provenance and serialization

The additive field remains inside `codescribe.transcript-evidence.v1`.
`ProjectedAcousticReceipt.presentation_receipt` is absent for legitimate plain
records and old records; deserialization preserves `None`. It never synthesizes
a receipt or treats absence as permission to shape. A present
`ProjectedPresentationReceipt` requires every field (including context bytes,
digest, source revision and source seal); malformed/incomplete objects refuse
decoding. Unknown fields inside that proof also refuse decoding. Older consumers
may ignore the additive outer field; they consequently have no Light+ proof.

Decoded observer JSON is not mutation authority. Only `TranscriptReducer` can
mint the private, non-serialized `TranscriptRevision` publication capability;
`publish_revision` accepts that type plus the live ledger, never decoded Bus
rows. Neither serialized receipt IDs nor the in-process digest constitute a
cryptographic signature authenticating an externally supplied log. Existing
trusted controller IPC transports the owner-produced JSON to the bridge; external
readers are observers of its provenance, not new admission authorities.

`CsProjectedPresentationReceipt` carries every field losslessly via
`CsProjectedAcousticReceipt.presentation_receipt`, with no new outer event.
The four non-generated Swift receipt constructors in ComposerDeliveryJoinTests,
OverlayRefusalLayoutHangTests and OverlayStateTests are adapted. Generated Swift
must be regenerated by W3 `make app-bindings`; checked-in generated code is not
updated by this W2 source checkpoint. The CLI projection reader remains a text
snapshot consumer and does not expose a full receipt audit surface.

Occurrence and terminal seal scopes are ledger-minted and have distinct IDs.
A one-occurrence terminal is still terminal. `EngineEvent::LedgerSeal` remains
an in-process, serde-skipped carrier, so no permissive old-JSON scope default
exists. `SessionFinalised` cannot fabricate a ledger seal. Presentation revisions
stay `lifecycle_terminal=false`, `delivery=unattempted`; only the controller's
unique lifecycle end carries destination disposition.

All new tests are UNRUN under W2. This schema description is source evidence,
not successful binding generation, installation or runtime delivery evidence.

### Terminal document revisions

The overlay canvas is read-only in every phase and displays the exact engine
projection, including empty text. Status messages and unfamiliar chrome phases
never replace or reject its document. A user-revision request sends
`session_id + source_revision + rendered_text` across FFI; it does not paint
Swift state. `TranscriptReducer::apply_user_revision` accepts only the
exact current terminal revision, and `AcousticLedger` appends a
`ManualDocumentRevisionReceipt` with `provenance=user-edit`, the source
occurrence/seal set, and the replacement bytes. A whole-document edit does not
invent new word-to-PCM alignment or rewrite any source acoustic receipt.

Rust then emits a new terminal `apply_manual_edit` evidence projection. The
projection carries the ledger's `user-edit-*` receipt in each source occurrence
row and is the only event that replaces the formatted canvas and delivery
buffer. It may follow `session_ended` because microphone lifecycle is already
closed. Replay accepts that terminal revision only for the just-ended session;
once a newer session is active, an older edit cannot displace it.

The Format dock command is the sibling route, not a second reducer. Rust reads
the exact current terminal document under the same `session_id + source_revision` CAS, runs `format_text_with_status_for_policy`, and admits only
an `Applied` result through `TranscriptReducer::apply_user_revision`. Its
`ManualDocumentRevisionReceipt` uses `provenance=formatter` and a
`formatter-*` receipt; the resulting Bus projection is the only canvas repaint.
`Failed`, `Skipped`, and `AiNoop` results return a visible refusal to Swift and
append no ledger, Bus, history, delivery-buffer, or Copy-last state.

Controller-authenticated context captures enter the same presentation reducer
as `RecordContextMarker` actions (`record_context_marker` on the Bus). The
reducer anchors each marker at the captured character position and renders it
into every later complete `rendered_text` revision, preserving capture order at
equal positions. Swift receives that finished projection verbatim; it does not
insert, pad, retain, or replay marker text.

### Receiver lifecycle and presentation guarantees

The overlay receiver keeps three things apart: the capture that is pending, the
previous take's authoritative document, and an unsent local draft. A new capture
is admitted on the controller's own `on_recording_preparing` /
`on_recording_started` callback while nothing is recording — never on a Bus
`session_started` row, because the consumer contract below forbids reading that
row as permission to mutate product state.

At that admission the receiver holds a monotonic, presentation-local capture
generation. It fences asynchronous UI work only: the terminal auto-hide wake, the
orphaned-"starting" watchdog, and the agent-handoff fade completion each capture
the generation they were armed under and refuse to act once it moved. The
generation cannot mint a session, an occurrence, a seal, a delivery
acknowledgement or acoustic evidence; those remain Rust-owned, and a UI counter
that named any of them would be exactly the forged authority this boundary
forbids.

A pending capture paints no previous speech and inherits no action capabilities:
phase, terminal flag, reducer revision and the five action bits are reset, and
the previous projection leaves the paint path. It is retired, not destroyed.

Superseded work has exactly one owner. Each superseded take is retained as a
single identity-associated unit — Rust's session id, the last projected
document, its reducer revision and the uncommitted draft that differed from it —
never as separate string and projection slots that a later capture can move
independently. A take with no observed projection has no identity and is
therefore not retained, rather than retained under one this receiver minted.
Delivery recovery still belongs to the composer store and the existing
retained-delivery documents, and no second transcript history store exists.

Retention is never implicitly evicted. No capture boundary, late event or
watchdog may drop an unsaved edit; only an explicit user decision resolves one.

Capacity is asymmetric, and the asymmetry is stated rather than dressed up as a
bound. Clean documents are genuinely capped at one, because each remains
authoritative in the ledger and reproducible from it. Unsaved edits have no
count limit. From this presentation fence the only two ways to impose one would
be discarding a user's edit, which is the silent loss the owner exists to
prevent, or refusing microphone admission, which is not this layer's decision to
make. So the store is bounded by the user's own unresolved decisions and not by
a constant, and the reported count is disclosure, not enforcement. That residual
capacity boundary is open and belongs to an owner outside this fence; it is not
closed by a second history store, and no receiver counter should be read as
closing it.

Recovery is reachable and explicit. The sole overlay action surface projects two
commands whenever retained work exists — recover and discard — and they are the
only commands on that rail sourced from local presentation state rather than the
reducer, because the bytes they protect are an edit Rust never saw. They are
offered independently of error mode, whose projection table is otherwise
`[close]` alone, and during a live capture the rail shows those labelled
commands only: the previous words never return to the canvas as current speech.
Recovery hands the retained bytes to the pasteboard, and consumes the retained
item only on a confirmed write. A refused write keeps the exact item — identity
and draft included — and surfaces the failure, because the alternative is
destroying the only copy of an edit at the precise moment the copy did not
happen. Recovery commits nothing to the reducer, mints no session, forges no
seal, submits no delivery and takes no focus. A scheduled draft commit for the superseded take is cancelled rather than
sent, so no revision request crosses FFI for a closed session while a new
capture is live.

Retiring a session also fences its late events, on both receiver paths. A
retired projection may still complete its own addressed delivery and capture
release, but it cannot repaint the successor's canvas, change its chrome,
finalize it, arm its countdown or close it. The sibling presentation-status path
is fenced by the same identity: a status for a known retired session leaves the
current capture, text, mode and countdown untouched and paints no card, while a
status addressed to the current capture still presents and still releases it.

Status identity has an explicit disposition, read off the producer rather than
guessed. `PresentationStatusProjection` carries `session_id: Option<String>` and
a typed `kind`. A non-retired session id — including one this receiver has never
observed — is addressed to the current capture, because the lifecycle callbacks
carry no session id at all and the sole producer of `admission_refused` emits it
from the start path of the take the user just asked for; a refusal with no
session id is that same capture verdict and still lands. The two calibration
outcomes carry no session by construction: they are Settings-owned microphone
results, so while a capture is in flight such a status paints its card but may
not end a take it cannot name. Ending it would be minting capture identity for
an event that has none.

Duplicate `preparing` / `started` beats for an open capture are idempotent: they
do not re-fence the take, erase already admitted text, or restart the session
clock. A `preparing` that repeats for a capture which already proved it is alive
— recorder confirmed, audio or speech measured, final pass begun, or text
admitted — additionally may not un-prove it. Regressing the warmup state there
re-armed the orphaned-"starting" watchdog against a live take, and because the
capture and its generation were unchanged the generation fence passed and the
wake aborted a capture the user was still speaking into. Warmup is the only
state that watchdog may dismiss, so a genuine first warmup timeout — including
one whose `preparing` was itself duplicated before any audio arrived — still
recovers.

Visibility follows the current capture route plus the explicit overlay
preference. An enabled Dictation take stays visible through measured silence; an
explicit overlay-off runs headless; a genuine Agent/Assistive route stays hidden;
and showing the panel never takes key or main focus. There is no always-show
shortcut and no disabled animation.

One seam is not closable inside the receiver. `CsTrayStatusPayload`
(`bridge/src/tray_status.rs`) carries `kind`, `tone`, `indicator_mode`,
`assistive`, `tooltip`, `menu_label` and a monotonic tray `generation`, but no
session or capture identity. `TrayStatusStore` already refuses non-monotonic
ticks, so ordering is sound; what the payload cannot express is whether a current
`assistive` reading belongs to the live capture or to a different route. The
documented mid-hold `Fn` → `Fn+Shift` upgrade is delivered on exactly that tick,
so the receiver honours it and does not guess. Binding a tray tick to a capture
requires capture identity on the producer side; until then this is a stated
boundary, not an inferred hide cause. The lifecycle callbacks are identity-less
for the same reason: `on_recording_preparing` / `on_recording_started` carry no
session id, so a projection for a session the receiver has never observed cannot
be classified as predecessor or successor by presentation alone.

These guarantees are source contracts authored under W2. The Swift tests that
state them are UNRUN, and no binding generation, install or runtime reproduction
is claimed here.

## Authority boundary

```text
OccurrenceIdentity + AcousticLedger receipts
  → TranscriptReducer.document_by_occurrence
  + controller-authenticated context markers
  + terminal user revision receipt (source session + reducer revision)
  → TranscriptRevision
  → TranscriptBus::publish_revision
  → CsTranscriptProjectionEvent
  → OverlayState.applyTranscriptProjection

session_ended + last committed Bus render + delivery/audio snapshot
  → the same CsTranscriptProjectionEvent (`terminal=true`)

controller admission / calibration outcome
  → PresentationStatusProjection (not a Transcript Bus row)
  → CsPresentationStatusEvent
  → OverlayState.applyPresentationStatus
```

`EngineEvent::Preview` is ephemeral overlay paint. Raw `UtteranceFinal`,
`Correction`, `ReplaceRange`, and `InsertAnnotation` events are observation or
diagnostics. `Stats` and `SessionFinalised` are lifecycle. None can enter Bus
truth, delivery, history, clipboard, final controller text, or a terminal seal.
Lane and transport errors remain `Warning` / presentation-status / log
evidence. The session archive accepts a typed `Committed`, `NoSpeech`, or
`Unavailable` outcome: only `Committed` writes copyable user text;
`Unavailable` writes no transcript artifact, and `NoSpeech` has the fixed
history title `(no speech)`. Diagnostic strings are never history titles or
"Copy last transcript" candidates.

There is no Bus draft API, reducer draft storage, arbitrary-text
`publish_sealed` API, or raw-event `DeltaSinkAdapter`. The overlay's editor
state is ephemeral and cannot reach delivery. Consumers must observe the
authenticated evidence projection rather than reduce engine text themselves.

## Consumer contract

An external consumer follows the resolved path with an ordinary NDJSON tailer:

```bash
tail -F "$HOME/.codescribe/transcript-events.jsonl"
```

That is the non-XDG default. With `XDG_STATE_HOME` set, follow
`$XDG_STATE_HOME/codescribe/transcript-events.jsonl`; an explicit bus-path
override wins over both. A consumer must tolerate both schemas and must not
interpret `session_started` or raw IPC events as permission to mutate product
state.

Named-agent demultiplexing remains a read-only observer over this same file; it
never opens audio or changes transcript text. State change is permitted only by
the downstream consumer of a ledger-authenticated projection, never by a draft
or preview envelope.

Each Bus `session_id` owns one wav at `~/.codescribe/sessions/<session_id>.wav`
(or `$CODESCRIBE_DATA_DIR/sessions/<session_id>.wav`). The controller copies
the take there at stop. `bus-demux` assigns that path onto every envelope for
the session. It must not read or emit `last_session.wav`: that file is only the
latest-take alias for overlay Retranscribe and `codescribe transcribe last`.
Hold and toggle/double-tap both land in the same daily bag
`~/.codescribe/transcriptions/YYYY-MM-DD/` (paired m4a/wav + txt). The agent
follower is a session observer of that bag, not a second archive.

`codescribe transcribe live` uses the shared Rust projection reader. The
default stdout is the human canvas view: an extending revision appends only
its suffix to the open line, a non-extending reducer rewrite closes the line
and marks `⟲ rev N` with the full new render, and a terminal seal closes the
take as a permanent `⏺ sealed` block carrying the session, revision, and PCM
sample range. `--json` switches to the machine contract:
`codescribe.transcript-projection.v1` JSONL to stdout. Every output row is an
exact full `rendered_text` snapshot with `kind=live_revision|terminal_seal` and
the source session, sequence, reducer revision/action, occurrence coordinates,
document index, phase, five action bits, and terminal flag. Consumers replace
their displayed snapshot when metadata is newer; stdout never pretends that a
textual suffix can encode a replacement. A text-free `session_ended` row emits
one terminal projection by combining its control fields with the last committed
render for that session; old rows without the additive fields retain the same
deterministic formatted/no-speech fallback. On macOS the follower wakes from
kqueue vnode events; a bounded timeout exists only to recover from a missed
rotation/replacement watch.

## File CLI and Finder

`codescribe transcribe --no-bus recording.wav second.m4a` decodes files in
order through the process-owned Whisper singleton. One failed file does not
prevent later files from running; the batch exits nonzero if any file fails.
Use `--no-bus` for archive batches that should not replace Copy-last.

`--stream` prints and flushes newly admitted segments after each decode window,
before starting the next window. These are file-verdict drafts, not live
microphone observations. Overlapping windows use the same timestamp assembly
as non-streaming transcription. The final text is not printed a second time;
if final lexicon processing changes it, a `⟲ final:` line explicitly replaces
the draft. Without `--stream`, stdout contains only the final transcript.
Warnings and file/provenance headers go to stderr. Streaming does not remove
decode-window latency or make decoder tokens into committed transcript text.

Run `scripts/install-finder-quick-action.sh` to install **Transcribe with
Codescribe** in Finder's Quick Actions menu. It uses the installed CLI with
`--no-bus`, writes a sibling `.txt`, and copies successful results to the
clipboard. Existing output files are preserved and reported as failures.
Failed decodes leave no partial `.txt`, and other selected files continue.

## C11 evidence boundary

`484095ce` was the last executable-code cut before documentation successor
`d57196ab`. C11 is the next structural executable cut; its actual commit hash is
recorded only in the durable C11 report. Compiler, tests, runtime, app, install,
and release behavior are `NOT_ASSESSED` under the C11 embargo.
