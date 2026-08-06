# recob-probes

Feasibility probes for the RECOB daemon (`docs/recob-protocol-spec.md`). These
are not tests and nothing depends on them at runtime. They exist because the
spec makes load-bearing claims about what a **plain non-GUI Rust process** can
do on macOS, and a claim of that kind is worth nothing without a program that
demonstrates it.

Keep them. Re-deriving the working `objc2` call shapes cost several rounds of
compile errors each — the feature lists in `Cargo.toml`, the property-list
signature, and the document-type statics in `attrstr.rs` are all things that
fail in ways that do not point at their cause.

```sh
cargo run --release --bin pasteboard     # writes only to a PRIVATE pasteboard
cargo run --release --bin gui-context    # read-only against the real one
cargo run --release --bin attrstr
```

## What each one settles

**`pasteboard`** — the write path the daemon takes over from Hammerspoon
(§14.1). No `NSApplication`, no run loop, writing to a uniquely-named private
pasteboard so the real clipboard is never touched.

| | Result |
| --- | --- |
| Q0 pasteboard usable with no GUI context | ok |
| Q1 four UTIs in **one** `changeCount` step | delta 1 — atomicity, which dedup and single-observation depend on |
| Q1b text round-trips byte-exact including an embedded NUL | true — the property the zsh implementation could not hold |
| Q2 `NSFilenamesPboardType` via `setPropertyList:forType:` | true |
| Q4 read the plist back with the real parser | 2 entries, `"` in a path preserved — replaces `plutil -convert json` plus hand-rolled JSON splitting |
| Q5 in-process SHA256 | **0.000280 ms** against a measured 14.82 ms `shasum` spawn |
| Q6 constant-time compare (`subtle`) | available |

Q5 is the measurement that reversed the implementation language. The
authentication handshake in §9.2 needs several digests per connection; at
14.82 ms per `shasum` spawn the persistent-listener saving was being spent
before it was earned.

**`gui-context`** — the two watcher capabilities the audit flagged as
unverified, and the ones that would fail silently rather than loudly if a
daemon could not reach them.

| | Result |
| --- | --- |
| Q7 `frontmostApplication` from a non-GUI process | OK, with name and bundle id — so `source_app` and the password-manager deny-list keep working after absorption |
| Q8 general-pasteboard `changeCount` | readable |
| Q8c cost of the poll the watcher does twice a second | **0.5 µs** |

**`attrstr`** — the riskiest single API in the absorbed set.
`restore_plain_by_id` falls back to converting HTML or RTF to plain text, which
natively is `NSAttributedString(data:options:documentAttributes:)`. Its HTML
importer is WebKit-backed and documented as main-thread-only, so it had a real
chance of failing outside a GUI app. It does not: `<b>hi</b> &amp; bye` →
`hi & bye`, and the RTF sample converts too.

The trap, which cost the most iterations: the options dictionary key must be
the exported `NSDocumentTypeDocumentAttribute` **static**, and the value the
`NSHTMLTextDocumentType` / `NSRTFTextDocumentType` statics. Passing the
equivalent string literals compiles and then fails at runtime with the
unhelpful "Cocoa error 65806".

## Notes for the implementation

- Under `objc2` 0.6 the AppKit accessors used in `gui-context` are all safe
  fns; the pasteboard mutators in `pasteboard` still require `unsafe`.
- The `startup` argument to `pasteboard` returns immediately and does nothing.
  It exists so binary startup can be timed without the probe body: measured at
  5.5 ms against a 4.7 ms platform floor, and linking AppKit accounts for about
  2.6 ms of it — which is why §8 forbids the clients from linking AppKit.
