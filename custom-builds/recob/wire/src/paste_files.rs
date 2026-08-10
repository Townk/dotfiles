//! `paste --files`: materialize the current file clip into a directory.
//!
//! A port of `executable_pbpaste`'s materialization engine, which is the
//! largest body of behavior in either shim and the one with the most
//! hard-won detail: staging so a kill never leaves a partial entry in the
//! target, rename-aside recovery so a forced replacement can be restored,
//! conflict and duplicate-basename refusal *before* any transfer, the
//! per-item size cap with its parse contract, and the porcelain stream two
//! other programs read.
//!
//! Two things the wire changes, both simplifications the old design could not
//! have: `files.fetch` declares `kind`, so the `is-directory` retry — and the
//! second connection it cost — is gone; and §6.4's explicit empty `D` makes a
//! truncated archive detectable by the protocol rather than only by tar's own
//! opinion of what it received.
//!
//! **The messages say `pbpaste:`, not `system-clip:`.** They are a parse
//! contract: `smart-paste.yazi` anchors on `^pbpaste: ` to recognize a cap
//! refusal, and the name a user sees is the shim they invoked. The binary's
//! own name never appears in output for that reason.

use std::io::{Read, Write};
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::process::Command;

use crate::client::{ClientError, ClientStream, Session, StreamSink};
use crate::wire::Fields;

/// §11's per-item cap, from the same variable the shim honors. Read once by
/// the caller into [`Context`] rather than by the engine: a policy the engine
/// looked up itself would be process-global state two callers could not hold
/// different opinions about.
pub fn size_cap_from_env() -> u64 {
    std::env::var("CLIP_FILE_MAX")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(209_715_200)
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Output {
    Auto,
    Quiet,
    Progress,
    Porcelain,
}

pub struct Options {
    pub force: bool,
    pub output: Output,
    pub dir: PathBuf,
}

impl Options {
    /// `[--force] [--quiet|--progress|--porcelain] [dir]`, argument order and
    /// refusals as the shim parses them.
    pub fn parse(args: &[String]) -> Result<Options, String> {
        let mut force = false;
        let mut output = Output::Auto;
        let mut dir: Option<String> = None;
        let mut rest = args.iter();
        let mut positional_only = false;
        for arg in rest.by_ref() {
            if positional_only {
                if dir.replace(arg.clone()).is_some() {
                    return Err("pbpaste: too many arguments".to_string());
                }
                continue;
            }
            match arg.as_str() {
                "--force" => force = true,
                "--quiet" => output = Output::Quiet,
                "--progress" => output = Output::Progress,
                "--porcelain" => output = Output::Porcelain,
                "--" => positional_only = true,
                other if other.starts_with('-') => {
                    return Err(format!("pbpaste: unknown option: {other}"))
                }
                other => {
                    if dir.replace(other.to_string()).is_some() {
                        return Err("pbpaste: too many arguments".to_string());
                    }
                }
            }
        }
        let dir = dir.map_or_else(
            || std::env::current_dir().map_err(|e| format!("pbpaste: cannot resolve cwd: {e}")),
            |dir| Ok(PathBuf::from(dir)),
        )?;
        if !dir.is_dir() {
            return Err(format!("pbpaste: no such directory: {}", dir.display()));
        }
        Ok(Options { force, output, dir })
    }

    fn show(&self) -> bool {
        match self.output {
            Output::Progress => true,
            Output::Auto => is_terminal_stdout(),
            Output::Quiet | Output::Porcelain => false,
        }
    }

    fn porcelain(&self) -> bool {
        self.output == Output::Porcelain
    }
}

fn is_terminal_stdout() -> bool {
    extern "C" {
        fn isatty(fd: i32) -> i32;
    }
    unsafe { isatty(1) == 1 }
}

/// The manifest `files.grant` answers with.
pub struct Manifest {
    pub kind: String,
    pub host: String,
    pub token: String,
    pub paths: Vec<PathBuf>,
}

impl Manifest {
    fn from_reply(reply: &Fields) -> Result<Manifest, String> {
        let text =
            |name: &str| String::from_utf8_lossy(reply.get(name).unwrap_or_default()).into_owned();
        let paths: Vec<PathBuf> = reply
            .get("paths")
            .unwrap_or_default()
            .split(|byte| *byte == 0)
            .filter(|path| !path.is_empty())
            .map(|path| PathBuf::from(std::ffi::OsStr::from_bytes(path)))
            .collect();
        if paths.is_empty() {
            return Err("pbpaste: clipboard bridge returned an empty file manifest".to_string());
        }
        Ok(Manifest {
            kind: text("kind"),
            host: text("host"),
            token: text("token"),
            paths,
        })
    }

    /// A real capability, as opposed to the `-` a pointer row answers with.
    fn has_capability(&self) -> bool {
        self.token.len() == 64 && self.token.bytes().all(|b| b.is_ascii_hexdigit())
    }
}

/// Everything the run must undo if it does not finish. Drop covers the normal
/// and panicking paths; the signal flag covers Ctrl+C; a SIGKILL is covered by
/// the next run's sweep, exactly as before.
struct Workspace {
    staging: PathBuf,
    recovery: PathBuf,
}

impl Workspace {
    fn new(dir: &Path) -> Result<Workspace, String> {
        let pid = std::process::id();
        let workspace = Workspace {
            staging: dir.join(format!(".pbpaste-staging.{pid}")),
            recovery: dir.join(format!(".pbpaste-recovery.{pid}")),
        };
        std::fs::create_dir_all(&workspace.staging).map_err(|e| {
            format!(
                "pbpaste: could not create staging dir under {}: {e}",
                dir.display()
            )
        })?;
        Ok(workspace)
    }
}

impl Drop for Workspace {
    fn drop(&mut self) {
        // Order is load-bearing: restore any displaced original whose
        // destination is missing FIRST, then discard the disposable staging.
        recover_dir(&self.recovery);
        let _ = std::fs::remove_dir_all(&self.staging);
    }
}

/// Restore every displaced original whose destination is currently absent —
/// the replacement never landed — then drop the recovery dir. Idempotent, so
/// the same pass serves this run's cleanup and a later run's stale sweep.
fn recover_dir(recovery: &Path) {
    let Ok(entries) = std::fs::read_dir(recovery) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let Some(name) = path
            .file_name()
            .and_then(|name| name.to_str())
            .map(str::to_string)
        else {
            continue;
        };
        let Some(index) = name.strip_prefix("bak.") else {
            continue;
        };
        let sidecar = recovery.join(format!("final.{index}"));
        let Ok(raw) = std::fs::read(&sidecar) else {
            continue;
        };
        if raw.is_empty() {
            continue;
        }
        let destination = PathBuf::from(std::ffi::OsStr::from_bytes(&raw));
        if !destination.exists() {
            let _ = std::fs::rename(&path, &destination);
        }
    }
    let _ = std::fs::remove_dir_all(recovery);
}

/// Sweep what a previous run left behind when it could not clean up after
/// itself. PID-gated, never a blind wildcard: a genuinely concurrent run's
/// live directories belong to it.
fn sweep_stale(dir: &Path) {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    let mut staging = Vec::new();
    let mut recovery = Vec::new();
    for entry in entries.flatten() {
        let path = entry.path();
        let Some(name) = path
            .file_name()
            .and_then(|name| name.to_str())
            .map(str::to_string)
        else {
            continue;
        };
        if let Some(pid) = name.strip_prefix(".pbpaste-recovery.") {
            recovery.push((path, pid.to_string()));
        } else if let Some(pid) = name.strip_prefix(".pbpaste-staging.") {
            staging.push((path, pid.to_string()));
        }
    }
    // Recover before reaping: a restore must not be undone by a sweep.
    for (path, pid) in recovery {
        if !pid_alive(&pid) {
            recover_dir(&path);
        }
    }
    for (path, pid) in staging {
        if !pid_alive(&pid) {
            let _ = std::fs::remove_dir_all(&path);
        }
    }
}

fn pid_alive(pid: &str) -> bool {
    extern "C" {
        fn kill(pid: i32, sig: i32) -> i32;
    }
    match pid.parse::<i32>() {
        Ok(pid) if pid > 0 => unsafe { kill(pid, 0) == 0 },
        // An unparseable suffix is not a live run's directory.
        _ => false,
    }
}

// --- interruption -----------------------------------------------------------

static INTERRUPTED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

extern "C" fn note_signal(_sig: i32) {
    // The only async-signal-safe thing this does is set a flag; the checks in
    // the item and chunk loops turn it into an orderly exit with cleanup.
    INTERRUPTED.store(true, std::sync::atomic::Ordering::SeqCst);
}

fn install_signal_handlers() {
    extern "C" {
        fn signal(sig: i32, handler: usize) -> usize;
    }
    const SIGINT: i32 = 2;
    const SIGTERM: i32 = 15;
    let handler = note_signal as *const () as usize;
    unsafe {
        signal(SIGINT, handler);
        signal(SIGTERM, handler);
    }
}

fn interrupted() -> bool {
    INTERRUPTED.load(std::sync::atomic::Ordering::SeqCst)
}

// --- sizes and rendering ----------------------------------------------------

/// Bytes for the progress fields: exact for a file, `du -sk`-derived for a
/// directory, and a refusal for a symlink or anything unreadable — the shim's
/// fail-closed rule when no trustworthy size exists.
fn item_size(path: &Path) -> Option<u64> {
    let meta = std::fs::symlink_metadata(path).ok()?;
    if meta.file_type().is_symlink() {
        return None;
    }
    if meta.is_dir() {
        let out = Command::new("du").arg("-sk").arg(path).output().ok()?;
        if !out.status.success() {
            return None;
        }
        let text = String::from_utf8_lossy(&out.stdout);
        let kb: u64 = text.split_whitespace().next()?.parse().ok()?;
        Some(kb * 1024)
    } else if meta.is_file() {
        Some(meta.len())
    } else {
        None
    }
}

pub fn human_size(bytes: u64) -> String {
    if bytes >= 1_073_741_824 {
        format!("{:.1}G", bytes as f64 / 1_073_741_824.0)
    } else if bytes >= 1_048_576 {
        format!("{:.1}M", bytes as f64 / 1_048_576.0)
    } else if bytes >= 1024 {
        format!("{:.1}K", bytes as f64 / 1024.0)
    } else {
        format!("{bytes}B")
    }
}

/// The conflict scan, run before any transfer: names already in the target
/// (waived by `--force`) and two manifest entries sharing one basename (never
/// waived — materializing both into one flat directory would silently make
/// the last one win).
pub fn conflicts(
    paths: &[PathBuf],
    dir: &Path,
    force: bool,
    exists: &dyn Fn(&Path) -> bool,
) -> Result<(), String> {
    let mut seen: Vec<Vec<u8>> = Vec::new();
    let mut dupes: Vec<String> = Vec::new();
    let mut existing: Vec<String> = Vec::new();
    for path in paths {
        let Some(name) = path.file_name() else {
            return Err(format!(
                "pbpaste: manifest entry has no name: {}",
                path.display()
            ));
        };
        let key = name.as_bytes().to_vec();
        if seen.contains(&key) {
            dupes.push(name.to_string_lossy().into_owned());
        } else {
            seen.push(key);
        }
        if !force && exists(&dir.join(name)) {
            existing.push(name.to_string_lossy().into_owned());
        }
    }
    if !dupes.is_empty() {
        let mut message = String::from(
            "pbpaste: clip contains multiple items with the same name -- cannot paste into one directory:",
        );
        for name in dupes {
            message.push_str(&format!("\n  {name}"));
        }
        return Err(message);
    }
    if !existing.is_empty() {
        let mut message =
            String::from("pbpaste: refusing to overwrite existing items (use --force):");
        for name in existing {
            message.push_str(&format!("\n  {name}"));
        }
        return Err(message);
    }
    Ok(())
}

/// §11's cap prompt. The refusal line is a **parse contract**: `smart-paste`
/// matches everything up through `-- refusing` to tell a cap refusal from any
/// other failure, and raises its own dialog. Only the text after `refusing`
/// is free-form.
fn cap_check(label: &Path, bytes: u64, cap: u64, interactive: bool) -> Result<(), String> {
    if bytes <= cap {
        return Ok(());
    }
    let label = label.display();
    if interactive && has_tty() {
        if confirm_over_cap(&format!(
            "pbpaste: {label} ({bytes} bytes) exceeds CLIP_FILE_MAX ({cap} bytes) -- continue?"
        )) {
            return Ok(());
        }
        return Err(format!("pbpaste: aborted at user request ({label})"));
    }
    Err(format!(
        "pbpaste: {label} exceeds size cap (CLIP_FILE_MAX={cap} bytes, item is {bytes} bytes) \
         -- refusing (no interactive confirm available; set CLIP_FILE_MAX={bytes} or higher to allow)"
    ))
}

/// Interactivity is decided by a usable controlling terminal, never by
/// `isatty(0)`: stdin here is the caller's, not a tty, and the prompt is
/// read and written through `/dev/tty` so it touches neither stdin nor the
/// porcelain-reserved stdout.
fn has_tty() -> bool {
    is_terminal_stdout()
        && std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .open("/dev/tty")
            .is_ok()
}

fn confirm_over_cap(prompt: &str) -> bool {
    if which("gum") {
        let mut cmd = Command::new("gum");
        cmd.arg("confirm").arg(prompt);
        // Every gum dialog is themed from the palette; the hex values come
        // from the generated JSON projection, never from exported shell
        // variables, and fall back to the literals on any failure.
        cmd.env("COLORTERM", "truecolor")
            .env("GUM_CONFIRM_PROMPT_FOREGROUND", palette("dialog_warning"))
            .env("GUM_CONFIRM_SELECTED_BACKGROUND", palette("dialog_warning"))
            .env("GUM_CONFIRM_SELECTED_FOREGROUND", palette("crust"))
            .env("GUM_CONFIRM_UNSELECTED_FOREGROUND", palette("subtext0"))
            .env("GUM_CONFIRM_UNSELECTED_BACKGROUND", palette("surface0"));
        if let (Ok(input), Ok(output)) = (tty_handle(false), tty_handle(true)) {
            cmd.stdin(input);
            cmd.stdout(output);
        }
        return cmd.status().map(|status| status.success()).unwrap_or(false);
    }
    let Ok(mut tty) = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open("/dev/tty")
    else {
        return false;
    };
    let _ = write!(tty, "{prompt} [y/N] ");
    let _ = tty.flush();
    let mut answer = [0u8; 1];
    matches!(tty.read(&mut answer), Ok(1) if answer[0] == b'y' || answer[0] == b'Y')
}

fn tty_handle(write: bool) -> std::io::Result<std::fs::File> {
    std::fs::OpenOptions::new()
        .read(!write)
        .write(write)
        .open("/dev/tty")
}

fn which(bin: &str) -> bool {
    std::env::var_os("PATH")
        .is_some_and(|paths| std::env::split_paths(&paths).any(|dir| dir.join(bin).is_file()))
}

/// One themed colour, read from the same generated JSON projection every
/// other non-zsh consumer reads, with the Mocha literal as the fallback on
/// any failure — a missing or stale palette must never block a dialog.
fn palette(field: &str) -> String {
    let (keys, fallback): (&[&str], &str) = match field {
        "dialog_warning" => (&["extended", "dialog", "warning"], "#e5bf7b"),
        "crust" => (&["palette", "crust"], "#11111b"),
        "subtext0" => (&["palette", "subtext0"], "#a6adc8"),
        _ => (&["palette", "surface0"], "#313244"),
    };
    palette_json()
        .and_then(|json| extract_hex(&json, keys))
        .unwrap_or_else(|| fallback.to_string())
}

fn palette_json() -> Option<String> {
    // The same resolution order every zsh reader uses, so this dialog stays on
    // the palette the rest of the session is wearing (including an SSH tint).
    if let Some(explicit) = std::env::var_os("THEME_PALETTE_JSON") {
        return std::fs::read_to_string(explicit).ok();
    }
    let cache = std::env::var_os("XDG_CACHE_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join(".cache")
        });
    let cached = cache.join("theme/chezmoi-system.json");
    if let Ok(text) = std::fs::read_to_string(&cached) {
        return Some(text);
    }
    let config = std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join(".config")
        });
    std::fs::read_to_string(config.join("theme/chezmoi-system.json")).ok()
}

/// A deliberately small nested-key scan rather than a JSON dependency: the
/// contract is "a `#rrggbb` under this key path, or the fallback", and every
/// failure mode lands on the fallback.
fn extract_hex(json: &str, keys: &[&str]) -> Option<String> {
    let mut cursor = 0;
    for key in keys {
        let needle = format!("\"{key}\"");
        let found = json[cursor..].find(&needle)?;
        cursor += found + needle.len();
    }
    let value_start = json[cursor..].find('#')? + cursor;
    let value_end = json[value_start..].find('"')? + value_start;
    let value = &json[value_start..value_end];
    if value.len() == 7 && value[1..].bytes().all(|b| b.is_ascii_hexdigit()) {
        Some(value.to_string())
    } else {
        None
    }
}

// --- the run ----------------------------------------------------------------

struct Progress<'a> {
    options: &'a Options,
    inflight: bool,
    started: std::time::Instant,
    files: u64,
    bytes: u64,
}

impl<'a> Progress<'a> {
    fn new(options: &'a Options) -> Progress<'a> {
        Progress {
            options,
            inflight: false,
            started: std::time::Instant::now(),
            files: 0,
            bytes: 0,
        }
    }

    /// The in-flight line: one `\r`-rewritten line for a human, the raw
    /// counter for porcelain. Percent is clamped at 100 because a directory
    /// total is an estimate; the porcelain counter is never clamped, because
    /// it must not lie about what was actually transferred.
    fn tick(&mut self, item: &Path, done: u64, total: u64, item_started: std::time::Instant) {
        if self.options.porcelain() {
            println!("progress\t{}\t{done}\t{total}", item.display());
        } else if self.options.show() {
            let percent = done
                .checked_mul(100)
                .and_then(|scaled| scaled.checked_div(total))
                .map_or(0, |percent| std::cmp::min(100, percent));
            let elapsed = std::cmp::max(1, item_started.elapsed().as_secs());
            let rate = human_size(done / elapsed);
            let name = item
                .file_name()
                .map(|name| name.to_string_lossy().into_owned())
                .unwrap_or_default();
            print!("\r{name}  {done}/{total}  {percent}%  {rate}/s");
            let _ = std::io::stdout().flush();
            self.inflight = true;
        }
    }

    fn placed(&mut self, name: &str, size: u64, destination: &Path) {
        self.files += 1;
        self.bytes += size;
        if self.options.porcelain() {
            println!("progress\t{}\t{size}\t{size}", destination.display());
        } else if self.options.show() {
            if self.inflight {
                // Clear the in-flight line so the two never visually collide.
                print!("\r\x1b[K");
                self.inflight = false;
            }
            println!("✓ {name} ({})", human_size(size));
        }
    }

    fn finish(&self) {
        let elapsed = self.started.elapsed().as_secs();
        if self.options.porcelain() {
            println!("done\t{}\t{}\t{elapsed}", self.files, self.bytes);
        } else if self.options.show() {
            println!(
                "done: {} file(s), {} in {elapsed}s",
                self.files,
                human_size(self.bytes)
            );
        }
    }
}

/// The local copy tiers: APFS clone, then brew rsync with its live meter,
/// then `cp -a` with one honest note that this transfer has no meter.
fn copy_local(src: &Path, dst: &Path, show: bool, noted: &mut bool) -> Result<(), String> {
    if cfg!(target_os = "macos")
        && Command::new("cp")
            .arg("-Rc")
            .arg("--")
            .arg(src)
            .arg(dst)
            .status()
            .map(|s| s.success())
            .unwrap_or(false)
    {
        return Ok(());
    }
    // A failed tier can leave a partial destination; the next tier must not
    // merge into it or nest beneath it.
    let _ = std::fs::remove_dir_all(dst);
    let _ = std::fs::remove_file(dst);

    let brew_rsync = Path::new("/opt/homebrew/bin/rsync");
    if brew_rsync.is_file() {
        let mut from = src.as_os_str().to_os_string();
        if src.is_dir() {
            // "contents into a pre-made destination" is byte-equivalent to
            // `cp -R src dst` for a directory.
            from.push("/");
            std::fs::create_dir_all(dst).map_err(|e| format!("pbpaste: {e}"))?;
        }
        let mut cmd = Command::new(brew_rsync);
        cmd.arg("-a")
            .arg("--info=progress2")
            .arg("--")
            .arg(from)
            .arg(dst);
        if show {
            // The tier-2 promise is the live meter — on stderr, so a
            // porcelain stdout stream stays parseable.
            cmd.stdout(std::process::Stdio::inherit());
        } else {
            cmd.stdout(std::process::Stdio::null());
            cmd.stderr(std::process::Stdio::null());
        }
        if cmd.status().map(|s| s.success()).unwrap_or(false) {
            return Ok(());
        }
        let _ = std::fs::remove_dir_all(dst);
        let _ = std::fs::remove_file(dst);
    }

    if !*noted && show {
        eprintln!("pbpaste: no live progress meter for this transfer (cp -a fallback)");
        *noted = true;
    }
    let status = Command::new("cp")
        .arg("-a")
        .arg("--")
        .arg(src)
        .arg(dst)
        .status()
        .map_err(|e| format!("pbpaste: cannot run cp: {e}"))?;
    if status.success() {
        Ok(())
    } else {
        Err(format!("pbpaste: failed to copy {}", src.display()))
    }
}

/// Move a staged item into place. Every destination-visible step is a rename:
/// a forced replacement displaces the original into the recovery dir (with
/// its sidecar written first), so a kill between the two renames leaves the
/// name briefly absent but the original fully intact and restorable.
fn place(
    workspace: &Workspace,
    index: usize,
    staged: &Path,
    destination: &Path,
) -> Result<(), String> {
    let mut displaced = None;
    if destination.symlink_metadata().is_ok() {
        std::fs::create_dir_all(&workspace.recovery)
            .map_err(|e| format!("pbpaste: could not create recovery dir: {e}"))?;
        let backup = workspace.recovery.join(format!("bak.{index}"));
        std::fs::write(
            workspace.recovery.join(format!("final.{index}")),
            destination.as_os_str().as_bytes(),
        )
        .map_err(|e| format!("pbpaste: failed to record replacement: {e}"))?;
        std::fs::rename(destination, &backup).map_err(|e| {
            format!(
                "pbpaste: failed to displace existing {}: {e}",
                destination.display()
            )
        })?;
        displaced = Some(backup);
    }
    match std::fs::rename(staged, destination) {
        Ok(()) => {
            if let Some(backup) = displaced {
                // The replacement landed, so the displaced original is stale.
                let _ = std::fs::remove_dir_all(&backup);
                let _ = std::fs::remove_file(&backup);
                let _ = std::fs::remove_file(workspace.recovery.join(format!("final.{index}")));
            }
            Ok(())
        }
        Err(e) => {
            if let Some(backup) = displaced {
                let _ = std::fs::rename(&backup, destination);
                let _ = std::fs::remove_file(workspace.recovery.join(format!("final.{index}")));
            }
            Err(format!(
                "pbpaste: failed to move {} into {}: {e}",
                staged.display(),
                destination.display()
            ))
        }
    }
}

/// What the engine needs to know about the machine it runs on. Explicit
/// rather than read from the environment inside, so the decisions it drives —
/// local versus mounted versus streamed — are testable without mutating
/// process-global state.
pub struct Context {
    /// This machine's identity, for the manifest-host comparison.
    pub self_host: Option<String>,
    /// Whether this shell is on the far end of the tunnel. Over SSH a remote
    /// manifest streams; sitting at the Mac it must be mounted or localized,
    /// because the origin's endpoint is not forwarded back here.
    pub over_ssh: bool,
    pub mount_helper: PathBuf,
    /// §11's per-item size cap.
    pub cap: u64,
    /// Whether an over-cap item may be put to the human instead of refused.
    /// Injected rather than sensed inside the engine, for the same reason
    /// `cap` and `over_ssh` are: read from the ambient terminal down in
    /// `cap_check`, it made the refusal untestable and — worse — let a TEST
    /// open a real dialog. `cargo test` captures output per thread without
    /// replacing fd 1, so `isatty(1)` is true whenever the suite is run from
    /// a terminal; the cap tests then prompted, took the answer as consent,
    /// and failed on the machine of whoever ran them interactively (caught
    /// on the dev-shell). The binary decides this once, at the edge.
    pub interactive: bool,
}

/// How the items are sourced.
enum Source {
    /// Paths this machine can read directly — a same-host clip, a
    /// picker-localized cache row, or a manifest mapped through a peer mount.
    Local(Vec<PathBuf>),
    /// The clip lives on the machine at the other end of the connection.
    Remote,
}

/// `paste --files`, whole. `session` is the endpoint the manifest and any
/// remote bytes come from; `self_host` decides whether the clip is this
/// machine's.
pub fn run<S: ClientStream>(
    session: &mut Session<S>,
    options: &Options,
    context: &Context,
) -> Result<(), String> {
    install_signal_handlers();

    let reply = session
        .exchange(&Fields::new().with("op", b"files.grant".to_vec()), false)
        .map_err(|e| match &e {
            // §8 rule 3: the code is the contract. The shim grepped message
            // text for `not-files`; the reason field carries the fact now.
            ClientError::Server { code, .. } if code == "not-found" => {
                "pbpaste: current clipboard entry is not a files clip -- use plain pbpaste to read it as text"
                    .to_string()
            }
            _ => format!("pbpaste: {e}"),
        })?;
    let manifest = Manifest::from_reply(&reply)?;

    let is_this_machine =
        manifest.host.is_empty() || Some(manifest.host.as_str()) == context.self_host.as_deref();
    let mut source = if is_this_machine {
        Source::Local(manifest.paths.clone())
    } else {
        Source::Remote
    };

    // A remote manifest read from a machine that is not over SSH — a Mac
    // holding a peer's clip — cannot stream: the peer's endpoint is not
    // forwarded back here. Prefer an already-localized picker cache row,
    // else map through the healthy read-only peer mount, else say plainly
    // that the mount is the missing piece.
    let mut deferred_sizes = false;
    if matches!(source, Source::Remote) && !context.over_ssh {
        let cache_root = std::env::var_os("PICK_CLIPBOARD_CACHE_ROOT")
            .map(PathBuf::from)
            .unwrap_or_else(|| {
                PathBuf::from(std::env::var_os("HOME").unwrap_or_default())
                    .join(".cache/pick-clipboard/files")
            });
        let all_cached = manifest.paths.iter().all(|path| {
            path.starts_with(&cache_root)
                && !path.components().any(|c| c.as_os_str() == "..")
                && path.exists()
        });
        if all_cached && manifest.has_capability() {
            source = Source::Local(manifest.paths.clone());
        } else if let Some(mount_point) = mount_check(&context.mount_helper, &manifest.host) {
            let mut mapped = Vec::with_capacity(manifest.paths.len());
            for path in &manifest.paths {
                mapped.push(
                    mount_map(&context.mount_helper, &manifest.host, path).ok_or_else(|| {
                        format!(
                            "pbpaste: cannot map remote clipboard path: {}",
                            path.display()
                        )
                    })?,
                );
            }
            let _ = mount_point;
            source = Source::Local(mapped);
            // Sizes come from the staged copies: the mount can vanish
            // mid-run, and a size read from it afterwards would be a lie.
            deferred_sizes = true;
        } else {
            return Err(format!(
                "pbpaste: manifest lives on {} and its mount is unavailable -- use pick-clipboard Ctrl-Y to localize it on this Mac",
                manifest.host
            ));
        }
    }

    // §9.3: a pointer row cannot mint file authority, and the shim's
    // PF_REQUIRE_CAP demanded a real capability on every route but two. The
    // exemptions are load-bearing: a mount-mapped read's authority is the
    // read-only peer mount itself (the local daemon can never mint a token
    // for a peer's files), and over SSH the manifest comes from the ORIGIN's
    // daemon, which cannot mint authority over this machine's own paths —
    // refusing there would break the ordinary paste-back flow. A self-host
    // pointer row read AT this machine has neither excuse: this daemon mints
    // tokens for every row it vouches for, so `-` means unauthorized bytes
    // (the shape a peer-mount-enriched pasteboard produces).
    if !manifest.has_capability()
        && (matches!(source, Source::Remote) || (is_this_machine && !context.over_ssh))
    {
        return Err(
            "pbpaste: origin did not authorize this manifest for remote file transfer; copy the files again on the origin"
                .to_string(),
        );
    }

    sweep_stale(&options.dir);

    // Names are always the manifest's basenames, even when the sources were
    // mapped through a mount.
    let names: Vec<PathBuf> = manifest.paths.clone();
    conflicts(&names, &options.dir, options.force, &|path| {
        path.symlink_metadata().is_ok()
    })?;

    if let Source::Local(paths) = &source {
        for path in paths {
            if path.symlink_metadata().is_err() {
                return Err(format!(
                    "pbpaste: source no longer exists: {}",
                    path.display()
                ));
            }
        }
    }

    let workspace = Workspace::new(&options.dir)?;
    let mut progress = Progress::new(options);
    let mut cp_noted = false;
    let mut staged: Vec<(PathBuf, PathBuf, Option<u64>)> = Vec::new();

    for (index, name) in names.iter().enumerate() {
        if interrupted() {
            return Err("pbpaste: interrupted".to_string());
        }
        let base = name
            .file_name()
            .ok_or_else(|| format!("pbpaste: manifest entry has no name: {}", name.display()))?;
        let stage_target = workspace.staging.join(base);
        let destination = options.dir.join(base);

        let size = match &source {
            Source::Local(paths) => {
                let src = &paths[index];
                let size = item_size(src).ok_or_else(|| {
                    format!(
                        "pbpaste: could not determine source size: {}",
                        src.display()
                    )
                })?;
                // §11's cap is scoped to transfers that cross a machine
                // boundary — the shim gated every local-engine cap_check on
                // PF_MOUNT_REMOTE, so a same-host copy of the user's own file
                // is never capped. On the mount route this is the preflight
                // check against the source's size, which spares copying a
                // refused item across the mount; the staged copies are
                // re-measured and re-checked whole before placement below.
                if deferred_sizes {
                    cap_check(&destination, size, context.cap, context.interactive)?;
                }
                copy_local(src, &stage_target, options.show(), &mut cp_noted)?;
                if deferred_sizes {
                    None
                } else {
                    Some(size)
                }
            }
            Source::Remote => Some(fetch_item(
                session,
                index + 1,
                &manifest,
                &stage_target,
                &destination,
                &mut progress,
                context,
            )?),
        };
        staged.push((stage_target, destination, size));
    }

    // Placement, deferred whole when the sizes had to come from the staged
    // copies rather than from a mount that may no longer be there. Two passes,
    // as the shim ran them: every deferred item is measured and cap-checked
    // BEFORE the first one is placed, so a refusal anywhere leaves the target
    // untouched — which is what makes a refusal safe to retry with a higher
    // cap.
    let mut resolved: Vec<(&PathBuf, &PathBuf, u64)> = Vec::with_capacity(staged.len());
    for (stage_target, destination, size) in &staged {
        let size = match size {
            Some(size) => *size,
            None => {
                let size = item_size(stage_target).ok_or_else(|| {
                    format!(
                        "pbpaste: could not determine staged item size: {}",
                        destination.display()
                    )
                })?;
                cap_check(destination, size, context.cap, context.interactive)?;
                size
            }
        };
        resolved.push((stage_target, destination, size));
    }
    for (index, (stage_target, destination, size)) in resolved.into_iter().enumerate() {
        place(&workspace, index + 1, stage_target, destination)?;
        let name = destination
            .file_name()
            .map(|name| name.to_string_lossy().into_owned())
            .unwrap_or_default();
        progress.placed(&name, size, destination);
    }

    progress.finish();
    Ok(())
}

/// One remote item. `kind` in the head decides file or directory — the
/// `is-directory` error, and the second connection it forced, are gone (§6.2).
/// Returns the bytes actually delivered.
fn fetch_item<S: ClientStream>(
    session: &mut Session<S>,
    index: usize,
    manifest: &Manifest,
    stage_target: &Path,
    destination: &Path,
    progress: &mut Progress<'_>,
    context: &Context,
) -> Result<u64, String> {
    let request = Fields::new()
        .with("op", b"files.fetch".to_vec())
        .with("token", manifest.token.as_bytes().to_vec())
        .with("index", index.to_string().into_bytes());

    let mut file = None;
    let mut tar = None;
    let (result, refusal, done) = {
        let mut sink = KindAwareSink {
            label: destination.to_path_buf(),
            stage_target: stage_target.to_path_buf(),
            file: &mut file,
            tar: &mut tar,
            cap: context.cap,
            interactive: context.interactive,
            total: 0,
            done: 0,
            since_tick: 0,
            started: std::time::Instant::now(),
            progress,
            refusal: None,
            kind: String::new(),
        };
        let result = session.fetch(&request, &mut sink);
        (result, sink.refusal.take(), sink.done)
    };
    drop(file.take());

    // tar's own exit status still matters, but it is no longer the only
    // truncation signal: a stream that ended without §6.4's empty `D` already
    // failed above, which is the error channel the raw-tar design never had.
    if let Some(mut child) = tar.take() {
        drop(child.stdin.take());
        let status = child
            .wait()
            .map_err(|e| format!("pbpaste: tar did not exit: {e}"))?;
        if result.is_ok() && !status.success() {
            let _ = std::fs::remove_dir_all(stage_target);
            return Err(format!(
                "pbpaste: archive extraction failed for {} (truncated or corrupt stream)",
                destination.display()
            ));
        }
    }

    match result {
        Ok(_) => Ok(done),
        Err(e) => {
            let _ = std::fs::remove_dir_all(stage_target);
            let _ = std::fs::remove_file(stage_target);
            match refusal {
                Some(message) => Err(message),
                None => Err(format!("pbpaste: {} ({e})", destination.display())),
            }
        }
    }
}

/// The sink that learns file-versus-directory from the head and opens the
/// right destination for the body.
struct KindAwareSink<'a, 'b> {
    label: PathBuf,
    stage_target: PathBuf,
    file: &'a mut Option<std::fs::File>,
    tar: &'a mut Option<std::process::Child>,
    cap: u64,
    interactive: bool,
    total: u64,
    done: u64,
    since_tick: u64,
    started: std::time::Instant,
    progress: &'a mut Progress<'b>,
    refusal: Option<String>,
    kind: String,
}

impl StreamSink for KindAwareSink<'_, '_> {
    fn head(&mut self, head: &Fields) -> Result<(), ClientError> {
        self.kind = String::from_utf8_lossy(head.get("kind").unwrap_or_default()).into_owned();
        self.total = head
            .get("size")
            .and_then(|size| String::from_utf8_lossy(size).parse().ok())
            .unwrap_or(0);
        if let Err(message) = cap_check(&self.label, self.total, self.cap, self.interactive) {
            self.refusal = Some(message);
            return Err(ClientError::Protocol(
                "size cap refused the item".to_string(),
            ));
        }
        if self.kind == "directory" {
            let parent = self
                .stage_target
                .parent()
                .unwrap_or(Path::new("."))
                .to_path_buf();
            let child = Command::new("tar")
                .arg("-xf")
                .arg("-")
                .arg("-C")
                .arg(&parent)
                .stdin(std::process::Stdio::piped())
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null())
                .spawn()
                .map_err(|e| ClientError::Protocol(format!("cannot start tar: {e}")))?;
            *self.tar = Some(child);
        } else {
            let file = std::fs::File::create(&self.stage_target).map_err(ClientError::Io)?;
            *self.file = Some(file);
        }
        Ok(())
    }

    fn chunk(&mut self, bytes: &[u8]) -> Result<(), ClientError> {
        if interrupted() {
            return Err(ClientError::Protocol("interrupted".to_string()));
        }
        if let Some(child) = self.tar.as_mut() {
            if let Some(stdin) = child.stdin.as_mut() {
                stdin.write_all(bytes)?;
            }
        } else if let Some(file) = self.file.as_mut() {
            file.write_all(bytes)?;
        }
        self.done += bytes.len() as u64;
        self.since_tick += bytes.len() as u64;
        if self.since_tick >= 65_536 {
            self.progress
                .tick(&self.label, self.done, self.total, self.started);
            self.since_tick = 0;
        }
        Ok(())
    }

    fn finish(&mut self) -> Result<(), ClientError> {
        if let Some(file) = self.file.as_mut() {
            file.flush()?;
        }
        self.progress
            .tick(&self.label, self.done, self.total, self.started);
        Ok(())
    }
}

fn mount_check(helper: &Path, host: &str) -> Option<String> {
    if !helper.is_file() {
        return None;
    }
    let out = Command::new(helper).arg("check").arg(host).output().ok()?;
    if !out.status.success() {
        return None;
    }
    let point = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if point.is_empty() {
        None
    } else {
        Some(point)
    }
}

fn mount_map(helper: &Path, host: &str, path: &Path) -> Option<PathBuf> {
    let out = Command::new(helper)
        .arg("map")
        .arg(host)
        .arg(path)
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let mut mapped = out.stdout;
    while mapped.last() == Some(&b'\n') {
        mapped.pop();
    }
    if mapped.is_empty() {
        None
    } else {
        Some(PathBuf::from(std::ffi::OsStr::from_bytes(&mapped)))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn human_sizes_match_the_shim() {
        assert_eq!(human_size(512), "512B");
        assert_eq!(human_size(2048), "2.0K");
        assert_eq!(human_size(3_145_728), "3.0M");
        assert_eq!(human_size(2_147_483_648), "2.0G");
    }

    #[test]
    fn duplicate_basenames_are_refused_even_with_force() {
        let paths = vec![PathBuf::from("/a/notes.txt"), PathBuf::from("/b/notes.txt")];
        let err = conflicts(&paths, Path::new("/dst"), true, &|_| false).unwrap_err();
        assert!(err.contains("multiple items with the same name"), "{err}");
    }

    #[test]
    fn existing_names_are_refused_and_force_waives_them() {
        let paths = vec![PathBuf::from("/a/one.txt")];
        let err = conflicts(&paths, Path::new("/dst"), false, &|_| true).unwrap_err();
        assert!(err.contains("refusing to overwrite existing items (use --force)"));
        assert!(err.contains("  one.txt"), "every conflict is listed: {err}");
        conflicts(&paths, Path::new("/dst"), true, &|_| true).unwrap();
    }

    #[test]
    fn the_cap_refusal_line_matches_the_yazi_parse_contract() {
        // smart-paste.yazi anchors on:
        //   ^pbpaste: (.-) exceeds size cap %(CLIP_FILE_MAX=(%d+) bytes, item is (%d+) bytes%) %-%- refusing
        let err = cap_check(Path::new("/dst/big.bin"), 500, 100, false).unwrap_err();
        let prefix = "pbpaste: /dst/big.bin exceeds size cap (CLIP_FILE_MAX=100 bytes, item is 500 bytes) -- refusing";
        assert!(
            err.starts_with(prefix),
            "the load-bearing prefix changed:\n{err}"
        );
    }

    #[test]
    fn a_palette_value_is_read_or_falls_back() {
        let json = r##"{"palette":{"crust":"#010203","surface0":"#0a0b0c"},
                        "extended":{"dialog":{"warning":"#ffcc00"}}}"##;
        assert_eq!(
            extract_hex(json, &["extended", "dialog", "warning"]).as_deref(),
            Some("#ffcc00")
        );
        assert_eq!(
            extract_hex(json, &["palette", "crust"]).as_deref(),
            Some("#010203")
        );
        assert_eq!(extract_hex(json, &["palette", "absent"]), None);
        assert_eq!(extract_hex("not json", &["palette", "crust"]), None);
    }

    #[test]
    fn options_parse_the_shims_argument_shapes() {
        let dir = crate::testutil::tempdir("paste-files-args");
        let path = dir.path().to_string_lossy().into_owned();
        let opts = Options::parse(&["--force".into(), "--porcelain".into(), path.clone()]).unwrap();
        assert!(opts.force);
        assert_eq!(opts.output, Output::Porcelain);
        assert_eq!(opts.dir, dir.path());

        assert!(Options::parse(&["--nope".into()]).is_err());
        assert!(Options::parse(&[path.clone(), path]).is_err());
        assert!(Options::parse(&["/nonexistent/dir".into()]).is_err());
    }

    #[test]
    fn a_stale_recovery_dir_restores_a_displaced_original() {
        let dir = crate::testutil::tempdir("paste-files-recover");
        let recovery = dir.path().join(".pbpaste-recovery.999999");
        std::fs::create_dir_all(&recovery).unwrap();
        let destination = dir.path().join("kept.txt");
        std::fs::write(recovery.join("bak.1"), b"original").unwrap();
        std::fs::write(recovery.join("final.1"), destination.as_os_str().as_bytes()).unwrap();

        recover_dir(&recovery);
        assert_eq!(std::fs::read(&destination).unwrap(), b"original");
        assert!(!recovery.exists(), "the recovery dir is dropped after use");
    }

    #[test]
    fn a_landed_replacement_is_not_restored_over() {
        let dir = crate::testutil::tempdir("paste-files-landed");
        let recovery = dir.path().join(".pbpaste-recovery.999999");
        std::fs::create_dir_all(&recovery).unwrap();
        let destination = dir.path().join("kept.txt");
        std::fs::write(&destination, b"replacement").unwrap();
        std::fs::write(recovery.join("bak.1"), b"original").unwrap();
        std::fs::write(recovery.join("final.1"), destination.as_os_str().as_bytes()).unwrap();

        recover_dir(&recovery);
        assert_eq!(
            std::fs::read(&destination).unwrap(),
            b"replacement",
            "the recovery pass keys on the destination being ABSENT"
        );
    }

    #[test]
    fn the_sweep_spares_a_live_runs_directories() {
        let dir = crate::testutil::tempdir("paste-files-sweep");
        let mine = dir
            .path()
            .join(format!(".pbpaste-staging.{}", std::process::id()));
        let dead = dir.path().join(".pbpaste-staging.999999");
        std::fs::create_dir_all(&mine).unwrap();
        std::fs::create_dir_all(&dead).unwrap();

        sweep_stale(dir.path());
        assert!(mine.exists(), "a live pid's staging dir is left alone");
        assert!(!dead.exists(), "a dead pid's staging dir is swept");
    }
}
