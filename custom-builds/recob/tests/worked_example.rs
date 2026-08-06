//! §4.4's worked example, byte-exact in both directions.
//!
//! The reference is not a transcription of the spec's hex block: it is what
//! `bench/verify-worked-example.zsh` prints, encoded from §4.3's field grammar
//! independently of this crate. That script is why the body length is `0x3d` —
//! an early draft hand-computed `0x3a` and the script caught it — so the test
//! trusts the script over any figure computed here.

use std::process::Command;

use recobd::wire::{self, Fields, Kind};

/// `clip.set` of the four bytes `hi\n\0` with regtype `l`, originating on a host
/// recorded as `boxA`. `clip.set` itself is Phase 4; this exercises the codec,
/// which is what §4.4 pins down.
fn worked_example() -> Fields {
    Fields::new()
        .with("op", b"clip.set".to_vec())
        .with("text", b"hi\n\0".to_vec())
        .with("regtype", b"l".to_vec())
        .with("origin_host", b"boxA".to_vec())
}

fn reference_bytes() -> Vec<u8> {
    let script = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/bench/verify-worked-example.zsh"
    );
    let out = Command::new("zsh")
        .arg(script)
        .output()
        .unwrap_or_else(|e| panic!("cannot run {script}: {e}"));
    assert!(
        out.status.success(),
        "{script} failed: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    let printed = String::from_utf8_lossy(&out.stdout);
    assert!(
        printed.contains("body length = 61 (0x3d)"),
        "the reference script no longer reports the §4.4 body length:\n{printed}"
    );
    let bytes: Vec<u8> = printed
        .lines()
        .skip_while(|line| !line.starts_with(' '))
        .flat_map(|line| line.split_whitespace())
        .map(|token| {
            u8::from_str_radix(token, 16)
                .unwrap_or_else(|e| panic!("od token {token:?} is not a byte: {e}"))
        })
        .collect();
    assert_eq!(bytes.len(), 66, "frame length from {script}");
    bytes
}

#[test]
fn the_encoder_emits_the_reference_bytes() {
    let frame = wire::encode(Kind::Request, &worked_example());
    let reference = reference_bytes();
    assert_eq!(
        frame,
        reference,
        "\nencoded:   {}\nreference: {}",
        hex(&frame),
        hex(&reference)
    );
    // The figures §4.4 states, read back out of the bytes rather than assumed.
    assert_eq!(frame[0], b'Q');
    assert_eq!(&frame[1..5], &[0x00, 0x00, 0x00, 0x3d]);
    assert_eq!(frame.len(), 66);
}

#[test]
fn the_decoder_parses_the_reference_bytes_back() {
    let reference = reference_bytes();
    let mut cursor = std::io::Cursor::new(reference);
    let (kind, body) = wire::read_frame(&mut cursor, wire::MAX_BODY)
        .unwrap()
        .unwrap();
    assert_eq!(kind, Kind::Request);
    let fields = wire::parse_body(&body).unwrap();
    assert_eq!(fields, worked_example());
    // §4.4's note: the NUL inside `text` survives, and no delimiter could have
    // collided with it.
    assert_eq!(fields.get("text"), Some(&b"hi\n\0"[..]));
    assert_eq!(fields.get("regtype"), Some(&b"l"[..]));
    assert_eq!(fields.get("origin_host"), Some(&b"boxA"[..]));
    assert_eq!(fields.len(), 4);
}

#[test]
fn the_spec_hex_block_and_the_script_agree() {
    // §4.4's hex block, transcribed. If this and the script ever disagree, the
    // script wins and the document is wrong.
    let spec: Vec<u8> = vec![
        0x51, 0x00, 0x00, 0x00, 0x3d, 0x02, 0x6f, 0x70, 0x00, 0x00, 0x00, 0x08, 0x63, 0x6c, 0x69,
        0x70, 0x2e, 0x73, 0x65, 0x74, 0x04, 0x74, 0x65, 0x78, 0x74, 0x00, 0x00, 0x00, 0x04, 0x68,
        0x69, 0x0a, 0x00, 0x07, 0x72, 0x65, 0x67, 0x74, 0x79, 0x70, 0x65, 0x00, 0x00, 0x00, 0x01,
        0x6c, 0x0b, 0x6f, 0x72, 0x69, 0x67, 0x69, 0x6e, 0x5f, 0x68, 0x6f, 0x73, 0x74, 0x00, 0x00,
        0x00, 0x04, 0x62, 0x6f, 0x78, 0x41,
    ];
    assert_eq!(hex(&spec), hex(&reference_bytes()));
}

fn hex(bytes: &[u8]) -> String {
    bytes
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect::<Vec<_>>()
        .join(" ")
}
