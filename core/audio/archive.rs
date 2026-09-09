//! Bounded archive-only conversion. The child owns only anonymous staging files.

use anyhow::{Context, Result, anyhow};
use std::fs::File;
use std::io::{Seek, SeekFrom};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

/// Existing Stop budget is 120s; archive conversion gets at most 15s of it.
const ENCODE_TIMEOUT: Duration = Duration::from_secs(15);

/// Own the child until it has been waited for, including error/unwind paths.
struct EncoderChild(Child);

impl Drop for EncoderChild {
    fn drop(&mut self) {
        if let Err(error) = self.0.kill() {
            // An already reaped child needs no kill; wait below remains harmless.
            tracing::debug!("archive child kill: {error}");
        }
        if let Err(error) = self.0.wait() {
            tracing::warn!("archive child reap failed: {error}");
        }
    }
}

/// Run an owned converter with seekable file descriptors, no pipes to fill,
/// and no unbounded diagnostic buffer. Status/timeout are the diagnostics.
fn run_encoder(command: &mut Command, input: &mut File, output: &mut File, timeout: Duration) -> Result<()> {
    input.seek(SeekFrom::Start(0))?;
    output.set_len(0)?;
    output.seek(SeekFrom::Start(0))?;
    let child = command
        .stdin(Stdio::from(input.try_clone()?))
        .stdout(Stdio::from(output.try_clone()?))
        .stderr(Stdio::null())
        .spawn().context("spawn archive encoder")?;
    supervise(child, output, timeout)
}

fn supervise(child: Child, output: &mut File, timeout: Duration) -> Result<()> {
    let mut child = EncoderChild(child);
    let started = Instant::now();
    loop {
        if let Some(status) = child.0.try_wait().context("poll archive encoder")? {
            anyhow::ensure!(status.success(), "archive encoder failed: {status}");
            anyhow::ensure!(output.metadata()?.len() > 0, "archive encoder returned empty success");
            output.seek(SeekFrom::Start(0))?;
            return Ok(());
        }
        anyhow::ensure!(started.elapsed() < timeout, "archive encoder deadline exceeded");
        // No detached waiter: this thread owns polling, termination and reaping.
        std::thread::park_timeout(Duration::from_millis(10));
    }
}

/// Encode private staged WAV to private staged AAC; neither is a published path.
/// /dev/fd/0 and /dev/fd/1 refer to the inherited regular files, not a caller path.
pub(crate) fn encode_wav_to_m4a(input: &mut File, output: &mut File) -> Result<()> {
    if cfg!(target_os = "macos") {
        run_encoder(
            Command::new("/usr/bin/afconvert")
                .args(["-f", "m4af", "-d", "aac@44100", "-b", "64000", "/dev/fd/0", "/dev/fd/1"]),
            input, output, ENCODE_TIMEOUT,
        )
    } else {
        Err(anyhow!("m4a archive encoding requires macOS afconvert"))
    }
}

/// Closed test scenarios: no caller-supplied shell program is accepted.
#[cfg(all(test, unix))]
pub(crate) enum TestEncoderOutcome {
    Failed,
    Empty,
    Hanging,
}

/// Inject the actual child owner into history failure tests (never afconvert).
#[cfg(all(test, unix))]
pub(crate) fn encode_test_child(input: &mut File, output: &mut File, outcome: TestEncoderOutcome) -> Result<()> {
    let mut command = Command::new("/bin/sh");
    match outcome {
        TestEncoderOutcome::Failed => command.args(["-c", "exit 9"]),
        TestEncoderOutcome::Empty => command.args(["-c", "exit 0"]),
        TestEncoderOutcome::Hanging => command.args(["-c", "while :; do :; done"]),
    };
    run_encoder(&mut command, input, output, Duration::from_millis(100))
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::io::{Read, Write};

    #[test]
    fn failed_empty_and_hanging_children_are_reaped_and_source_survives() {
        for script in ["exit 7", "exit 0", "while :; do :; done"] {
            let mut input = tempfile::tempfile().expect("input");
            input.write_all(b"admitted WAV").expect("fixture");
            let mut output = tempfile::tempfile().expect("output");
            let result = run_encoder(Command::new("/bin/sh").args(["-c", script]),
                &mut input, &mut output, Duration::from_millis(100));
            assert!(result.is_err());
            input.rewind().expect("rewind");
            let mut bytes = Vec::new();
            input.read_to_end(&mut bytes).expect("read");
            assert_eq!(bytes, b"admitted WAV");
        }
    }

    #[test]
    fn deadline_returns_only_after_owned_child_is_reaped() {
        let child = Command::new("/bin/sh").args(["-c", "while :; do :; done"])
            .stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null())
            .spawn().expect("child");
        let pid = child.id() as libc::pid_t;
        let mut output = tempfile::tempfile().expect("output");
        assert!(supervise(child, &mut output, Duration::ZERO).is_err());
        let mut status = 0;
        // SAFETY: check only the recorded child; the status pointer is valid.
        assert_eq!(unsafe { libc::waitpid(pid, &mut status, libc::WNOHANG) }, -1);
        assert_eq!(std::io::Error::last_os_error().raw_os_error(), Some(libc::ECHILD));
    }

    #[test]
    fn successful_child_uses_only_inherited_files() {
        let mut input = tempfile::tempfile().expect("input");
        input.write_all(b"staged audio").expect("fixture");
        let mut output = tempfile::tempfile().expect("output");
        run_encoder(&mut Command::new("/bin/cat"), &mut input, &mut output,
            Duration::from_secs(2)).expect("converter");
        let mut bytes = Vec::new();
        output.read_to_end(&mut bytes).expect("read");
        assert_eq!(bytes, b"staged audio");
    }
}
