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
use std::sync::{Arc, Mutex};
use std::time::Duration;

use objc2::rc::Retained;
use objc2::runtime::{AnyObject, ProtocolObject};
use objc2_app_kit::{NSPasteboard, NSPasteboardItem, NSPasteboardWriting, NSWorkspace};
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
    /// The name the child-process writer re-opens this board by; None = the
    /// general pasteboard. See `write_file_urls`.
    pb_name: Option<String>,
}

impl Pasteboard {
    /// The general pasteboard — the human's live clipboard. Reads are free;
    /// nothing in this module writes it unless explicitly asked to.
    pub fn general() -> Pasteboard {
        Pasteboard {
            pb: NSPasteboard::generalPasteboard(),
            pb_name: None,
        }
    }

    /// A named pasteboard. The capture loop accepts one so tests (and a wary
    /// operator) can observe a private pasteboard instead of the live one.
    pub fn with_name(name: &str) -> Pasteboard {
        Pasteboard {
            pb: NSPasteboard::pasteboardWithName(&NSString::from_str(name)),
            pb_name: Some(name.to_string()),
        }
    }

    /// A uniquely-named private pasteboard, the way `probes/pasteboard.rs`
    /// keeps the real clipboard untouched.
    pub fn unique() -> Pasteboard {
        let pb = NSPasteboard::pasteboardWithUniqueName();
        let name = pb.name().to_string();
        Pasteboard {
            pb,
            pb_name: Some(name),
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
        // File flavors MUST go through the item interface below: the legacy
        // declare+setData path silently stores NOTHING for public.file-url
        // (and translation-serves NSFilenames readers from url items it then cannot
        // find), leaving declared-but-empty flavors that every reader blocks
        // on this LIVING daemon to furnish -- the Finder/pboard wedge found
        // live 2026-08-18. URLs derive from the filenames plist (the real
        // parser) or the single file-url payload; every remaining UTI rides
        // the first item; NSFilenamesPboardType itself is never written --
        // AppKit's own legacy translator serves those readers from the items.
        let urls: Option<Vec<String>> = data
            .get("NSFilenamesPboardType")
            .and_then(|blob| parse_filenames_bytes(blob))
            .map(|paths| {
                paths
                    .iter()
                    .map(|path| format!("file://{}", url_encode(path)))
                    .collect()
            })
            .or_else(|| {
                data.get("public.file-url")
                    .map(|blob| vec![String::from_utf8_lossy(blob).into_owned()])
            });
        if let Some(urls) = urls {
            let extra: Vec<(&str, &[u8])> = data
                .iter()
                .filter(|(uti, _)| {
                    uti.as_str() != "NSFilenamesPboardType" && uti.as_str() != "public.file-url"
                })
                .map(|(uti, blob)| (uti.as_str(), blob.as_slice()))
                .collect();
            return self.write_file_urls(&urls, &extra);
        }
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

    /// The file write, DELEGATED for the GENERAL pasteboard to a one-shot
    /// Hammerspoon script (the D7 `hs <file>` pattern, never `hs -c`).
    /// Empirically (2026-08-18, exhaustively probed): every write mechanism
    /// tried from THIS daemon's launchd lineage -- legacy declare+setData,
    /// NSPasteboardItem writeObjects, even a freshly spawned child of this
    /// process -- reports success while the pasteboard server strips the
    /// url flavors (readers then hang on the living owner, or see a
    /// marker-only item). The same writes from any shell- or GUI-app
    /// lineage keep every flavor. Hammerspoon is a real GUI app, already a
    /// tool dependency, and its `writeObjects` + same-change marker add is
    /// verified to leave the full flavor set with ONE changeCount step.
    /// Named (test) pasteboards use the in-process writer below -- their
    /// processes are shell-spawned and unaffected, and a test must never
    /// touch the human's general pasteboard.
    fn write_file_urls(&self, urls: &[String], extra: &[(&str, &[u8])]) -> isize {
        if self.pb_name.is_none() {
            if let Some(count) = self.write_file_urls_via_hs(urls, extra) {
                return count;
            }
            crate::log!("write_file_urls: hs delegate failed; in-process fallback");
        }
        self.write_file_urls_here(urls, extra)
    }

    fn write_file_urls_via_hs(&self, urls: &[String], extra: &[(&str, &[u8])]) -> Option<isize> {
        use std::io::Write;
        use std::process::{Command, Stdio};
        let hs = std::env::var_os("RECOB_HS_BIN")
            .map(std::path::PathBuf::from)
            .unwrap_or_else(|| std::path::PathBuf::from("hs"));
        let mut lua = String::from("local pb = require(\"hs.pasteboard\")\nlocal objs = {}\n");
        for url in urls {
            // urls are %-encoded ASCII (url_encode), so no quote can appear.
            lua.push_str(&format!("objs[#objs + 1] = {{ url = \"{url}\" }}\n"));
        }
        lua.push_str("pb.writeObjects(objs)\n");
        for (uti, blob) in extra {
            let bytes: String = blob.iter().map(|b| format!("\\{b}")).collect();
            lua.push_str(&format!(
                "pb.writeDataForUTI(nil, \"{uti}\", \"{bytes}\", true)\n"
            ));
        }
        let dir = std::env::temp_dir();
        let path = dir.join(format!("recob-pbwrite-{}.lua", std::process::id()));
        {
            let mut file = std::fs::File::create(&path).ok()?;
            file.write_all(lua.as_bytes()).ok()?;
        }
        let status = Command::new(hs)
            .arg("-q")
            .arg(&path)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::inherit())
            .status();
        let _ = std::fs::remove_file(&path);
        match status {
            Ok(code) if code.success() => Some(self.pb.changeCount()),
            _ => None,
        }
    }

    pub fn write_file_urls_here(&self, urls: &[String], extra: &[(&str, &[u8])]) -> isize {
        let mut items: Vec<Retained<ProtocolObject<dyn NSPasteboardWriting>>> =
            Vec::with_capacity(urls.len());
        let url_type = NSString::from_str("public.file-url");
        for (index, url) in urls.iter().enumerate() {
            let item = NSPasteboardItem::new();
            let payload = NSData::with_bytes(url.as_bytes());
            let _ = item.setData_forType(&payload, &url_type);
            if index == 0 {
                for (uti, blob) in extra {
                    let data = NSData::with_bytes(blob);
                    let _ = item.setData_forType(&data, &NSString::from_str(uti));
                }
            }
            items.push(ProtocolObject::from_retained(item));
        }
        self.pb.clearContents();
        let array = NSArray::from_retained_slice(&items);
        let _ = self.pb.writeObjects(&array);
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

/// The XML property list the pasteboard's `NSFilenamesPboardType` carries —
/// the shape the zsh generated, escape rules included.
pub fn filenames_plist(paths: &[String]) -> Vec<u8> {
    let mut xml = String::from(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n\
         <!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \
         \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n\
         <plist version=\"1.0\"><array>\n",
    );
    for path in paths {
        let escaped = path
            .replace('&', "&amp;")
            .replace('<', "&lt;")
            .replace('>', "&gt;");
        xml.push_str(&format!("<string>{escaped}</string>\n"));
    }
    xml.push_str("</array></plist>\n");
    xml.into_bytes()
}

/// Percent-encode everything outside `[A-Za-z0-9-._~/]`, byte-wise — the zsh
/// `urlenc`, for `public.file-url` values.
pub fn url_encode(path: &str) -> String {
    let mut out = String::with_capacity(path.len());
    for byte in path.bytes() {
        if byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'.' | b'_' | b'~' | b'/') {
            out.push(byte as char);
        } else {
            out.push_str(&format!("%{byte:02X}"));
        }
    }
    out
}

/// Which rich representation [`attributed_to_text`] is decoding.
#[derive(Clone, Copy)]
pub enum RichDoc {
    Html,
    Rtf,
    Rtfd,
}

/// HTML/RTF/RTFD to plain text via `NSAttributedString`, the riskiest API in
/// the absorbed set (`probes/attrstr.rs`): the options dictionary must carry
/// the exported document-type *statics* — the equivalent string literals
/// compile and then fail at runtime with the unhelpful "Cocoa error 65806".
pub fn attributed_to_text(bytes: &[u8], doc: RichDoc) -> Option<String> {
    use objc2::rc::Retained;
    use objc2::runtime::AnyObject;
    use objc2::AllocAnyThread;
    use objc2_app_kit::{
        NSAttributedStringDocumentFormats, NSDocumentTypeDocumentAttribute, NSHTMLTextDocumentType,
        NSRTFDTextDocumentType, NSRTFTextDocumentType,
    };
    use objc2_foundation::{NSAttributedString, NSDictionary};

    /// The exported statics are typed as plain `NSObject`; they are NSString
    /// constants (probe-verified), and passing anything else — a literal above
    /// all — fails at runtime with "Cocoa error 65806".
    unsafe fn cast_static(object: &objc2_foundation::NSObject) -> &NSString {
        unsafe { std::mem::transmute::<&objc2_foundation::NSObject, &NSString>(object) }
    }

    let data = NSData::with_bytes(bytes);
    let doctype: &NSString = unsafe {
        match doc {
            RichDoc::Html => cast_static(NSHTMLTextDocumentType),
            RichDoc::Rtf => cast_static(NSRTFTextDocumentType),
            RichDoc::Rtfd => cast_static(NSRTFDTextDocumentType),
        }
    };
    let key: &NSString = unsafe { cast_static(NSDocumentTypeDocumentAttribute) };
    let opts: Retained<NSDictionary<NSString, AnyObject>> =
        NSDictionary::from_slices(&[key], &[doctype as &AnyObject]);
    let parsed = unsafe {
        NSAttributedString::initWithData_options_documentAttributes_error(
            NSAttributedString::alloc(),
            &data,
            std::mem::transmute::<&NSDictionary<NSString, AnyObject>, &NSDictionary<_, _>>(&opts),
            None,
        )
    };
    parsed.ok().map(|s| s.string().to_string())
}

/// Whether this process may touch `NSWorkspace` yet. The workspace's
/// LaunchServices connection is process-global and established on FIRST use:
/// touched while the login session is still assembling, it latches the
/// sessionless answer and `frontmostApplication` stays nil for the process's
/// whole life — found live 2026-08-27, when a boot-time daemon start (console
/// login 11:19, recobd 11:19:25) had silently refused every observed copy for
/// six days as `Skip::NoGuiSession` while `clip.get` and the pasteboard reads
/// all still worked. A FRESH process always resolves the truth (verified from
/// shell, launchd-submitted and daemon-child lineages alike), so the gate asks
/// one — `lsappinfo`, over its own new connection — and opens only once a
/// real, non-loginwindow application is frontmost. Only then is NSWorkspace
/// touched in-process, by which point the session is established and the
/// first touch is safe.
enum WorkspaceGate {
    /// No live GUI session confirmed yet; probe again once the cooldown
    /// allows.
    Closed {
        last_probe: Option<std::time::Instant>,
    },
    /// A live session was seen; NSWorkspace is safe for this process.
    Open,
}

static WORKSPACE_GATE: Mutex<WorkspaceGate> =
    Mutex::new(WorkspaceGate::Closed { last_probe: None });

/// One probe is ~15 ms of child process — nothing against a human copy, but
/// `ensure_current` runs on every `files.list`/`files.grant`, so a machine
/// sitting at loginwindow must not fork per request.
const GATE_PROBE_COOLDOWN: Duration = Duration::from_secs(5);

fn workspace_ready() -> bool {
    let mut gate = WORKSPACE_GATE.lock().unwrap();
    match &*gate {
        WorkspaceGate::Open => true,
        WorkspaceGate::Closed { last_probe } => {
            if last_probe.is_some_and(|at| at.elapsed() < GATE_PROBE_COOLDOWN) {
                return false;
            }
            match probed_front_app_name() {
                Some(name) if name != "loginwindow" => {
                    crate::log!("gui session confirmed; frontmost attribution enabled");
                    *gate = WorkspaceGate::Open;
                    true
                }
                _ => {
                    *gate = WorkspaceGate::Closed {
                        last_probe: Some(std::time::Instant::now()),
                    };
                    false
                }
            }
        }
    }
}

/// The out-of-process session probe: `lsappinfo` resolves the frontmost
/// application through a LaunchServices connection this process has never
/// used, so it tells the truth a too-early in-process query cannot. `None` —
/// no output, `[ NULL ]`, no resolvable name — means no live GUI session.
fn probed_front_app_name() -> Option<String> {
    use std::process::{Command, Stdio};
    let output = Command::new("/bin/sh")
        .args(["-c", r#"lsappinfo info -only name "$(lsappinfo front)""#])
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .ok()?;
    parse_lsappinfo_name(&String::from_utf8_lossy(&output.stdout))
}

/// `lsappinfo info -only name` prints `"LSDisplayName"="Ghostty"` for a live
/// application and `"LSDisplayName"=[ NULL ]` (or nothing at all) otherwise.
fn parse_lsappinfo_name(out: &str) -> Option<String> {
    let (_, value) = out.split_once('=')?;
    let name = value.trim().strip_prefix('"')?.strip_suffix('"')?;
    if name.is_empty() {
        None
    } else {
        Some(name.to_string())
    }
}

/// The frontmost application, from a non-GUI process (probe Q7): what
/// `source_app`, `source_bundle_id` and the password-manager deny-list all
/// depend on. `None` — no frontmost application, or one with no name — is the
/// no-GUI-session case the capture pipeline refuses. Gated: until an
/// out-of-process probe confirms a live GUI session, NSWorkspace is not
/// touched at all (see [`WorkspaceGate`]) and the answer is the same `None` a
/// genuine sessionless machine gives.
pub fn frontmost_app() -> Option<FrontmostApp> {
    if !workspace_ready() {
        return None;
    }
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
        last = capture_step_with_push(
            &pasteboard,
            &mut store,
            tracker,
            &host,
            last,
            &frontmost_app,
            &|capture, host| crate::visited::push_capture(capture, host),
        );
        *last_cc.lock().unwrap() = Some(last);
    }
}

/// One observation step, extracted so the macOS tests can drive it
/// deterministically against a private pasteboard. Returns the `changeCount`
/// the next step should compare against. Tests use this no-push form; the
/// production loop wires `visited::push_capture` through the variant below —
/// keeping the push OUT of the shared signature means no test can ever
/// accidentally dial a live visited peer.
pub fn capture_step(
    pasteboard: &Pasteboard,
    store: &mut Store,
    tracker: &RegtypeTracker,
    host: &HostIdentity,
    last: isize,
    frontmost: &dyn Fn() -> Option<FrontmostApp>,
) -> isize {
    capture_step_with_push(
        pasteboard,
        store,
        tracker,
        host,
        last,
        frontmost,
        &|_, _| {},
    )
}

/// The full step: on a successfully STORED local capture, `push` fires with
/// the capture and this machine's identity (6c's pointer push — see
/// `crate::visited`). `capture::decide` has already refused remote-origin
/// pasteboard contents by this point, so a push can never loop.
#[allow(clippy::too_many_arguments)]
pub fn capture_step_with_push(
    pasteboard: &Pasteboard,
    store: &mut Store,
    tracker: &RegtypeTracker,
    host: &HostIdentity,
    last: isize,
    frontmost: &dyn Fn() -> Option<FrontmostApp>,
    push: &dyn Fn(&capture::Capture, &str),
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
            } else {
                push(&capture, &host);
            }
        }
        Err(skip) => {
            // Refusals stay content-free, as the watcher's were: a sensitive
            // clip must not be described in a log line. But the no-session
            // refusal must be VISIBLE — it is the shape a wedged frontmost
            // resolution takes, and six days of silently refused copies
            // (2026-08-27) is what fully silent cost.
            if skip == capture::Skip::NoGuiSession {
                log!("capture: change {change_count} refused: no interactive gui session");
            }
        }
    }
    change_count
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lsappinfo_name_parsing_covers_live_null_and_garbage() {
        // The two shapes `lsappinfo info -only name` actually prints
        // (captured live 2026-08-27), plus the degenerate ones.
        assert_eq!(
            parse_lsappinfo_name("\"LSDisplayName\"=\"Ghostty\"\n").as_deref(),
            Some("Ghostty")
        );
        assert_eq!(
            parse_lsappinfo_name("\"LSDisplayName\"=\"Bambu Studio\"").as_deref(),
            Some("Bambu Studio")
        );
        assert_eq!(parse_lsappinfo_name("\"LSDisplayName\"=[ NULL ] \n"), None);
        assert_eq!(parse_lsappinfo_name(""), None);
        assert_eq!(parse_lsappinfo_name("no equals sign"), None);
        assert_eq!(parse_lsappinfo_name("\"LSDisplayName\"=\"\""), None);
    }

    #[test]
    fn the_workspace_gate_and_the_probe_agree() {
        // The probe consults launchservicesd from a fresh child, so it tells
        // the truth regardless of this process's history. The gated query
        // must agree in kind: a live session resolves a frontmost app, no
        // session yields None WITHOUT NSWorkspace ever being touched — the
        // touch that wedges a too-early process is exactly what the gate
        // exists to defer.
        match probed_front_app_name() {
            Some(name) if name != "loginwindow" => {
                assert!(
                    frontmost_app().is_some(),
                    "a live GUI session opens the gate and resolves"
                );
            }
            _ => {
                assert!(
                    frontmost_app().is_none(),
                    "without a live session the gate stays shut"
                );
            }
        }
    }
}
