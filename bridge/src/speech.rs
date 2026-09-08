//! On-demand Agent speech on the process-owned application runtime.
use crate::{CsError, application_runtime};
use codescribe_core::llm::speech;

/// Outcome of an explicitly requested spoken assistant turn.
#[derive(Clone, Debug, uniffi::Record)]
pub struct CsSpeechResult {
    /// `played` or `stopped`; failures use the bridge error channel.
    pub outcome: String,
    /// Duration of synthesized PCM (zero if cancelled during synthesis).
    pub duration_ms: u64,
    /// Whether synthesis used the disk cache.
    pub cached: bool,
}

/// None means locally configured; server permissions are checked by speak_text.
#[uniffi::export]
pub fn speech_availability() -> Option<String> {
    speech::speech_availability()
}

/// Cancel current playback and invalidate pending synthesis.
#[uniffi::export]
pub fn stop_speaking() {
    speech::playback::stop();
}

/// Speak the turn through the provider currently selected for the assistive lane.
#[uniffi::export]
pub async fn speak_text(text: String) -> Result<CsSpeechResult, CsError> {
    let ticket = speech::playback::begin();
    application_runtime::run(async move {
        let cancelled = async {
            while speech::playback::current(ticket) {
                tokio::time::sleep(std::time::Duration::from_millis(20)).await;
            }
        };
        let audio = tokio::select! {
            biased;
            _ = cancelled => return Ok(CsSpeechResult { outcome: "stopped".into(), duration_ms: 0, cached: false }),
            result = speech::synthesize(&text) => result.map_err(anyhow::Error::from)?,
        };
        let duration_ms = audio.duration_ms();
        let cached = audio.cached;
        let played = tokio::task::spawn_blocking(move || {
            speech::playback::play(audio.samples, audio.sample_rate, ticket)
        })
        .await.map_err(anyhow::Error::from)??;
        Ok(CsSpeechResult {
            outcome: if played { "played" } else { "stopped" }.into(),
            duration_ms,
            cached,
        })
    })
    .await?
}
