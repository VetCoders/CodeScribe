//! Public PCM-only regression fixtures. No private recording or transcript.
use super::*;

fn state() -> AppleSealState {
    let mut state = AppleSealState::new_for_session(16_000, "seal-recovery".into(), 1);
    state.energy_calibration = Some(EnergyCalibration::new("synthetic", 1.0, 1));
    state
}

fn observe(
    state: &mut AppleSealState,
    tx: &mpsc::UnboundedSender<EngineEvent>,
    start: u64,
    end: u64,
    id: u64,
) -> Option<MutationReceipt> {
    admit_ledger_label(
        state,
        tx,
        LabelAdmission {
            observation: LedgerObservationIdentity::new(
                LedgerObservationProducer::Whisper,
                id,
                0,
                OccurrenceIdentity::new("seal-recovery", 1, start, end),
            ),
            label: "Iwo",
            energy: EnergyAdmission::QualifyFinalPassGap,
        },
    )
}

#[test]
fn recovery_retention_head_before_120_seconds_remains_qualifiable() {
    let mut state = state();
    let pcm = vec![0.25; 16_000 * 121];
    state.audio.push(&pcm);
    let file = tempfile::NamedTempFile::new().unwrap();
    let mut wav = hound::WavWriter::create(
        file.path(),
        hound::WavSpec {
            channels: 1,
            sample_rate: 16_000,
            bits_per_sample: 16,
            sample_format: hound::SampleFormat::Int,
        },
    )
    .unwrap();
    for sample in &pcm {
        wav.write_sample((*sample * i16::MAX as f32) as i16)
            .unwrap();
    }
    wav.finalize().unwrap();
    state.terminal_pcm = Some(
        super::super::live_audio_buffer::FinalizedPcmArchive {
            session_id: state.session_id.clone(),
            capture_epoch: 1,
            sample_rate: 16_000,
            sample_count: pcm.len() as u64,
            path: file.path().into(),
        }
        .load(&state.session_id, 1, 16_000, pcm.len() as u64)
        .unwrap(),
    );
    let recovered = state.owned_pcm_window(0, 16_000).unwrap();
    assert_eq!(recovered.sample_start, 0);
    assert_eq!(recovered.sample_end, 16_000);
    assert!(
        recovered
            .samples
            .iter()
            .all(|sample| (*sample - 0.25).abs() <= 1.0 / i16::MAX as f32)
    );

    assert!(
        state.audio.window_by_samples(0, 16_000).is_none(),
        "live retention must stay bounded"
    );
    let (tx, _) = mpsc::unbounded_channel();
    assert!(
        observe(&mut state, &tx, 0, 16_000, 1).is_some(),
        "terminal owned PCM must recover the evicted head"
    );
}

#[test]
fn recovery_open_silero_final_waits_for_stable_extent() {
    let mut state = state();
    state.audio.push(&vec![0.25; 32_000]);
    let mut fusion = SileroIngress::new(16_000, state.session_id.clone(), 1);
    fusion
        .ledger_mut()
        .open_or_extend(&state.session_id, 1, 0, 16_000);
    state.fusion = Some(fusion);
    state.fusion_seal_armed = true;
    let (tx, _) = mpsc::unbounded_channel();
    let words = vec![TranscriptSegment {
        text: "Iwo".into(),
        start_ts: 0.1,
        end_ts: 0.8,
    }];
    assert!(seal_sliced_by_silero(&mut state, &tx, &words));
    assert!(
        state
            .acoustic_ledger
            .lock()
            .unwrap()
            .rendered_text()
            .is_empty(),
        "open physical occurrence must not acquire a sealed identity"
    );
    state
        .fusion
        .as_mut()
        .unwrap()
        .ledger_mut()
        .open_or_extend(&state.session_id, 1, 0, 32_000);
    state
        .fusion
        .as_mut()
        .unwrap()
        .ledger_mut()
        .close_open(32_000);
    assert!(seal_sliced_by_silero(&mut state, &tx, &words));
    assert_eq!(state.acoustic_ledger.lock().unwrap().rendered_text(), "Iwo");
}

#[test]
fn recovery_equal_words_on_disjoint_pcm_stay_distinct() {
    let mut state = state();
    state.audio.push(&vec![0.25; 32_000]);
    let (tx, _) = mpsc::unbounded_channel();
    assert!(observe(&mut state, &tx, 0, 16_000, 1).is_some());
    assert!(observe(&mut state, &tx, 16_000, 32_000, 2).is_some());
    assert_eq!(
        state.acoustic_ledger.lock().unwrap().rendered_text(),
        "Iwo Iwo"
    );
}

#[test]
fn recovery_new_gap_formatter_work_prevents_terminal_seal() {
    let mut state = state();
    state.audio.push(&vec![0.25; 16_000]);
    let (formatter, mut requests) = mpsc::channel(FORMATTER_QUEUE_CAP);
    state.formatter = Some(formatter);
    let (tx, _) = mpsc::unbounded_channel();
    assert!(observe(&mut state, &tx, 0, 16_000, 1).is_some());
    assert!(requests.try_recv().is_ok());
    assert_eq!(state.formatter_awaiting_completion, 1);
    assert!(
        state
            .acoustic_ledger
            .lock()
            .unwrap()
            .seal_terminal(&state.session_id, 1)
            .is_err()
    );
}

#[test]
fn recovery_closed_occurrence_submits_owned_tail_job() {
    let mut state = state();
    state.audio.push(&vec![0.25; 32_000]);
    let mut fusion = SileroIngress::new(16_000, state.session_id.clone(), 1);
    fusion
        .ledger_mut()
        .open_or_extend(&state.session_id, 1, 0, 32_000);
    fusion.ledger_mut().close_open(32_000);
    state.fusion = Some(fusion);
    state.fusion_seal_armed = true;
    let (tail, mut jobs) = mpsc::channel(TAIL_PATCH_QUEUE_CAP);
    state.tail_patch = Some(tail);
    let (tx, _) = mpsc::unbounded_channel();
    assert!(seal_sliced_by_silero(
        &mut state,
        &tx,
        &[TranscriptSegment {
            text: "Iwo".into(),
            start_ts: 0.1,
            end_ts: 1.8,
        }]
    ));
    state.flush_layer1_coalesce(&tx);
    let job = jobs
        .try_recv()
        .expect("armed local lane must submit real PCM work");
    assert_eq!(job.audio.len(), 32_000);
    assert_eq!(job.provider_request.identity.range.sample_start, 0);
    assert_eq!(job.provider_request.identity.range.sample_end, 32_000);
    assert_eq!(state.tail_patch_awaiting_completion, 1);
}
