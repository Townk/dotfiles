//! The macOS pasteboard, natively (§14.1), and the capture loop absorbed from
//! the Hammerspoon watcher (§14.2).
//!
//! Every `objc2` call shape here was established by `probes/` first — the
//! feature lists, the property-list signature and the pointer casts each cost
//! rounds of compile errors to find, and `probes/README.md` records the traps.
//! All of it runs from a plain non-GUI process: no `NSApplication`, no run
//! loop, no bundle, which is what the probes existed to verify.
//!
//! During the Phase 3–7 window the Hammerspoon watcher captures too; §14.4
//! expects duplicate rows until it is retired and they are deliberately not
//! "fixed" here.

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use objc2::rc::Retained;
use objc2::runtime::AnyObject;
use objc2_app_kit::{NSPasteboard, NSWorkspace};
use objc2_foundation::{
    NSArray, NSData, NSPropertyListFormat, NSPropertyListReadOptions, NSPropertyListSerialization,
    NSString, NSURL,
};

use crate::capture::{self, FrontmostApp, Snapshot};
use crate::host::HostIdentity;
use crate::log;
use crate::platform::RegtypeTracker;
use crate::store::{self, Store};

/// A pasteboard handle. Not `Send` — the capture thread creates its own.
pub struct Pasteboard {
    pb: Retained<NSPasteboard>,
}

impl Pasteboard {
    /// The general pasteboard — the human's live clipboard. Reads are free;
    /// nothing in this module writes it unless explicitly asked to.
    pub fn general() -> Pasteboard {
        Pasteboard {
            pb: NSPasteboard::generalPasteboard(),
        }
    }

    /// A named pasteboard. The capture loop accepts one so tests (and a wary
    /// operator) can observe a private pasteboard instead of the live one.
    pub fn with_name(name: &str) -> Pasteboard {
        Pasteboard {
            pb: NSPasteboard::pasteboardWithName(&NSString::from_str(name)),
        }
    }

    /// A uniquely-named private pasteboard, the way `probes/pasteboard.rs`
    /// keeps the real clipboard untouched.
    pub fn unique() -> Pasteboard {
        Pasteboard {
            pb: NSPasteboard::pasteboardWithUniqueName(),
        }
    }

    pub fn name(&self) -> String {
        self.pb.name().to_string()
    }

    /// Releases a named pasteboard's server-side resources. Tests must call
    /// this on their unique pasteboards; the general pasteboard is never
    /// released.
    pub fn release(self) {
        // Not in the generated bindings, so sent by selector; the method has
        // no arguments and no result.
        let () = unsafe { objc2::msg_send![&*self.pb, releaseGlobally] };
    }

    pub fn change_count(&self) -> isize {
        self.pb.changeCount()
    }

    /// One atomic multi-UTI write: one `declareTypes` then one `setData` per
    /// representation, a single `changeCount` step (§14.1 — the property dedup
    /// and single-observation depend on). Returns the new `changeCount`, which
    /// the caller records on the [`RegtypeTracker`] so the observation loop
    /// recognizes the echo (§6.2).
    pub fn write_all(&self, data: &BTreeMap<String, Vec<u8>>) -> isize {
        let types: Vec<Retained<NSString>> =
            data.keys().map(|uti| NSString::from_str(uti)).collect();
        let array = NSArray::from_retained_slice(&types);
        unsafe { self.pb.declareTypes_owner(&array, None) };
        for (blob, uti) in data.values().zip(&types) {
            let payload = NSData::with_bytes(blob);
            self.pb.setData_forType(Some(&payload), uti);
        }
        self.pb.changeCount()
    }

    /// The observed state, resolved far enough for `capture::decide`: the
    /// declared types, every readable payload, the `NSFilenamesPboardType`
    /// plist parsed with the real parser (§14.1 — this is what retires the
    /// `plutil` + hand-rolled JSON splitting defect), and the first item's
    /// file URL resolved to a path. The frontmost application is the caller's
    /// to supply, so tests can pin it.
    pub fn snapshot(&self, frontmost: Option<FrontmostApp>) -> Snapshot {
        let item_utis: Vec<String> = self
            .pb
            .types()
            .map(|types| types.iter().map(|uti| uti.to_string()).collect())
            .unwrap_or_default();

        let mut data = BTreeMap::new();
        for uti in &item_utis {
            if let Some(blob) = self.pb.dataForType(&NSString::from_str(uti)) {
                data.insert(uti.clone(), blob.to_vec());
            }
        }

        // Asked by legacy type NAME, not enumerated UTI: a restored clip
        // re-advertises this blob under a dynamic `dyn.*` UTI, and only the
        // name-based bridging still resolves it (R5a, `clipboard-history.lua`).
        // Parsed for classification and authority only — `data`, and therefore
        // `type_hash`, stays exactly the enumerated set, because hash parity
        // with the Lua writer is what dedups the two writers' rows during the
        // Phase 3–7 window.
        let filenames = self
            .pb
            .dataForType(&NSString::from_str("NSFilenamesPboardType"))
            .and_then(|blob| parse_filenames_plist(&blob));

        let resolved_url_path = data
            .get("public.file-url")
            .and_then(|blob| std::str::from_utf8(blob).ok())
            .and_then(resolve_file_url);

        Snapshot {
            item_utis,
            data,
            frontmost,
            filenames,
            resolved_url_path,
        }
    }
}

/// `readURL().filePath` equivalent: resolve a pasteboard file URL — including
/// the opaque `file:///.file/id=…` reference form some Finder affordances
/// vend — to a POSIX path.
fn resolve_file_url(url: &str) -> Option<String> {
    let url = NSURL::URLWithString(&NSString::from_str(url))?;
    let path = match url.filePathURL() {
        Some(resolved) => resolved.path(),
        None => url.path(),
    }?;
    Some(path.to_string())
}

/// As [`parse_filenames_plist`], from raw stored bytes — the shape
/// `files.list` needs when a store row carries the watcher-captured
/// `NSFilenamesPboardType` blob.
pub fn parse_filenames_bytes(blob: &[u8]) -> Option<Vec<String>> {
    parse_filenames_plist(&NSData::with_bytes(blob))
}

/// Parse an `NSFilenamesPboardType` blob (a binary or XML property list
/// holding an array of POSIX path strings) with the real parser — probe Q4's
/// call shape, plus the class checks the probe could skip.
fn parse_filenames_plist(blob: &NSData) -> Option<Vec<String>> {
    let mut format = NSPropertyListFormat::XMLFormat_v1_0;
    let parsed = unsafe {
        NSPropertyListSerialization::propertyListWithData_options_format_error(
            blob,
            NSPropertyListReadOptions::empty(),
            &mut format,
        )
    }
    .ok()?;
    let array = parsed.downcast::<NSArray<AnyObject>>().ok()?;
    let mut paths = Vec::with_capacity(array.len());
    for entry in &array {
        paths.push(entry.downcast::<NSString>().ok()?.to_string());
    }
    if paths.is_empty() {
        None
    } else {
        Some(paths)
    }
}

/// The frontmost application, from a non-GUI process (probe Q7): what
/// `source_app`, `source_bundle_id` and the password-manager deny-list all
/// depend on. `None` — no frontmost application, or one with no name — is the
/// no-GUI-session case the capture pipeline refuses.
pub fn frontmost_app() -> Option<FrontmostApp> {
    let app = NSWorkspace::sharedWorkspace().frontmostApplication()?;
    let name = app.localizedName()?.to_string();
    Some(FrontmostApp {
        name,
        bundle_id: app.bundleIdentifier().map(|id| id.to_string()),
    })
}

/// How the capture loop is launched (`recobd --capture`).
pub struct CaptureConfig {
    /// A named pasteboard to observe instead of the general one — the test
    /// seam, `RECOB_CAPTURE_PASTEBOARD`.
    pub pasteboard: Option<String>,
    pub db_path: PathBuf,
    pub poll: Duration,
}

impl CaptureConfig {
    /// The production shape: the general pasteboard, the pickers' store, and
    /// the watcher's 0.5 s interval (`RECOB_CAPTURE_POLL_MS` to override —
    /// §6.2 measured the poll at 0.56 µs, so the interval is free to shrink).
    pub fn from_env() -> CaptureConfig {
        let poll = std::env::var("RECOB_CAPTURE_POLL_MS")
            .ok()
            .and_then(|v| v.trim().parse::<u64>().ok())
            .filter(|ms| *ms > 0)
            .map_or(Duration::from_millis(500), Duration::from_millis);
        CaptureConfig {
            pasteboard: std::env::var("RECOB_CAPTURE_PASTEBOARD")
                .ok()
                .filter(|name| !name.is_empty()),
            db_path: store::default_db_path(),
            poll,
        }
    }
}

/// Spawn the capture thread: poll `changeCount`, and on every change the
/// daemon did not make itself, run the §14.2 pipeline and write the store row.
/// `last_cc` is the shared record of what has been observed, which §6.5's
/// synchronous no-race capture in `files.list`/`files.grant` reads.
pub fn start_capture(
    config: CaptureConfig,
    tracker: Arc<RegtypeTracker>,
    last_cc: Arc<std::sync::Mutex<Option<isize>>>,
) -> std::io::Result<std::thread::JoinHandle<()>> {
    std::thread::Builder::new()
        .name("capture".to_string())
        .spawn(move || run_capture(&config, &tracker, &last_cc))
}

fn run_capture(
    config: &CaptureConfig,
    tracker: &RegtypeTracker,
    last_cc: &std::sync::Mutex<Option<isize>>,
) {
    let host = HostIdentity::resolve();
    let pasteboard = match &config.pasteboard {
        Some(name) => Pasteboard::with_name(name),
        None => Pasteboard::general(),
    };
    let mut store = match Store::open(&config.db_path, &host.current().unwrap_or_default()) {
        Ok(store) => store,
        Err(e) => {
            log!(
                "capture: cannot open the store at {}: {e}",
                config.db_path.display()
            );
            return;
        }
    };
    log!(
        "capture: observing pasteboard {:?} every {:?} into {}",
        pasteboard.name(),
        config.poll,
        config.db_path.display()
    );
    let mut last = pasteboard.change_count();
    *last_cc.lock().unwrap() = Some(last);
    loop {
        std::thread::sleep(config.poll);
        last = capture_step(
            &pasteboard,
            &mut store,
            tracker,
            &host,
            last,
            &frontmost_app,
        );
        *last_cc.lock().unwrap() = Some(last);
    }
}

/// One observation step, extracted so the macOS tests can drive it
/// deterministically against a private pasteboard. Returns the `changeCount`
/// the next step should compare against.
pub fn capture_step(
    pasteboard: &Pasteboard,
    store: &mut Store,
    tracker: &RegtypeTracker,
    host: &HostIdentity,
    last: isize,
    frontmost: &dyn Fn() -> Option<FrontmostApp>,
) -> isize {
    let change_count = pasteboard.change_count();
    if change_count == last {
        return last;
    }
    // §6.2: the daemon's own write already stored its row in the same
    // operation; observing it again would be the echo the old origin-file
    // apparatus existed to suppress.
    if tracker.is_own(change_count) {
        return change_count;
    }
    let snapshot = pasteboard.snapshot(frontmost());
    match capture::decide(&snapshot) {
        Ok(capture) => {
            let host = host.current().unwrap_or_default();
            if let Err(e) = store.write_capture(&capture, &host, true, store::now_ts()) {
                log!("capture: store write failed: {e}");
            }
        }
        Err(_skip) => {
            // Refusals are silent, as the watcher's are: a sensitive clip must
            // not be described in a log line either.
        }
    }
    change_count
}
