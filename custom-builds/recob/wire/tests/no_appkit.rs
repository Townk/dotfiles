//! §8's build-level assertion: **the clients must not link AppKit.** The crate
//! split is the structural half; this is the measured half, so a future
//! dependency that quietly pulls the framework in fails a test instead of
//! costing 2.6 ms of dynamic linking that someone has to re-measure to notice.

#![cfg(target_os = "macos")]

#[test]
fn the_client_binary_links_no_apple_ui_framework() {
    let out = std::process::Command::new("otool")
        .args(["-L", env!("CARGO_BIN_EXE_recob-clip")])
        .output()
        .expect("otool runs on macOS");
    assert!(out.status.success(), "otool failed");
    let linked = String::from_utf8_lossy(&out.stdout);
    for framework in ["AppKit", "Cocoa", "Foundation.framework", "CoreFoundation"] {
        assert!(
            !linked.contains(framework),
            "the client binary links {framework}:\n{linked}"
        );
    }
}
