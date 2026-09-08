//! Legacy URL inversion exists only at this one-shot migration boundary.
use super::settings::UserSettings;
use crate::stt::{SttLane, validate_stt_endpoint};

pub struct SttV2Legacy {
    pub cloud_transcription_endpoint: Option<String>,
}
impl SttV2Legacy {
    pub fn from_json(raw: &serde_json::Value) -> Self {
        Self {
            cloud_transcription_endpoint: raw
                .pointer("/speech/engine/cloud_transcription_endpoint")
                .or_else(|| raw.pointer("/stt_endpoint"))
                .and_then(serde_json::Value::as_str)
                .map(str::to_owned),
        }
    }
    pub(crate) fn from_endpoint(raw: &str) -> Self {
        Self {
            cloud_transcription_endpoint: Some(raw.into()),
        }
    }
    pub fn needs_migration(&self) -> bool {
        self.cloud_transcription_endpoint.is_some()
    }
}
pub struct SttMigrationStep {
    pub from: &'static str,
    pub to: &'static str,
    pub value: String,
}

fn invert_live_to_file(raw: &str) -> Option<String> {
    let mut url = reqwest::Url::parse(raw).ok()?;
    if !url.path().ends_with("/transcribe") {
        return None;
    }
    let scheme = match url.scheme() {
        "ws" => "http",
        "wss" => "https",
        _ => return None,
    };
    let loopback = crate::stt::tail_provider::stt_auth_mode(raw)
        == crate::stt::tail_provider::SttAuthMode::Unauthenticated;
    url.set_scheme(scheme).ok()?;
    url.set_path(&(url.path().trim_end_matches("transcribe").to_owned() + "transcriptions"));
    url.set_query(None);
    url.set_fragment(None);
    if loopback && url.port() == Some(8446) {
        url.set_port(Some(8444)).ok()?;
    }
    validate_stt_endpoint(SttLane::File, url.as_str()).ok()
}

/// R1–R4, without I/O. Existing explicit rows win over a legacy fallback.
pub fn migrate_legacy_stt_lanes(
    legacy: &SttV2Legacy,
    settings: &mut UserSettings,
) -> (Vec<SttMigrationStep>, Vec<&'static str>) {
    let mut steps = Vec::new();
    if let Some(raw) = legacy.cloud_transcription_endpoint.as_deref() {
        let (file, live) = if let Ok(live) = validate_stt_endpoint(SttLane::Live, raw) {
            (invert_live_to_file(&live), Some(live))
        } else if let Ok(file) = validate_stt_endpoint(SttLane::File, raw) {
            (Some(file), None)
        } else {
            tracing::warn!("Legacy STT endpoint is invalid; no lane synthesized");
            (None, None)
        };
        for (lane, target, value) in [
            (SttLane::File, &mut settings.stt_file_endpoint, file),
            (SttLane::Live, &mut settings.stt_live_endpoint, live),
        ] {
            if target.is_none()
                && let Some(value) = value
            {
                steps.push(SttMigrationStep {
                    from: "STT_ENDPOINT",
                    to: lane.wire_key(),
                    value: value.clone(),
                });
                *target = Some(value);
            }
        }
    }
    let mut targets: Vec<&'static str> = [
        (SttLane::File, &settings.stt_file_endpoint),
        (SttLane::Live, &settings.stt_live_endpoint),
    ]
    .into_iter()
    .filter(|(_, row)| row.as_deref().is_some_and(|v| !v.trim().is_empty()))
    .map(|(lane, _)| lane.key_account())
    .collect();
    if targets.is_empty() {
        targets.push(SttLane::File.key_account());
    }
    (steps, targets)
}

/// Retired `STT_ENDPOINT` alias split into `(file, live)` rows; warned once per process.
pub(crate) fn split_retired_stt_endpoint(raw: &str) -> (Option<String>, Option<String>) {
    static WARN: std::sync::Once = std::sync::Once::new();
    WARN.call_once(|| {
        tracing::warn!(
            "STT_ENDPOINT is retired; use STT_FILE_ENDPOINT / STT_LIVE_ENDPOINT (removed after 2026-10-15)"
        )
    });
    let mut settings = UserSettings::default();
    migrate_legacy_stt_lanes(&SttV2Legacy::from_endpoint(raw), &mut settings);
    (settings.stt_file_endpoint, settings.stt_live_endpoint)
}

/// Called with the settings transaction lock held, before legacy fields are serialized away.
pub fn migrate_legacy_stt_lanes_once(settings: &mut UserSettings) {
    let raw = std::fs::read(UserSettings::settings_path())
        .ok()
        .and_then(|bytes| serde_json::from_slice(&bytes).ok())
        .unwrap_or(serde_json::Value::Null);
    let legacy = SttV2Legacy::from_json(&raw);
    let (steps, targets) = migrate_legacy_stt_lanes(&legacy, settings);
    if !legacy.needs_migration() {
        return;
    }
    // Copy the retired `STT_API_KEY` into both lanes at the migration moment
    // only. A plain load must never open the Keychain by itself: an unsigned
    // CLI binary blocks on the authorization dialog (bisect 2026-09-08). The
    // retry after a Keychain outage lives in `keychain::populate_env_from_keychain`,
    // where the bundle is already open.
    super::keychain::fan_out_key("STT_API_KEY", &targets);
    match settings.save_unlocked() {
        Ok(()) => {
            *settings = UserSettings::from_v2(settings.to_v2());
            tracing::info!(rows = steps.len(), "Migrated legacy STT lanes");
        }
        Err(error) => tracing::warn!(%error, "Failed to persist STT lane migration"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const FOUNDER: &str = "wss://api.libraxis.cloud/v1/audio/transcribe";

    #[test]
    fn migrates_founder_wss_socket_into_both_lanes() {
        let mut settings = UserSettings::default();
        let legacy = SttV2Legacy::from_json(
            &serde_json::json!({"speech":{"engine":{"cloud_transcription_endpoint":FOUNDER}}}),
        );
        let (steps, targets) = migrate_legacy_stt_lanes(&legacy, &mut settings);
        assert_eq!(settings.stt_live_endpoint.as_deref(), Some(FOUNDER));
        assert_eq!(
            settings.stt_file_endpoint.as_deref(),
            Some("https://api.libraxis.cloud/v1/audio/transcriptions")
        );
        assert_eq!(targets, ["STT_FILE_API_KEY", "STT_LIVE_API_KEY"]);
        assert_eq!(steps.len(), 2);
    }

    #[test]
    fn http_legacy_lands_in_file_lane_only() {
        let mut settings = UserSettings::default();
        let legacy =
            SttV2Legacy::from_json(&serde_json::json!({"stt_endpoint":"https://example.com/stt"}));
        let (_, targets) = migrate_legacy_stt_lanes(&legacy, &mut settings);
        assert_eq!(
            settings.stt_file_endpoint.as_deref(),
            Some("https://example.com/stt")
        );
        assert_eq!(settings.stt_live_endpoint, None);
        assert_eq!(targets, ["STT_FILE_API_KEY"]);
        for raw in [
            "not a URL",
            "wss://example.com/live",
            "ws://127.0.0.1:8446/v1/audio/transcribe?q=x#f",
        ] {
            let mut settings = UserSettings::default();
            let legacy = SttV2Legacy {
                cloud_transcription_endpoint: Some(raw.into()),
            };
            migrate_legacy_stt_lanes(&legacy, &mut settings);
            if raw.contains("8446") {
                assert_eq!(
                    settings.stt_file_endpoint.as_deref(),
                    Some("http://127.0.0.1:8444/v1/audio/transcriptions")
                );
            } else {
                assert!(settings.stt_file_endpoint.is_none());
            }
        }
    }

    #[test]
    #[serial_test::serial]
    fn migration_is_idempotent_on_second_load() {
        let dir = tempfile::tempdir().unwrap();
        let previous = std::env::var_os("CODESCRIBE_DATA_DIR");
        // SAFETY: serialized test; restore the isolated data root after the witness.
        unsafe {
            std::env::set_var("CODESCRIBE_DATA_DIR", dir.path());
        }
        struct Restore(Option<std::ffi::OsString>);
        impl Drop for Restore {
            fn drop(&mut self) {
                // SAFETY: same serialized environment scope.
                unsafe {
                    match &self.0 {
                        Some(v) => std::env::set_var("CODESCRIBE_DATA_DIR", v),
                        None => std::env::remove_var("CODESCRIBE_DATA_DIR"),
                    }
                }
            }
        }
        let _restore = Restore(previous);
        std::fs::create_dir_all(UserSettings::settings_dir()).unwrap();
        for raw in [
            serde_json::json!({"stt_endpoint":FOUNDER}),
            serde_json::json!({"schema_version":3,"speech":{"engine":{"cloud_transcription_endpoint":FOUNDER},"llm_endpoint":"https://api.libraxis.cloud/v1/responses"}}),
        ] {
            std::fs::write(UserSettings::settings_path(), raw.to_string()).unwrap();
            let first = UserSettings::load();
            let bytes = std::fs::read(UserSettings::settings_path()).unwrap();
            let second = UserSettings::load();
            assert_eq!(first, second);
            assert_eq!(first.stt_live_endpoint.as_deref(), Some(FOUNDER));
            assert_eq!(
                first.stt_file_endpoint.as_deref(),
                Some("https://api.libraxis.cloud/v1/audio/transcriptions")
            );
            assert_eq!(bytes, std::fs::read(UserSettings::settings_path()).unwrap());
            assert!(
                !SttV2Legacy::from_json(&serde_json::from_slice(&bytes).unwrap()).needs_migration()
            );
        }
    }

    #[test]
    #[serial_test::serial]
    fn load_of_migrated_settings_never_opens_the_keychain() {
        // Bisect 2026-09-08: an unsigned `target/debug/codescribe transcribe`
        // hung in `SecItemCopyMatching` because every load retried the
        // `STT_API_KEY` fan-out. A migrated file must load without touching
        // the bundle; the retry belongs to the loader's Keychain step.
        let dir = tempfile::tempdir().unwrap();
        let previous = std::env::var_os("CODESCRIBE_DATA_DIR");
        // SAFETY: serialized test; restore the isolated data root after the witness.
        unsafe {
            std::env::set_var("CODESCRIBE_DATA_DIR", dir.path());
        }
        struct Restore(Option<std::ffi::OsString>);
        impl Drop for Restore {
            fn drop(&mut self) {
                // SAFETY: same serialized environment scope.
                unsafe {
                    match &self.0 {
                        Some(v) => std::env::set_var("CODESCRIBE_DATA_DIR", v),
                        None => std::env::remove_var("CODESCRIBE_DATA_DIR"),
                    }
                }
            }
        }
        let _restore = Restore(previous);
        std::fs::create_dir_all(UserSettings::settings_dir()).unwrap();
        let migrated = serde_json::json!({"schema_version":3,"speech":{"engine":{
            "file_transcription_endpoint":"https://api.libraxis.cloud/v1/audio/transcriptions",
            "live_transcription_endpoint":FOUNDER}}});
        std::fs::write(UserSettings::settings_path(), migrated.to_string()).unwrap();
        let _bundle =
            super::super::keychain::test_support::install_bundle(&[("STT_API_KEY", "retired")]);
        let loaded = UserSettings::load();
        assert_eq!(loaded.stt_live_endpoint.as_deref(), Some(FOUNDER));
        let bundle = super::super::keychain::test_support::snapshot_bundle().unwrap();
        assert_eq!(
            bundle.get("STT_API_KEY").map(String::as_str),
            Some("retired")
        );
        assert!(!bundle.contains_key("STT_FILE_API_KEY"));
        assert!(!bundle.contains_key("STT_LIVE_API_KEY"));
    }
}
