//! The operation handlers (§6.1), grouped by prefix. Policy rows live on the
//! registry rows in `registry.rs`; what lives here is behavior — each handler
//! a port of the zsh dispatcher path it replaces, with the §6.2 collapses
//! applied.

pub mod gui;

use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

/// Run a helper to completion with a hard deadline, capturing both output
/// streams — the daemon's version of the dispatcher's `timeout 10 …`. A helper
/// past its deadline is killed and reported as a failure.
pub(crate) struct Finished {
    pub ok: bool,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
}

pub(crate) fn run_with_deadline(
    mut command: Command,
    deadline: Duration,
) -> std::io::Result<Finished> {
    command.stdin(Stdio::null());
    command.stdout(Stdio::piped());
    command.stderr(Stdio::piped());
    let mut child = command.spawn()?;

    // Readers on their own threads, so a chatty helper cannot deadlock against
    // a full pipe while the parent polls for exit.
    let stdout = child.stdout.take();
    let stderr = child.stderr.take();
    let out_reader = std::thread::spawn(move || read_all(stdout));
    let err_reader = std::thread::spawn(move || read_all(stderr));

    let started = Instant::now();
    let status = loop {
        match child.try_wait()? {
            Some(status) => break Some(status),
            None if started.elapsed() >= deadline => {
                let _ = child.kill();
                let _ = child.wait();
                break None;
            }
            None => std::thread::sleep(Duration::from_millis(20)),
        }
    };
    let stdout = out_reader.join().unwrap_or_default();
    let stderr = err_reader.join().unwrap_or_default();
    Ok(Finished {
        ok: status.is_some_and(|s| s.success()),
        stdout,
        stderr,
    })
}

fn read_all(pipe: Option<impl std::io::Read>) -> Vec<u8> {
    let mut buf = Vec::new();
    if let Some(mut pipe) = pipe {
        let _ = pipe.read_to_end(&mut buf);
    }
    buf
}

/// A private scratch directory for a handler that stages side files, removed
/// on drop. Under the system temp dir, mode 0700 like `testutil`'s.
pub(crate) struct Scratch(std::path::PathBuf);

impl Scratch {
    pub fn new(label: &str) -> std::io::Result<Scratch> {
        use std::os::unix::fs::DirBuilderExt;
        use std::sync::atomic::{AtomicU32, Ordering};
        static SEQ: AtomicU32 = AtomicU32::new(0);
        let seq = SEQ.fetch_add(1, Ordering::Relaxed);
        let path =
            std::env::temp_dir().join(format!("recobd-{label}-{}-{seq}", std::process::id()));
        std::fs::DirBuilder::new().mode(0o700).create(&path)?;
        Ok(Scratch(path))
    }

    pub fn path(&self) -> &std::path::Path {
        &self.0
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}
