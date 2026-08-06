// RECOB language feasibility probe — throwaway, /tmp only.
//
// Question: can a plain non-GUI Rust process (no NSApplication, no run loop)
// do everything the current zsh+Hammerspoon path does to the pasteboard?
//   Q1 atomic multi-UTI write (hs.pasteboard.writeAllData equivalent)
//   Q2 NSFilenamesPboardType property-list write + read back
//   Q3 changeCount
//   Q4 binary/XML plist parse (replaces plutil + hand-rolled JSON splitting)
//   Q5 in-process SHA256 vs the measured 14.8 ms `shasum` spawn
//
// Writes to a UNIQUE (private) pasteboard, never the general one, so the
// user's real clipboard is untouched.

use sha2::{Digest, Sha256};
use std::time::Instant;
use subtle::ConstantTimeEq;

#[cfg(target_os = "macos")]
fn pasteboard_probe() {
    use objc2_app_kit::NSPasteboard;
    use objc2_foundation::{
        NSArray, NSData, NSPropertyListFormat, NSPropertyListReadOptions, NSPropertyListSerialization, NSString,
    };

    unsafe {
        let pb = NSPasteboard::pasteboardWithUniqueName();
        println!("Q0 private pasteboard created (no NSApplication, no run loop): ok");

        let t_text = NSString::from_str("public.utf8-plain-text");
        let t_pdf = NSString::from_str("com.adobe.pdf");
        let t_marker = NSString::from_str("org.chezmoi.clipboard.UntrustedFileURLs");
        let t_files = NSString::from_str("NSFilenamesPboardType");

        let types = NSArray::from_retained_slice(&[
            t_text.clone(),
            t_pdf.clone(),
            t_marker.clone(),
            t_files.clone(),
        ]);

        // ONE declareTypes + N setData = one atomic pasteboard change,
        // exactly what writeAllData gives and what the change-bound
        // provenance marker in clipboard-platform-macos.zsh depends on.
        let cc_before = pb.changeCount();
        pb.declareTypes_owner(&types, None);

        let text_data = NSData::with_bytes(b"hi\n\0world");
        pb.setData_forType(Some(&text_data), &t_text);

        let pdf_data = NSData::with_bytes(&[0x25, 0x50, 0x44, 0x46, 0x2d, 0x31, 0x2e, 0x34]);
        pb.setData_forType(Some(&pdf_data), &t_pdf);

        let marker = NSData::with_bytes(b"1");
        pb.setData_forType(Some(&marker), &t_marker);

        // NSFilenamesPboardType as a real property list, not hand-built XML.
        let paths = NSArray::from_retained_slice(&[
            NSString::from_str("/tmp/a b\"quote.txt"),
            NSString::from_str("/tmp/second.txt"),
        ]);
        let ok_plist = pb.setPropertyList_forType(&paths, &t_files);

        let cc_after = pb.changeCount();

        println!(
            "Q1 atomic multi-UTI write: {} types in ONE change (changeCount {} -> {}, delta {})",
            4,
            cc_before,
            cc_after,
            cc_after - cc_before
        );
        println!("Q2 NSFilenamesPboardType setPropertyList: {}", ok_plist);
        println!("Q3 changeCount readable: {}", cc_after);

        // Read every type back and confirm byte-exactness, NUL included.
        let got_text = pb.dataForType(&t_text).expect("text back");
        let got_bytes = got_text.to_vec();
        println!(
            "Q1b text round-trip byte-exact (incl. embedded NUL): {}",
            got_bytes == b"hi\n\0world"
        );
        println!(
            "Q1c private marker UTI survives: {}",
            pb.dataForType(&t_marker).is_some()
        );

        // Q4: parse the plist blob back with the real API. This is what
        // replaces `plutil -convert json` plus ~60 lines of hand-rolled JSON
        // string splitting that has already produced quote-in-path bugs.
        let raw = pb.dataForType(&t_files).expect("plist blob back");
        let mut fmt = NSPropertyListFormat::XMLFormat_v1_0;
        let parsed = NSPropertyListSerialization::propertyListWithData_options_format_error(
            &raw,
            NSPropertyListReadOptions::empty(),
            &mut fmt,
        );
        match parsed {
            Ok(obj) => {
                let arr: &NSArray<NSString> = &*(std::ptr::from_ref(&*obj) as *const NSArray<NSString>);
                let n = arr.count();
                let first = arr.objectAtIndex(0).to_string();
                println!(
                    "Q4 plist parse: {} entries, first = {:?} (quote preserved: {})",
                    n,
                    first,
                    first.contains('"')
                );
            }
            Err(e) => println!("Q4 plist parse: FAILED ({e:?})"),
        }

    }
}

#[cfg(not(target_os = "macos"))]
fn pasteboard_probe() {
    println!("Q0-Q4 skipped: not macOS (this is the headless-Linux build path)");
}

fn crypto_probe() {
    let token = b"a-token-of-some-plausible-length-0123456789abcdef";
    let nonce = b"0123456789abcdef0123456789abcdef";

    let n = 100_000u32;
    let t0 = Instant::now();
    let mut last = [0u8; 32];
    for _ in 0..n {
        let mut h = Sha256::new();
        h.update(token);
        h.update(b":c:");
        h.update(nonce);
        last = h.finalize().into();
    }
    let per = t0.elapsed().as_secs_f64() * 1000.0 / f64::from(n);
    println!("Q5 in-process SHA256: {:.6} ms each  (measured `shasum` spawn: 14.82 ms)", per);
    println!("Q5b speedup vs shasum spawn: {:.0}x", 14.82 / per);

    let other = last;
    let t0 = Instant::now();
    let eq: bool = last.ct_eq(&other).into();
    println!(
        "Q6 constant-time compare available (subtle::ConstantTimeEq): {} in {:?}",
        eq,
        t0.elapsed()
    );
}

fn main() {
    if std::env::args().any(|a| a == "startup") {
        return;
    }
    let start = Instant::now();
    pasteboard_probe();
    crypto_probe();
    println!("total probe runtime: {:?}", start.elapsed());
}
