// Probe: what can a plain non-GUI process see of the GUI session?
//
// Two capabilities the watcher depends on, both flagged "unverified" in the
// audit. Both are READ-ONLY here: nothing is written to the real pasteboard.
//
//   Q7  NSWorkspace frontmostApplication -- source_app, and the DENY_APPS
//       password-manager guard that refuses to capture from 1Password et al.
//       If a daemon cannot see this, that guard silently stops working.
//   Q8  General-pasteboard changeCount + type enumeration, i.e. whether a
//       daemon can observe real clipboard activity at all.

use objc2_app_kit::{NSPasteboard, NSWorkspace};
use std::time::Instant;

fn main() {
    // Q7
    let ws = NSWorkspace::sharedWorkspace();
    match ws.frontmostApplication() {
        Some(app) => {
            let name = app
                .localizedName()
                .map(|s| s.to_string())
                .unwrap_or_else(|| "<none>".into());
            let bid = app
                .bundleIdentifier()
                .map(|s| s.to_string())
                .unwrap_or_else(|| "<none>".into());
            println!("Q7 frontmostApplication from non-GUI process: OK");
            println!("   name = {name:?}, bundleIdentifier = {bid:?}");
        }
        None => println!("Q7 frontmostApplication: nil -- DENY_APPS guard would break"),
    }

    // Q8 -- read only.
    let pb = NSPasteboard::generalPasteboard();
    let t0 = Instant::now();
    let cc = pb.changeCount();
    let poll = t0.elapsed();
    println!("Q8 general pasteboard changeCount = {cc}, read in {poll:?}");

    match pb.types() {
        Some(t) => {
            let n = t.count();
            let names: Vec<String> = (0..n.min(6)).map(|i| t.objectAtIndex(i).to_string()).collect();
            println!("Q8b current clipboard advertises {n} type(s): {names:?}");
        }
        None => println!("Q8b clipboard is empty"),
    }

    // How cheap is the 0.5s poll the watcher does today?
    let n = 10_000;
    let t0 = Instant::now();
    let mut last = 0isize;
    for _ in 0..n {
        last = pb.changeCount();
    }
    let per = t0.elapsed().as_secs_f64() * 1e6 / f64::from(n);
    println!("Q8c changeCount poll cost: {per:.3} us each (last={last})");
}
