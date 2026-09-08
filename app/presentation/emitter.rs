//! Event-driven presentation emitter.
//!
//! Converts `EngineEvent`s into user-facing output through the one canonical
//! reducer and an ordered delta-delivery worker.
//!
//! Uses an ordered mpsc channel to guarantee that target updates and finish
//! arrive in the exact order they were emitted,
//! eliminating the fire-and-forget tokio::spawn ordering race.

use std::{collections::BTreeMap, io::Write as _, sync::Arc};

use codescribe_core::llm::ai_formatting::{AiFormatResult, AiFormatStatus};
use codescribe_core::llm::inline_format::{LabelProposalDisposition, OccurrenceLabelProposal};
use codescribe_core::pipeline::acoustic_ledger::{
    AcousticLedger, AcousticSerial, DocumentRevisionProvenance, LedgerSealReceipt,
    ManualDocumentRevisionReceipt, MutationReceipt, ObservationIdentity, ObservationProducer,
    OccurrenceIdentity, SealCoverageReceipt, SealCoverageStatus, TranscriptComparisonReceipt,
};
use codescribe_core::pipeline::contracts::{DeltaSink, EngineEvent, EventSink, TranscriptDelta};
use tokio::sync::Mutex;
use tracing::{debug, info};

use super::transcript_bus::{TranscriptBus, TranscriptBusEvidenceEvent};

/// Commands sent through the ordered channel to the emitter worker.
enum EmitterCmd {
    /// Publish ledger-authenticated text to both overlay paint and delivery.
    PublishCommittedRevision(String),
    /// Paint volatile text without touching delivery or any committed sink.
    PaintEphemeralPreview(String),
    Finish,
}

fn append_stream_delta(path: &std::path::Path, delta: &str) -> std::io::Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let mut file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)?;
    let timestamp = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true);
    let payload = delta
        .replace('\n', "\\n")
        .replace('\r', "\\r")
        .replace('\u{0008}', "\\b");
    writeln!(file, "[{timestamp}] {payload}")
}

/// One canonical transcript slot, keyed only by the physical occurrence that
/// earned it. Text is a ledger-authorized label; receipt values are immutable
/// provenance references and never participate in entry identity.
///
/// W2 input: one admitted ledger decision for `occurrence`. W2 output: this
/// entry inside a [`TranscriptRevision`]. Formatter proposals re-enter through
/// `EngineEvent::OccurrenceLabelProposal`; delivery consumes the decided route.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TranscriptDocumentEntry {
    pub occurrence: OccurrenceIdentity,
    pub label: String,
    pub observation_receipt: String,
    pub word_evidence_receipts: Vec<String>,
    pub layer_decision_receipts: Vec<String>,
    pub seal_receipt: Option<String>,
    pub manual_edit_receipt: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct DocumentContextMarker {
    position: usize,
    label: String,
    order: usize,
}

/// A ledger-authorized document transition. Every variant names a physical
/// occurrence; no action locates content by comparing transcript strings.
///
/// W2 must construct these actions from ledger receipts. W1 deliberately does
/// not expose an `apply` path, so no engine, Bus, bridge, or Swift caller can
/// mutate the document through this declaration alone.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ReducerAction {
    ApplyLedgerDecision {
        entry: TranscriptDocumentEntry,
    },
    RecordLedgerSeal {
        occurrence: OccurrenceIdentity,
        seal_receipt: String,
        terminal: bool,
    },
    RecordSealCoverage {
        receipt: SealCoverageReceipt,
        comparison: Option<TranscriptComparisonReceipt>,
    },
    ApplyManualEdit {
        entry: TranscriptDocumentEntry,
    },
    ApplyUserRevision {
        receipt: ManualDocumentRevisionReceipt,
    },
    RecordContextMarker {
        position: usize,
        label: String,
        order: usize,
    },
}

/// Immutable reducer output for observers and explicit delivery selection.
/// `entries` is the complete occurrence-ordered document at `revision`.
///
/// W2 output: `TranscriptBus` observation, the single formatter proposal path,
/// and `delivery_route`. Those consumers are intentionally unresolved in W1;
/// this file is the only owner of the revision and its document entries.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TranscriptRevision {
    pub schema: String,
    pub revision: u64,
    pub action: ReducerAction,
    pub entries: Vec<TranscriptDocumentEntry>,
    pub rendered_text: String,
    pub seal_coverage: Option<SealCoverageReceipt>,
    pub comparison: Option<TranscriptComparisonReceipt>,
}

/// A UI request to replace one exact terminal reducer revision.
///
/// The source session and revision form the compare-and-swap boundary. Text is
/// payload only: it never identifies the document or an acoustic occurrence.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UserRevisionIntent {
    pub session_id: String,
    pub source_revision: u64,
    pub rendered_text: String,
    pub provenance: DocumentRevisionProvenance,
}

/// Rust-authored acknowledgement for one committed user revision. Swift uses
/// this only as request status; visible text still arrives through projection.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UserRevisionCommit {
    pub session_id: String,
    pub source_revision: u64,
    pub revision: u64,
    pub rendered_text: String,
    pub provenance_receipt: String,
}

/// Typed refusal reasons for a stale or unauthenticated revision request.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum UserRevisionRefusal {
    EmptyText,
    NoCommittedDocument,
    NotTerminal,
    SessionMismatch,
    StaleRevision { expected: u64, actual: u64 },
    Unchanged,
    RevisionExhausted,
    LedgerRefusal(&'static str),
    AuthorityUnavailable,
    FormatterFailed,
    FormatterUnavailable,
    FormatterNoop,
}

impl std::fmt::Display for UserRevisionRefusal {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::EmptyText => formatter.write_str("user revision text is empty"),
            Self::NoCommittedDocument => formatter.write_str("no committed transcript document"),
            Self::NotTerminal => formatter.write_str("transcript is not terminal"),
            Self::SessionMismatch => formatter.write_str("user revision session does not match"),
            Self::StaleRevision { expected, actual } => write!(
                formatter,
                "stale user revision: source {actual}, current {expected}"
            ),
            Self::Unchanged => formatter.write_str("user revision is unchanged"),
            Self::RevisionExhausted => formatter.write_str("transcript revision counter exhausted"),
            Self::LedgerRefusal(reason) => {
                write!(formatter, "ledger refused user revision: {reason}")
            }
            Self::AuthorityUnavailable => {
                formatter.write_str("transcript revision authority unavailable")
            }
            Self::FormatterFailed => formatter.write_str("formatter gateway failed"),
            Self::FormatterUnavailable => {
                formatter.write_str("formatter is unavailable for the current policy or text")
            }
            Self::FormatterNoop => formatter.write_str("formatter returned unchanged text"),
        }
    }
}

impl std::error::Error for UserRevisionRefusal {}

/// The one committed Rust document plus explicitly non-authoritative UI paint.
/// Only `document_by_occurrence` can produce a committed revision. The preview
/// field is volatile, has no occurrence identity, and is discarded at terminal
/// boundaries without ever entering the Transcript Bus or delivery buffer.
#[derive(Debug, Default)]
pub struct TranscriptReducer {
    /// Canonical document ordered by the PCM-backed occurrence key. W2 alone
    /// connects authenticated ledger actions and emits revisions from it.
    document_by_occurrence: BTreeMap<OccurrenceIdentity, TranscriptDocumentEntry>,
    revision: u64,
    ephemeral_preview: String,
    latest_seal_coverage: Option<SealCoverageReceipt>,
    latest_comparison: Option<TranscriptComparisonReceipt>,
    context_markers: Vec<DocumentContextMarker>,
    manual_rendered_text: Option<String>,
    manual_document_revision_receipt: Option<String>,
    terminal: bool,
}

/// Trim a fragment's outer edges. Interior whitespace and newlines survive —
/// the renderer receives markdown, so collapsing them would flatten structure.
fn normalize_transcript_fragment(text: &str) -> String {
    text.trim().to_string()
}

/// Append a fragment to the rendered buffer, inserting a single separating
/// space only when one is actually needed. Empty fragments are skipped, so a
/// blank preview cannot leave trailing whitespace on the canvas.
fn append_rendered_fragment(rendered: &mut String, fragment: &str) {
    let normalized = normalize_transcript_fragment(fragment);
    if normalized.is_empty() {
        return;
    }

    if !rendered.is_empty() && !rendered.ends_with(char::is_whitespace) {
        rendered.push(' ');
    }
    rendered.push_str(&normalized);
}

impl TranscriptReducer {
    fn encode_serial(serial: &AcousticSerial) -> String {
        format!(
            "v{}:{}:{}:{}:{}:{}",
            serial.version,
            serial.digest,
            serial.occurrence.session,
            serial.occurrence.capture_epoch,
            serial.occurrence.sample_start,
            serial.occurrence.sample_end,
        )
    }

    fn revision_for_action(&mut self, action: ReducerAction) -> TranscriptRevision {
        self.revision = self.revision.saturating_add(1);
        let mut entries = self
            .document_by_occurrence
            .values()
            .cloned()
            .collect::<Vec<_>>();
        if let Some(receipt) = &self.manual_document_revision_receipt {
            for entry in &mut entries {
                entry.manual_edit_receipt = Some(receipt.clone());
            }
        }
        let rendered_text = self.committed_rendered_text();
        TranscriptRevision {
            schema: "codescribe.transcript-revision.v1".to_string(),
            revision: self.revision,
            action,
            entries,
            rendered_text,
            seal_coverage: self.latest_seal_coverage.clone(),
            comparison: self.latest_comparison.clone(),
        }
    }

    /// Apply only the mutation authority granted by the shared ledger. An
    /// unsigned or unqualified occurrence fails closed and creates no document
    /// entry, even when an engine supplied visible text.
    pub fn apply_ledger_mutation(
        &mut self,
        ledger: &AcousticLedger,
        observation: &ObservationIdentity,
        receipt: &MutationReceipt,
    ) -> Option<TranscriptRevision> {
        if !receipt.grants_mutation() || !ledger.is_qualified(&observation.occurrence) {
            return None;
        }
        let serial = ledger.serial_of(&observation.occurrence)?;
        let composition = ledger.compose(&observation.occurrence).ok()?;
        let trail = ledger
            .layer_trail_for(&observation.occurrence)
            .filter(|decision| decision.is_evidence_backed())
            .map(|decision| decision.receipt_id.clone())
            .collect::<Vec<_>>();
        if trail.is_empty() || composition.tokens.is_empty() {
            return None;
        }
        self.manual_rendered_text = None;
        self.manual_document_revision_receipt = None;
        let entry = TranscriptDocumentEntry {
            occurrence: observation.occurrence.clone(),
            label: ledger.text_of(&observation.occurrence)?.to_string(),
            observation_receipt: format!(
                "{}:{}:{}:{}",
                observation.producer.as_str(),
                observation.request,
                observation.generation,
                receipt.as_str(),
            ),
            word_evidence_receipts: composition
                .tokens
                .iter()
                .map(|token| {
                    format!(
                        "{}:{}:{}",
                        token.token_ordinal,
                        token.token,
                        token.cited_digests().collect::<Vec<_>>().join(","),
                    )
                })
                .collect(),
            layer_decision_receipts: trail,
            seal_receipt: ledger
                .seal_of(&observation.occurrence)
                .map(|seal| seal.receipt_id.clone()),
            manual_edit_receipt: ledger
                .manual_edits()
                .iter()
                .rev()
                .find(|edit| edit.occurrence == observation.occurrence)
                .map(|edit| edit.receipt_id.clone()),
        };
        let _serial_receipt = Self::encode_serial(serial);
        self.document_by_occurrence
            .insert(observation.occurrence.clone(), entry.clone());
        let action = if observation.producer == ObservationProducer::ManualHuman {
            ReducerAction::ApplyManualEdit { entry }
        } else {
            ReducerAction::ApplyLedgerDecision { entry }
        };
        Some(self.revision_for_action(action))
    }

    /// Project ledger-owned finality; the reducer does not decide whether the
    /// frontier is closed and cannot lift the seal later.
    pub fn apply_ledger_seal(&mut self, receipt: &LedgerSealReceipt) -> Option<TranscriptRevision> {
        if !receipt.is_occurrence_seal()
            && self
                .latest_seal_coverage
                .as_ref()
                .is_some_and(|coverage| coverage.status == SealCoverageStatus::Incomplete)
        {
            return None;
        }
        for occurrence in &receipt.sealed_occurrences {
            if let Some(entry) = self.document_by_occurrence.get_mut(occurrence) {
                entry.seal_receipt = Some(receipt.receipt_id.clone());
            }
        }
        let occurrence = receipt.sealed_occurrences.first()?.clone();
        let terminal = !receipt.is_occurrence_seal();
        if terminal {
            self.terminal = true;
        }
        Some(self.revision_for_action(ReducerAction::RecordLedgerSeal {
            occurrence,
            seal_receipt: receipt.receipt_id.clone(),
            terminal: !receipt.is_occurrence_seal(),
        }))
    }

    /// Commit a whole-document user edit without fabricating per-word acoustic
    /// ownership. The ledger authenticates the exact sealed source occurrence
    /// set, then this reducer mints the only new document revision.
    pub fn apply_user_revision(
        &mut self,
        ledger: &mut AcousticLedger,
        intent: &UserRevisionIntent,
    ) -> Result<TranscriptRevision, UserRevisionRefusal> {
        if intent.rendered_text.trim().is_empty() {
            return Err(UserRevisionRefusal::EmptyText);
        }
        let source_occurrences =
            self.authenticated_revision_occurrences(&intent.session_id, intent.source_revision)?;
        if self.committed_rendered_text() == intent.rendered_text {
            return Err(UserRevisionRefusal::Unchanged);
        }
        let revision = self
            .revision
            .checked_add(1)
            .ok_or(UserRevisionRefusal::RevisionExhausted)?;
        let receipt = ledger
            .record_manual_document_revision(
                &intent.session_id,
                intent.source_revision,
                revision,
                &intent.rendered_text,
                &source_occurrences,
                intent.provenance,
            )
            .map_err(UserRevisionRefusal::LedgerRefusal)?;
        self.manual_rendered_text = Some(intent.rendered_text.clone());
        self.manual_document_revision_receipt = Some(receipt.receipt_id.clone());
        Ok(self.revision_for_action(ReducerAction::ApplyUserRevision { receipt }))
    }

    fn authenticated_revision_occurrences(
        &self,
        session_id: &str,
        source_revision: u64,
    ) -> Result<Vec<OccurrenceIdentity>, UserRevisionRefusal> {
        if self.document_by_occurrence.is_empty() {
            return Err(UserRevisionRefusal::NoCommittedDocument);
        }
        if !self.terminal {
            return Err(UserRevisionRefusal::NotTerminal);
        }
        if source_revision != self.revision {
            return Err(UserRevisionRefusal::StaleRevision {
                expected: self.revision,
                actual: source_revision,
            });
        }
        let source_occurrences = self
            .document_by_occurrence
            .keys()
            .cloned()
            .collect::<Vec<_>>();
        if source_occurrences
            .iter()
            .any(|occurrence| occurrence.session != session_id)
        {
            return Err(UserRevisionRefusal::SessionMismatch);
        }
        Ok(source_occurrences)
    }

    /// Return the exact current terminal document after authenticating the
    /// session/revision compare-and-swap boundary. This is read-only formatter
    /// input and cannot mint a ledger or Bus event.
    pub fn terminal_revision_source(
        &self,
        session_id: &str,
        source_revision: u64,
    ) -> Result<String, UserRevisionRefusal> {
        self.authenticated_revision_occurrences(session_id, source_revision)?;
        Ok(self.committed_rendered_text())
    }

    /// The Light+ revision this terminal document is owed, or `None` when
    /// there is nothing to shape: no committed document, not yet terminal, or
    /// the shaped text is byte-identical (Light+ is idempotent, so a second
    /// pass — or a document a formatter already shaped — mints nothing).
    /// Read-only: the intent enters the same corridor as a user edit.
    pub fn light_plus_intent(&self) -> Option<UserRevisionIntent> {
        if !self.terminal {
            return None;
        }
        let session_id = self.document_by_occurrence.keys().next()?.session.clone();
        let source = self.committed_rendered_text();
        if source.trim().is_empty() {
            return None;
        }
        let shaped = codescribe_core::pipeline::light_plus::apply(&source);
        if shaped == source {
            return None;
        }
        Some(UserRevisionIntent {
            session_id,
            source_revision: self.revision,
            rendered_text: shaped,
            provenance: DocumentRevisionProvenance::LightPlus,
        })
    }

    /// Open terminal review only after the engine lifecycle has finished. This
    /// carries no text and mints no reducer revision; it closes the one-
    /// occurrence ambiguity where a whole-session seal has the same physical
    /// coverage shape as its sole occurrence seal.
    fn mark_terminal_lifecycle(&mut self) {
        self.terminal = true;
    }

    /// Record ledger-computed session coverage without changing a single
    /// document entry. The next terminal seal projects the same immutable
    /// receipt and is refused above while it remains incomplete.
    pub fn apply_seal_coverage(
        &mut self,
        receipt: &SealCoverageReceipt,
        comparison: Option<&TranscriptComparisonReceipt>,
    ) -> TranscriptRevision {
        self.latest_seal_coverage = Some(receipt.clone());
        if let Some(comparison) = comparison {
            self.latest_comparison = Some(comparison.clone());
        }
        self.revision_for_action(ReducerAction::RecordSealCoverage {
            receipt: receipt.clone(),
            comparison: comparison.cloned(),
        })
    }

    /// The sole automatic author may relabel only an occurrence the ledger
    /// already holds. The producer must have launched and scheduled its
    /// exact occurrence before this return arrives; the reducer never turns an
    /// unsolicited proposal into its own authority. Only the ledger receipt
    /// reaches the document. The boolean is true only when this call returned
    /// that exact open Formatter slot; the event handler may seal only then.
    pub fn apply_occurrence_label_proposal(
        &mut self,
        ledger: &mut AcousticLedger,
        proposal: &OccurrenceLabelProposal,
    ) -> (bool, Option<TranscriptRevision>) {
        if !proposal.binds_real_samples() {
            return (false, None);
        }
        let occurrence = OccurrenceIdentity::new(
            proposal.session.clone(),
            proposal.capture_epoch,
            proposal.sample_start,
            proposal.sample_end,
        );
        if !ledger.is_qualified(&occurrence) || ledger.text_of(&occurrence).is_none() {
            return (false, None);
        }
        let formatter_is_open = ledger.frontier_of(&occurrence).is_some_and(|frontier| {
            frontier
                .open_producers()
                .contains(&ObservationProducer::Formatter)
        });
        if !formatter_is_open {
            return (false, None);
        }
        if proposal.disposition != LabelProposalDisposition::Propose {
            let _ = ledger.note_frontier_return(&occurrence, ObservationProducer::Formatter);
            return (true, None);
        }
        let candidate_label = proposal.proposed_label.trim();
        if candidate_label.is_empty() {
            let _ = ledger.note_frontier_return(&occurrence, ObservationProducer::Formatter);
            return (true, None);
        }
        let observation = ObservationIdentity::new(
            ObservationProducer::Formatter,
            self.revision.saturating_add(1),
            self.revision.saturating_add(1),
            occurrence,
        );
        let receipt = ledger.admit(&observation, candidate_label);
        let _ =
            ledger.note_frontier_return(&observation.occurrence, ObservationProducer::Formatter);
        (
            true,
            self.apply_ledger_mutation(ledger, &observation, &receipt),
        )
    }

    /// Record one controller-authenticated context reference. The captured
    /// position is applied to every later document render, so an early marker
    /// remains anchored as preceding occurrences arrive.
    pub fn record_context_marker(
        &mut self,
        position: usize,
        label: &str,
    ) -> Option<TranscriptRevision> {
        let label = label.trim();
        if label.is_empty() {
            return None;
        }
        let order = self.context_markers.len();
        self.context_markers.push(DocumentContextMarker {
            position,
            label: label.to_string(),
            order,
        });
        Some(
            self.revision_for_action(ReducerAction::RecordContextMarker {
                position,
                label: label.to_string(),
                order,
            }),
        )
    }

    fn committed_rendered_text(&self) -> String {
        if let Some(text) = &self.manual_rendered_text {
            return text.clone();
        }
        let rendered = self
            .document_by_occurrence
            .values()
            .map(|entry| entry.label.trim())
            .filter(|label| !label.is_empty())
            .collect::<Vec<_>>()
            .join(" ");
        render_context_markers(&rendered, &self.context_markers)
    }

    fn set_ephemeral_preview(&mut self, text: &str) {
        self.ephemeral_preview = normalize_transcript_fragment(text);
    }

    fn clear_ephemeral_preview(&mut self) {
        self.ephemeral_preview.clear();
    }

    fn ephemeral_visual_text(&self) -> String {
        let mut rendered = self.committed_rendered_text();
        append_rendered_fragment(&mut rendered, &self.ephemeral_preview);
        rendered
    }
}

fn render_context_markers(text: &str, markers: &[DocumentContextMarker]) -> String {
    let mut rendered = text.to_string();
    let mut ordered = markers.to_vec();
    ordered.sort_by(|left, right| {
        right
            .position
            .cmp(&left.position)
            .then_with(|| right.order.cmp(&left.order))
    });
    for marker in ordered {
        let chars = rendered.chars().collect::<Vec<_>>();
        let offset = marker.position.min(chars.len());
        let previous = offset.checked_sub(1).and_then(|index| chars.get(index));
        let next = chars.get(offset);
        let splits_word = previous.is_some_and(|ch| ch.is_alphanumeric())
            && next.is_some_and(|ch| ch.is_alphanumeric());
        let leading_space = !splits_word && previous.is_some_and(|ch| !ch.is_whitespace());
        let trailing_space = !splits_word && next.is_some_and(|ch| !ch.is_whitespace());
        let insertion = format!(
            "{}{}{}",
            if leading_space { " " } else { "" },
            marker.label,
            if trailing_space { " " } else { "" }
        );
        let byte_offset = rendered
            .char_indices()
            .nth(offset)
            .map_or(rendered.len(), |(index, _)| index);
        rendered.insert_str(byte_offset, &insertion);
    }
    rendered
}

/// Presentation emitter — the single reducer and ordered delivery writer.
///
/// Implements `EventSink` so it can be plugged directly into `transcription_session`.
/// Observer of one committed Bus projection.
///
/// Named because this is an authority-bearing role, not an anonymous closure
/// slot: it is invoked only after an occurrence-authenticated ledger receipt
/// has already produced a committed revision, never on preview paint. The
/// controller publishes the terminal copy separately after `session_ended`;
/// that copy reads this same Bus book and never re-enters the reducer.
pub type ProjectionObserver = Arc<dyn Fn(&TranscriptBusEvidenceEvent) + Send + Sync>;

/// All target mutations are serialized through one mpsc worker, guaranteeing
/// that overlay deltas and the shared transcript snapshot see identical order.
pub struct PresentationEmitter {
    cmd_tx: std::sync::Mutex<Option<tokio::sync::mpsc::UnboundedSender<EmitterCmd>>>,
    cmd_handle: Option<tokio::task::JoinHandle<()>>,
    /// One occurrence-keyed committed document plus volatile overlay paint.
    session_state: std::sync::Mutex<TranscriptReducer>,
    /// Durable observer of this exact reducer's committed/final truth.
    transcript_bus: Option<Arc<TranscriptBus>>,
    acoustic_ledger: Option<Arc<std::sync::Mutex<AcousticLedger>>>,
    projection_callback: Option<ProjectionObserver>,
    /// The literal contract (Ctrl-hold `force_raw`): when set, the terminal
    /// seal mints no Light+ revision and the document stays word-for-word.
    /// Every other lane — including auto-format "off" — gets the Light+
    /// floor, exactly as the pre-ledger controller gated it.
    literal_delivery: std::sync::atomic::AtomicBool,
}

impl PresentationEmitter {
    /// Build the reducer and start its single FIFO delivery worker.
    pub fn new(
        transcript_buffer: Arc<Mutex<String>>,
        delta_callback: Option<Arc<dyn DeltaSink>>,
        stream_log_path: Option<std::path::PathBuf>,
    ) -> Self {
        Self::new_with_transcript_bus(transcript_buffer, delta_callback, stream_log_path, None)
    }

    /// Build an emitter observed by the clean transcript bus. The bus sees the
    /// same reducer mutation as paste/history and never reconstructs UI deltas.
    pub fn new_with_transcript_bus(
        transcript_buffer: Arc<Mutex<String>>,
        delta_callback: Option<Arc<dyn DeltaSink>>,
        stream_log_path: Option<std::path::PathBuf>,
        transcript_bus: Option<Arc<TranscriptBus>>,
    ) -> Self {
        Self::new_with_authority(
            transcript_buffer,
            delta_callback,
            stream_log_path,
            transcript_bus,
            None,
            None,
        )
    }

    /// Build the production reducer projection over the exact ledger bound to
    /// the recorder. No other constructor is used by the controller.
    pub fn new_with_authority(
        transcript_buffer: Arc<Mutex<String>>,
        delta_callback: Option<Arc<dyn DeltaSink>>,
        stream_log_path: Option<std::path::PathBuf>,
        transcript_bus: Option<Arc<TranscriptBus>>,
        acoustic_ledger: Option<Arc<std::sync::Mutex<AcousticLedger>>>,
        projection_callback: Option<ProjectionObserver>,
    ) -> Self {
        // One ordered worker preserves paint order while keeping authority
        // effects explicit. Both command families may paint; only a committed
        // ledger revision may write the shared delivery buffer.
        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<EmitterCmd>();
        let cmd_handle = Some(tokio::spawn(async move {
            let mut painted_text = String::new();
            while let Some(cmd) = rx.recv().await {
                let (target, commits_delivery) = match cmd {
                    EmitterCmd::PublishCommittedRevision(target) => (target, true),
                    EmitterCmd::PaintEphemeralPreview(target) => (target, false),
                    EmitterCmd::Finish => break,
                };
                if let Some(delta) = TranscriptDelta::from_diff(&painted_text, &target) {
                    if let Some(sink) = &delta_callback {
                        sink.apply(&delta);
                    }
                    if let Some(path) = stream_log_path.as_deref()
                        && let Err(error) = append_stream_delta(path, &delta.delta)
                    {
                        tracing::warn!(%error, path = %path.display(), "stream delta log append failed");
                    }
                }
                painted_text.clone_from(&target);
                if commits_delivery {
                    *transcript_buffer.lock().await = target;
                }
            }
        }));

        Self {
            cmd_tx: std::sync::Mutex::new(Some(tx)),
            cmd_handle,
            session_state: std::sync::Mutex::new(TranscriptReducer::default()),
            transcript_bus,
            acoustic_ledger,
            projection_callback,
            literal_delivery: std::sync::atomic::AtomicBool::new(false),
        }
    }

    /// Declare the literal contract for this take. `true` is the Ctrl-hold
    /// `force_raw` lane: the terminal seal then delivers the ledger words
    /// untouched. Default `false`: Light+ shapes the terminal document.
    pub fn set_literal_delivery(&self, literal: bool) {
        self.literal_delivery
            .store(literal, std::sync::atomic::Ordering::SeqCst);
    }

    /// Whether this take promised literal words (see [`Self::set_literal_delivery`]).
    pub fn literal_delivery(&self) -> bool {
        self.literal_delivery
            .load(std::sync::atomic::Ordering::SeqCst)
    }

    /// Signal the emitter to finish after every queued reducer revision.
    pub async fn finish(&mut self) {
        // Send Finish through channel (ordered after all pending pushes).
        if let Ok(guard) = self.cmd_tx.lock()
            && let Some(tx) = guard.as_ref()
        {
            let _ = tx.send(EmitterCmd::Finish);
        }

        if let Some(handle) = self.cmd_handle.take()
            && let Err(e) = handle.await
        {
            tracing::error!("Emitter cmd worker failed: {}", e);
        }
    }

    /// Send a command to the emitter worker (non-blocking, ordered).
    fn send_cmd(&self, cmd: EmitterCmd) {
        if let Ok(guard) = self.cmd_tx.lock()
            && let Some(tx) = guard.as_ref()
            && tx.send(cmd).is_err()
        {
            debug!("Emitter channel closed, dropping command");
        }
    }

    fn publish_revision(&self, revision: TranscriptRevision) {
        if let Some(ledger) = &self.acoustic_ledger {
            let ledger = ledger.lock().unwrap_or_else(|error| error.into_inner());
            if let Some(bus) = &self.transcript_bus {
                let events = bus.publish_revision(&revision, &ledger);
                if let Some(callback) = &self.projection_callback {
                    for event in &events {
                        callback(event);
                    }
                }
            }
        }
        self.send_cmd(EmitterCmd::PublishCommittedRevision(revision.rendered_text));
    }

    /// Accept one explicit overlay revision intent against the retained terminal
    /// reducer. The acknowledgement carries no authority to Swift: projection is
    /// emitted first, and only that callback may repaint the canvas.
    pub fn apply_user_revision(
        &self,
        intent: UserRevisionIntent,
    ) -> Result<UserRevisionCommit, UserRevisionRefusal> {
        let ledger = self
            .acoustic_ledger
            .as_ref()
            .ok_or(UserRevisionRefusal::AuthorityUnavailable)?;
        let mut ledger = ledger.lock().unwrap_or_else(|error| error.into_inner());
        self.commit_document_revision(&mut ledger, intent)
    }

    /// The one whole-document revision corridor: reducer mints the revision
    /// against the ledger, the Bus observes it, the delivery buffer follows.
    /// User edits, formatter results, and the terminal Light+ pass all enter
    /// here; only the provenance differs.
    fn commit_document_revision(
        &self,
        ledger: &mut AcousticLedger,
        intent: UserRevisionIntent,
    ) -> Result<UserRevisionCommit, UserRevisionRefusal> {
        let revision = self
            .session_state
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .apply_user_revision(ledger, &intent)?;
        if let Some(bus) = &self.transcript_bus {
            let events = bus.publish_revision(&revision, ledger);
            if let Some(callback) = &self.projection_callback {
                for event in &events {
                    callback(event);
                }
            }
        }
        self.send_cmd(EmitterCmd::PublishCommittedRevision(
            revision.rendered_text.clone(),
        ));
        let ReducerAction::ApplyUserRevision { receipt } = &revision.action else {
            unreachable!("apply_user_revision must mint an ApplyUserRevision action")
        };
        Ok(UserRevisionCommit {
            session_id: receipt.session_id.clone(),
            source_revision: receipt.source_revision,
            revision: revision.revision,
            rendered_text: revision.rendered_text,
            provenance_receipt: receipt.receipt_id.clone(),
        })
    }

    /// Light+ floor at the terminal seal. Deterministic sentence shape for the
    /// sealed document — capital at sentence starts, a closing period,
    /// hesitation sounds dropped, punctuation seams collapsed — minted as one
    /// ledger-stamped document revision with provenance `light-plus`, so the
    /// Bus, the delivery buffer, and the formatter CAS all see the same bytes.
    /// It runs for every lane except the literal contract and never touches
    /// an occurrence label: the ledger stays the sole author of the words.
    fn mint_light_plus_revision(&self, ledger: &mut AcousticLedger) {
        if self.literal_delivery() {
            return;
        }
        let intent = self
            .session_state
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .light_plus_intent();
        let Some(intent) = intent else {
            return;
        };
        match self.commit_document_revision(ledger, intent) {
            Ok(commit) => debug!(
                revision = commit.revision,
                receipt = %commit.provenance_receipt,
                "Light+ terminal revision committed"
            ),
            Err(UserRevisionRefusal::Unchanged) => {}
            Err(refusal) => debug!(%refusal, "Light+ terminal revision refused"),
        }
    }

    /// Authenticate formatter input without mutating reducer, ledger, Bus, or
    /// delivery state. The controller feeds these exact bytes into the one
    /// production formatter pipeline and retains the source revision as CAS.
    pub fn terminal_revision_source(
        &self,
        session_id: &str,
        source_revision: u64,
    ) -> Result<String, UserRevisionRefusal> {
        self.session_state
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .terminal_revision_source(session_id, source_revision)
    }

    /// Admit only a successful formatter result into the existing revision
    /// corridor. Failure, skipped policy, and healthy no-op are visible
    /// refusals and therefore mint no ledger/history/Copy-last evidence.
    pub fn apply_formatter_revision(
        &self,
        session_id: String,
        source_revision: u64,
        result: AiFormatResult,
    ) -> Result<UserRevisionCommit, UserRevisionRefusal> {
        let rendered_text = match result.status {
            AiFormatStatus::Applied => result.text,
            AiFormatStatus::Failed => return Err(UserRevisionRefusal::FormatterFailed),
            AiFormatStatus::Skipped => return Err(UserRevisionRefusal::FormatterUnavailable),
            AiFormatStatus::AiNoop => return Err(UserRevisionRefusal::FormatterNoop),
        };
        self.apply_user_revision(UserRevisionIntent {
            session_id,
            source_revision,
            rendered_text,
            provenance: DocumentRevisionProvenance::Formatter,
        })
    }
}

impl Drop for PresentationEmitter {
    /// Close the cmd channel and abort emitter worker tasks to avoid leaks.
    fn drop(&mut self) {
        // Close command channel first (lets cmd worker exit naturally).
        if let Ok(mut guard) = self.cmd_tx.lock() {
            let _ = guard.take();
        }
        // Abort the detached worker as a hard stop fallback to avoid leaks.
        if let Some(handle) = self.cmd_handle.take() {
            handle.abort();
        }
    }
}

impl EventSink for PresentationEmitter {
    /// Route an `EngineEvent` into reducer state and ordered delta delivery.
    fn on_event(&self, event: &EngineEvent) {
        match event {
            EngineEvent::LedgerMutation {
                observation,
                receipt,
                ..
            } => {
                let Some(ledger) = &self.acoustic_ledger else {
                    return;
                };
                let ledger = ledger.lock().unwrap_or_else(|error| error.into_inner());
                let revision = self
                    .session_state
                    .lock()
                    .unwrap_or_else(|error| error.into_inner())
                    .apply_ledger_mutation(&ledger, observation, receipt);
                if let Some(revision) = revision {
                    if let Some(bus) = &self.transcript_bus {
                        let events = bus.publish_revision(&revision, &ledger);
                        if let Some(callback) = &self.projection_callback {
                            for event in &events {
                                callback(event);
                            }
                        }
                    }
                    self.send_cmd(EmitterCmd::PublishCommittedRevision(revision.rendered_text));
                }
            }
            EngineEvent::ContextMarker { position, label } => {
                let revision = self
                    .session_state
                    .lock()
                    .unwrap_or_else(|error| error.into_inner())
                    .record_context_marker(*position, label);
                if let Some(revision) = revision {
                    self.publish_revision(revision);
                }
            }
            EngineEvent::LedgerSeal { receipt } => {
                let Some(ledger) = &self.acoustic_ledger else {
                    return;
                };
                let mut ledger = ledger.lock().unwrap_or_else(|error| error.into_inner());
                let revision = self
                    .session_state
                    .lock()
                    .unwrap_or_else(|error| error.into_inner())
                    .apply_ledger_seal(receipt);
                let Some(revision) = revision else {
                    return;
                };
                let terminal = matches!(
                    revision.action,
                    ReducerAction::RecordLedgerSeal { terminal: true, .. }
                );
                if let Some(bus) = &self.transcript_bus {
                    let events = bus.publish_revision(&revision, &ledger);
                    if let Some(callback) = &self.projection_callback {
                        for event in &events {
                            callback(event);
                        }
                    }
                }
                // The terminal seal closes the ledger's word authority; the
                // Light+ floor follows immediately, before the controller
                // publishes `session_ended`, so the terminal projection Swift
                // holds already carries the shaped bytes and revision number.
                if terminal {
                    self.mint_light_plus_revision(&mut ledger);
                }
            }
            EngineEvent::SealCoverage {
                receipt,
                comparison,
            } => {
                let Some(ledger) = &self.acoustic_ledger else {
                    return;
                };
                let ledger = ledger.lock().unwrap_or_else(|error| error.into_inner());
                let revision = self
                    .session_state
                    .lock()
                    .unwrap_or_else(|error| error.into_inner())
                    .apply_seal_coverage(receipt, comparison.as_ref());
                if let Some(bus) = &self.transcript_bus {
                    let events = bus.publish_revision(&revision, &ledger);
                    if let Some(callback) = &self.projection_callback {
                        for event in &events {
                            callback(event);
                        }
                    }
                }
            }
            EngineEvent::OccurrenceLabelProposal { proposal } => {
                let Some(ledger) = &self.acoustic_ledger else {
                    return;
                };
                let occurrence = OccurrenceIdentity::new(
                    proposal.session.clone(),
                    proposal.capture_epoch,
                    proposal.sample_start,
                    proposal.sample_end,
                );
                let mut ledger = ledger.lock().unwrap_or_else(|error| error.into_inner());
                let (proposal_revision, seal_revision) = {
                    let mut reducer = self
                        .session_state
                        .lock()
                        .unwrap_or_else(|error| error.into_inner());
                    let (formatter_returned, proposal_revision) =
                        reducer.apply_occurrence_label_proposal(&mut ledger, proposal);
                    let seal_revision = formatter_returned
                        .then(|| ledger.seal(&occurrence).ok().cloned())
                        .flatten()
                        .and_then(|receipt| reducer.apply_ledger_seal(&receipt));
                    (proposal_revision, seal_revision)
                };
                for (is_label_revision, revision) in
                    [(true, proposal_revision), (false, seal_revision)]
                        .into_iter()
                        .filter_map(|(is_label_revision, revision)| {
                            revision.map(|revision| (is_label_revision, revision))
                        })
                {
                    if let Some(bus) = &self.transcript_bus {
                        let events = bus.publish_revision(&revision, &ledger);
                        if let Some(callback) = &self.projection_callback {
                            for event in &events {
                                callback(event);
                            }
                        }
                    }
                    if is_label_revision {
                        self.send_cmd(EmitterCmd::PublishCommittedRevision(revision.rendered_text));
                    }
                }
            }
            EngineEvent::VadStart { .. } | EngineEvent::VadEnd { .. } => {}
            EngineEvent::SidebandEvidence { evidence } => {
                debug!(
                    sequence = evidence.sequence,
                    sample_start = evidence.range.sample_start,
                    sample_end = evidence.range.sample_end,
                    "PresentationEmitter observed sideband evidence without mutating text"
                );
            }
            EngineEvent::Preview { text, .. } => {
                let visual_text = {
                    let mut state = self.session_state.lock().unwrap_or_else(|e| e.into_inner());
                    state.set_ephemeral_preview(text);
                    state.ephemeral_visual_text()
                };
                self.send_cmd(EmitterCmd::PaintEphemeralPreview(visual_text));
            }
            EngineEvent::UtteranceFinal { utterance_id, .. } => {
                debug!(
                    utterance_id = *utterance_id,
                    "PresentationEmitter observed raw final without mutating product text"
                );
            }
            EngineEvent::Correction { .. }
            | EngineEvent::ReplaceRange { .. }
            | EngineEvent::InsertAnnotation { .. } => {
                debug!(
                    "PresentationEmitter observed diagnostic text event without mutating product text"
                );
            }
            EngineEvent::NoSpeech { reason } => {
                let canonical_text = {
                    let mut state = self.session_state.lock().unwrap_or_else(|e| e.into_inner());
                    state.mark_terminal_lifecycle();
                    state.clear_ephemeral_preview();
                    state.committed_rendered_text()
                };
                self.send_cmd(EmitterCmd::PaintEphemeralPreview(canonical_text));
                info!("Engine reported no speech: {}", reason);
            }
            EngineEvent::Drop { kind, text, reason } => {
                debug!(
                    "Engine dropped: {:?} — {} (text: '{}')",
                    kind,
                    reason,
                    text.chars().take(50).collect::<String>()
                );
            }
            EngineEvent::Stats {
                hallucination_drops,
                filtered_empty_drops,
                corrections_applied,
                total_utterances,
                dropped_audio_chunks,
                partial_runs_total,
                trigger_utterance_count,
                trigger_speech_count,
                trigger_timer_count,
                partial_stale_count,
                partial_coalesced_count,
                partial_dropped_count,
            } => {
                info!(
                    "Session stats: utterances={}, hallucinations={}, filtered_empty={}, corrections={}, dropped_chunks={}, partial_runs={} (utterance={}, speech={}, watchdog={}, stale={}, coalesced={}, dropped={})",
                    total_utterances,
                    hallucination_drops,
                    filtered_empty_drops,
                    corrections_applied,
                    dropped_audio_chunks,
                    partial_runs_total,
                    trigger_utterance_count,
                    trigger_speech_count,
                    trigger_timer_count,
                    partial_stale_count,
                    partial_coalesced_count,
                    partial_dropped_count,
                );
                let canonical_text = {
                    let mut state = self.session_state.lock().unwrap_or_else(|e| e.into_inner());
                    state.clear_ephemeral_preview();
                    state.committed_rendered_text()
                };
                self.send_cmd(EmitterCmd::PaintEphemeralPreview(canonical_text));
                // Capture is over, but terminal presentation authority stays
                // alive for an explicit overlay revision. The controller
                // replaces or drops it at the next take; `finish()` is for an
                // owner that truly retires the presentation.
            }
            EngineEvent::Warning { code, message } => {
                tracing::warn!("Engine warning [{}]: {}", code, message);
            }
            EngineEvent::SessionFinalised { .. } => {
                let canonical_text = {
                    let mut state = self.session_state.lock().unwrap_or_else(|e| e.into_inner());
                    state.mark_terminal_lifecycle();
                    state.clear_ephemeral_preview();
                    state.committed_rendered_text()
                };
                self.send_cmd(EmitterCmd::PaintEphemeralPreview(canonical_text));
                // Lifecycle end is the second Light+ gate: a one-occurrence
                // session's whole-session seal is indistinguishable from its
                // sole occurrence seal, so the reducer becomes terminal only
                // here. Idempotent — a document the terminal seal already
                // shaped yields no intent, so nothing is minted twice.
                if let Some(ledger) = &self.acoustic_ledger {
                    let mut ledger = ledger.lock().unwrap_or_else(|error| error.into_inner());
                    self.mint_light_plus_revision(&mut ledger);
                }
            }
        }
    }
}

/// Authority-bound presentation tests. These are preregistered for C12; C11
/// does not compile or execute them under the W2 embargo.
#[cfg(test)]
mod tests {
    use super::{PresentationEmitter, TranscriptReducer, UserRevisionIntent, UserRevisionRefusal};
    use crate::presentation::transcript_bus::{
        TranscriptBus, TranscriptBusEvidenceEvent, TranscriptMode, TranscriptProjectionPhase,
        TranscriptSession, TranscriptSessionEndReason,
    };
    use crate::presentation::transcript_projection::TranscriptProjectionReader;
    use codescribe_core::llm::ai_formatting::{AiFormatResult, AiFormatStatus};
    use codescribe_core::llm::inline_format::{LabelProposalDisposition, OccurrenceLabelProposal};
    use codescribe_core::pipeline::acoustic_ledger::{
        AcousticEvidence, AcousticLedger, DocumentRevisionProvenance, EnergyCalibration,
        ObservationIdentity, ObservationProducer, OccurrenceIdentity,
    };
    use codescribe_core::pipeline::contracts::{
        AnnotationKind, DeltaSink, EngineEvent, EventSink, LayerSource, LayerSummary,
        TranscriptDelta,
    };
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::{Arc, Mutex as StdMutex};
    use tokio::sync::Mutex;

    #[derive(Default)]
    struct RecordingDeltaSink {
        deltas: StdMutex<Vec<TranscriptDelta>>,
    }

    impl DeltaSink for RecordingDeltaSink {
        fn apply(&self, delta: &TranscriptDelta) {
            self.deltas
                .lock()
                .unwrap_or_else(|error| error.into_inner())
                .push(delta.clone());
        }
    }

    /// Qualify one occurrence through the ledger's calibrated energy predicate,
    /// then admit an Apple observation over exactly that span.
    ///
    /// Both steps are load-bearing. `admit` alone records a layer decision whose
    /// serial list is copied from `evidence`, so an occurrence that never
    /// cleared `qualify` produces a decision that is not evidence-backed — and
    /// the reducer must refuse it. Authenticating here is what makes the
    /// assertions downstream about repetition and revision projection, rather
    /// than about the admission gate itself.
    fn admitted_mutation(
        ledger: &mut AcousticLedger,
        occurrence: OccurrenceIdentity,
        request: u64,
        label: &str,
    ) -> EngineEvent {
        let calibration = EnergyCalibration {
            version: "emitter-test".to_string(),
            min_energy_integral: 1.0,
            min_valley_samples: 1,
        };
        let evidence = AcousticEvidence {
            occurrence: occurrence.clone(),
            duration_ms: 1_000.0,
            energy_integral: 10.0,
            mean_rms_dbfs: -12.0,
            peak_dbfs: -3.0,
            vad_open_sample: Some(occurrence.sample_start),
            vad_close_sample: Some(occurrence.sample_end),
            evidence_calibration_version: calibration.version.clone(),
        };
        assert!(ledger.qualify(&evidence, &calibration).is_qualified());
        let observation =
            ObservationIdentity::new(ObservationProducer::Apple, request, 0, occurrence);
        let receipt = ledger.admit(&observation, label);
        EngineEvent::LedgerMutation {
            observation,
            label: label.to_string(),
            receipt,
        }
    }

    fn raw_final(text: &str) -> EngineEvent {
        EngineEvent::UtteranceFinal {
            utterance_id: 1,
            text: text.to_string(),
            raw_text: text.to_string(),
            start_ts: 0.0,
            end_ts: 1.0,
            segments: Vec::new(),
            vad_speech_pct: None,
            avg_logprob: None,
            compression_ratio: None,
            confidence_flags: Vec::new(),
        }
    }

    #[tokio::test]
    async fn preview_paints_overlay_without_writing_delivery() {
        let delivery = Arc::new(Mutex::new("ledger truth".to_string()));
        let deltas = Arc::new(RecordingDeltaSink::default());
        let mut emitter =
            PresentationEmitter::new(Arc::clone(&delivery), Some(deltas.clone()), None);

        emitter.on_event(&EngineEvent::Preview {
            rev: 1,
            text: "volatile words".to_string(),
        });
        emitter.finish().await;

        assert_eq!(delivery.lock().await.as_str(), "ledger truth");
        assert!(
            !deltas
                .deltas
                .lock()
                .unwrap_or_else(|error| error.into_inner())
                .is_empty()
        );
    }

    #[tokio::test]
    async fn ledger_mutation_paints_overlay_and_writes_exact_revision_to_delivery() {
        let delivery = Arc::new(Mutex::new(String::new()));
        let deltas = Arc::new(RecordingDeltaSink::default());
        let temp = tempfile::tempdir().unwrap();
        let bus_path = temp.path().join("ledger.jsonl");
        let bus = Arc::new(
            TranscriptBus::open_at(
                TranscriptSession {
                    session_id: "session".to_string(),
                    mode: TranscriptMode::Dictation,
                    has_latched_target: true,
                    latched_target_is_self: false,
                },
                bus_path.clone(),
                None,
            )
            .unwrap(),
        );
        let projection_count = Arc::new(AtomicUsize::new(0));
        let projection_count_for_callback = Arc::clone(&projection_count);
        let ledger = Arc::new(StdMutex::new(AcousticLedger::new()));
        let mutation = {
            let mut guard = ledger.lock().unwrap_or_else(|error| error.into_inner());
            admitted_mutation(
                &mut guard,
                OccurrenceIdentity::new("session", 3, 0, 16_000),
                1,
                "Iwo",
            )
        };
        bus.publish_started();
        let mut emitter = PresentationEmitter::new_with_authority(
            Arc::clone(&delivery),
            Some(deltas.clone()),
            None,
            Some(Arc::clone(&bus)),
            Some(ledger),
            Some(Arc::new(move |_| {
                projection_count_for_callback.fetch_add(1, Ordering::SeqCst);
            })),
        );

        emitter.on_event(&mutation);
        emitter.finish().await;
        let terminal = bus
            .publish_ended(TranscriptSessionEndReason::Completed, true)
            .expect("committed book must produce a terminal projection");

        assert_eq!(delivery.lock().await.as_str(), "Iwo");
        assert!(
            !deltas
                .deltas
                .lock()
                .unwrap_or_else(|error| error.into_inner())
                .is_empty()
        );
        assert_eq!(projection_count.load(Ordering::SeqCst), 1);
        assert_eq!(terminal.rendered_text, "Iwo");
        assert_eq!(terminal.phase, TranscriptProjectionPhase::Formatted);
        assert!(terminal.can_paste);
        assert!(terminal.can_insert);
        assert!(terminal.can_copy);
        assert!(terminal.can_retranscribe);
        assert!(terminal.can_format);
        assert!(terminal.terminal);
        let bus_bytes = std::fs::read(bus_path).unwrap();
        assert!(
            std::str::from_utf8(&bus_bytes)
                .unwrap()
                .contains("codescribe.transcript-evidence.v1")
        );
        let mut reader = TranscriptProjectionReader::new();
        let tail_projections = reader
            .push_bytes(&bus_bytes)
            .into_iter()
            .collect::<Result<Vec<_>, _>>()
            .expect("projection tail must parse");
        let tail_terminal = tail_projections.last().expect("terminal tail projection");
        assert_eq!(tail_terminal.rendered_text, "Iwo");
        assert_eq!(tail_terminal.phase, TranscriptProjectionPhase::Formatted);
        assert!(tail_terminal.can_paste);
        assert!(tail_terminal.terminal);
    }

    #[tokio::test]
    async fn raw_text_lane_failure_and_session_close_cannot_change_delivery() {
        let delivery = Arc::new(Mutex::new("last ledger revision".to_string()));
        let temp = tempfile::tempdir().unwrap();
        let bus_path = temp.path().join("raw-events.jsonl");
        let bus = Arc::new(
            TranscriptBus::open_at(
                TranscriptSession {
                    session_id: "session".to_string(),
                    mode: TranscriptMode::Dictation,
                    has_latched_target: false,
                    latched_target_is_self: false,
                },
                bus_path.clone(),
                None,
            )
            .unwrap(),
        );
        let projection_count = Arc::new(AtomicUsize::new(0));
        let projection_count_for_callback = Arc::clone(&projection_count);
        let mut emitter = PresentationEmitter::new_with_authority(
            Arc::clone(&delivery),
            None,
            None,
            Some(bus),
            Some(Arc::new(StdMutex::new(AcousticLedger::new()))),
            Some(Arc::new(move |_| {
                projection_count_for_callback.fetch_add(1, Ordering::SeqCst);
            })),
        );

        emitter.on_event(&EngineEvent::Preview {
            rev: 1,
            text: "volatile".to_string(),
        });
        emitter.on_event(&raw_final("raw final"));
        emitter.on_event(&EngineEvent::Correction {
            rev: 2,
            text: "correction".to_string(),
            previous_text: "raw final".to_string(),
        });
        emitter.on_event(&EngineEvent::ReplaceRange {
            utterance_id: 1,
            start: 0,
            end: 1,
            text: "replacement".to_string(),
            source: LayerSource::TailPatch,
        });
        emitter.on_event(&EngineEvent::InsertAnnotation {
            utterance_id: 1,
            position: 0,
            text: "annotation".to_string(),
            kind: AnnotationKind::HesitationPause,
        });
        emitter.on_event(&EngineEvent::Warning {
            code: "agent_lane_transport_failed".to_string(),
            message: "Tool-enabled response failed (ConnectError: gateway unavailable)".to_string(),
        });
        emitter.on_event(&EngineEvent::SessionFinalised {
            session_id: "session".to_string(),
            layer_summary: LayerSummary::default(),
        });
        emitter.finish().await;

        assert_eq!(delivery.lock().await.as_str(), "last ledger revision");
        assert!(!delivery.lock().await.contains("ConnectError"));
        assert_eq!(projection_count.load(Ordering::SeqCst), 0);
        assert!(std::fs::read_to_string(bus_path).unwrap().is_empty());
    }

    /// Effect witness for W4-T15: the request names a session/revision rather
    /// than text identity, Rust mints the next document revision and a
    /// `user-edit` ledger receipt, the Bus persists it after microphone
    /// lifecycle end, and replay returns the same terminal bytes.
    #[tokio::test]
    async fn terminal_user_revision_is_ledger_stamped_and_replayable() {
        let delivery = Arc::new(Mutex::new(String::new()));
        let temp = tempfile::tempdir().unwrap();
        let bus_path = temp.path().join("user-revision.jsonl");
        let bus = Arc::new(
            TranscriptBus::open_at(
                TranscriptSession {
                    session_id: "revision-session".to_string(),
                    mode: TranscriptMode::Dictation,
                    has_latched_target: true,
                    latched_target_is_self: false,
                },
                bus_path.clone(),
                None,
            )
            .unwrap(),
        );
        let occurrence = OccurrenceIdentity::new("revision-session", 4, 0, 16_000);
        let ledger = Arc::new(StdMutex::new(AcousticLedger::new()));
        let mutation = {
            let mut ledger = ledger.lock().unwrap_or_else(|error| error.into_inner());
            let mutation = admitted_mutation(&mut ledger, occurrence.clone(), 1, "Tekst bazowy");
            ledger.schedule_frontier(occurrence.clone(), [ObservationProducer::Apple]);
            assert!(ledger.note_frontier_return(&occurrence, ObservationProducer::Apple));
            mutation
        };
        let projected = Arc::new(StdMutex::new(Vec::new()));
        let projected_for_callback = Arc::clone(&projected);
        bus.publish_started();
        let mut emitter = PresentationEmitter::new_with_authority(
            Arc::clone(&delivery),
            None,
            None,
            Some(Arc::clone(&bus)),
            Some(Arc::clone(&ledger)),
            Some(Arc::new(move |event| {
                projected_for_callback
                    .lock()
                    .unwrap_or_else(|error| error.into_inner())
                    .push(event.clone());
            })),
        );
        emitter.on_event(&mutation);
        let terminal_seal = ledger
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .seal_terminal("revision-session", 4)
            .expect("closed qualified occurrence must produce terminal seal");
        emitter.on_event(&EngineEvent::LedgerSeal {
            receipt: terminal_seal,
        });
        // Production order (controller): the session emits `SessionFinalised`
        // inside recorder stop; `publish_ended` follows in the take reset.
        emitter.on_event(&EngineEvent::SessionFinalised {
            session_id: "revision-session".to_string(),
            layer_summary: LayerSummary::default(),
        });
        let terminal = bus
            .publish_ended(TranscriptSessionEndReason::Completed, true)
            .expect("terminal projection");

        let commit = emitter
            .apply_user_revision(UserRevisionIntent {
                session_id: "revision-session".to_string(),
                source_revision: terminal.reducer_revision,
                rendered_text: "Tekst poprawiony przez użytkownika".to_string(),
                provenance: DocumentRevisionProvenance::UserEdit,
            })
            .expect("current terminal revision intent must commit");
        assert_eq!(commit.revision, terminal.reducer_revision + 1);
        assert_eq!(commit.rendered_text, "Tekst poprawiony przez użytkownika");
        assert!(commit.provenance_receipt.starts_with("user-edit-"));
        let stale = emitter.apply_user_revision(UserRevisionIntent {
            session_id: "revision-session".to_string(),
            source_revision: terminal.reducer_revision,
            rendered_text: "Spóźniona edycja".to_string(),
            provenance: DocumentRevisionProvenance::UserEdit,
        });
        assert!(matches!(
            stale,
            Err(UserRevisionRefusal::StaleRevision { .. })
        ));

        emitter.finish().await;
        assert_eq!(
            delivery.lock().await.as_str(),
            "Tekst poprawiony przez użytkownika"
        );
        let ledger = ledger.lock().unwrap_or_else(|error| error.into_inner());
        // Two document revisions: the terminal Light+ floor ("Tekst bazowy."),
        // then the user edit on top of it.
        assert_eq!(ledger.manual_document_revisions().len(), 2);
        assert_eq!(
            ledger.manual_document_revisions()[0].provenance,
            "light-plus"
        );
        let receipt = &ledger.manual_document_revisions()[1];
        assert_eq!(receipt.provenance, "user-edit");
        assert_eq!(receipt.rendered_text, commit.rendered_text);
        assert_eq!(receipt.source_occurrences, vec![occurrence]);
        drop(ledger);

        let projected = projected.lock().unwrap_or_else(|error| error.into_inner());
        let revision_projection = projected
            .iter()
            .rev()
            .find(|event| event.reducer_revision == commit.revision)
            .expect("user revision projection callback");
        assert_eq!(revision_projection.reducer_action, "apply_manual_edit");
        assert_eq!(
            revision_projection.phase,
            TranscriptProjectionPhase::Formatted
        );
        assert!(revision_projection.terminal);
        assert_eq!(revision_projection.rendered_text, commit.rendered_text);
        assert_eq!(
            revision_projection.acoustic_receipts[0]
                .manual_edit_receipt
                .as_deref(),
            Some(commit.provenance_receipt.as_str())
        );
        drop(projected);

        let bus_bytes = std::fs::read(bus_path).unwrap();
        let mut reader = TranscriptProjectionReader::new();
        let replay = reader
            .push_bytes(&bus_bytes)
            .into_iter()
            .collect::<Result<Vec<_>, _>>()
            .expect("revision Bus bytes must replay");
        let replayed_revision = replay.last().expect("replayed user revision");
        assert_eq!(replayed_revision.reducer_revision, commit.revision);
        assert_eq!(replayed_revision.reducer_action, "apply_manual_edit");
        assert_eq!(replayed_revision.rendered_text, commit.rendered_text);
        assert!(replayed_revision.terminal);
    }

    /// I4m effect witness: a failed formatter result cannot touch ledger, Bus,
    /// projection, or delivery. An applied result then mints formatter
    /// provenance and repaints only through the committed projection callback.
    #[tokio::test]
    async fn terminal_formatter_revision_commits_effect_and_failure_is_pure() {
        let delivery = Arc::new(Mutex::new(String::new()));
        let temp = tempfile::tempdir().unwrap();
        let bus_path = temp.path().join("formatter-revision.jsonl");
        let bus = Arc::new(
            TranscriptBus::open_at(
                TranscriptSession {
                    session_id: "formatter-session".to_string(),
                    mode: TranscriptMode::Dictation,
                    has_latched_target: true,
                    latched_target_is_self: false,
                },
                bus_path.clone(),
                None,
            )
            .unwrap(),
        );
        let occurrence = OccurrenceIdentity::new("formatter-session", 5, 0, 16_000);
        let ledger = Arc::new(StdMutex::new(AcousticLedger::new()));
        let mutation = {
            let mut ledger = ledger.lock().unwrap_or_else(|error| error.into_inner());
            let mutation = admitted_mutation(
                &mut ledger,
                occurrence.clone(),
                1,
                "to jest tekst wymagający formatowania",
            );
            ledger.schedule_frontier(occurrence.clone(), [ObservationProducer::Apple]);
            assert!(ledger.note_frontier_return(&occurrence, ObservationProducer::Apple));
            mutation
        };
        let projected = Arc::new(StdMutex::new(Vec::new()));
        let projected_for_callback = Arc::clone(&projected);
        bus.publish_started();
        let mut emitter = PresentationEmitter::new_with_authority(
            Arc::clone(&delivery),
            None,
            None,
            Some(Arc::clone(&bus)),
            Some(Arc::clone(&ledger)),
            Some(Arc::new(move |event| {
                projected_for_callback
                    .lock()
                    .unwrap_or_else(|error| error.into_inner())
                    .push(event.clone());
            })),
        );
        emitter.on_event(&mutation);
        let terminal_seal = ledger
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .seal_terminal("formatter-session", 5)
            .expect("closed qualified occurrence must produce terminal seal");
        emitter.on_event(&EngineEvent::LedgerSeal {
            receipt: terminal_seal,
        });
        // Production order (controller): the session emits `SessionFinalised`
        // inside recorder stop; `publish_ended` follows in the take reset.
        emitter.on_event(&EngineEvent::SessionFinalised {
            session_id: "formatter-session".to_string(),
            layer_summary: LayerSummary::default(),
        });
        let terminal = bus
            .publish_ended(TranscriptSessionEndReason::Completed, true)
            .expect("terminal projection");

        let source = emitter
            .terminal_revision_source("formatter-session", terminal.reducer_revision)
            .expect("current terminal source");
        // Light+ ran at the terminal seal, so the formatter is fed shaped text
        // (Light+ before LLM, as the controller always ordered it).
        assert_eq!(source, "To jest tekst wymagający formatowania.");
        let revisions_before_failure = ledger
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .manual_document_revisions()
            .len();
        let bus_before_failure = std::fs::read(&bus_path).unwrap();
        let delivery_before_failure = delivery.lock().await.clone();
        let projection_count_before_failure = projected
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .len();
        let failure = emitter.apply_formatter_revision(
            "formatter-session".to_string(),
            terminal.reducer_revision,
            AiFormatResult {
                text: source.clone(),
                reasoning_text: None,
                status: AiFormatStatus::Failed,
            },
        );
        assert_eq!(failure, Err(UserRevisionRefusal::FormatterFailed));
        assert_eq!(
            ledger
                .lock()
                .unwrap_or_else(|error| error.into_inner())
                .manual_document_revisions()
                .len(),
            revisions_before_failure
        );
        assert_eq!(std::fs::read(&bus_path).unwrap(), bus_before_failure);
        assert_eq!(
            projected
                .lock()
                .unwrap_or_else(|error| error.into_inner())
                .len(),
            projection_count_before_failure
        );
        assert_eq!(*delivery.lock().await, delivery_before_failure);

        let formatted = "To jest tekst, który wymaga formatowania.".to_string();
        let commit = emitter
            .apply_formatter_revision(
                "formatter-session".to_string(),
                terminal.reducer_revision,
                AiFormatResult {
                    text: formatted.clone(),
                    reasoning_text: None,
                    status: AiFormatStatus::Applied,
                },
            )
            .expect("applied formatter result must enter revision corridor");
        assert_eq!(commit.rendered_text, formatted);
        assert!(commit.provenance_receipt.starts_with("formatter-"));

        emitter.finish().await;
        assert_eq!(delivery.lock().await.as_str(), formatted);
        let ledger = ledger.lock().unwrap_or_else(|error| error.into_inner());
        assert_eq!(ledger.manual_document_revisions().len(), 2);
        assert_eq!(
            ledger.manual_document_revisions()[0].provenance,
            "light-plus"
        );
        assert_eq!(
            ledger.manual_document_revisions()[1].provenance,
            "formatter"
        );
        drop(ledger);
        let projected = projected.lock().unwrap_or_else(|error| error.into_inner());
        let revision_projection = projected
            .iter()
            .rev()
            .find(|event| event.reducer_revision == commit.revision)
            .expect("formatter revision projection callback");
        assert_eq!(revision_projection.reducer_action, "apply_manual_edit");
        assert_eq!(revision_projection.rendered_text, formatted);
        assert_eq!(
            revision_projection.acoustic_receipts[0]
                .manual_edit_receipt
                .as_deref(),
            Some(commit.provenance_receipt.as_str())
        );
    }

    /// Light+ standard in live: an unpunctuated ledger document gains sentence
    /// shape at the terminal seal, as one `light-plus` document revision that
    /// the Bus persists, the delivery buffer carries, the formatter CAS sees
    /// as its source, and a replay of the Bus bytes reproduces. The ledger's
    /// occurrence labels stay untouched — Rust remains the only author.
    #[tokio::test]
    async fn terminal_seal_mints_light_plus_revision_before_session_end() {
        let delivery = Arc::new(Mutex::new(String::new()));
        let temp = tempfile::tempdir().unwrap();
        let bus_path = temp.path().join("light-plus.jsonl");
        let bus = Arc::new(
            TranscriptBus::open_at(
                TranscriptSession {
                    session_id: "light-plus-session".to_string(),
                    mode: TranscriptMode::Dictation,
                    has_latched_target: true,
                    latched_target_is_self: false,
                },
                bus_path.clone(),
                None,
            )
            .unwrap(),
        );
        let occurrence = OccurrenceIdentity::new("light-plus-session", 6, 0, 16_000);
        let ledger = Arc::new(StdMutex::new(AcousticLedger::new()));
        let raw_words = "to jest tekst bez interpunkcji yyy i koniec";
        let mutation = {
            let mut ledger = ledger.lock().unwrap_or_else(|error| error.into_inner());
            let mutation = admitted_mutation(&mut ledger, occurrence.clone(), 1, raw_words);
            ledger.schedule_frontier(occurrence.clone(), [ObservationProducer::Apple]);
            assert!(ledger.note_frontier_return(&occurrence, ObservationProducer::Apple));
            mutation
        };
        let projected = Arc::new(StdMutex::new(Vec::new()));
        let projected_for_callback = Arc::clone(&projected);
        bus.publish_started();
        let mut emitter = PresentationEmitter::new_with_authority(
            Arc::clone(&delivery),
            None,
            None,
            Some(Arc::clone(&bus)),
            Some(Arc::clone(&ledger)),
            Some(Arc::new(move |event| {
                projected_for_callback
                    .lock()
                    .unwrap_or_else(|error| error.into_inner())
                    .push(event.clone());
            })),
        );
        emitter.on_event(&mutation);
        let terminal_seal = ledger
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .seal_terminal("light-plus-session", 6)
            .expect("closed qualified occurrence must produce terminal seal");
        emitter.on_event(&EngineEvent::LedgerSeal {
            receipt: terminal_seal,
        });
        // Production order (controller): the session emits `SessionFinalised`
        // inside recorder stop; `publish_ended` follows in the take reset.
        emitter.on_event(&EngineEvent::SessionFinalised {
            session_id: "light-plus-session".to_string(),
            layer_summary: LayerSummary::default(),
        });
        let terminal = bus
            .publish_ended(TranscriptSessionEndReason::Completed, true)
            .expect("terminal projection");
        emitter.finish().await;

        let shaped = "To jest tekst bez interpunkcji i koniec.";
        assert_eq!(delivery.lock().await.as_str(), shaped);

        // The ledger words are untouched; the shaping is a document revision.
        let ledger = ledger.lock().unwrap_or_else(|error| error.into_inner());
        assert_eq!(ledger.text_of(&occurrence), Some(raw_words));
        assert_eq!(ledger.manual_document_revisions().len(), 1);
        let receipt = &ledger.manual_document_revisions()[0];
        assert_eq!(receipt.provenance, "light-plus");
        assert!(receipt.receipt_id.starts_with("light-plus-"));
        assert_eq!(receipt.rendered_text, shaped);
        assert_eq!(receipt.source_occurrences, vec![occurrence.clone()]);
        drop(ledger);

        // `session_ended` copies the Light+ revision: Swift's terminal CAS
        // source is the shaped document, and so is the formatter's input.
        assert_eq!(terminal.rendered_text, shaped);
        assert_eq!(terminal.reducer_revision, receipt_revision(&projected));
        assert_eq!(
            emitter
                .terminal_revision_source("light-plus-session", terminal.reducer_revision)
                .expect("light-plus revision is the current terminal source"),
            shaped
        );

        let projected = projected.lock().unwrap_or_else(|error| error.into_inner());
        let light_plus_projection = projected
            .iter()
            .rev()
            .find(|event| event.reducer_action == "apply_manual_edit")
            .expect("light-plus revision projection callback");
        assert_eq!(light_plus_projection.rendered_text, shaped);
        assert_eq!(light_plus_projection.label, raw_words);
        assert!(light_plus_projection.terminal);
        assert!(
            light_plus_projection.acoustic_receipts[0]
                .manual_edit_receipt
                .as_deref()
                .is_some_and(|receipt| receipt.starts_with("light-plus-"))
        );
        drop(projected);

        let bus_bytes = std::fs::read(bus_path).unwrap();
        let mut reader = TranscriptProjectionReader::new();
        let replay = reader
            .push_bytes(&bus_bytes)
            .into_iter()
            .collect::<Result<Vec<_>, _>>()
            .expect("light-plus Bus bytes must replay");
        let replayed = replay.last().expect("replayed light-plus revision");
        assert_eq!(replayed.rendered_text, shaped);
        assert!(replayed.terminal);
    }

    fn receipt_revision(projected: &StdMutex<Vec<TranscriptBusEvidenceEvent>>) -> u64 {
        projected
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .last()
            .expect("at least one projection")
            .reducer_revision
    }

    /// The literal contract (Ctrl-hold `force_raw`): with literal delivery
    /// declared, the terminal seal mints no Light+ revision and the words
    /// reach delivery exactly as the ledger holds them.
    #[tokio::test]
    async fn literal_delivery_keeps_terminal_words_untouched() {
        let delivery = Arc::new(Mutex::new(String::new()));
        let temp = tempfile::tempdir().unwrap();
        let bus_path = temp.path().join("literal.jsonl");
        let bus = Arc::new(
            TranscriptBus::open_at(
                TranscriptSession {
                    session_id: "literal-session".to_string(),
                    mode: TranscriptMode::Dictation,
                    has_latched_target: true,
                    latched_target_is_self: false,
                },
                bus_path,
                None,
            )
            .unwrap(),
        );
        let occurrence = OccurrenceIdentity::new("literal-session", 7, 0, 16_000);
        let ledger = Arc::new(StdMutex::new(AcousticLedger::new()));
        let raw_words = "słowa literalne bez kropki";
        let mutation = {
            let mut ledger = ledger.lock().unwrap_or_else(|error| error.into_inner());
            let mutation = admitted_mutation(&mut ledger, occurrence.clone(), 1, raw_words);
            ledger.schedule_frontier(occurrence.clone(), [ObservationProducer::Apple]);
            assert!(ledger.note_frontier_return(&occurrence, ObservationProducer::Apple));
            mutation
        };
        bus.publish_started();
        let mut emitter = PresentationEmitter::new_with_authority(
            Arc::clone(&delivery),
            None,
            None,
            Some(Arc::clone(&bus)),
            Some(Arc::clone(&ledger)),
            None,
        );
        emitter.set_literal_delivery(true);
        emitter.on_event(&mutation);
        let terminal_seal = ledger
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .seal_terminal("literal-session", 7)
            .expect("closed qualified occurrence must produce terminal seal");
        emitter.on_event(&EngineEvent::LedgerSeal {
            receipt: terminal_seal,
        });
        let terminal = bus
            .publish_ended(TranscriptSessionEndReason::Completed, true)
            .expect("terminal projection");
        emitter.finish().await;

        assert_eq!(delivery.lock().await.as_str(), raw_words);
        assert_eq!(terminal.rendered_text, raw_words);
        assert!(
            ledger
                .lock()
                .unwrap_or_else(|error| error.into_inner())
                .manual_document_revisions()
                .is_empty()
        );
    }

    #[test]
    fn equal_labels_on_disjoint_occurrences_remain_two_document_entries() {
        let mut ledger = AcousticLedger::new();
        let first = admitted_mutation(
            &mut ledger,
            OccurrenceIdentity::new("session", 7, 0, 8_000),
            1,
            "Iwo",
        );
        let second = admitted_mutation(
            &mut ledger,
            OccurrenceIdentity::new("session", 7, 16_000, 24_000),
            2,
            "Iwo",
        );
        let mut reducer = TranscriptReducer::default();

        for event in [first, second] {
            let EngineEvent::LedgerMutation {
                observation,
                receipt,
                ..
            } = event
            else {
                unreachable!();
            };
            assert!(
                reducer
                    .apply_ledger_mutation(&ledger, &observation, &receipt)
                    .is_some()
            );
        }

        assert_eq!(reducer.document_by_occurrence.len(), 2);
        assert_eq!(reducer.committed_rendered_text(), "Iwo Iwo");

        // The two entries are kept apart by their PCM span, not by their text.
        // Asserting the exact keys stops a future dedup-by-string from passing
        // this test with one entry and a doubled render.
        let spans = reducer
            .document_by_occurrence
            .keys()
            .map(|occurrence| (occurrence.sample_start, occurrence.sample_end))
            .collect::<Vec<_>>();
        assert_eq!(spans, vec![(0, 8_000), (16_000, 24_000)]);
        for entry in reducer.document_by_occurrence.values() {
            assert_eq!(entry.label, "Iwo");
        }
    }

    #[test]
    fn context_marker_rendered_into_document() {
        fn reducer_with_text(text: &str) -> TranscriptReducer {
            let mut ledger = AcousticLedger::new();
            let event = admitted_mutation(
                &mut ledger,
                OccurrenceIdentity::new("session", 1, 0, 16_000),
                1,
                text,
            );
            let EngineEvent::LedgerMutation {
                observation,
                receipt,
                ..
            } = event
            else {
                unreachable!();
            };
            let mut reducer = TranscriptReducer::default();
            assert!(
                reducer
                    .apply_ledger_mutation(&ledger, &observation, &receipt)
                    .is_some()
            );
            reducer
        }

        let mut boundary = reducer_with_text("alpha beta");
        boundary.record_context_marker(5, "{selection_1}");
        assert_eq!(
            boundary.committed_rendered_text(),
            "alpha {selection_1} beta"
        );

        let mut inside_word = reducer_with_text("bardzo mnie drażni");
        inside_word.record_context_marker(9, "{selection_1}");
        assert_eq!(
            inside_word.committed_rendered_text(),
            "bardzo mn{selection_1}ie drażni"
        );

        let mut ordered = reducer_with_text("alpha");
        ordered.record_context_marker(5, "{selection_1}");
        ordered.record_context_marker(5, "{selection_2}");
        ordered.record_context_marker(5, "{selection_3}");
        assert_eq!(
            ordered.committed_rendered_text(),
            "alpha {selection_1} {selection_2} {selection_3}"
        );

        let mut anchored_before_text = TranscriptReducer::default();
        anchored_before_text.record_context_marker(5, "{selection_1}");
        let mut ledger = AcousticLedger::new();
        let event = admitted_mutation(
            &mut ledger,
            OccurrenceIdentity::new("session", 2, 0, 16_000),
            2,
            "alpha beta",
        );
        let EngineEvent::LedgerMutation {
            observation,
            receipt,
            ..
        } = event
        else {
            unreachable!();
        };
        anchored_before_text.apply_ledger_mutation(&ledger, &observation, &receipt);
        assert_eq!(
            anchored_before_text.committed_rendered_text(),
            "alpha {selection_1} beta"
        );
    }

    /// A terminal seal closes committed truth. A later non-manual observation
    /// replaying the same occurrence must move neither the label nor the
    /// document, and must not mint a revision.
    #[test]
    fn sealed_occurrence_refuses_a_later_machine_observation() {
        let mut ledger = AcousticLedger::new();
        let occurrence = OccurrenceIdentity::new("session", 11, 0, 16_000);
        let admitted = admitted_mutation(&mut ledger, occurrence.clone(), 1, "Iwo");
        let EngineEvent::LedgerMutation {
            observation,
            receipt,
            ..
        } = admitted
        else {
            unreachable!();
        };
        let mut reducer = TranscriptReducer::default();
        let first = reducer
            .apply_ledger_mutation(&ledger, &observation, &receipt)
            .expect("an authenticated occurrence commits");

        // A seal is only mintable once the scheduled observer frontier has
        // actually closed; there is no arbitrary text seal.
        ledger.schedule_frontier(occurrence.clone(), [ObservationProducer::Apple]);
        // Apple is the only scheduled observer, so its return is the exact
        // open -> closed transition.
        assert!(ledger.note_frontier_return(&occurrence, ObservationProducer::Apple));
        let sealed = ledger
            .seal(&occurrence)
            .expect("a closed frontier over qualified audio seals")
            .clone();
        assert!(reducer.apply_ledger_seal(&sealed).is_some());
        let revision_after_seal = reducer.revision;

        // Same occurrence, later generation, different text: refused outright.
        let replay = ObservationIdentity::new(ObservationProducer::Apple, 2, 1, occurrence.clone());
        let replay_receipt = ledger.admit(&replay, "Iwo drugie");
        assert!(
            reducer
                .apply_ledger_mutation(&ledger, &replay, &replay_receipt)
                .is_none()
        );

        assert_eq!(reducer.revision, revision_after_seal);
        assert_eq!(ledger.text_of(&occurrence), Some("Iwo"));
        assert_eq!(reducer.committed_rendered_text(), "Iwo");
        assert_eq!(reducer.document_by_occurrence.len(), 1);
        assert_eq!(first.entries.len(), 1);
    }

    fn open_formatter_frontier() -> (AcousticLedger, TranscriptReducer, OccurrenceIdentity) {
        let occurrence = OccurrenceIdentity::new("formatter-session", 9, 0, 16_000);
        let calibration = EnergyCalibration {
            version: "formatter-emitter-test".to_string(),
            min_energy_integral: 1.0,
            min_valley_samples: 1,
        };
        let evidence = AcousticEvidence {
            occurrence: occurrence.clone(),
            duration_ms: 1_000.0,
            energy_integral: 10.0,
            mean_rms_dbfs: -12.0,
            peak_dbfs: -3.0,
            vad_open_sample: Some(occurrence.sample_start),
            vad_close_sample: Some(occurrence.sample_end),
            evidence_calibration_version: calibration.version.clone(),
        };
        let mut ledger = AcousticLedger::new();
        assert!(ledger.qualify(&evidence, &calibration).is_qualified());
        ledger.schedule_frontier(
            occurrence.clone(),
            [ObservationProducer::Apple, ObservationProducer::Lexicon],
        );
        let apple = ObservationIdentity::new(ObservationProducer::Apple, 1, 0, occurrence.clone());
        let apple_receipt = ledger.admit(&apple, "Iwo");
        assert!(!ledger.note_frontier_return(&occurrence, ObservationProducer::Apple));
        let mut reducer = TranscriptReducer::default();
        assert!(
            reducer
                .apply_ledger_mutation(&ledger, &apple, &apple_receipt)
                .is_some()
        );

        let lexicon =
            ObservationIdentity::new(ObservationProducer::Lexicon, 1, 0, occurrence.clone());
        let _ = ledger.admit(&lexicon, "Iwo");
        assert!(ledger.schedule_observer(occurrence.clone(), ObservationProducer::Formatter,));
        assert!(!ledger.note_frontier_return(&occurrence, ObservationProducer::Lexicon));
        (ledger, reducer, occurrence)
    }

    #[test]
    fn preserve_refuse_and_empty_propose_return_formatter_without_fake_observation() {
        for (disposition, proposed_label) in [
            (LabelProposalDisposition::PreserveExisting, ""),
            (LabelProposalDisposition::Refuse, ""),
            (LabelProposalDisposition::Propose, "   "),
        ] {
            let (mut ledger, mut reducer, occurrence) = open_formatter_frontier();
            let trail_before = ledger.layer_trail_for(&occurrence).count();
            let proposal = OccurrenceLabelProposal::for_existing_occurrence(
                occurrence.session.clone(),
                occurrence.capture_epoch,
                occurrence.sample_start,
                occurrence.sample_end,
                proposed_label,
                disposition,
            );

            let (formatter_returned, revision) =
                reducer.apply_occurrence_label_proposal(&mut ledger, &proposal);
            assert!(formatter_returned);
            assert!(revision.is_none());
            assert_eq!(ledger.layer_trail_for(&occurrence).count(), trail_before);
            assert_eq!(ledger.text_of(&occurrence), Some("Iwo"));
            assert!(ledger.seal(&occurrence).is_ok());
            assert_eq!(reducer.committed_rendered_text(), "Iwo");
        }
    }

    #[test]
    fn formatter_proposal_can_only_relabel_one_existing_open_occurrence_once() {
        let (mut ledger, mut reducer, occurrence) = open_formatter_frontier();
        let qualified_before = ledger.qualified_occurrences().count();
        let proposal = OccurrenceLabelProposal::for_existing_occurrence(
            occurrence.session.clone(),
            occurrence.capture_epoch,
            occurrence.sample_start,
            occurrence.sample_end,
            "Iwo!",
            LabelProposalDisposition::Propose,
        );

        let (formatter_returned, revision) =
            reducer.apply_occurrence_label_proposal(&mut ledger, &proposal);
        assert!(formatter_returned);
        assert!(revision.is_some());
        assert_eq!(ledger.text_of(&occurrence), Some("Iwo!"));
        assert_eq!(ledger.qualified_occurrences().count(), qualified_before);
        assert_eq!(reducer.document_by_occurrence.len(), 1);
        assert!(ledger.seal(&occurrence).is_ok());

        let trail_after_seal = ledger.layer_trail_for(&occurrence).count();
        let (formatter_returned, revision) =
            reducer.apply_occurrence_label_proposal(&mut ledger, &proposal);
        assert!(!formatter_returned);
        assert!(revision.is_none());
        assert_eq!(
            ledger.layer_trail_for(&occurrence).count(),
            trail_after_seal
        );
        assert_eq!(ledger.text_of(&occurrence), Some("Iwo!"));
        assert_eq!(ledger.qualified_occurrences().count(), qualified_before);
        assert_eq!(reducer.document_by_occurrence.len(), 1);
    }
}
