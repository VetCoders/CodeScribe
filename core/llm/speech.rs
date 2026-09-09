//! On-demand vendor speech, sharing the assistive provider and account authority.
//! This sibling of the LLM transport deliberately does not enable local CSM.
use super::{
    account_auth,
    provider::ProviderKind,
    vendors::{openai, xai},
};
use crate::config::{Config, RuntimeLlmLane, keychain};
use base64::Engine as _;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    fmt,
    path::{Path, PathBuf},
    time::Duration,
};

/// Cancellable output independent of the disabled local TTS engine.
pub mod playback;

/// All speech responses and cache entries are mono signed little-endian PCM16.
pub const SAMPLE_RATE: u32 = 24_000;
/// Content-free diagnostic errors: never include response bodies or credentials.
#[derive(Debug, PartialEq, Eq)]
pub enum SpeechError {
    /// No vendor speech protocol exists.
    Unsupported(String),
    /// Neither account nor API key is present.
    MissingCredentials(&'static str),
    /// A signed-in account failed; API key fallback is forbidden.
    Account(&'static str),
    /// Invalid input, settings, response, or storage operation.
    Invalid(&'static str),
    /// HTTP refusal, safe for probes and UI.
    Http(u16),
    /// Transport did not return an HTTP response.
    Transport,
}
impl fmt::Display for SpeechError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Unsupported(v) => write!(f, "unavailable: {v} has no speech endpoint"),
            Self::MissingCredentials(v) => {
                write!(f, "unavailable: {v}: no signed-in account and no API key")
            }
            Self::Account(v) => write!(
                f,
                "unavailable: {v} account authentication failed; sign in again"
            ),
            Self::Invalid(s) => f.write_str(s),
            Self::Http(s) => write!(f, "Speech endpoint returned HTTP {s}"),
            Self::Transport => f.write_str("Speech endpoint transport failed"),
        }
    }
}
impl std::error::Error for SpeechError {}

/// The chosen credential mechanism, never the credential itself.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AuthSource {
    OAuth,
    ApiKey,
}
impl AuthSource {
    /// Machine-readable probe label.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::OAuth => "oauth",
            Self::ApiKey => "api_key",
        }
    }
}
/// Intentionally not Debug: contains a bearer secret.
pub struct SpeechAuth {
    pub bearer: String,
    pub source: AuthSource,
}

fn pins(vendor: ProviderKind) -> Result<(&'static str, &'static str, &'static str), SpeechError> {
    match vendor {
        ProviderKind::OpenAiResponses => {
            Ok(("openai", openai::API_KEY_ACCOUNT, openai::TTS_ENDPOINT))
        }
        ProviderKind::XaiResponses => Ok(("xai", xai::API_KEY_ACCOUNT, xai::TTS_ENDPOINT)),
        _ => Err(SpeechError::Unsupported(format!("{vendor:?}"))),
    }
}
/// Recognize only exact TLS vendor origins. Never send a vendor token to a custom endpoint.
pub fn vendor_for_endpoint(endpoint: &str) -> Option<ProviderKind> {
    let url = reqwest::Url::parse(endpoint).ok()?;
    if !matches!(url.scheme(), "https" | "wss")
        || url.port_or_known_default() != Some(443)
        || !url.username().is_empty()
        || url.password().is_some()
    {
        return None;
    }
    match url.host_str()? {
        "api.openai.com" => Some(ProviderKind::OpenAiResponses),
        "api.x.ai" => Some(ProviderKind::XaiResponses),
        _ => None,
    }
}
/// Request-time account lookup; never called by the settings loader.
pub fn vendor_signed_in(vendor: ProviderKind) -> bool {
    account_auth::account_status(vendor).signed_in
}
fn api_key(vendor: ProviderKind, fallback: Option<&str>) -> Option<String> {
    let (_, account, _) = pins(vendor).ok()?;
    fallback
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_owned)
        .or_else(|| keychain::runtime_key(account))
        .filter(|s| !s.trim().is_empty())
}
async fn resolve_with<F, Fut, K>(
    vendor: ProviderKind,
    signed_in: bool,
    oauth: F,
    key: K,
) -> Result<SpeechAuth, SpeechError>
where
    F: FnOnce() -> Fut,
    Fut: std::future::Future<Output = Result<String, SpeechError>>,
    K: FnOnce() -> Option<String>,
{
    let (name, _, _) = pins(vendor)?;
    // A stored key wins: vendor account tokens are an identity for the
    // vendor's own backend and are refused by the public API endpoints
    // (live 2026-09-09: `401 … Missing scopes: api.responses.write`).
    if let Some(bearer) = key().filter(|s| !s.trim().is_empty()) {
        return Ok(SpeechAuth {
            bearer,
            source: AuthSource::ApiKey,
        });
    }
    if signed_in {
        let bearer = oauth().await?;
        if bearer.trim().is_empty() {
            return Err(SpeechError::Account(name));
        }
        return Ok(SpeechAuth {
            bearer,
            source: AuthSource::OAuth,
        });
    }
    Err(SpeechError::MissingCredentials(name))
}
/// Stored API key first; the signed-in account only serves a vendor with no key.
pub async fn resolve_vendor_auth(
    vendor: ProviderKind,
    fallback_key: Option<&str>,
) -> Result<SpeechAuth, SpeechError> {
    let (name, _, _) = pins(vendor)?;
    resolve_with(
        vendor,
        vendor_signed_in(vendor),
        || async move {
            account_auth::access_token(vendor)
                .await
                .map_err(|_| SpeechError::Account(name))
        },
        || api_key(vendor, fallback_key),
    )
    .await
}

/// Settings sealed once for a synthesis; cache identity includes all audible options.
#[derive(Clone, Debug)]
pub struct SpeechOptions {
    pub vendor: ProviderKind,
    pub model: String,
    pub voice: String,
    pub speed: f32,
}
impl SpeechOptions {
    /// Resolve vendor-specific defaults and validate the optional environment overrides.
    pub fn for_vendor(vendor: ProviderKind) -> Result<Self, SpeechError> {
        pins(vendor)?;
        let read = |key, default: &str| {
            std::env::var(key)
                .ok()
                .filter(|s| !s.trim().is_empty())
                .unwrap_or_else(|| default.into())
        };
        let (model, voice) = match vendor {
            ProviderKind::OpenAiResponses => (
                read("SPEECH_TTS_MODEL_OPENAI", openai::DEFAULT_TTS_MODEL),
                read("SPEECH_TTS_VOICE_OPENAI", openai::DEFAULT_TTS_VOICE),
            ),
            _ => (
                xai::DEFAULT_TTS_MODEL.into(),
                read("SPEECH_TTS_VOICE_XAI", xai::DEFAULT_TTS_VOICE),
            ),
        };
        let speed = read("SPEECH_TTS_SPEED", "1.25")
            .parse::<f32>()
            .map_err(|_| SpeechError::Invalid("SPEECH_TTS_SPEED must be a number"))?;
        let value = Self {
            vendor,
            model,
            voice,
            speed,
        };
        value.validate()?;
        Ok(value)
    }
    fn validate(&self) -> Result<(), SpeechError> {
        pins(self.vendor)?;
        let range = if self.vendor == ProviderKind::XaiResponses {
            0.7..=1.5
        } else {
            0.25..=4.0
        };
        if !range.contains(&self.speed) {
            return Err(SpeechError::Invalid(
                "SPEECH_TTS_SPEED outside vendor range (OpenAI 0.25–4; xAI 0.7–1.5)",
            ));
        }
        if self.voice.trim().is_empty() {
            return Err(SpeechError::Invalid("Speech voice is empty"));
        }
        Ok(())
    }
    /// Vendor cap in Unicode characters, never UTF-8 bytes.
    pub fn character_cap(&self) -> usize {
        if self.vendor == ProviderKind::XaiResponses {
            15_000
        } else {
            4096
        }
    }
    /// Vendor body; xAI has no model parameter.
    pub fn request_body(&self, text: &str) -> Value {
        if self.vendor == ProviderKind::XaiResponses {
            json!({"text":text,"voice_id":self.voice,"language":"auto","output_format":{"codec":"pcm","sample_rate":SAMPLE_RATE},"speed":self.speed})
        } else {
            json!({"model":self.model,"input":text,"voice":self.voice,"response_format":"pcm","speed":self.speed})
        }
    }
    fn cache_key(&self, text: &str) -> String {
        let identity = json!({"vendor":format!("{:?}",self.vendor),"model":self.model,"voice":self.voice,"speed":self.speed,"text":text,"sample_rate":SAMPLE_RATE});
        format!("{:x}", Sha256::digest(identity.to_string().as_bytes()))
    }
}
fn lane_vendor(lane: &RuntimeLlmLane) -> Result<ProviderKind, SpeechError> {
    let vendor = lane
        .vendor()
        .ok_or_else(|| SpeechError::Unsupported(lane.provider_display_name().into()))?;
    pins(vendor).map_err(|_| SpeechError::Unsupported(lane.provider_display_name().into()))?;
    Ok(vendor)
}
/// None means credentials and configuration are present; it is not an API liveness claim.
pub fn speech_availability() -> Option<String> {
    let check = || -> Result<(), SpeechError> {
        let settings = Config::load_runtime_snapshot()
            .map_err(|_| SpeechError::Invalid("Speech settings could not be loaded"))?;
        let lane = settings.llm_lanes().assistive();
        let vendor = lane_vendor(lane)?;
        SpeechOptions::for_vendor(vendor)?;
        if !vendor_signed_in(vendor)
            && api_key(vendor, lane.credential().request_api_key().as_deref()).is_none()
        {
            return Err(SpeechError::MissingCredentials(pins(vendor)?.0));
        }
        Ok(())
    };
    check().err().map(|e| e.to_string())
}
/// Audio plus content-free cache/transport evidence.
pub struct SpeechAudio {
    pub samples: Vec<f32>,
    pub sample_rate: u32,
    pub cached: bool,
    pub http_status: Option<u16>,
    pub auth_source: AuthSource,
}
impl SpeechAudio {
    /// PCM duration, not request latency.
    pub fn duration_ms(&self) -> u64 {
        self.samples.len() as u64 * 1000 / u64::from(self.sample_rate)
    }
}
/// Reject partial samples rather than silently truncating a corrupt response.
pub fn decode_pcm(bytes: &[u8]) -> Result<Vec<f32>, SpeechError> {
    if bytes.is_empty() || !bytes.len().is_multiple_of(2) {
        return Err(SpeechError::Invalid("Invalid PCM16 speech response"));
    }
    Ok(bytes
        .chunks_exact(2)
        .map(|b| f32::from(i16::from_le_bytes([b[0], b[1]])) / 32768.0)
        .collect())
}
/// Lossless cap splitting, preferring whitespace boundaries when possible.
pub fn chunks(text: &str, cap: usize) -> Vec<&str> {
    if cap == 0 {
        return vec![];
    }
    let mut remaining = text;
    let mut result = Vec::new();
    while !remaining.is_empty() {
        let end = remaining
            .char_indices()
            .nth(cap)
            .map_or(remaining.len(), |(i, _)| i);
        let split = if end == remaining.len() {
            end
        } else {
            remaining[..end]
                .char_indices()
                .rev()
                .find(|(_, c)| c.is_whitespace())
                .map_or(end, |(i, c)| i + c.len_utf8())
        };
        result.push(&remaining[..split]);
        remaining = &remaining[split..];
    }
    result
}
fn cache_dir() -> Result<PathBuf, SpeechError> {
    let home =
        directories::BaseDirs::new().ok_or(SpeechError::Invalid("Home directory unavailable"))?;
    Ok(home.home_dir().join(".codescribe/cache/tts"))
}
/// Synthesize using the current assistive lane, sealed for the entire request.
pub async fn synthesize(text: &str) -> Result<SpeechAudio, SpeechError> {
    let settings = Config::load_runtime_snapshot()
        .map_err(|_| SpeechError::Invalid("Speech settings could not be loaded"))?;
    let lane = settings.llm_lanes().assistive();
    let vendor = lane_vendor(lane)?;
    let options = SpeechOptions::for_vendor(vendor)?;
    let auth = resolve_vendor_auth(vendor, None).await?;
    synthesize_with(text, &options, &auth).await
}
/// Probe entry point; uses the same network and cache path as the Agent.
pub async fn synthesize_with(
    text: &str,
    options: &SpeechOptions,
    auth: &SpeechAuth,
) -> Result<SpeechAudio, SpeechError> {
    let (_, _, endpoint) = pins(options.vendor)?;
    synthesize_at(text, options, auth, endpoint, &cache_dir()?).await
}
async fn synthesize_at(
    text: &str,
    options: &SpeechOptions,
    auth: &SpeechAuth,
    endpoint: &str,
    cache: &Path,
) -> Result<SpeechAudio, SpeechError> {
    options.validate()?;
    if text.trim().is_empty() {
        return Err(SpeechError::Invalid("No text to speak"));
    }
    tokio::fs::create_dir_all(cache)
        .await
        .map_err(|_| SpeechError::Invalid("Cannot create speech cache"))?;
    let path = cache.join(format!("{}.pcm", options.cache_key(text)));
    if let Ok(bytes) = tokio::fs::read(&path).await
        && let Ok(samples) = decode_pcm(&bytes)
    {
        return Ok(SpeechAudio {
            samples,
            sample_rate: SAMPLE_RATE,
            cached: true,
            http_status: None,
            auth_source: auth.source,
        });
    }
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(180))
        .connect_timeout(Duration::from_secs(15))
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .map_err(|_| SpeechError::Transport)?;
    let mut pcm = Vec::new();
    let mut status = None;
    for chunk in chunks(text, options.character_cap()) {
        let response = client
            .post(endpoint)
            .bearer_auth(&auth.bearer)
            .json(&options.request_body(chunk))
            .send()
            .await
            .map_err(|_| SpeechError::Transport)?;
        let code = response.status().as_u16();
        if !response.status().is_success() {
            return Err(SpeechError::Http(code));
        }
        status = Some(code);
        let is_json = response
            .headers()
            .get(reqwest::header::CONTENT_TYPE)
            .and_then(|v| v.to_str().ok())
            .is_some_and(|s| s.starts_with("application/json"));
        let bytes = response.bytes().await.map_err(|_| SpeechError::Transport)?;
        let bytes = if options.vendor == ProviderKind::XaiResponses && is_json {
            let body: Value = serde_json::from_slice(&bytes)
                .map_err(|_| SpeechError::Invalid("Invalid xAI speech response"))?;
            base64::engine::general_purpose::STANDARD
                .decode(
                    body.get("audio")
                        .and_then(Value::as_str)
                        .ok_or(SpeechError::Invalid("Missing xAI audio"))?,
                )
                .map_err(|_| SpeechError::Invalid("Invalid xAI base64 audio"))?
        } else {
            bytes.to_vec()
        };
        decode_pcm(&bytes)?;
        pcm.extend(bytes);
    }
    let samples = decode_pcm(&pcm)?;
    // Atomic per-call temporary file prevents concurrent writers publishing partial PCM.
    let tmp = cache.join(format!("{}.tmp", uuid::Uuid::new_v4()));
    let write = async {
        use tokio::io::AsyncWriteExt;
        let mut open = tokio::fs::OpenOptions::new();
        open.write(true).create_new(true);
        #[cfg(unix)]
        open.mode(0o600);
        let mut file = open.open(&tmp).await?;
        file.write_all(&pcm).await?;
        file.sync_all().await?;
        tokio::fs::rename(&tmp, &path).await
    }
    .await;
    if write.is_err() {
        let _ = tokio::fs::remove_file(&tmp).await;
        return Err(SpeechError::Invalid("Cannot write speech cache"));
    }
    Ok(SpeechAudio {
        samples,
        sample_rate: SAMPLE_RATE,
        cached: false,
        http_status: status,
        auth_source: auth.source,
    })
}

#[cfg(test)]
mod tests;
