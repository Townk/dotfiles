# rip-audiobook, part 4 of 4 — --repair-companions, the panel, remote sidecars and --retag --apply.
# Hermetic: sandboxed staging, fake LibationCli (RIP_LIBATION_BIN), fake ssh
# (RIP_SSH_BIN), no network, no GUI. The sandbox and shared helpers live in
# tests/rip_audiobook_helper.sh.
Describe 'rip audiobooks'
  RIPLIB="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib/rip.zsh"
  PROVIDER="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_rip-provider-libation"
  ABS_BIN="$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_rip-abs-authors"
  Include tests/rip_helper.sh
  Include tests/rip_audiobook_helper.sh
  BeforeEach 'setup'
  AfterEach 'cleanup'

  # --- companion repair: --repair-companions (Task 6) -----------------------
  #
  # The retroactive half of the companions feature. Measured on the live
  # library 2026-08-24: 13 stored books carry a PDF and 246 carry a cover
  # image, and the library describes NONE of them — they survive only because
  # rsync moves whole directories. Task 5 records companions for every book
  # written from now on; this sweep describes the ones already stored.
  #
  # Every example that writes runs the SSH branch through fake_server_ssh: the
  # server has no jq, the JSON is assembled locally, and the remote side lists
  # names, sizes and hashes with POSIX tools plus sha256sum.

  rc_sha()   { shasum -a 256 "$RIP_SANDBOX/server/audiobooks/A/B/.fleet-book.json" | cut -d' ' -f1; }
  rc_kinds() { jq -c '[.companions[].kind] | sort' "$RIP_SANDBOX/server/audiobooks/A/B/.fleet-book.json"; }
  rc_view()  { jq -c '[(.companions|map(.kind)|sort),.ids["audible.asin"],.work.openlibrary]' "$RIP_SANDBOX/server/audiobooks/A/B/.fleet-book.json"; }
  rc_type()  { jq -r '.companions | type' "$RIP_SANDBOX/server/audiobooks/A/B/.fleet-book.json"; }
  rc_has_path() { jq -r 'has("_path")' "$RIP_SANDBOX/server/audiobooks/A/B/.fleet-book.json"; }
  rc_without_companions() { jq -Sc 'del(.companions)' "$RIP_SANDBOX/server/audiobooks/A/B/.fleet-book.json"; }

  # rc_mkbook — the stored book A/B: one audio file and one unrecorded PDF.
  rc_mkbook() {
    mkdir -p "$RIP_SANDBOX/server/audiobooks/A/B"
    printf 'audio\n' > "$RIP_SANDBOX/server/audiobooks/A/B/B.m4b"
    printf 'pdf\n'   > "$RIP_SANDBOX/server/audiobooks/A/B/B.pdf"
  }
  rc_plain_sidecar() {
    printf '%s\n' '{"schema":1,"kind":"audiobook","title":"B","authors":["A"],"ids":{}}' \
      | jq . > "$RIP_SANDBOX/server/audiobooks/A/B/.fleet-book.json"
  }

  It 'repair-companions: dry run reports a book whose PDF is unrecorded and writes nothing'
    rc_mkbook
    rc_plain_sidecar
    before=$(shasum -a 256 "$RIP_SANDBOX/server/audiobooks/A/B/.fleet-book.json" | cut -d' ' -f1)
    When run zsh -c "source $RIPLIB && rip::ab_repair_companions"
    The status should equal 0
    The output should include "A/B"
    The output should include "re-run with --apply"
    The result of function rc_sha should equal "$before"
  End

  It 'repair-companions: --apply records the companion and touches nothing else'
    rc_mkbook
    printf '%s\n' '{"schema":1,"kind":"audiobook","title":"B","authors":["A"],"ids":{"audible.asin":"X1"},"work":{"openlibrary":"OL9W"}}' \
      | jq . > "$RIP_SANDBOX/server/audiobooks/A/B/.fleet-book.json"
    When run zsh -c "source $RIPLIB && rip::ab_repair_companions --apply"
    The status should equal 0
    The output should include "recorded companions for 1 of 1"
    The result of function rc_view should equal '[["pdf"],"X1","OL9W"]'
  End

  # The recorded row is the REAL size and the REAL hash of the stored file,
  # computed on the server (which holds the only copy) — not a placeholder.
  It 'repair-companions: the recorded row carries the real size and hash'
    rc_mkbook
    rc_plain_sidecar
    fake_server_ssh
    When run zsh -c "source $RIPLIB && rip::ab_repair_companions --apply && jq -c '.companions[0] | [.file,.kind,.bytes,.sha256]' $RIP_SANDBOX/server/audiobooks/A/B/.fleet-book.json"
    The status should equal 0
    The output should include "[\"B.pdf\",\"pdf\",4,\"$(shasum -a 256 "$RIP_SANDBOX/server/audiobooks/A/B/B.pdf" | cut -d' ' -f1)\"]"
  End

  It 'repair-companions: a book whose companions are already correct is left byte-identical'
    rc_mkbook
    jq -n --arg s "$(shasum -a 256 "$RIP_SANDBOX/server/audiobooks/A/B/B.pdf" | cut -d' ' -f1)" \
      '{schema:1,kind:"audiobook",title:"B",authors:["A"],ids:{},companions:[{file:"B.pdf",kind:"pdf",bytes:4,sha256:$s}]}' \
      > "$RIP_SANDBOX/server/audiobooks/A/B/.fleet-book.json"
    before=$(shasum -a 256 "$RIP_SANDBOX/server/audiobooks/A/B/.fleet-book.json" | cut -d' ' -f1)
    When run zsh -c "source $RIPLIB && rip::ab_repair_companions --apply"
    The status should equal 0
    The output should include "nothing to record"
    The result of function rc_sha should equal "$before"
  End

  # THE LESSON THIS SUBSYSTEM ALREADY PAID FOR: rip::_server_sidecars silently
  # DROPS a sidecar it cannot parse, so "unparseable" is indistinguishable from
  # "absent" unless the sweep checks the directory itself. Overwriting one
  # destroys identity a human could otherwise have recovered by hand.
  It 'repair-companions: a malformed sidecar is reported, never overwritten'
    mkdir -p "$RIP_SANDBOX/server/audiobooks/A/B"
    printf 'audio\n' > "$RIP_SANDBOX/server/audiobooks/A/B/B.m4b"
    printf 'pdf\n'   > "$RIP_SANDBOX/server/audiobooks/A/B/B.pdf"
    printf '%s' '{"schema":1, "title": "B", BROKEN' > "$RIP_SANDBOX/server/audiobooks/A/B/.fleet-book.json"
    before=$(shasum -a 256 "$RIP_SANDBOX/server/audiobooks/A/B/.fleet-book.json" | cut -d' ' -f1)
    When run zsh -c "source $RIPLIB && rip::ab_repair_companions --apply"
    The status should not equal 0
    The output should include "A/B"
    The output should not include "recorded companions for 1"
    The stderr should include "malformed sidecar"
    The result of function rc_sha should equal "$before"
  End

  # A DRY RUN OPENS NO WRITE CONNECTION. Two ssh calls — enumerate the
  # sidecars, list the files — and the write script (its `mv --` is the only
  # thing that replaces a sidecar) is never handed to the server at all.
  It 'repair-companions: a dry run opens no write connection'
    rc_mkbook
    rc_plain_sidecar
    fake_server_ssh
    When run zsh -c "source $RIPLIB && rip::ab_repair_companions"
    The status should equal 0
    The output should include "re-run with --apply"
    The result of function ssh_calls should equal "2"
    The contents of file "$RIP_SANDBOX/ssh.cmds" should not include "mv --"
  End

  It 'repair-companions: --apply writes through a server with NO jq, in ONE ssh for the whole batch'
    rc_mkbook
    rc_plain_sidecar
    mkdir -p "$RIP_SANDBOX/server/audiobooks/C/D"
    printf 'audio\n' > "$RIP_SANDBOX/server/audiobooks/C/D/D.m4b"
    printf 'jpg\n'   > "$RIP_SANDBOX/server/audiobooks/C/D/cover.jpg"
    printf '%s\n' '{"schema":1,"kind":"audiobook","title":"D","authors":["C"],"ids":{}}' \
      | jq . > "$RIP_SANDBOX/server/audiobooks/C/D/.fleet-book.json"
    fake_server_ssh
    When run zsh -c "source $RIPLIB && rip::ab_repair_companions --apply"
    The status should equal 0
    The output should include "recorded companions for 2 of 2"
    # THREE ssh calls for two books: enumerate, list, and ONE write batch.
    # 247 books must not be 247 round-trips.
    The result of function ssh_calls should equal "3"
    # …and nothing the server was asked to run mentions jq. fake_server_ssh's
    # handpicked PATH holds none; this names the regression.
    The result of function ssh_cmds should not include "jq"
    The result of function rc_kinds should equal '["pdf"]'
  End

  # rip::_server_sidecars ANNOTATES every row with a `_path` key that is NOT
  # in the stored file; writing the annotated object back would permanently
  # add a bogus field to the only copy of a book's identity. Everything else
  # — a resolved `work`, existing `ids`, a null, a false, a title full of
  # characters that would wreck an unquoted remote command line — must
  # survive byte for byte.
  RC_RICH='{"schema":1,"kind":"audiobook","title":"Elantris: 10th $Ann - Omega","authors":["Sanderson, B. \"Bran\""],"ids":{"audible.asin":"X1","isbn":null},"abridged":false,"work":{"openlibrary":"OL9W"},"source":{"provider":"libation","acquired_utc":"2026-08-22"}}'

  It 'repair-companions: the written sidecar gains ONLY companions — no _path, nothing else altered'
    rc_mkbook
    printf '%s' "$RC_RICH" > "$RIP_SANDBOX/server/audiobooks/A/B/.fleet-book.json"
    expected=$(printf '%s' "$RC_RICH" | jq -Sc .)
    fake_server_ssh
    When run zsh -c "source $RIPLIB && rip::ab_repair_companions --apply"
    The status should equal 0
    The output should include "recorded companions for 1 of 1"
    The result of function rc_has_path should equal "false"
    The result of function rc_without_companions should equal "$expected"
  End

  # ONE answer for what counts as audio. The module already answers it in
  # rip::_dir_has_audio, rip::_sidecars_hash_primary's server-side scan and
  # rip::_companions_json with the same 11 extensions; the remote listing this
  # sweep ships must not be a fourth, narrower one. A retained Libation `.aax`
  # and an uppercase `.MP3` chapter are both audio — recording either would
  # also mean the server sha256s multi-gigabyte files it has no reason to read.
  It 'repair-companions: audio is never recorded as a companion, whatever its case'
    rc_mkbook
    printf 'source-audio\n' > "$RIP_SANDBOX/server/audiobooks/A/B/B.aax"
    printf 'chapter\n' > "$RIP_SANDBOX/server/audiobooks/A/B/01 - Chapter One.MP3"
    rc_plain_sidecar
    fake_server_ssh
    When run zsh -c "source $RIPLIB && rip::ab_repair_companions --apply"
    The status should equal 0
    The result of function rc_kinds should equal '["pdf"]'
  End

  # A book with NO companion files at all still gains the field: `[]` means
  # "scanned, nothing there", an absent key means "never looked". jq's
  # `length` returns 0 for `null` as well as `[]`, so `type` is what actually
  # discriminates the two.
  It 'repair-companions: a book with no companion files gains an empty array, not a missing key'
    mkdir -p "$RIP_SANDBOX/server/audiobooks/A/B"
    printf 'audio\n' > "$RIP_SANDBOX/server/audiobooks/A/B/B.m4b"
    rc_plain_sidecar
    fake_server_ssh
    When run zsh -c "source $RIPLIB && rip::ab_repair_companions --apply"
    The status should equal 0
    The result of function rc_type should equal "array"
    The result of function rc_kinds should equal "[]"
  End

  # A server that was never reached must not read as a library with nothing to
  # record — the same refusal --backfill-published and --editions already make.
  It 'repair-companions: an unreachable server records nothing and never says "nothing to record"'
    rc_mkbook
    rc_plain_sidecar
    fake_server_ssh
    printf '#!/bin/sh\nexit 255\n' > "$RIP_SANDBOX/ssh"
    chmod +x "$RIP_SANDBOX/ssh"
    before=$(shasum -a 256 "$RIP_SANDBOX/server/audiobooks/A/B/.fleet-book.json" | cut -d' ' -f1)
    When run zsh -c "source $RIPLIB && rip::ab_repair_companions --apply"
    The status should equal 2
    The output should not include "nothing to record"
    The output should not include "recorded companions"
    The stderr should include "refusing"
    The result of function rc_sha should equal "$before"
  End

  # A write that cannot land leaves the good sidecar exactly as it was, leaves
  # no temp file behind, and is COUNTED AS A FAILURE — never inferred from the
  # call having been made.
  rc_stray_tmp() { find "$RIP_SANDBOX/server" -name '*.tmp.*' | wc -l | tr -d ' '; }

  It 'repair-companions: a write that fails leaves the good sidecar untouched and reports it'
    rc_mkbook
    rc_plain_sidecar
    fake_server_ssh
    before=$(shasum -a 256 "$RIP_SANDBOX/server/audiobooks/A/B/.fleet-book.json" | cut -d' ' -f1)
    When run zsh -c "source $RIPLIB
      chmod 555 '$RIP_SANDBOX/server/audiobooks/A/B'
      rip::ab_repair_companions --apply; rc=\$?
      chmod 755 '$RIP_SANDBOX/server/audiobooks/A/B'
      exit \$rc"
    The status should equal 1
    The output should include "recorded companions for 0 of 1"
    The output should include "1 sidecar(s) could not be written"
    The result of function rc_sha should equal "$before"
    The result of function rc_stray_tmp should equal "0"
  End

  # REVIEW FINDING 1 (2026-08-25). The malformed guard used to test NON-EMPTY,
  # not SHAPE — and a sidecar whose entire content is the JSON literal `null`
  # survives the read path: jq accepts a null left operand for `+`, so
  # rip::_server_sidecars turns it into `{"_path":"A/B"}` and
  # rip::_sidecar_index strips that back to `{}`, which is non-empty. The book
  # was laundered out of the malformed report and rewritten as
  # `{"companions":[...]}` — an identity-less file that now looks SWEPT. The
  # other malformed shapes (empty, truncated, bare array, string, number) were
  # already reported correctly; only `null` slipped through.
  It 'repair-companions: a sidecar that is the JSON literal null is reported, never rewritten'
    rc_mkbook
    printf 'null' > "$RIP_SANDBOX/server/audiobooks/A/B/.fleet-book.json"
    before=$(shasum -a 256 "$RIP_SANDBOX/server/audiobooks/A/B/.fleet-book.json" | cut -d' ' -f1)
    When run zsh -c "source $RIPLIB && rip::ab_repair_companions --apply"
    The status should not equal 0
    The output should include "A/B"
    The output should not include "recorded companions for 1"
    The result of function rc_sha should equal "$before"
  End

  # A stored empty object carries no identity either, and is indistinguishable
  # from the `null` above by the time rip::_sidecar_index has run — so the same
  # refusal covers both. Writing companions into it would manufacture a book
  # that looks scanned and identifies nothing.
  It 'repair-companions: a sidecar that is an empty object is reported, never rewritten'
    rc_mkbook
    printf '{}' > "$RIP_SANDBOX/server/audiobooks/A/B/.fleet-book.json"
    before=$(shasum -a 256 "$RIP_SANDBOX/server/audiobooks/A/B/.fleet-book.json" | cut -d' ' -f1)
    When run zsh -c "source $RIPLIB && rip::ab_repair_companions --apply"
    The status should not equal 0
    The output should include "A/B"
    The result of function rc_sha should equal "$before"
  End

  # REVIEW FINDING 2 (2026-08-25), the eleventh defect of this class in this
  # subsystem. The remote enumeration is `find … | while read`, and a POSIX
  # pipeline reports the LAST command status — so find exiting non-zero
  # because it could not descend into a directory was DISCARDED, and the sweep
  # printed "recorded companions for 2 of 2" with rc 0 for a library where a
  # third book was never seen. rip::_server_sidecars under-enumerates
  # identically, so the denominator agrees with the short listing and nothing
  # internal catches the discrepancy: a tally claiming a completeness it never
  # established, on the very count the operator is told to read before writing
  # 247 files.
  rc_a2_companions() { jq -r '.companions // "ABSENT"' "$RIP_SANDBOX/server/audiobooks/A2/B2/.fleet-book.json"; }

  It 'repair-companions: a directory find could not read never reads as a complete sweep'
    rc_mkbook
    rc_plain_sidecar
    mkdir -p "$RIP_SANDBOX/server/audiobooks/C/D" "$RIP_SANDBOX/server/audiobooks/A2/B2"
    printf 'audio\n' > "$RIP_SANDBOX/server/audiobooks/C/D/D.m4b"
    printf 'jpg\n'   > "$RIP_SANDBOX/server/audiobooks/C/D/cover.jpg"
    printf '%s\n' '{"schema":1,"kind":"audiobook","title":"D","authors":["C"],"ids":{}}' \
      | jq . > "$RIP_SANDBOX/server/audiobooks/C/D/.fleet-book.json"
    printf 'audio\n' > "$RIP_SANDBOX/server/audiobooks/A2/B2/B2.m4b"
    printf 'pdf\n'   > "$RIP_SANDBOX/server/audiobooks/A2/B2/B2.pdf"
    printf '%s\n' '{"schema":1,"kind":"audiobook","title":"B2","authors":["A2"],"ids":{}}' \
      | jq . > "$RIP_SANDBOX/server/audiobooks/A2/B2/.fleet-book.json"
    fake_server_ssh
    When run zsh -c "source $RIPLIB
      chmod 000 '$RIP_SANDBOX/server/audiobooks/A2'
      rip::ab_repair_companions --apply; rc=\$?
      chmod 755 '$RIP_SANDBOX/server/audiobooks/A2'
      exit \$rc"
    The status should equal 1
    The output should include "incomplete"
    # The two books it COULD see are still recorded — the refusal is about the
    # tally claiming to be the whole library, not about refusing to work.
    The result of function rc_kinds should equal '["pdf"]'
    # …and the book behind the unreadable directory is demonstrably untouched.
    The result of function rc_a2_companions should equal "ABSENT"
  End

  # REVIEW TEST GAP (2026-08-25). `ssh` reads and forwards local stdin unless
  # given -n, so one inside a loop fed by a pipe swallows the rest of the list
  # and the loop silently ends after ONE item. Three occurrences in this
  # module so far, and a guard nobody tests is a guard that gets removed.
  # fake_server_ssh_reads_stdin is the only fake that models the slurp, and it
  # HONOURS -n exactly as ssh does — which is what makes this observable.
  It 'repair-companions: the listing ssh never eats the caller stdin'
    rc_mkbook
    rc_plain_sidecar
    fake_server_ssh_reads_stdin
    cat > "$RIP_SANDBOX/probe.zsh" <<EOF
source $RIPLIB
base="\$(rip::remote_base)"
n=0
while IFS= read -r l; do
  n=\$(( n + 1 ))
  rip::_server_companion_files "\$base" >/dev/null 2>&1
done < <(printf 'a\nb\nc\n')
print -r -- "loops=\$n"
EOF
    When run zsh "$RIP_SANDBOX/probe.zsh"
    The status should equal 0
    The output should include "loops=3"
  End

  It 'cli: --repair-companions is dispatched, and the usage names it'
    rc_mkbook
    rc_plain_sidecar
    When run zsh "$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_rip-audiobook" --repair-companions
    The status should equal 0
    The output should include "re-run with --apply"
  End

  It 'cli: the usage line names --repair-companions'
    When run zsh "$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_rip-audiobook" --help
    The status should equal 2
    The stderr should include "--repair-companions"
  End

  # --- --browse <root>: the folder provider as an alternative library ------
  #
  # `--browse` is `--library` pointed at a local tree instead of Libation's
  # catalogue: the SAME JSON-lines shape out, so the panel, the session
  # worker and the push all keep working without knowing which side it came
  # from. These assert the pass-through, not the provider (that is
  # tests/rip-folder-provider_spec.sh's whole file).
  browse_a_tree() {
    mkdir -p "$RIP_SANDBOX/incoming/Martha Wells/Network Effect"
    printf 'audio\n' > "$RIP_SANDBOX/incoming/Martha Wells/Network Effect/Network Effect.m4b"
    zsh "$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_rip-audiobook" \
      --browse "$RIP_SANDBOX/incoming"
  }

  It 'cli: --browse emits the folder provider rows for a root'
    When call browse_a_tree
    The status should equal 0
    The output should include '"provider":"folder"'
    The output should include '"path":"Martha Wells/Network Effect"'
    The output should include '"derived_from":"path"'
  End

  It 'cli: --browse without a root refuses rather than scanning something'
    When run zsh "$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_rip-audiobook" --browse
    The status should not equal 0
    The stderr should include "root required"
  End

  It 'cli: the usage line names --browse'
    When run zsh "$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_rip-audiobook" --help
    The status should equal 2
    The stderr should include "--browse"
  End

  # --- the library panel's Audible Plus marks (rip-library.html) ------------
  #
  # The panel's row rendering is JavaScript, so a mark that stops rendering is
  # invisible to every shell-level example above — and one of them did stop:
  # the "borrowed; rip before it lapses" line was gated on SERVER_KNOWN, so a
  # failed `--server-library` fetch (server down, VPN off) made the warning
  # vanish for the panel's whole lifetime. That is the warning whose absence
  # cost four Talon Saga books, and it must be at its loudest exactly when
  # the server cannot be reached.
  #
  # node runs the panel's OWN IIFE unmodified against a small DOM stub (at
  # boot it touches nothing but document.getElementById / addEventListener),
  # so these examples assert the real function rather than a transcription.
  PANEL_HTML="$SHELLSPEC_PROJECT_ROOT/home/dot_config/hammerspoon/Assets/html/rip-library.html"
  no_node() { ! command -v node >/dev/null 2>&1; }

  # panel_rows <rows-json> [server-paths-json] — the rendered #rows innerHTML.
  # OMIT the second argument to leave the server listing UNKNOWN, which is
  # exactly what a failed or absent --server-library fetch leaves behind
  # (library-dialog.lua returns without calling setServerLibrary).
  panel_rows() {
    cat > "$RIP_SANDBOX/panel.js" <<'JS'
const fs = require('fs');
const html = fs.readFileSync(process.env.PANEL_HTML, 'utf8');
// The second <script> block is the panel itself; the first is the onerror
// shim. %%LIBRARY_JSON%% is library-dialog.lua's payload placeholder.
const src = html.split('<script>')[2].split('</script>')[0]
                .replace('%%LIBRARY_JSON%%', 'null');
const els = {};
function stub() {
  return { innerHTML: '', textContent: '', value: '',
           classList: { add() {}, remove() {}, toggle() {} },
           addEventListener() {}, setAttribute() {},
           getAttribute() { return null; }, setSelectionRange() {} };
}
global.document = {
  getElementById(id) { return els[id] || (els[id] = stub()); },
  addEventListener() {}
};
global.window = global;
(0, eval)(src);
window.__setRows(JSON.parse(process.argv[2]));
if (process.argv[3] !== undefined) window.__setServerLibrary(JSON.parse(process.argv[3]));
process.stdout.write(els.rows.innerHTML);
JS
    PANEL_HTML="$PANEL_HTML" node "$RIP_SANDBOX/panel.js" "$@"
  }

  # panel_rows_shown <rows-json> <server-paths-json> — same, with the "show
  # library" chip ON, which is the only state in which a stored row is
  # rendered at all (with it off, visible() filters it out entirely).
  panel_rows_shown() {
    cat > "$RIP_SANDBOX/panel2.js" <<'JS'
const fs = require('fs');
const html = fs.readFileSync(process.env.PANEL_HTML, 'utf8');
const src = html.split('<script>')[2].split('</script>')[0]
                .replace('%%LIBRARY_JSON%%', 'null');
const els = {};
function stub() {
  return { innerHTML: '', textContent: '', value: '',
           classList: { add() {}, remove() {}, toggle() {} },
           addEventListener() {}, setAttribute() {},
           getAttribute() { return null; }, setSelectionRange() {} };
}
global.document = {
  getElementById(id) { return els[id] || (els[id] = stub()); },
  addEventListener() {}
};
global.window = global;
(0, eval)(src);
// The source MUST be switched first: __setRows discards a delivery whose
// sourceKind does not match the current SOURCE.kind (the guard that stops a
// folder scan landing in an Audible panel), so tagging it 'folder' while the
// panel is still in library mode silently renders nothing.
window.__setSource({ kind: 'folder', root: '/incoming' });
window.__setRows(JSON.parse(process.argv[2]), 'folder');
window.__setServerLibrary(JSON.parse(process.argv[3]));
window.__setShowLibrary(true);
process.stdout.write(els.rows.innerHTML);
JS
    PANEL_HTML="$PANEL_HTML" node "$RIP_SANDBOX/panel2.js" "$@"
  }

  # Mode B, 2026-08-25: re-ripping a book the server already held was refused,
  # but only in the job log — the panel let it be armed and the session exited
  # 0, so it read as success. The refusal is keyed on the composed path, which
  # the panel already knows, so it can be prevented instead of reported.
  It 'panel: a book already on cantina is blocked, with the reason and the way out'
    Skip if 'node is unavailable' no_node
    When call panel_rows_shown '[{"id":"1","path":"A/B","title":"B","authors":["A"],"narrators":[],"acquired":true}]' '["A/B"]'
    The status should equal 0
    The output should include 'data-blocked="true"'
    The output should include "already on cantina"
    # the way out is the Edition field, and it must be stated in the row
    # (2026-08-26: was "edit the title" — the title route still worked but
    # silently turned a deliberate edition into an unrelated book with an
    # odd title; the Edition field is the named, tracked route now).
    The output should include "set an Edition"
  End

  It 'panel: a book the server does NOT hold is left rippable'
    Skip if 'node is unavailable' no_node
    When call panel_rows_shown '[{"id":"1","path":"A/B","title":"B","authors":["A"],"narrators":[],"acquired":true}]' '["Someone/Else"]'
    The status should equal 0
    The output should include 'data-blocked="false"'
    The output should not include "already on cantina"
  End

  BORROWED='[{"id":"1","path":"Martha Wells/Fugitive Telemetry","title":"Fugitive Telemetry","authors":["Martha Wells"],"narrators":[],"plus":true,"absent":false,"acquired":false}]'

  It 'panel: the borrowed mark renders even when the server listing is unknown'
    Skip if 'node is unavailable' no_node
    When call panel_rows "$BORROWED"
    The status should equal 0
    The output should include "rip before it lapses"
  End

  It 'panel: the borrowed mark still renders once the server listing lands without this book'
    Skip if 'node is unavailable' no_node
    When call panel_rows "$BORROWED" '["Brandon Sanderson/Wind and Truth"]'
    The status should equal 0
    The output should include "rip before it lapses"
  End

  # The lapsed mark comes off the row alone and never needed the server.
  It 'panel: a lapsed Plus title is marked with the server listing unknown'
    Skip if 'node is unavailable' no_node
    When call panel_rows '[{"id":"1","path":"A/B","title":"B","authors":[],"narrators":[],"plus":true,"absent":true}]'
    The status should equal 0
    The output should include "licence lapsed"
    The output should not include "rip before it lapses"
  End

  # WHAT MUST NOT REGRESS: neverPushedHtml asserts a divergence BETWEEN TWO
  # SYSTEMS ("Libation has it, cantina does not"), so its tri-state gate is
  # correct and stays — silent until the server actually answers.
  It 'panel: "liberated, never pushed" stays silent until the server listing lands'
    Skip if 'node is unavailable' no_node
    When call panel_rows '[{"id":"1","path":"A/B","title":"B","authors":[],"narrators":[],"acquired":true}]'
    The status should equal 0
    The output should not include "never pushed"
  End

  It 'panel: "liberated, never pushed" appears once the server listing lands without the book'
    Skip if 'node is unavailable' no_node
    When call panel_rows '[{"id":"1","path":"A/B","title":"B","authors":[],"narrators":[],"acquired":true}]' '[]'
    The status should equal 0
    The output should include "never pushed"
  End

  # --- Files mode: the browsed source, and inline identity editing ---------
  #
  # The whole point of the folder source is that the operator FIXES a bad
  # guess in the panel instead of retyping three fields per book, and the
  # thing that must actually change is the row's `path` — that is what
  # rip::ab_worker passes to `rip-provider-folder acquire` as its third
  # argument and what the book stages (and pushes) under. So these examples
  # drive the panel's own handlers and assert on the PLAN IT POSTS, not on
  # the rendered markup: a row whose display looks right but whose posted
  # `path` still carries the guess would ship the book to the wrong shelf.
  #
  # This also pins the trap normalizeRow has already sprung once (it dropped
  # keys, and the sidecar recorded a false identity permanently): a NEW
  # provider key, `derived_from`, has to survive the round trip — including
  # when its value is falsy, which a truthiness-based copy would silently
  # drop while a non-empty value sailed through.
  #
  # panel_files <rows-json> [edits-json] [server-paths-json] [root]
  #   edits-json: [[<row id>, "author"|"title", "<new value>"], ...], each
  #   replayed through the panel's real delegated `input` handler.
  #   A 5th arg sets the browsed root; a 6th sets the source kind
  #   ("folder", the default, or "library").
  # Prints the posted plan as JSON, then #rows, #source and #summary raw.
  panel_files() {
    cat > "$RIP_SANDBOX/panel-files.js" <<'JS'
const fs = require('fs');
const html = fs.readFileSync(process.env.PANEL_HTML, 'utf8');
const src = html.split('<script>')[2].split('</script>')[0]
                .replace('%%LIBRARY_JSON%%', 'null');
const els = {};
function stub(id) {
  const listeners = {};
  const el = {
    id: id, innerHTML: '', textContent: '', value: '', hidden: false,
    classList: { add() {}, remove() {}, toggle() {} },
    addEventListener(type, fn) { (listeners[type] = listeners[type] || []).push(fn); },
    setAttribute() {}, getAttribute() { return null; }, setSelectionRange() {},
    fire(type, ev) { (listeners[type] || []).forEach((f) => f.call(el, ev)); }
  };
  return el;
}
global.document = {
  getElementById(id) { return els[id] || (els[id] = stub(id)); },
  addEventListener() {},
  querySelector() { return null; }
};
const POSTED = [];
global.window = global;
global.webkit = { messageHandlers: { ripLibrary: { postMessage(m) { POSTED.push(m); } } } };
(0, eval)(src);

// Fake event targets: closestAttr() only ever calls getAttribute/parentNode,
// so these stand in for the real nodes without needing a DOM.
const ev = () => ({ preventDefault() {} });
function toggleTarget(id) {
  return { getAttribute: (a) => (a === 'data-toggle' ? id : null), parentNode: null };
}
function editTarget(id, field, value) {
  return {
    value: value, selectionStart: value.length, setSelectionRange() {},
    classList: { add() {}, remove() {}, toggle() {} },
    getAttribute: (a) => (a === 'data-edit-row' ? id : a === 'data-field' ? field : null),
    parentNode: null
  };
}

const rows = JSON.parse(process.argv[2]);
const edits = JSON.parse(process.argv[3] || '[]');
window.__setSource({ kind: process.argv[6] || 'folder', root: process.argv[5] || '/Volumes/Media/Incoming' });
window.__setRows(rows);
if (process.argv[4] !== undefined && process.argv[4] !== '') {
  window.__setServerLibrary(JSON.parse(process.argv[4]));
}
// 7th arg 'show' flips the "show library" chip ON. Without it visible()
// filters a STORED row out of the markup entirely, so an example asserting
// that a row is blocked again would have nothing to assert against.
if (process.argv[7] === 'show') window.__setShowLibrary(true);
// A 4th tuple element names the event to fire ('input', the default, or
// 'blur') — added for task 3's on-blur author normalisation, which is
// deliberately NOT wired to 'input' (see panel_author_events below, which
// pins the caret-safety half of that). Every earlier caller omits it and
// keeps firing 'input'.
for (const edit of edits) {
  const evt = edit[3] || 'input';
  els.rows.fire(evt, Object.assign(ev(), { target: editTarget(String(edit[0]), edit[1], edit[2]) }));
}
for (const r of rows) {
  els.rows.fire('mousedown', Object.assign(ev(), { target: toggleTarget(String(r.id)) }));
}
els.btnStart.fire('mousedown', ev());
// The posted plan as JSON, then the rendered markup RAW. One combined
// JSON.stringify would escape every quote inside the innerHTML strings, so
// a `data-blocked="true"` assertion could never match what the panel
// actually emitted.
process.stdout.write(JSON.stringify(POSTED) + '\n'
  + els.rows.innerHTML + '\n' + els.source.innerHTML + '\n' + els.summary.innerHTML);
JS
    PANEL_HTML="$PANEL_HTML" node "$RIP_SANDBOX/panel-files.js" "$@"
  }

  FOLDER_ROW='[{"id":"/inc/Anncillary/Ancilary Justice","path":"Anncillary/Ancilary Justice","title":"Ancilary Justice","subtitle":null,"authors":["Anncillary"],"narrators":[],"derived_from":"path","provider":"folder","provider_version":"1","format":"m4b","acquired":true,"duration_s":0}]'

  It 'panel: a browsed row carries derived_from through to the posted plan'
    Skip if 'node is unavailable' no_node
    When call panel_files "$FOLDER_ROW"
    The status should equal 0
    The output should include '"derived_from":"path"'
    The output should include '"provider":"folder"'
  End

  # The falsy case specifically: a copy written as `if (r.derived_from)` keeps
  # "path" above and silently drops "" here.
  It 'panel: an EMPTY derived_from still survives into the posted plan'
    Skip if 'node is unavailable' no_node
    When call panel_files '[{"id":"1","path":"A/B","title":"B","authors":["A"],"narrators":[],"derived_from":""}]'
    The status should equal 0
    The output should include '"derived_from":""'
  End

  It 'panel: editing the author rewrites the row path the worker stages under'
    Skip if 'node is unavailable' no_node
    When call panel_files "$FOLDER_ROW" '[["/inc/Anncillary/Ancilary Justice","author","Ann Leckie"]]'
    The status should equal 0
    The output should include '"path":"Ann Leckie/Ancilary Justice"'
  End

  It 'panel: editing the title rewrites the row path the worker stages under'
    Skip if 'node is unavailable' no_node
    When call panel_files "$FOLDER_ROW" '[["/inc/Anncillary/Ancilary Justice","title","Ancillary Justice"]]'
    The status should equal 0
    The output should include '"path":"Anncillary/Ancillary Justice"'
  End

  # An emptied author must not leave a leading "/" in the path (that would be
  # an absolute path on the server side) — AND the row must not ship at all.
  # rip::_validate_ab_plan refuses a single-segment path for the WHOLE plan,
  # so a blank author here would abort a 40-book session after the panel has
  # already closed. Blocking the one row is the difference.
  It 'panel: clearing the author blocks that row instead of shipping a bare title'
    Skip if 'node is unavailable' no_node
    When call panel_files "$FOLDER_ROW" '[["/inc/Anncillary/Ancilary Justice","author",""]]'
    The status should equal 0
    The output should not include '"path":"/Ancilary Justice"'
    The output should not include '"action":"start"'
    The output should include 'data-blocked="true"'
  End

  # --- the Edition field (task 4, 2026-08-26) -------------------------------
  #
  # A third inline field beside Author and Title, files mode only. Empty by
  # default (an ordinary rip is unchanged); setting one composes
  # <Author>/<Title> (<Edition>) — the exact suffix rip::ab_worker strips
  # back off to resolve the shared base book. This is also what clears the
  # stored-book block above (the "already on cantina" tests): the composed
  # path stops colliding, so isStored(r) goes false with no special case
  # added anywhere.

  It 'panel: the Edition field renders beside Author and Title in files mode'
    Skip if 'node is unavailable' no_node
    When call panel_files "$FOLDER_ROW"
    The status should equal 0
    The output should include 'data-field="edition"'
    The output should include 'placeholder="Edition"'
  End

  It 'panel: setting an edition composes <Author>/<Title> (<Edition>)'
    Skip if 'node is unavailable' no_node
    When call panel_files "$FOLDER_ROW" '[["/inc/Anncillary/Ancilary Justice","edition","Full Cast"]]'
    The status should equal 0
    The output should include '"path":"Anncillary/Ancilary Justice (Full Cast)"'
  End

  It 'panel: a row blocked as stored becomes unblocked once an edition is set'
    Skip if 'node is unavailable' no_node
    When call panel_files "$FOLDER_ROW" '[["/inc/Anncillary/Ancilary Justice","edition","Full Cast"]]' '["Anncillary/Ancilary Justice"]'
    The status should equal 0
    The output should include '"path":"Anncillary/Ancilary Justice (Full Cast)"'
    The output should include 'data-blocked="false"'
    The output should not include "already on cantina"
  End

  # Not merely "the path has no suffix" — an unrecognized field would be a
  # silent no-op that happens to leave the path unchanged too, which would
  # pass this whole example even with no edition support at all. Pinning
  # the rendered field's OWN presence and its valid (non-'invalid') class
  # is what actually exercises "empty is legal" (editionValid, not
  # titleValid) rather than "nothing happened".
  It 'panel: an empty edition composes the unsuffixed path, unchanged'
    Skip if 'node is unavailable' no_node
    When call panel_files "$FOLDER_ROW" '[["/inc/Anncillary/Ancilary Justice","edition",""]]'
    The status should equal 0
    The output should include '"path":"Anncillary/Ancilary Justice"'
    The output should not include '" ("'
    The output should include 'edit-edition'
    The output should not include 'edit-edition invalid'
  End

  It 'panel: a slash in the edition field is stripped as typed'
    Skip if 'node is unavailable' no_node
    When call panel_files "$FOLDER_ROW" '[["/inc/Anncillary/Ancilary Justice","edition","Full/Cast"]]'
    The status should equal 0
    The output should include '"path":"Anncillary/Ancilary Justice (FullCast)"'
    The output should not include "Full/Cast"
  End

  # --- task 5, 2026-08-26: the Edition field in library mode ---------------
  #
  # An Audible book can be a distinct edition too (a re-recording, a
  # full-cast production), and the panel gains ONE editable field there —
  # not inline editing of Audible metadata. Library rows render `name`/
  # `byline`, never editHtml, so author and title must stay non-editable:
  # a change that made the whole row editable would let the operator
  # silently rewrite Audible-derived identity, which is exactly what the
  # folder provider's inline editing exists to keep separate.
  #
  # panel_files's 6th arg is the source kind, already plumbed for this
  # (`window.__setSource({ kind: process.argv[6] || 'folder', ... })`), and
  # its __setRows call is untagged, so it lands regardless of SOURCE.kind —
  # no need for a dedicated harness.
  LIBRARY_ROW='[{"id":"1","path":"J. R. R. Tolkien/The Silmarillion","title":"The Silmarillion","subtitle":null,"authors":["J. R. R. Tolkien"],"narrators":[]}]'

  # Both facts pinned in ONE example, deliberately: asserting the absence of
  # data-field="author"/"title" BY ITSELF would pass even with no
  # implementation at all (library mode renders neither field today) — a
  # vacuous pass. Requiring data-field="edition" to ALSO be present in the
  # same output is what makes the absence assertions mean something.
  It 'panel: the Edition field renders for a library-mode row, without making the rest editable'
    Skip if 'node is unavailable' no_node
    When call panel_files "$LIBRARY_ROW" '[]' '' '' 'library'
    The status should equal 0
    The output should include 'data-field="edition"'
    The output should include 'placeholder="Edition"'
    The output should not include 'data-field="author"'
    The output should not include 'data-field="title"'
    The output should include 'class="name"'
    The output should include 'class="byline"'
  End

  # applyEdit's field dispatch is already mode-agnostic (task 4), and the
  # harness fires the `input` event through a synthetic target rather than a
  # real DOM node — so asserting only the posted path here would pass with
  # NOTHING written for this task: applyEdit does not consult isFiles(), and
  # the composition it runs was never mode-specific to begin with. Pinning
  # `data-field="edition"` in the SAME example ties the claim to the render
  # path this task actually adds — without it, there is no field for the
  # operator to have typed into in the first place.
  It 'panel: a library row with an edition composes <Author>/<Title> (<Edition>), same as files mode'
    Skip if 'node is unavailable' no_node
    When call panel_files "$LIBRARY_ROW" '[["1","edition","Full Cast"]]' '' '' 'library'
    The status should equal 0
    The output should include 'data-field="edition"'
    The output should include '"path":"J. R. R. Tolkien/The Silmarillion (Full Cast)"'
  End

  # --- THE SUBTITLE (review finding, 2026-08-26) ---------------------------
  #
  # applyEdit recomposes `path` from authors[0] + title. That invariant holds
  # for FOLDER rows — rip-provider-folder emits path = author + "/" + title
  # — but NOT for the libation rows library mode is made of: that provider
  # composes `$folder` as "Title: Subtitle" and emits path = "$author/
  # $folder" while `title` stays BARE. LIBRARY_ROW above has no subtitle, so
  # every library-mode example written before this one agreed with the
  # recomposition by accident. Most of the operator's library does have one.
  #
  # Both proved consequences get an example: the composed path the worker
  # strips its suffix off, and touch-and-clear.
  LIBRARY_ROW_SUB='[{"id":"1","path":"J. R. R. Tolkien/The Silmarillion: Of the Beginning of Days","title":"The Silmarillion","subtitle":"Of the Beginning of Days","authors":["J. R. R. Tolkien"],"narrators":[]}]'

  # Consequence (a): the suffix must hang off the path the book actually
  # lives at. rip::ab_worker resolves the shared work by stripping exactly
  # " (<Edition>)" back off and reading THAT book's sidecar — so a base that
  # drops the subtitle names a book that is not stored anywhere, the edition
  # mints a fresh uid, and the two never group. Permanent: both then carry a
  # non-null `work` and neither is a --backfill-work-uid candidate again.
  It 'panel: an edition on a library row with a subtitle keeps the subtitle in the composed path'
    Skip if 'node is unavailable' no_node
    When call panel_files "$LIBRARY_ROW_SUB" '[["1","edition","Full Cast"]]' '' '' 'library'
    The status should equal 0
    The output should include 'data-field="edition"'
    The output should include '"path":"J. R. R. Tolkien/The Silmarillion: Of the Beginning of Days (Full Cast)"'
    The output should not include '"path":"J. R. R. Tolkien/The Silmarillion (Full Cast)"'
  End

  # Consequence (b), the dangerous one: TOUCH-AND-CLEAR. Typing one character
  # into a library row's Edition and deleting it again must leave the row
  # exactly as it was — still blocked as already on cantina. With the path
  # recomposed from the bare title it came back subtitle-less, which is a
  # path the server does not hold: the block silently cleared and the row
  # shipped as a duplicate under a truncated name.
  #
  # The 'show' argument is load-bearing and so are the POSITIVE assertions:
  # a stored row is filtered out of the markup with the chip off, so
  # "should not include data-blocked=false" would pass against a panel that
  # rendered nothing at all.
  It 'panel: touching and clearing a library row Edition leaves it blocked, subtitle intact'
    Skip if 'node is unavailable' no_node
    When call panel_files "$LIBRARY_ROW_SUB" '[["1","edition","F"],["1","edition",""]]' '["J. R. R. Tolkien/The Silmarillion: Of the Beginning of Days"]' '' 'library' 'show'
    The status should equal 0
    The output should include 'data-field="edition"'
    The output should include 'data-blocked="true"'
    The output should include "already on cantina as J. R. R. Tolkien/The Silmarillion: Of the Beginning of Days"
    The output should not include 'data-blocked="false"'
    # ...and nothing is posted: the only selected row is stored, so there is
    # no plan to start at all.
    The output should not include '"action":"start"'
  End

  # A derived identity is a GUESS, and the panel has to say which kind: the
  # operator scans for the weak ones rather than re-reading every row.
  It 'panel: each files-mode row shows where its identity was guessed from'
    Skip if 'node is unavailable' no_node
    When call panel_files '[{"id":"1","path":"B","title":"B","authors":[],"narrators":[],"derived_from":"filename"}]'
    The status should equal 0
    The output should include "from the filename"
  End

  # A mis-picked folder surfacing hundreds of rows must be obvious BEFORE the
  # operator starts selecting, so the root itself is on screen, not just a
  # "Files" label.
  It 'panel: the source chip names the browsed root and the candidate count'
    Skip if 'node is unavailable' no_node
    When call panel_files "$FOLDER_ROW" '[]' '' '/Volumes/Media/Wrong Folder'
    The status should equal 0
    The output should include "/Volumes/Media/Wrong Folder"
    The output should include "1 candidate"
  End

  # "liberated, never pushed" is Libation vocabulary about a divergence
  # between Audible and cantina. Every folder row carries acquired:true (the
  # bytes are on this disk), so without a mode gate the line would fire on
  # EVERY browsed row the server does not hold — noise on exactly the rows
  # the operator is about to select.
  # A browse that never lands must cost the operator NOTHING. The switch to
  # the folder source clears the rows (they belong to the library being
  # left), so a failure that merely ended the loading state would leave
  # "nothing to show" where a perfectly good library used to be — and the
  # panel offers no way to re-fetch it short of dismissing and reopening.
  # library.browseFailed() puts the whole switch back.
  panel_browse_failed() {
    cat > "$RIP_SANDBOX/panel-failed.js" <<'JS'
const fs = require('fs');
const html = fs.readFileSync(process.env.PANEL_HTML, 'utf8');
const src = html.split('<script>')[2].split('</script>')[0]
                .replace('%%LIBRARY_JSON%%', 'null');
const els = {};
function stub(id) {
  return { id: id, innerHTML: '', textContent: '', value: '',
           classList: { add() {}, remove() {}, toggle() {} },
           addEventListener() {}, setAttribute() {},
           getAttribute() { return null; }, setSelectionRange() {} };
}
global.document = {
  getElementById(id) { return els[id] || (els[id] = stub(id)); },
  addEventListener() {}, querySelector() { return null; }
};
global.window = global;
(0, eval)(src);
window.__setRows(JSON.parse(process.argv[2]));
window.__setSource({ kind: 'folder', root: '/nope' });
window.__sourceFailed();
process.stdout.write(els.rows.innerHTML + '' + els.source.innerHTML);
JS
    PANEL_HTML="$PANEL_HTML" node "$RIP_SANDBOX/panel-failed.js" "$@"
  }

  It 'panel: a failed browse restores the library that was already on screen'
    Skip if 'node is unavailable' no_node
    When call panel_browse_failed '[{"id":"1","path":"Martha Wells/Network Effect","title":"Network Effect","authors":["Martha Wells"],"narrators":[]}]'
    The status should equal 0
    The output should include "Network Effect"
    # .source-name only renders for the Audible source; files mode renders
    # .source-root instead — so this pins the SOURCE going back too, not
    # just the rows. (The literal words "Audible library" would not: the
    # way-back control in files mode carries them as its own label.)
    The output should include 'class="source-name"'
    The output should not include "/nope"
    The output should not include "nothing to show"
  End

  # --- author normalisation on blur (task 3, 2026-08-26) -------------------
  #
  # rip::_author_display (home/dot_local/lib/rip.zsh) is the canonical DISPLAY
  # form of an author: a single letter, a period, then immediately another
  # letter (no space between) gets a space inserted after the period. THIS IS
  # A SECOND IMPLEMENTATION of that exact rule, in JavaScript — the panel
  # cannot fork a shell on every blur, on a keystroke-latency path — and the
  # two must not drift. Every row of rip::_author_display's own table is
  # exercised here.
  #
  # ON BLUR, NOT ON INPUT. Rewriting the field per keystroke would move the
  # caret mid-word: typing "J." would become "J. " and the next character —
  # the "K" the operator is still typing — would land in the wrong place. The
  # existing slash-stripping IS per-keystroke and restores the caret
  # deliberately (see the `input` listener above); author normalisation does
  # not copy that pattern.
  #
  # panel_author_events fires ONE event at the author field and hands back
  # the mutated target's OWN `.value` — not the rendered row (edits
  # deliberately do not trigger a re-render, so the row markup would still
  # show the pre-edit value regardless of what the handler did) and not the
  # composed path (a bug that fired on BOTH 'input' and 'blur' would still
  # make a path-only assertion pass). Reading the field's value back is what
  # a naive "always run" or "never run" implementation cannot fake.
  panel_author_events() {
    cat > "$RIP_SANDBOX/panel-author.js" <<'JS'
const fs = require('fs');
const html = fs.readFileSync(process.env.PANEL_HTML, 'utf8');
const src = html.split('<script>')[2].split('</script>')[0]
                .replace('%%LIBRARY_JSON%%', 'null');
const els = {};
function stub(id) {
  const listeners = {};
  const el = {
    id: id, innerHTML: '', textContent: '', value: '', hidden: false,
    classList: { add() {}, remove() {}, toggle() {} },
    addEventListener(type, fn) { (listeners[type] = listeners[type] || []).push(fn); },
    setAttribute() {}, getAttribute() { return null; }, setSelectionRange() {},
    fire(type, ev) { (listeners[type] || []).forEach((f) => f.call(el, ev)); }
  };
  return el;
}
global.document = {
  getElementById(id) { return els[id] || (els[id] = stub(id)); },
  addEventListener() {},
  querySelector() { return null; }
};
global.window = global;
global.webkit = { messageHandlers: { ripLibrary: { postMessage() {} } } };
(0, eval)(src);

const ev = () => ({ preventDefault() {} });
function editTarget(id, field, value) {
  return {
    value: value, selectionStart: value.length, setSelectionRange() {},
    classList: { add() {}, remove() {}, toggle() {} },
    getAttribute: (a) => (a === 'data-edit-row' ? id : a === 'data-field' ? field : null),
    parentNode: null
  };
}

const rows = JSON.parse(process.argv[2]);
window.__setSource({ kind: 'folder', root: '/incoming' });
// Untagged, same as panel_files above: __setRows discards a delivery whose
// sourceKind does not match SOURCE.kind, and an untagged call lands
// regardless — the folder source above is only there so isFiles() renders
// the author field at all.
window.__setRows(rows);

const t = editTarget(String(rows[0].id), 'author', process.argv[3]);
els.rows.fire(process.argv[4], Object.assign(ev(), { target: t }));
process.stdout.write(JSON.stringify({ value: t.value }));
JS
    PANEL_HTML="$PANEL_HTML" node "$RIP_SANDBOX/panel-author.js" "$@"
  }

  AUTHOR_ROW='[{"id":"1","path":"A/B","title":"B","authors":["A"],"narrators":[]}]'

  It 'panel: J.K. Rowling becomes J. K. Rowling on blur'
    Skip if 'node is unavailable' no_node
    When call panel_author_events "$AUTHOR_ROW" 'J.K. Rowling' 'blur'
    The status should equal 0
    The output should eq '{"value":"J. K. Rowling"}'
  End

  It 'panel: J.R.R. Tolkien becomes J. R. R. Tolkien on blur'
    Skip if 'node is unavailable' no_node
    When call panel_author_events "$AUTHOR_ROW" 'J.R.R. Tolkien' 'blur'
    The status should equal 0
    The output should eq '{"value":"J. R. R. Tolkien"}'
  End

  It 'panel: e.e. cummings becomes e. e. cummings on blur'
    Skip if 'node is unavailable' no_node
    When call panel_author_events "$AUTHOR_ROW" 'e.e. cummings' 'blur'
    The status should equal 0
    The output should eq '{"value":"e. e. cummings"}'
  End

  It 'panel: J.K.Rowling (no space before the second initial either) becomes J. K. Rowling on blur'
    Skip if 'node is unavailable' no_node
    When call panel_author_events "$AUTHOR_ROW" 'J.K.Rowling' 'blur'
    The status should equal 0
    The output should eq '{"value":"J. K. Rowling"}'
  End

  # The negative that matters: two letters before the period is an
  # abbreviation ("Dr"), not two initials, and must NOT get a space. A greedy
  # "space every period" rule mangles this into "Dr. Smith".
  It 'panel: Dr.Smith is left alone on blur — two letters before the period is not an initial'
    Skip if 'node is unavailable' no_node
    When call panel_author_events "$AUTHOR_ROW" 'Dr.Smith' 'blur'
    The status should equal 0
    The output should eq '{"value":"Dr.Smith"}'
  End

  # The other negative: already spaced, so the rule must be idempotent about
  # detecting "already correct" rather than counting periods.
  It 'panel: St. Martin is left alone on blur — already spaced'
    Skip if 'node is unavailable' no_node
    When call panel_author_events "$AUTHOR_ROW" 'St. Martin' 'blur'
    The status should equal 0
    The output should eq '{"value":"St. Martin"}'
  End

  It 'panel: J. K. Rowling is unchanged on blur — idempotent'
    Skip if 'node is unavailable' no_node
    When call panel_author_events "$AUTHOR_ROW" 'J. K. Rowling' 'blur'
    The status should equal 0
    The output should eq '{"value":"J. K. Rowling"}'
  End

  It 'panel: Brandon Sanderson is unchanged on blur — no periods to touch'
    Skip if 'node is unavailable' no_node
    When call panel_author_events "$AUTHOR_ROW" 'Brandon Sanderson' 'blur'
    The status should equal 0
    The output should eq '{"value":"Brandon Sanderson"}'
  End

  It 'panel: an empty author stays empty on blur'
    Skip if 'node is unavailable' no_node
    When call panel_author_events "$AUTHOR_ROW" '' 'blur'
    The status should equal 0
    The output should eq '{"value":""}'
  End

  # THE CARET GUARD. Firing 'input' — a mid-word keystroke, not a commit — is
  # the event the per-keystroke slash-stripping DOES use; author
  # normalisation must not. If this fired on 'input', typing "J." one
  # character at a time would come back "J. " immediately, moving the caret
  # into the middle of the word the operator is still typing.
  It 'panel: typing "J." does NOT get rewritten on input — only blur normalises'
    Skip if 'node is unavailable' no_node
    When call panel_author_events "$AUTHOR_ROW" 'J.' 'input'
    The status should equal 0
    The output should eq '{"value":"J."}'
  End

  # Same value, the composing event: confirms the SAME string that stayed put
  # on input above DOES normalise once the field is committed.
  It 'panel: "J." is left as a partial initial on input, but a fuller value normalises on blur'
    Skip if 'node is unavailable' no_node
    When call panel_author_events "$AUTHOR_ROW" 'J.K.' 'blur'
    The status should equal 0
    The output should eq '{"value":"J. K."}'
  End

  # And the composed path follows — the whole reason this lives in the panel
  # rather than only the worker (docs/superpowers/specs/2026-08-26-audiobook-
  # authoritative-tags-design.md §1): applyEdit recomposes <Author>/<Title>
  # from whatever the field holds, so the canonical form has to enter through
  # the field itself.
  It 'panel: blurring the author field with initials rewrites the composed path too'
    Skip if 'node is unavailable' no_node
    When call panel_files "$FOLDER_ROW" '[["/inc/Anncillary/Ancilary Justice","author","J.K. Rowling","blur"]]'
    The status should equal 0
    The output should include '"path":"J. K. Rowling/Ancilary Justice"'
  End

  # --- the CLICK path (review finding F1, 2026-08-26) ----------------------
  #
  # Every example above commits the field with an EVENT the test fires
  # directly. The operator's ordinary gesture does not: they type into the
  # author field and click "Start Rip". #btnStart is a <span> whose mousedown
  # handler calls e.preventDefault(), which is what keeps the click from
  # pulling focus out of the row list — and which also suppresses the FOCUS
  # CHANGE, so the field never blurred, authorDisplay() never ran, and start()
  # posted whatever the PER-KEYSTROKE `input` listener had last written: the
  # raw spelling. This panel is the only place the canonical form can enter
  # for an author the server has never seen.
  #
  # The harness models exactly that sequence — select the row, type, focus,
  # click — and reads BOTH the field and the posted payload, because the
  # payload is what actually reaches the worker.
  panel_click_commit() {
    cat > "$RIP_SANDBOX/panel-click.js" <<'JS'
const fs = require('fs');
const html = fs.readFileSync(process.env.PANEL_HTML, 'utf8');
const src = html.split('<script>')[2].split('</script>')[0]
                .replace('%%LIBRARY_JSON%%', 'null');
const els = {};
function stub(id) {
  const listeners = {};
  const el = {
    id: id, innerHTML: '', textContent: '', value: '', hidden: false,
    classList: { add() {}, remove() {}, toggle() {} },
    addEventListener(type, fn) { (listeners[type] = listeners[type] || []).push(fn); },
    setAttribute() {}, getAttribute() { return null; }, setSelectionRange() {},
    fire(type, ev) { (listeners[type] || []).forEach((f) => f.call(el, ev)); }
  };
  return el;
}
global.document = {
  activeElement: null,
  getElementById(id) { return els[id] || (els[id] = stub(id)); },
  addEventListener() {},
  querySelector() { return null; }
};
global.window = global;
const posted = [];
global.webkit = { messageHandlers: { ripLibrary: { postMessage(m) { posted.push(m); } } } };
(0, eval)(src);

const ev = () => ({ preventDefault() {} });
const rows = JSON.parse(process.argv[2]);
const raw = process.argv[3];
const clickId = process.argv[4];

window.__setSource({ kind: 'folder', root: '/incoming' });
window.__setRows(rows);

// 1. select the row, through the panel's own delegated toggle handler.
els.rows.fire('mousedown', Object.assign(ev(), {
  target: { getAttribute: (a) => (a === 'data-toggle' ? String(rows[0].id) : null), parentNode: null }
}));

// 2. type into the author field — the per-keystroke `input` listener is what
//    writes the RAW value into the model, and is the state a click interrupts.
const t = {
  value: raw, selectionStart: raw.length, setSelectionRange() {},
  classList: { add() {}, remove() {}, toggle() {} },
  getAttribute: (a) => (a === 'data-edit-row' ? String(rows[0].id) : a === 'data-field' ? 'author' : null),
  parentNode: null
};
els.rows.fire('input', Object.assign(ev(), { target: t }));

// 3. focus it. blur() is the real thing: it dispatches a blur event that the
//    capture-phase listener on #rows sees, exactly as the DOM would.
t.blur = function () {
  document.activeElement = null;
  els.rows.fire('blur', Object.assign(ev(), { target: t }));
};
document.activeElement = t;

// 4. click.
els[clickId].fire('mousedown', ev());
process.stdout.write(JSON.stringify({ value: t.value, posted: posted }));
JS
    PANEL_HTML="$PANEL_HTML" node "$RIP_SANDBOX/panel-click.js" "$@"
  }

  CLICK_ROW='[{"id":"1","path":"A/B","title":"B","authors":["A"],"narrators":[]}]'

  It 'panel: clicking Start Rip commits the author field, so the CANONICAL form is what gets posted'
    Skip if 'node is unavailable' no_node
    When call panel_click_commit "$CLICK_ROW" 'J.K. Rowling' btnStart
    The status should equal 0
    # The field itself was committed…
    The output should include '"value":"J. K. Rowling"'
    # …and — the fact that actually matters — the POSTED plan carries the
    # canonical spelling in the composed path. "J.K. Rowling" is not a
    # substring of "J. K. Rowling", so neither assertion can pass on an echo
    # of the raw input.
    The output should include '"action":"start"'
    The output should include '"path":"J. K. Rowling/B"'
    The output should not include '"path":"J.K. Rowling/B"'
  End

  # Same shape, same suppression: the chips preventDefault too, and every one
  # of them re-renders — which DESTROYS the field being edited without ever
  # blurring it, losing the normalisation just as silently as Start did.
  It 'panel: clicking a chip commits the author field before it re-renders'
    Skip if 'node is unavailable' no_node
    When call panel_click_commit "$CLICK_ROW" 'J.R.R. Tolkien' chipBrowse
    The status should equal 0
    The output should include '"value":"J. R. R. Tolkien"'
    The output should include '"action":"browse"'
  End

  It 'panel: clicking Not now commits the author field too — one rule, no exception to remember'
    Skip if 'node is unavailable' no_node
    When call panel_click_commit "$CLICK_ROW" 'e.e. cummings' btnDismiss
    The status should equal 0
    The output should include '"value":"e. e. cummings"'
    The output should include '"action":"dismiss"'
  End

  # --- author normalisation AT BUILD TIME (2026-08-26 followup) ------------
  #
  # authorDisplay() above only ran on blur, so a row the operator never
  # clicked into kept the provider's raw spelling all the way into
  # isStored's `SERVER.has(r.path)` compare. Cantina's sweep renamed a whole
  # shelf from "J.K. Rowling" to "J. K. Rowling"; rip-provider-folder still
  # derives "J.K. Rowling" from the file's own tags, composes
  # <Author>/<Title> from that raw spelling, and the panel never touched an
  # untouched row — so a book already on cantina rendered as rippable.
  # normalizeRow now runs authorDisplay on every author the moment the row
  # is built (library-dialog.lua's setRows/setLibrary/boot payload), not
  # only on blur.
  #
  # These rows deliberately mirror the provider's OWN composition rule
  # (path = authors[0] + "/" + title in files mode — rip-provider-folder's
  # cmd_list, restated in applyEdit's comment above) so an untouched row's
  # `path` starts life already agreeing with what normalizeRow should now
  # produce once the fix lands.
  BUILD_ROW='[{"id":"1","path":"J.K. Rowling/Harry Potter and the Sorcerers Stone","title":"Harry Potter and the Sorcerers Stone","authors":["J.K. Rowling"],"narrators":[]}]'

  It 'panel: an unedited files-mode row already composes the canonical author into its path'
    Skip if 'node is unavailable' no_node
    When call panel_files "$BUILD_ROW"
    The status should equal 0
    # the posted plan — what actually reaches rip::ab_worker...
    The output should include '"path":"J. K. Rowling/Harry Potter and the Sorcerers Stone"'
    The output should include '"authors":["J. K. Rowling"]'
    # ...and the rendered field the operator would see, seeded already
    # canonical rather than waiting for a blur that may never happen.
    The output should include 'value="J. K. Rowling"'
    The output should not include '"path":"J.K. Rowling/Harry Potter and the Sorcerers Stone"'
    The output should not include 'value="J.K. Rowling"'
  End

  # THE POINT OF THE CHANGE: with the composed path now canonical, isStored's
  # raw SERVER.has(r.path) compare actually matches the server's renamed
  # shelf, so the row is blocked with no edit at all. 'show' is load-bearing
  # (visible() filters a stored row out of the markup entirely with the chip
  # off), and the negative "should not include action:start" is what a
  # pre-fix panel — which selects and starts this row happily — fails on.
  It 'panel: that row is blocked once the server holds the canonical path'
    Skip if 'node is unavailable' no_node
    When call panel_files "$BUILD_ROW" '[]' '["J. K. Rowling/Harry Potter and the Sorcerers Stone"]' '' 'folder' 'show'
    The status should equal 0
    The output should include 'data-blocked="true"'
    The output should include 'already on cantina as J. K. Rowling/Harry Potter and the Sorcerers Stone'
    The output should not include '"action":"start"'
  End

  # LIBRARY mode must NOT recompose `path` from authors[0] + title —
  # applyEdit's own rule (comment above it, 2026-08-26 review finding): a
  # libation row's `path` carries a subtitle `title` does not, so
  # recomposing from the fields drops it. The author co-occurring here needs
  # normalising (forcing this example RED before the fix, since pre-fix
  # nothing normalises it at all) while the composed path — subtitle and
  # raw author spelling both — must survive completely untouched.
  LIBRARY_ROW_BUILD='[{"id":"1","path":"J.K. Rowling/Deathly Hallows: The Final Battle","title":"Deathly Hallows","subtitle":"The Final Battle","authors":["J.K. Rowling"],"narrators":[]}]'

  It 'panel: a library row with a subtitle keeps its exact composed path, even though its author display normalises'
    Skip if 'node is unavailable' no_node
    When call panel_files "$LIBRARY_ROW_BUILD" '[]' '' '' 'library'
    The status should equal 0
    # unchanged: raw author spelling, subtitle intact, not recomposed from
    # authors[0] + title (which would drop the subtitle).
    The output should include '"path":"J.K. Rowling/Deathly Hallows: The Final Battle"'
    The output should not include '"path":"J. K. Rowling/Deathly Hallows: The Final Battle"'
    The output should not include '"path":"J.K. Rowling/Deathly Hallows"'
    # ...yet the byline the operator reads shows the canonical form.
    The output should include "J. K. Rowling"
  End

  # THE NEGATIVES a greedy build-time rule would mangle — paired with a
  # co-author that DOES need normalising, so the example is genuinely RED
  # before the fix (nothing normalises the second author pre-fix either) and
  # not a vacuous pass. Files mode composes `path` from authors[0] ALONE
  # (applyEdit's rule), so "Dr.Smith" sitting first must leave the path
  # byte-for-byte unchanged while the co-author still canonicalises in the
  # posted authors array.
  DRSMITH_ROW='[{"id":"1","path":"Dr.Smith/Two Voices","title":"Two Voices","authors":["Dr.Smith","J.K. Rowling"],"narrators":[]}]'

  It 'panel: Dr.Smith (two letters before the period, not an initial) stays untouched in the composed path at build time'
    Skip if 'node is unavailable' no_node
    When call panel_files "$DRSMITH_ROW"
    The status should equal 0
    The output should include '"path":"Dr.Smith/Two Voices"'
    The output should include '"authors":["Dr.Smith","J. K. Rowling"]'
    The output should not include '"path":"Dr. Smith/Two Voices"'
  End

  STMARTIN_ROW='[{"id":"1","path":"St. Martin/Two Voices","title":"Two Voices","authors":["St. Martin","J.K. Rowling"],"narrators":[]}]'

  It 'panel: St. Martin (already spaced) stays untouched in the composed path at build time'
    Skip if 'node is unavailable' no_node
    When call panel_files "$STMARTIN_ROW"
    The status should equal 0
    The output should include '"path":"St. Martin/Two Voices"'
    The output should include '"authors":["St. Martin","J. K. Rowling"]'
    The output should not include '"path":"St.  Martin/Two Voices"'
  End

  # --- library-dialog.lua under a stubbed hs (review round 3) --------------
  #
  # WHY THIS EXISTS. 344 green examples could not see a one-line Lua type
  # error, because nothing in this suite executed library-dialog.lua at all —
  # the node examples above run the PANEL's JavaScript, and the shell
  # examples run the CLI, but the module that bridges them was untested by
  # construction. The bug that got through: M.setRows tagged its delivery
  # with json_for_script(kind) on a BARE STRING. hs.json.encode requires a
  # table (LS_TTABLE) and raises on anything else, so the call aborted the
  # hs.task completion callback before evaluateJavaScript ever ran — and
  # since only a row delivery clears LOADING, the panel sat on
  # "loading library…" forever. Exactly the regression 1845a71b fixed,
  # through a different door.
  #
  # So the stub's encode() REFUSES a non-table, mirroring LS_TTABLE. That
  # refusal is the whole point: soften it and this harness goes blind to the
  # only class of bug it exists to catch.
  no_lua() { ! command -v lua >/dev/null 2>&1; }

  # panel_lua <verb> [arg] — drive one library-dialog setter and print every
  # string it handed to webview:evaluateJavaScript.
  panel_lua() {
    cat > "$RIP_SANDBOX/dialog.lua" <<'LUA'
local HS_DIR = os.getenv("HS_DIR")

-- hs.json.encode is NSJSONSerialization dataWithJSONObject:, which escapes
-- backslash, double quote, the control characters AND the forward slash
-- (`\/`) — see modules/ripper/session-dialog.lua's json_for_script, whose
-- whole rationale rests on that last one. A stub that emitted a bare
-- '"' .. v .. '"' would make every escaping assertion in this file pass
-- against the STUB rather than against the bridge, which is precisely the
-- self-validating failure this harness exists to prevent.
local ESC = {
  ['"'] = '\\"', ['\\'] = '\\\\', ['/'] = '\\/',
  ['\b'] = '\\b', ['\f'] = '\\f', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t',
}
local function encstr(v)
  local out = v:gsub('[%c"\\/]', function(c)
    return ESC[c] or string.format('\\u%04x', c:byte())
  end)
  return '"' .. out .. '"'
end

local function encode(v)
  -- hs.json.encode requires LS_TTABLE. Mirrored exactly.
  if type(v) ~= "table" then
    error("ERROR: incorrect type '" .. type(v) .. "' for argument (expected table)", 2)
  end
  local isArray, n = true, 0
  for k in pairs(v) do
    n = n + 1
    if type(k) ~= "number" then isArray = false end
  end
  if n == 0 then return "{}" end
  local parts = {}
  if isArray then
    for _, item in ipairs(v) do parts[#parts + 1] = encode(item) end
    return "[" .. table.concat(parts, ",") .. "]"
  end
  local keys = {}
  for k in pairs(v) do keys[#keys + 1] = tostring(k) end
  table.sort(keys)
  for _, k in ipairs(keys) do
    local val, enc = v[k], nil
    if type(val) == "table" then enc = encode(val)
    elseif type(val) == "string" then enc = encstr(val)
    else enc = tostring(val) end
    parts[#parts + 1] = encstr(k) .. ":" .. enc
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

local JS = {}
local webviewStub = setmetatable({}, { __index = function(_, key)
  return function(_, a)
    if key == "evaluateJavaScript" then JS[#JS + 1] = a end
    return nil
  end
end })

hs = {
  configdir = HS_DIR,
  json = { encode = encode },
  base64 = { encode = function() return "BASE64" end },
  printf = function() end,
  drawing = { windowLevels = { modalPanel = 1 } },
  window = { focusedWindow = function() return nil end },
  screen = { mainScreen = function()
    return { fullFrame = function() return { x = 0, y = 0, w = 1440, h = 900 } end }
  end },
  webview = {
    usercontent = { new = function() return { setCallback = function() end } end },
    new = function() return webviewStub end,
  },
}

package.preload["system.dismiss-on-blur"] = function()
  return { dismissOthers = function() end, dismissingViaSwitcher = false }
end

local M = dofile(HS_DIR .. "/modules/ripper/library-dialog.lua")

-- Every setter is a no-op until the panel is actually open.
M.show({ rows = {}, loading = true })
local verb, a = arg[1], arg[2]
if verb == "setRows" then
  M.setRows({}, a)
elseif verb == "setSource" then
  M.setSource(a, arg[3])
elseif verb == "sourceFailed" then
  M.sourceFailed()
end
for _, js in ipairs(JS) do print(js) end
LUA
    HS_DIR="$SHELLSPEC_PROJECT_ROOT/home/dot_config/hammerspoon" lua "$RIP_SANDBOX/dialog.lua" "$@"
  }

  It 'dialog: setRows tags the delivery without tripping hs.json.encode'
    Skip if 'lua is unavailable' no_lua
    When call panel_lua setRows library
    The status should equal 0
    The output should include 'window.__setRows({}, "library")'
  End

  It 'dialog: the folder tag survives the same path'
    Skip if 'lua is unavailable' no_lua
    When call panel_lua setRows folder
    The status should equal 0
    The output should include 'window.__setRows({}, "folder")'
  End

  # An untagged delivery is the preview harness, which has no source opinion.
  # It must emit ONE argument, not a bogus tag and not an error.
  It 'dialog: an untagged setRows emits no second argument'
    Skip if 'lua is unavailable' no_lua
    When call panel_lua setRows
    The status should equal 0
    The output should include 'window.__setRows({})'
  End

  # The other two evaluateJavaScript emitters this round added, equally
  # invisible to the node examples.
  It 'dialog: setSource crosses the bridge with kind and root'
    Skip if 'lua is unavailable' no_lua
    When call panel_lua setSource folder /Volumes/Media/Incoming
    The status should equal 0
    The output should include '"kind":"folder"'
    # The LIVE form. hs.json.encode is NSJSONSerialization, which escapes the
    # forward slash — asserting the bare path would have passed only under a
    # stub that did not, i.e. it would have validated the stub.
    The output should include '"root":"\/Volumes\/Media\/Incoming"'
  End

  # The property json_for_script EXISTS for, pinned end to end. A root is
  # operator-supplied and reaches an HTML <script> element, so it is exactly
  # as attacker-adjacent as a book title: the JSON encoder handles the
  # quote, the backslash and the slash, and json_for_script's own gsub turns
  # '<' into \u003C so '<script' cannot switch WebKit's tokenizer into the
  # double-escaped state and swallow the element's real closing tag
  # (session-dialog.lua documents that failure at length).
  It 'dialog: a hostile root is escaped on the way across the bridge'
    Skip if 'lua is unavailable' no_lua
    When call panel_lua setSource folder '/inc/a"b\c<script>'
    The status should equal 0
    The output should include '\/inc\/a'
    The output should include '\"b'
    The output should include '\\c'
    The output should include '\u003Cscript'
    # The raw sequence must not survive anywhere in the emitted JS.
    The output should not include '<script>'
  End

  It 'dialog: sourceFailed calls the restore entry point'
    Skip if 'lua is unavailable' no_lua
    When call panel_lua sourceFailed
    The status should equal 0
    The output should include 'window.__sourceFailed()'
  End

  # --- review round 2: the four findings ----------------------------------

  # FINDING 1. Switching source does not un-ask a fetch already walking a
  # large tree. The two row-producing fetches are separately anchored, and an
  # anchor's identity guard only ever defends it against its OWN successor —
  # never against the other source's answer arriving after the switch. Lua
  # now terminates the outgoing fetch, but terminate() is only SIGTERM: a
  # fetch that already finished writing still delivers rc = 0. The delivery
  # TAG is the half that cannot race, and it is the half testable here.
  #
  # panel_late_delivery <switch1-json> <switch2-json> <rows-json> [tag]
  #   Switches source twice, then delivers rows tagged for the FIRST source —
  #   exactly the late reply. Prints #rows + #source innerHTML.
  panel_late_delivery() {
    cat > "$RIP_SANDBOX/panel-late.js" <<'JS'
const fs = require('fs');
const html = fs.readFileSync(process.env.PANEL_HTML, 'utf8');
const src = html.split('<script>')[2].split('</script>')[0]
                .replace('%%LIBRARY_JSON%%', 'null');
const els = {};
function stub(id) {
  return { id: id, innerHTML: '', textContent: '', value: '',
           classList: { add() {}, remove() {}, toggle() {} },
           addEventListener() {}, setAttribute() {},
           getAttribute() { return null; }, setSelectionRange() {} };
}
global.document = {
  getElementById(id) { return els[id] || (els[id] = stub(id)); },
  addEventListener() {}, querySelector() { return null; }
};
global.window = global;
(0, eval)(src);
window.__setSource(JSON.parse(process.argv[2]));
window.__setSource(JSON.parse(process.argv[3]));
window.__setRows(JSON.parse(process.argv[4]), process.argv[5]);
process.stdout.write(els.rows.innerHTML + '' + els.source.innerHTML);
JS
    PANEL_HTML="$PANEL_HTML" node "$RIP_SANDBOX/panel-late.js" "$@"
  }

  AUDIBLE_ROW='[{"id":"B00ECDZ08I","path":"Brandon Sanderson/Steelheart","title":"Steelheart","authors":["Brandon Sanderson"],"narrators":[],"ids":{"audible.asin":"B00ECDZ08I"}}]'

  It 'panel: a late browse delivery is dropped after the switch back to the library'
    Skip if 'node is unavailable' no_node
    When call panel_late_delivery '{"kind":"folder","root":"/inc"}' '{"kind":"library"}' "$FOLDER_ROW" folder
    The status should equal 0
    The output should not include "Ancilary Justice"
  End

  # The mirror, and the worse one: Audible rows landing in files mode would
  # render real ASINs as editable identities and post them under provider
  # "folder", which rip::ab_worker hands to rip-provider-folder as a source
  # DIRECTORY.
  It 'panel: a late library delivery is dropped after the switch to a folder'
    Skip if 'node is unavailable' no_node
    When call panel_late_delivery '{"kind":"library"}' '{"kind":"folder","root":"/inc"}' "$AUDIBLE_ROW" library
    The status should equal 0
    The output should not include "Steelheart"
  End

  # Positive control: the tag must not be swallowing everything. A delivery
  # for the source ACTUALLY on screen still renders.
  It 'panel: a delivery tagged for the current source still lands'
    Skip if 'node is unavailable' no_node
    When call panel_late_delivery '{"kind":"library"}' '{"kind":"folder","root":"/inc"}' "$FOLDER_ROW" folder
    The status should equal 0
    The output should include "Ancilary Justice"
  End

  # FINDING 2, the un-edited case. The folder provider emits a single-segment
  # path for EVERY derived_from:"filename" row — a flat tree of loose .m4b
  # files, which is exactly what browse mode exists to import — and
  # rip::_validate_ab_plan aborts the whole plan on the first one.
  FLAT_ROW='[{"id":"/inc/Network Effect","path":"Network Effect","title":"Network Effect","authors":[],"narrators":[],"derived_from":"filename"}]'

  It 'panel: an author-less row is never posted, even with no edit at all'
    Skip if 'node is unavailable' no_node
    When call panel_files "$FLAT_ROW"
    The status should equal 0
    The output should not include '"action":"start"'
  End

  It 'panel: an author-less row says so before it is selected'
    Skip if 'node is unavailable' no_node
    When call panel_files "$FLAT_ROW"
    The status should equal 0
    The output should include 'data-blocked="true"'
    The output should include 'edit-author invalid'
  End

  It 'panel: supplying the missing author unblocks the row'
    Skip if 'node is unavailable' no_node
    When call panel_files "$FLAT_ROW" '[["/inc/Network Effect","author","Martha Wells"]]'
    The status should equal 0
    The output should include '"path":"Martha Wells/Network Effect"'
    # The block has to LIFT, not just the post go through: an edited row that
    # still rendered as blocked would leave the operator staring at a warning
    # they had already answered.
    The output should include 'data-blocked="false"'
  End

  # A blocked row must not take its healthy neighbours down with it — that is
  # the entire difference between a per-row block and _validate_ab_plan's
  # whole-session refusal.
  It 'panel: a blocked row does not stop its valid neighbour from shipping'
    Skip if 'node is unavailable' no_node
    When call panel_files '[{"id":"1","path":"Network Effect","title":"Network Effect","authors":[],"narrators":[],"derived_from":"filename"},{"id":"2","path":"Martha Wells/Fugitive Telemetry","title":"Fugitive Telemetry","authors":["Martha Wells"],"narrators":[],"derived_from":"tags"}]'
    The status should equal 0
    The output should include '"path":"Martha Wells/Fugitive Telemetry"'
    The output should not include '"path":"Network Effect"'
  End

  # FINDING 3. PROVIDER is read from the payload and only __setLibrary ever
  # rewrites it, so a COLD browse seeding provider:"folder" left the way back
  # posting Audible rows under the folder provider. Task 8's Quick Action is
  # the cold-browse entry point that arms this.
  panel_cold_browse_back() {
    cat > "$RIP_SANDBOX/panel-cold.js" <<'JS'
const fs = require('fs');
const html = fs.readFileSync(process.env.PANEL_HTML, 'utf8');
const src = html.split('<script>')[2].split('</script>')[0]
                .replace('%%LIBRARY_JSON%%', process.argv[2]);
const els = {};
function stub(id) {
  const listeners = {};
  const el = {
    id: id, innerHTML: '', textContent: '', value: '',
    classList: { add() {}, remove() {}, toggle() {} },
    addEventListener(type, fn) { (listeners[type] = listeners[type] || []).push(fn); },
    setAttribute() {}, getAttribute() { return null; }, setSelectionRange() {},
    fire(type, ev) { (listeners[type] || []).forEach((f) => f.call(el, ev)); }
  };
  return el;
}
global.document = {
  getElementById(id) { return els[id] || (els[id] = stub(id)); },
  addEventListener() {}, querySelector() { return null; }
};
const POSTED = [];
global.window = global;
global.webkit = { messageHandlers: { ripLibrary: { postMessage(m) { POSTED.push(m); } } } };
(0, eval)(src);
const ev = () => ({ preventDefault() {} });
const rows = JSON.parse(process.argv[3]);
window.__setSource({ kind: 'library' });
window.__setRows(rows, 'library');
for (const r of rows) {
  els.rows.fire('mousedown', Object.assign(ev(), {
    target: { getAttribute: (a) => (a === 'data-toggle' ? String(r.id) : null), parentNode: null }
  }));
}
els.btnStart.fire('mousedown', ev());
process.stdout.write(JSON.stringify(POSTED));
JS
    PANEL_HTML="$PANEL_HTML" node "$RIP_SANDBOX/panel-cold.js" "$@"
  }

  It 'panel: a cold browse then back to the library posts the catalogue provider'
    Skip if 'node is unavailable' no_node
    When call panel_cold_browse_back '{"loading":true,"rows":[],"provider":"folder","source":{"kind":"folder","root":"/inc"}}' "$AUDIBLE_ROW"
    The status should equal 0
    The output should include '"provider":"libation"'
    The output should not include '"provider":"folder"'
  End

  # FINDING 4. The way back loses just as much as a browse does: 400 browsed
  # books and 40 marks against one mid-update LibationCli. PREV_SOURCE holds
  # them; the failure path has to call the restore.
  panel_way_back_failed() {
    cat > "$RIP_SANDBOX/panel-wayback.js" <<'JS'
const fs = require('fs');
const html = fs.readFileSync(process.env.PANEL_HTML, 'utf8');
const src = html.split('<script>')[2].split('</script>')[0]
                .replace('%%LIBRARY_JSON%%', 'null');
const els = {};
function stub(id) {
  const listeners = {};
  const el = {
    id: id, innerHTML: '', textContent: '', value: '',
    classList: { add() {}, remove() {}, toggle() {} },
    addEventListener(type, fn) { (listeners[type] = listeners[type] || []).push(fn); },
    setAttribute() {}, getAttribute() { return null; }, setSelectionRange() {},
    fire(type, ev) { (listeners[type] || []).forEach((f) => f.call(el, ev)); }
  };
  return el;
}
global.document = {
  getElementById(id) { return els[id] || (els[id] = stub(id)); },
  addEventListener() {}, querySelector() { return null; }
};
global.window = global;
(0, eval)(src);
const rows = JSON.parse(process.argv[2]);
window.__setSource({ kind: 'folder', root: '/inc' });
window.__setRows(rows, 'folder');
// Mark one, then take the way back and have its fetch fail.
els.rows.fire('mousedown', {
  preventDefault() {},
  target: { getAttribute: (a) => (a === 'data-toggle' ? String(rows[0].id) : null), parentNode: null }
});
window.__setSource({ kind: 'library' });
window.__sourceFailed();
process.stdout.write(els.rows.innerHTML + '' + els.source.innerHTML + '' + els.summary.innerHTML);
JS
    PANEL_HTML="$PANEL_HTML" node "$RIP_SANDBOX/panel-wayback.js" "$@"
  }

  It 'panel: a failed way-back restores the browsed rows AND the marks on them'
    Skip if 'node is unavailable' no_node
    When call panel_way_back_failed "$FOLDER_ROW"
    The status should equal 0
    The output should include "Ancilary Justice"
    The output should include "/inc"
    The output should include "1 book"
    The output should not include "nothing to show"
  End

  # FINDING 2 (round 3). pathValid is PER-PATH; rip::_validate_ab_plan also
  # refuses the WHOLE plan when two items compose the same <Author>/<Title>.
  # Reachable with no editing at all: rip-provider-folder keys a row by
  # DIRECTORY but composes `path` from the embedded tags first, so a
  # re-download under another folder, a second format, or a backup copy
  # yields two rows with distinct ids and one identical path. Both look
  # perfectly valid on their own — and the plan they compose kills every
  # other selected book with them, after the panel has closed.
  DUPES='[{"id":"/inc/2023/Network Effect","path":"Martha Wells/Network Effect","title":"Network Effect","authors":["Martha Wells"],"narrators":[],"derived_from":"tags"},{"id":"/inc/2024/Network Effect","path":"Martha Wells/Network Effect","title":"Network Effect","authors":["Martha Wells"],"narrators":[],"derived_from":"tags"},{"id":"/inc/Fugitive","path":"Martha Wells/Fugitive Telemetry","title":"Fugitive Telemetry","authors":["Martha Wells"],"narrators":[],"derived_from":"tags"}]'

  It 'panel: two rows composing one path are never both posted'
    Skip if 'node is unavailable' no_node
    When call panel_files "$DUPES"
    The status should equal 0
    # jq -c over the posted plan: exactly one item may carry that path.
    The output should include '"id":"/inc/2023/Network Effect"'
    The output should not include '"id":"/inc/2024/Network Effect"'
  End

  # The whole point of a per-row block: the distinct third book still ships,
  # and the footer counts what is actually going rather than what is ticked.
  It 'panel: a duplicate pair does not take the rest of the selection with it'
    Skip if 'node is unavailable' no_node
    When call panel_files "$DUPES"
    The status should equal 0
    The output should include '"path":"Martha Wells/Fugitive Telemetry"'
    The output should include '2 books'
    The output should include '1 duplicate of a book already selected'
  End

  # Silently dropping one copy would be its own defect — the operator has to
  # see WHICH copy was excluded, and on what grounds.
  It 'panel: the excluded duplicate says which book it collides with'
    Skip if 'node is unavailable' no_node
    When call panel_files "$DUPES"
    The status should equal 0
    The output should include "already stages as"
    The output should include 'data-blocked="true"'
  End

  # Provider-agnostic: two Audible rows can compose one path too (a
  # re-release under the same author and title), and the server rule does
  # not care which provider produced them.
  It 'panel: the duplicate rule applies to library-mode rows as well'
    Skip if 'node is unavailable' no_node
    When call panel_files '[{"id":"A1","path":"Brandon Sanderson/Steelheart","title":"Steelheart","authors":["Brandon Sanderson"],"narrators":[]},{"id":"A2","path":"Brandon Sanderson/Steelheart","title":"Steelheart","authors":["Brandon Sanderson"],"narrators":[]}]' '[]' '' '' library
    The status should equal 0
    The output should include '"id":"A1"'
    The output should not include '"id":"A2"'
  End

  It 'panel: a files-mode row is never marked "liberated, never pushed"'
    Skip if 'node is unavailable' no_node
    When call panel_files "$FOLDER_ROW" '[]' '[]'
    The status should equal 0
    The output should not include "never pushed"
  End

  # --- rip::ab_backfill_work_uid ---------------------------------------------
  #
  # Mints `work.uid` for every stored book whose `work` is null, leaving
  # `edition: null` behind — the anchor of a work, not a named edition of one
  # (design doc S5). Mirrors rip::ab_backfill_published's shape (dry run by
  # default, --apply required, compose locally + ship base64-framed payloads
  # because cantina has no jq) — reuses that section's mkbook_empty,
  # sidecar_at, fake_server_ssh and ssh_calls helpers, already defined above.
  #
  # This writes to the only copy of a book's identity on 248 real sidecars —
  # the byte-identity and distinct-uid guards below are the ones that matter
  # most: a book that already anchors a work must never be re-serialized, and
  # a loop that mints once and reuses the value would silently merge the
  # whole library into one "work".

  bwu_sha() { shasum -a 256 "$(sidecar_at "$1")" | cut -d' ' -f1; }
  bwu_uid_at() { jq -r '.work.uid // ""' "$(sidecar_at "$1")"; }
  bwu_uid_ok() {
    bwu_uid_at "$1" | grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' \
      && echo "uuidv4" || echo "NOT A UUIDV4"
  }
  # "The result of function NAME" invokes NAME with no meaningful args (the
  # prior When's stdout/stderr/status land in $1-$3, unused here) — these
  # zero-arg wrappers close over a fixed path the way rpo_uid_ok closes over
  # $RPO above.
  bwu_uid_ok_ab() { bwu_uid_ok "A/B"; }
  bwu_ab_sha() { bwu_sha "A/B"; }
  bwu_already_sha() { bwu_sha "A/Already"; }
  bwu_two_uids_distinct() {
    u1=$(bwu_uid_at "A/One"); u2=$(bwu_uid_at "A/Two")
    if [ -n "$u1" ] && [ -n "$u2" ] && [ "$u1" != "$u2" ]; then
      echo "distinct"
    else
      echo "u1=$u1 u2=$u2"
    fi
  }
  # bwu_tree_digest — one hash covering every stored file's PATH and CONTENT,
  # so "the dry run writes nothing at all" is proved against the whole server
  # tree, not just the one sidecar an example happens to name (mission brief:
  # "prove it by comparing the whole sandbox server tree before and after,
  # not by trusting the absence of a log line").
  bwu_tree_digest() {
    ( cd "$RIP_SANDBOX/server" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do
        printf '%s\n' "$f"
        shasum -a 256 "$f" | cut -d' ' -f1
      done ) | shasum -a 256 | cut -d' ' -f1
  }

  It 'backfill-work-uid: dry-run names the candidate and writes nothing at all'
    mkbook_empty "A/B" libation
    before=$(bwu_tree_digest)
    When run zsh -c "source $RIPLIB && rip::ab_backfill_work_uid"
    The status should equal 0
    The output should include "would assign a work uid: A/B"
    The output should include "re-run with --apply"
    The result of function bwu_tree_digest should equal "$before"
  End

  It 'backfill-work-uid: --apply mints a uuidv4 and leaves edition null'
    mkbook_empty "A/B" libation
    When run zsh -c "source $RIPLIB && rip::ab_backfill_work_uid --apply"
    The status should equal 0
    The output should include "backfilled 1 of 1 sidecar(s)"
    The result of function bwu_uid_ok_ab should equal "uuidv4"
  End

  # Review finding, 2026-08-26. `done < <(rip::_server_sidecars)` discarded
  # the enumerator's status, so an unreachable cantina yielded zero rows,
  # printed "nothing to backfill" and exited 0 — `--backfill-work-uid --apply
  # && echo done` said "done" on a dropped VPN. It matters more for THIS sweep
  # than any other: running it is what makes the rip path read-only, so a
  # falsely complete run leaves the write-into-another-book's-sidecar path
  # armed with nobody aware. Mirrors the repair-companions example above.
  It 'backfill-work-uid: an unreachable server refuses and never says "nothing to backfill"'
    mkbook_empty "A/B" libation
    fake_server_ssh
    printf '#!/bin/sh\nexit 255\n' > "$RIP_SANDBOX/ssh"
    chmod +x "$RIP_SANDBOX/ssh"
    before=$(bwu_sha "A/B")
    When run zsh -c "source $RIPLIB && rip::ab_backfill_work_uid --apply"
    The status should equal 2
    The output should not include "nothing to backfill"
    The output should not include "backfilled"
    The result of function bwu_ab_sha should equal "$before"
  End

  It 'backfill-work-uid: a book that already carries a work object is untouched byte-for-byte'
    # Deliberately irregular formatting (extra spaces, a pre-existing edition
    # label) — a rewrite that merely re-serializes to the SAME parsed value
    # would still fail this, because the check is on the raw bytes.
    #
    # A CANDIDATE MUST BE PRESENT TOO (review finding, 2026-08-26). With only
    # the anchored book staged, `to_fill` comes back empty and the function
    # returns before the compose-and-ship loop ever runs — so the sha only
    # guarded the CLASSIFIER, and the write path went unexercised. Nothing in
    # the suite ran --apply over a library holding both kinds, which is the
    # only shape the operator's library actually has. Proved by mutation:
    # making the apply loop iterate every enumerated row instead of the
    # candidates left all eight examples green while this book's uid and
    # edition were destroyed and it printed "backfilled 2 of 1".
    ALREADY='{"schema":1,   "kind":"audiobook","title":"Already","authors":["A"],"ids":{},"work":{"uid":"11111111-1111-4111-8111-111111111111","edition":"Full Cast"},"source":{"provider":"libation"}}'
    mkdir -p "$RIP_SANDBOX/server/audiobooks/A/Already"
    printf '%s' "$ALREADY" > "$(sidecar_at "A/Already")"
    mkbook_empty "A/B" libation
    before=$(bwu_sha "A/Already")
    When run zsh -c "source $RIPLIB && rip::ab_backfill_work_uid --apply"
    The status should equal 0
    The output should include "backfilled 1 of 1"
    The result of function bwu_already_sha should equal "$before"
  End

  It 'backfill-work-uid: two candidate books mint two DIFFERENT uids'
    mkbook_empty "A/One" libation
    mkbook_empty "A/Two" libation
    When run zsh -c "source $RIPLIB && rip::ab_backfill_work_uid --apply"
    The status should equal 0
    The output should include "backfilled 2 of 2 sidecar(s)"
    The result of function bwu_two_uids_distinct should equal "distinct"
  End

  It 'backfill-work-uid: an enumerator that returns nothing is distinguished from a satisfied library'
    # No mkbook_empty call at all — nothing staged in $RIP_SANDBOX/server,
    # the same "seen==0" wording rip::ab_backfill_published uses so an
    # unreachable server is never conflated with a genuinely empty sweep.
    When run zsh -c "source $RIPLIB && rip::ab_backfill_work_uid"
    The status should equal 0
    The output should include "no sidecars found on the server"
    The output should include "cantina reachable"
  End

  It 'backfill-work-uid: --apply writes through a server with NO jq, in ONE ssh for the whole batch'
    mkbook_empty "A/B" libation
    mkbook_empty "C/D" libation
    fake_server_ssh
    When run zsh -c "source $RIPLIB && rip::ab_backfill_work_uid --apply"
    The status should equal 0
    The output should include "backfilled 2 of 2 sidecar(s)"
    # ONE ssh to enumerate, ONE for the whole write batch — not one per book.
    The result of function ssh_calls should equal "2"
    The result of function ssh_cmds should not include "jq"
  End

  It 'backfill-work-uid: a write that fails leaves the good sidecar untouched and reports the book failed'
    mkbook_empty "A/B" libation
    fake_server_ssh
    When run zsh -c "source $RIPLIB
      chmod 555 '$RIP_SANDBOX/server/audiobooks/A/B'
      rip::ab_backfill_work_uid --apply; rc=\$?
      chmod 755 '$RIP_SANDBOX/server/audiobooks/A/B'
      exit \$rc"
    The status should equal 1
    The output should include "backfilled 0 of 1 sidecar(s)"
    The output should include "1 sidecar(s) could not be written"
    The stderr should include "could not backfill A/B"
    The contents of file "$RIP_SANDBOX/server/audiobooks/A/B/.fleet-book.json" should include '"work": null'
    The result of function stray_tmp_files should equal "0"
  End

  It 'backfill-work-uid: a dry run against the ssh branch writes nothing and opens no write connection'
    mkbook_empty "A/B" libation
    fake_server_ssh
    When run zsh -c "source $RIPLIB && rip::ab_backfill_work_uid"
    The status should equal 0
    The output should include "re-run with --apply"
    The contents of file "$RIP_SANDBOX/server/audiobooks/A/B/.fleet-book.json" should include '"work": null'
    The result of function ssh_calls should equal "1"
  End

  # --- rip::_remote_sidecar_json (the work-uid read path) --------------------
  #
  # ONE book's stored sidecar, in ONE ssh, through a server with no jq — the
  # read rip::ab_worker makes per edition item, inside its acquire loop.
  # rip::_server_sidecars ships the WHOLE library (~124 KB for 248 books) and
  # is the wrong tool for a single lookup.

  rsj_ssh_cmds() { cat "$RIP_SANDBOX/ssh.cmds" 2>/dev/null; }

  # fake_server_ssh_logs_stdin — fake_server_ssh that also KEEPS what was fed
  # to the remote on stdin. rip::_sidecars_write ships the relpath inside a
  # base64 payload on stdin, so it never appears in ssh.cmds — and on APFS,
  # which is normalization-INSENSITIVE, an NFD relpath still opens the NFC
  # directory, so the file that lands proves nothing either. The bytes on the
  # wire are the only place the divergence is observable, which is why this
  # variant exists. -n is honoured exactly as ssh honours it, so the read
  # (which passes -n) contributes nothing here and the single logged payload
  # is the write.
  fake_server_ssh_logs_stdin() {
    fake_server_ssh || return 1
    local dash_bin
    dash_bin=$(command -v dash 2>/dev/null || true)
    cat > "$RIP_SANDBOX/ssh" <<EOF
#!/bin/sh
echo 1 >> "$RIP_SANDBOX/ssh.count"
cmd=""
noinput=0
for a in "\$@"; do
  [ "\$a" = "-n" ] && noinput=1
  cmd="\$a"
done
printf '%s\n' "\$cmd" >> "$RIP_SANDBOX/ssh.cmds"
PATH="$RIP_SANDBOX/remotebin"; export PATH
if [ "\$noinput" = 1 ]; then
  exec "$dash_bin" -c "\$cmd" < /dev/null
fi
cat > "$RIP_SANDBOX/ssh.stdin"
exec "$dash_bin" -c "\$cmd" < "$RIP_SANDBOX/ssh.stdin"
EOF
    chmod +x "$RIP_SANDBOX/ssh"
  }

  # The base64 relpath the WRITE actually shipped — field 1 of the single
  # payload line rip::_sidecars_write fed to the remote.
  wire_rel_b64() { cut -f1 "$RIP_SANDBOX/ssh.stdin" 2>/dev/null | head -1; }

  # THE READ NORMALIZES; THE WRITE MUST TOO (review finding, 2026-08-26).
  # rip::_remote_sidecar_json NFC-normalizes before asking the server, but the
  # write-back runs through rip::_sidecar_payload, whose contract is that the
  # relpath it ships is the SERVER's own spelling. A folder-provider plan path
  # is composed from ffprobe tags and macOS directory names with no
  # normalization anywhere, so for a decomposed author the read used c3a9 (NFC
  # é) while the payload carried cc81 (NFD e + U+0301): two byte sequences for
  # one directory. On cantina the redirect lands nowhere, the operator sees
  # "could not record the shared work uid", the edition keeps a fresh uid, and
  # --backfill-work-uid later mints the base a DIFFERENT one — the permanent
  # split the minted-uid design exists to prevent.
  #
  # An ssh-branch example DELIBERATELY: the plain-local-dir branch runs on
  # APFS, where both spellings open the same file, so a local-dir test of this
  # would be a test that cannot fail.
  It 'work uid: the write-back ships the same relpath bytes the read asked for (NFC)'
    nfc_author=$(printf 'Saint-Exup\303\251ry')
    nfd_author=$(printf 'Saint-Exupe\314\201ry')
    mkdir -p "$RIP_SANDBOX/server/audiobooks/$nfc_author/Le Petit Prince"
    jq -n '{schema:1,kind:"audiobook",title:"Le Petit Prince",authors:["A"],ids:{},work:null}' \
      > "$RIP_SANDBOX/server/audiobooks/$nfc_author/Le Petit Prince/.fleet-book.json"
    fake_server_ssh_logs_stdin
    want_b64=$(printf '%s/Le Petit Prince' "$nfc_author" | jq -sRr '@base64')
    When run zsh -c "source $RIPLIB && rip::_ab_work_uid_for '$nfd_author/Le Petit Prince' >/dev/null"
    The status should equal 0
    # The read asked for the NFC spelling...
    The contents of file "$RIP_SANDBOX/ssh.cmds" should include "$nfc_author"
    # ...and the write shipped the very same bytes, not the plan's NFD ones.
    The result of function wire_rel_b64 should equal "$want_b64"
  End

  It 'remote sidecar: reads ONE stored sidecar over ssh, with no jq on the server'
    mkbook_empty "A/B" libation
    fake_server_ssh
    When run zsh -c "source $RIPLIB && rip::_remote_sidecar_json 'A/B' | jq -r '.title'"
    The status should equal 0
    The output should equal "B"
    The result of function ssh_calls should equal "1"
    The result of function ssh_cmds should not include "jq"
  End

  It 'remote sidecar: a book with no sidecar is confirmed ABSENT, not unknown'
    mkbook_bare "A/NoSidecar"
    fake_server_ssh
    When run zsh -c "source $RIPLIB && rip::_remote_sidecar_json 'A/NoSidecar'"
    The status should equal 1
    The output should equal ""
  End

  # -n IS LOAD-BEARING, the same fd-0 guard rip::_remote_test carries: without
  # it ssh(1) drains THIS shell's stdin and forwards it to the remote, whether
  # or not the remote command consumes it. The fake honours -n exactly as ssh
  # does, so the sentinel survives only when the probe passed it.
  It 'remote sidecar: the read passes ssh -n and does not eat the caller stdin'
    mkbook_empty "A/B" libation
    fake_server_ssh_reads_stdin
    printf 'sentinel\n' > "$RIP_SANDBOX/in.txt"
    When run zsh -c "source $RIPLIB
      { rip::_remote_sidecar_json 'A/B' >/dev/null; cat; } < $RIP_SANDBOX/in.txt"
    The status should equal 0
    The output should equal "sentinel"
  End

  # An unreachable server must be UNKNOWN (rc 2), never "absent": the caller's
  # only write path fires on "the base book exists and has no uid", and an
  # absent verdict on an unread server would turn an outage into a mint that
  # can never match what the base book already carries.
  It 'remote sidecar: an ssh that never connects is unknown, not absent'
    mkbook_empty "A/B" libation
    fake_server_ssh
    cat > "$RIP_SANDBOX/ssh" <<'EOF'
#!/bin/sh
exit 255
EOF
    chmod +x "$RIP_SANDBOX/ssh"
    When run zsh -c "source $RIPLIB && rip::_remote_sidecar_json 'A/B'"
    The status should equal 2
    The output should equal ""
  End

  # A sidecar that EXISTS but does not parse is unknown too, for the same
  # reason with more at stake: composing a replacement over a truncated file
  # destroys the only copy of that book's identity.
  It 'remote sidecar: a malformed stored sidecar is unknown, never treated as readable'
    mkbook_malformed "A/Broken"
    fake_server_ssh
    When run zsh -c "source $RIPLIB && rip::_remote_sidecar_json 'A/Broken'"
    The status should equal 2
    The output should equal ""
  End

  # --- rip::ab_retag — --retag, for the library that already exists (S4) -----
  #
  # The same invariant as the enrichment retag, read from the other end: a
  # book's tags say exactly what its PATH says. The enrichment writes that
  # into a staged copy on the way in; this sweeps the ~248 books that were
  # already on cantina before the feature existed and were never tagged at
  # all.
  #
  # cantina has ffmpeg and ffprobe (design doc S4, verified 2026-08-26), so
  # the remux happens THERE — nothing is fetched, rewritten and pushed back.
  # These examples exercise exactly that shape: the sweep ships a POSIX sh
  # script, the "server" runs it against real media, and every judgement about
  # whether the tags took is made locally from probe JSON the server returned.
  #
  # REAL MEDIA, not six-byte text files named *.m4b, for the same reason the
  # enrichment section uses real media: a remux is the thing under test, and a
  # fake ffmpeg that copies its input would let a sweep that writes nothing at
  # all pass every assertion below.

  # rtg_seed — the parts every book here is muxed from, built once per
  # example: a 1s aac stream, an attached cover picture, and a chapter.
  #
  # THE CHAPTER IS NOT DECORATION. An m4b's chapters live in a text track that
  # ffmpeg's mov demuxer exposes as a `bin_data` stream, and the ipod muxer
  # refuses to copy it ("Tag text incompatible with output codec id
  # \'98314\'", rc 183, unreadable output) — which is why the remux excludes
  # data streams and regenerates chapters. A fixture with no chapter cannot
  # tell a correct remux from one missing that exclusion: verified by
  # mutation, a fixture without one left the whole sweep green while
  # $_RIP_RETAG_FF_MAP was broken.
  rtg_seed() {
    ffmpeg -v error -y -f lavfi -t 1 -i 'anullsrc=r=8000:cl=mono' -c:a aac -b:a 8k \
      "$RIP_SANDBOX/rtg-a.m4a"
    ffmpeg -v error -y -f lavfi -i 'color=c=red:s=16x16:d=1' -frames:v 1 "$RIP_SANDBOX/rtg-cover.jpg"
    printf '%s\n' ';FFMETADATA1' '[CHAPTER]' 'TIMEBASE=1/1000' 'START=0' 'END=1000' \
      'title=Chapter One' > "$RIP_SANDBOX/rtg-chap.txt"
  }

  # rtg_sidecar <Author/Title> <provider> <ids-json>
  rtg_sidecar() {
    jq -n --arg t "${1##*/}" --arg a "${1%%/*}" --arg p "$2" --argjson i "$3" \
      '{schema:1,kind:"audiobook",title:$t,subtitle:null,authors:[$a],narrators:[],
        series:null,duration_s:null,language:null,abridged:null,published:null,
        ids:$i,work:null,
        source:{provider:$p,provider_version:null,acquired_utc:null,format:"m4b"}}' \
      > "$RIP_SANDBOX/server/audiobooks/$1/.fleet-book.json"
  }

  # rtg_book <Author/Title> <album_artist> <album> <title> [provider] [ids]
  #
  # A stored book: a real m4b carrying those three tags PLUS an artist holding
  # the narrator and a composer, so "we did not write it" can be told apart
  # from "it survived the remux" by value rather than by hope.
  rtg_book() {
    mkdir -p "$RIP_SANDBOX/server/audiobooks/$1"
    ffmpeg -v error -y -i "$RIP_SANDBOX/rtg-a.m4a" -i "$RIP_SANDBOX/rtg-cover.jpg" \
      -i "$RIP_SANDBOX/rtg-chap.txt" \
      -map 0:a -map 1:v -map_metadata 2 -map_chapters 2 \
      -c:a copy -c:v mjpeg -disposition:v attached_pic \
      -metadata album_artist="$2" -metadata artist='Jim Dale' \
      -metadata composer='Comp Person' -metadata album="$3" -metadata title="$4" \
      "$RIP_SANDBOX/server/audiobooks/$1/book.m4b"
    rtg_ids_json='{}'
    [ $# -ge 6 ] && rtg_ids_json="$6"
    rtg_sidecar "$1" "${5:-libation}" "$rtg_ids_json"
  }

  # rtg_book_tags <Author/Title> <album_artist> <album> <title> <artist> <composer>
  # — rtg_book with the two NEVER-REPLACED tags under the example's control.
  # A literal `-` means the tag is not written at all (see rt_fixture_tags:
  # `-metadata artist=` deletes rather than never-creates, and afterwards the
  # two are indistinguishable), which is why they go in through the
  # FFMETADATA file instead of as flags.
  rtg_book_tags() {
    mkdir -p "$RIP_SANDBOX/server/audiobooks/$1"
    { printf '%s\n' ';FFMETADATA1'
      [ "$5" = "-" ] || printf 'artist=%s\n' "$5"
      [ "$6" = "-" ] || printf 'composer=%s\n' "$6"
      printf '%s\n' '[CHAPTER]' 'TIMEBASE=1/1000' 'START=0' 'END=1000' 'title=Chapter One'
    } > "$RIP_SANDBOX/rtg-chap-tags.txt"
    ffmpeg -v error -y -i "$RIP_SANDBOX/rtg-a.m4a" -i "$RIP_SANDBOX/rtg-cover.jpg" \
      -i "$RIP_SANDBOX/rtg-chap-tags.txt" \
      -map 0:a -map 1:v -map_metadata 2 -map_chapters 2 \
      -c:a copy -c:v mjpeg -disposition:v attached_pic \
      -metadata album_artist="$2" -metadata album="$3" -metadata title="$4" \
      "$RIP_SANDBOX/server/audiobooks/$1/book.m4b"
    rtg_sidecar "$1" libation '{}'
  }

  rtg_has() {
    ffprobe -v error -select_streams a:0 -show_entries format_tags:stream_tags -of json -- \
      "$RIP_SANDBOX/server/audiobooks/$1/book.m4b" 2>/dev/null \
      | jq -r '((.format.tags // {}) + (.streams[0].tags // {})) as $t
               | [ $t | has("artist"), has("composer") | tostring ] | join(" ")'
  }
  rtg_has_cd() { rtg_has "C Author/D Book"; }

  # rtg_tree_digest — one hash over every stored file's PATH and CONTENT. "The
  # dry run writes nothing" is only proved against the WHOLE server tree: an
  # assertion on one file, or on the absence of a log line, would pass against
  # a sweep that rewrote a neighbour.
  rtg_tree_digest() {
    ( cd "$RIP_SANDBOX/server" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do
        printf '%s\n' "$f"
        shasum -a 256 "$f" | cut -d' ' -f1
      done ) | shasum -a 256 | cut -d' ' -f1
  }

  rtg_sha() { shasum -a 256 "$RIP_SANDBOX/server/audiobooks/$1/book.m4b" | cut -d' ' -f1; }
  rtg_tag() {
    ffprobe -v error -select_streams a:0 -show_entries format_tags:stream_tags -of json -- \
      "$RIP_SANDBOX/server/audiobooks/$1/book.m4b" 2>/dev/null \
      | jq -r --arg k "$2" '((.format.tags // {}) + (.streams[0].tags // {})) | .[$k] // ""'
  }
  rtg_tags() { printf '%s|%s|%s' "$(rtg_tag "$1" album_artist)" "$(rtg_tag "$1" album)" "$(rtg_tag "$1" title)"; }
  rtg_ids() { jq -Sc '.ids' "$(sidecar_at "$1")"; }

  # rtg_survived_ab — what a remux that dropped the exclusion would lose:
  # the chapter (whose text track is the thing the ipod muxer refuses) and
  # the attached cover picture.
  rtg_survived_ab() {
    ab="$RIP_SANDBOX/server/audiobooks/A Author/B Book/book.m4b"
    printf '%s|%s' \
      "$(ffprobe -v error -show_chapters -of json -- "$ab" 2>/dev/null | jq -r '[.chapters[].tags.title] | join(",")')" \
      "$(ffprobe -v error -select_streams v -show_entries stream=codec_name -of csv=p=0 -- "$ab" 2>/dev/null | tr -d '\n')"
  }
  rtg_tags_ab()   { rtg_tags "A Author/B Book"; }
  rtg_extra_ab()  { printf '%s|%s' "$(rtg_tag "A Author/B Book" artist)" "$(rtg_tag "A Author/B Book" composer)"; }
  rtg_good_sha()  { rtg_sha "Good Author/Good Book"; }
  rtg_bad_sha()   { rtg_sha "A Author/Bad Book"; }
  # rtg_stray — neither a leftover temp nor the .work directory itself may
  # outlive the batch. A killed or failed remux that left a second audio file
  # anywhere under a BOOK directory would be shipped as part of the book by
  # the next push's age-gated find, which is why the temp lives in .work at
  # all; a .work left behind is how that guarantee starts eroding.
  rtg_stray() {
    find "$RIP_SANDBOX/server/audiobooks" \( -name '.work' -o -name 'retag.*' \) 2>/dev/null | wc -l | tr -d ' '
  }
  rtg_ids_bad()   { rtg_ids "A Author/Bad Book"; }
  rtg_ids_ab()    { rtg_ids "A Author/B Book"; }
  rtg_orphan_sha() { rtg_sha "Orphan Author/Orphan Book"; }

  # rtg_meta <file> <provider> <ids-json> — one provider row, the shape
  # rip::_book_meta_for hands rip::_book_sidecar.
  rtg_meta() {
    jq -n --arg p "$2" --argjson i "$3" \
      '{path:"A Author/B Book",title:"B Book",authors:["A Author"],ids:$i,provider:$p,format:"m4b"}' \
      > "$1"
  }
  rtg_ids_m()     { rtg_ids "M Author/M Book"; }
  rtg_ids_f()     { rtg_ids "F Author/F Book"; }

  It 'retag: a dry run names every book whose tags disagree with its path and writes NOTHING'
    rtg_seed
    rtg_book "A Author/B Book" "J.K. Rowling" "Wrong Album" "Wrong Title"
    before=$(rtg_tree_digest)
    When run zsh -c "source $RIPLIB && rip::ab_retag"
    The status should equal 0
    The output should include "would retag: A Author/B Book"
    The output should include 'album_artist="A Author"'
    The output should include 'album="B Book"'
    The output should include "re-run with --apply"
    The result of function rtg_tree_digest should equal "$before"
  End

  # VERBATIM FROM THE PATH, and the artist/composer assertion is not padding:
  # `artist` holds the NARRATOR in the files this feature exists for, and a
  # remux that dropped it would look identical to one that preserved it in
  # every other assertion here.
  It 'retag: --apply rewrites a mismatched book so its tags say what its path says'
    rtg_seed
    rtg_book "A Author/B Book" "J.K. Rowling" "Wrong Album" "Wrong Title"
    When run zsh -c "source $RIPLIB && rip::ab_retag --apply"
    The status should equal 0
    The output should include "retagged: A Author/B Book"
    The output should include "retagged 1 of 1 book(s)"
    The result of function rtg_tags_ab should equal "A Author|B Book|B Book"
    The result of function rtg_extra_ab should equal "Jim Dale|Comp Person"
    The result of function rtg_survived_ab should equal "Chapter One|mjpeg"
  End

  # THE SWEEP'S HALF OF "normalised in place" (2026-08-26, second amendment).
  # BOTH WRITE SITES MUST DO THE SAME THING — rip::_retag_book on the staged
  # copy and the POSIX sh in rip::_retag_write on a stored one — or a book
  # excluded by one and rewritten by the other never settles. The remote has
  # no jq, so the canonical values are computed HERE and shipped base64-framed
  # beside the album_artist/album/title it already carries.
  It 'retag: --apply canonicalises a stored artist and composer in place, and creates neither where absent'
    rtg_seed
    rtg_book_tags "A Author/B Book" "Wrong" "Wrong Album" "Wrong Title" 'J.D. Jackson' 'A.B. Comp'
    rtg_book_tags "C Author/D Book" "Wrong" "Wrong Album" "Wrong Title" - -
    When run zsh -c "source $RIPLIB && rip::ab_retag --apply"
    The status should equal 0
    The output should include "retagged 2 of 2 book(s)"
    The result of function rtg_tags_ab should equal "A Author|B Book|B Book"
    The result of function rtg_extra_ab should equal "J. D. Jackson|A. B. Comp"
    The result of function rtg_survived_ab should equal "Chapter One|mjpeg"
    The result of function rtg_has_cd should equal "false false"
  End

  # THE 258 BOOKS THIS CHANGE EXISTS FOR. Their album_artist/album/title
  # already agree with their paths — the first sweep saw to that — so the ONLY
  # fault left is an un-spaced `artist`, and before the predicate learned to
  # ask about it every one of them was skipped. "retagged 1 of 1" is the
  # assertion that fails without the change; "nothing to retag" alone would
  # not, because that is exactly what the unfixed sweep printed.
  #
  # And then it has to STOP. The second --apply is compared by CONTENT HASH,
  # not by the absence of a log line: a sweep that rewrote the same book on
  # every run forever is the failure mode this project has walked into twice.
  It 'retag: a stored book whose ONLY fault is an un-spaced artist is swept, and the sweep then converges'
    rtg_seed
    rtg_book_tags "A Author/B Book" "A Author" "B Book" "B Book" 'J.K. Rowling' -
    When run zsh -c "source $RIPLIB
      book='$RIP_SANDBOX/server/audiobooks/A Author/B Book/book.m4b'
      rip::ab_retag --apply || exit 9
      s1=\$(shasum -a 256 \"\$book\" | cut -d' ' -f1)
      rip::ab_retag --apply || exit 8
      s2=\$(shasum -a 256 \"\$book\" | cut -d' ' -f1)
      [[ \"\$s1\" == \"\$s2\" ]] && print -r -- 'stable' || print -r -- 'REWRITTEN AGAIN'"
    The status should equal 0
    The output should include "retagged 1 of 1 book(s)"
    The output should include "nothing to retag"
    The output should include "stable"
    The output should not include "REWRITTEN AGAIN"
    The result of function rtg_extra_ab should equal "J. K. Rowling|"
  End

  # BOTH WRITE SITES, ON THE SAME BYTES, ASSERTED EQUAL. The staged retag
  # (zsh, rip::_author_display) and the sweep (jq `_canon`, shipped to a
  # POSIX sh) are two implementations of one rule writing into two copies of
  # one file. Comparing each against a literal would let both drift together;
  # comparing them against EACH OTHER is what catches a divergence that no
  # amount of agreeing-with-the-spec would.
  It 'retag: the staged retag and the sweep write the same artist and composer'
    rtg_seed
    rtg_book_tags "A Author/B Book" "Wrong" "Wrong Album" "Wrong Title" 'J.R.R. Tolkien' 'e.e. cummings'
    mkdir -p "$RIP_STAGING_ROOT/audiobooks/A Author/B Book"
    cp "$RIP_SANDBOX/server/audiobooks/A Author/B Book/book.m4b" \
       "$RIP_STAGING_ROOT/audiobooks/A Author/B Book/book.m4b"
    When run zsh -c "source $RIPLIB
      $RT_PROBE
      export RIP_FFMPEG_BIN=ffmpeg RIP_FFPROBE_BIN=ffprobe
      staged='$RIP_STAGING_ROOT/audiobooks/A Author/B Book/book.m4b'
      stored='$RIP_SANDBOX/server/audiobooks/A Author/B Book/book.m4b'
      rip::_retag_book \"\$staged\" 'A Author' 'B Book' || exit 9
      rip::ab_retag --apply >/dev/null || exit 8
      print -r -- \"staged=\$(rt_probe \"\$staged\" artist)|\$(rt_probe \"\$staged\" composer)\"
      print -r -- \"stored=\$(rt_probe \"\$stored\" artist)|\$(rt_probe \"\$stored\" composer)\""
    The status should equal 0
    The line 1 should equal "staged=J. R. R. Tolkien|e. e. cummings"
    The line 2 should equal "stored=J. R. R. Tolkien|e. e. cummings"
  End

  # BYTES, not tags. A sweep that remuxed every book and happened to write the
  # same three values back would pass a tag assertion and fail this one — and
  # it is the failure that matters, because a no-op remux of 248 books changes
  # every mtime on the server and burns hours for nothing.
  #
  # A MISMATCHED BOOK IS STAGED TOO (the lesson --backfill-work-uid paid for):
  # with only the matching book present the function returns before the write
  # path ever runs, so the digest would guard the classifier and nothing else.
  It 'retag: --apply leaves a book whose tags already match byte-for-byte identical'
    rtg_seed
    rtg_book "Good Author/Good Book" "Good Author" "Good Book" "Good Book"
    rtg_book "A Author/B Book" "J.K. Rowling" "Wrong Album" "Wrong Title"
    before=$(rtg_good_sha)
    When run zsh -c "source $RIPLIB && rip::ab_retag --apply"
    The status should equal 0
    The output should include "retagged 1 of 1 book(s)"
    The output should not include "retagged: Good Author/Good Book"
    The result of function rtg_good_sha should equal "$before"
  End

  # The defect --backfill-work-uid was fixed for, in this verb: an enumerator
  # read through a process substitution throws its status away, so a dropped
  # VPN yields zero rows, prints "nothing to retag" and exits 0 — on the sweep
  # that rewrites audio in the operator's only copy of their library.
  It 'retag: an unreachable server refuses with rc 2 and never says "nothing to retag"'
    rtg_seed
    rtg_book "A Author/B Book" "J.K. Rowling" "Wrong Album" "Wrong Title"
    fake_server_ssh
    printf '#!/bin/sh\nexit 255\n' > "$RIP_SANDBOX/ssh"
    chmod +x "$RIP_SANDBOX/ssh"
    before=$(rtg_tree_digest)
    When run zsh -c "source $RIPLIB && rip::ab_retag --apply"
    The status should equal 2
    The output should not include "nothing to retag"
    The output should not include "retagged"
    The result of function rtg_tree_digest should equal "$before"
  End

  # The SECOND connection is a separate hole from the first: the enumeration
  # can land and the probe die, and an empty probe reads exactly like a
  # library whose tags are all already correct.
  It 'retag: a probe connection that dies is refused, not read as a library already in order'
    rtg_seed
    rtg_book "A Author/B Book" "J.K. Rowling" "Wrong Album" "Wrong Title"
    fake_server_ssh
    dash_bin=$(command -v dash)
    cat > "$RIP_SANDBOX/ssh" <<EOF
#!/bin/sh
echo 1 >> "$RIP_SANDBOX/ssh.count"
cmd=""
for a in "\$@"; do cmd="\$a"; done
case "\$cmd" in *ffprobe*) exit 255 ;; esac
PATH="$RIP_SANDBOX/remotebin"; export PATH
exec "$dash_bin" -c "\$cmd"
EOF
    chmod +x "$RIP_SANDBOX/ssh"
    before=$(rtg_tree_digest)
    When run zsh -c "source $RIPLIB && rip::ab_retag --apply"
    The status should equal 2
    The output should not include "nothing to retag"
    The output should not include "retagged"
    The result of function rtg_tree_digest should equal "$before"
  End

  # "The count never exceeds what actually changed" — the recurring defect in
  # this module ("backfilled 0 of 245") is a total taken from what was
  # ATTEMPTED. Here one book's remux fails, and the failure must show up as
  # both a smaller count and untouched bytes.
  It 'retag: --apply counts only the books whose bytes actually changed'
    rtg_seed
    rtg_book "A Author/Good Book" "J.K. Rowling" "Wrong Album" "Wrong Title"
    rtg_book "A Author/Bad Book" "J.K. Rowling" "Wrong Album" "Wrong Title" manual \
      '{"local.sha256":"aaaa"}'
    mkdir -p "$RIP_SANDBOX/stub"
    real_ffmpeg=$(command -v ffmpeg)
    cat > "$RIP_SANDBOX/stub/ffmpeg" <<EOF
#!/bin/sh
for a in "\$@"; do
  case "\$a" in *"Bad Book"*) exit 1 ;; esac
done
exec "$real_ffmpeg" "\$@"
EOF
    chmod +x "$RIP_SANDBOX/stub/ffmpeg"
    before=$(rtg_bad_sha)
    When run zsh -c "PATH='$RIP_SANDBOX/stub':\$PATH; source $RIPLIB && rip::ab_retag --apply"
    The status should equal 1
    The output should include "retagged 1 of 2 book(s)"
    The output should include "retagged: A Author/Good Book"
    The output should not include "retagged: A Author/Bad Book"
    The stderr should include "could not retag A Author/Bad Book"
    The result of function rtg_bad_sha should equal "$before"
    # AND ITS local.sha256 STAYS PUT. The re-key is gated on the server having
    # reported the rename, not on the book having been a candidate: a book
    # whose remux failed still holds bytes that match its recorded hash.
    The output should not include "re-keyed"
    The result of function rtg_ids_bad should equal '{"local.sha256":"aaaa"}'
    The result of function rtg_stray should equal "0"
  End

  # THE RE-KEY (design doc S5, carried into S4). A book repaired by an EARLIER
  # --repair-sidecars Case C run holds a STORED-BYTES hash under
  # `local.sha256`. That was correct when it was written and is stale the
  # instant this sweep rewrites those bytes — stale under the very key
  # rip::_stored_sha_index reads. Nothing can tell the two apart afterwards,
  # so the re-key has to happen in the pass that invalidates it.
  #
  # The discriminator is `source.provider`, and it is exact rather than a
  # heuristic: Case C only ever fires for a sidecar recording provider
  # "manual" whose ids were EMPTY, and the acquire only ever mints
  # `local.sha256` for a provider "folder" row. Both halves are asserted here
  # — moving the acquire's SOURCE hash would silently disable the byte-dedupe
  # for every folder-imported book, which is the failure this whole re-key
  # exists to prevent, pointed the other way.
  It 'retag: --apply re-keys a Case C stored-bytes hash and PRESERVES an acquire source hash'
    rtg_seed
    rtg_book "M Author/M Book" "Wrong" "Wrong Album" "Wrong Title" manual \
      '{"fleet.uid":"11111111-1111-4111-8111-111111111111","local.sha256":"aaaa"}'
    rtg_book "F Author/F Book" "Wrong" "Wrong Album" "Wrong Title" folder \
      '{"fleet.uid":"22222222-2222-4222-8222-222222222222","local.sha256":"bbbb"}'
    When run zsh -c "source $RIPLIB && rip::ab_retag --apply"
    The status should equal 0
    The output should include "retagged 2 of 2 book(s)"
    The output should include "re-keyed: M Author/M Book"
    The output should not include "re-keyed: F Author/F Book"
    The result of function rtg_ids_m should equal '{"fleet.uid":"11111111-1111-4111-8111-111111111111","local.stored.sha256":"aaaa"}'
    The result of function rtg_ids_f should equal '{"fleet.uid":"22222222-2222-4222-8222-222222222222","local.sha256":"bbbb"}'
  End

  # SCOPED TO WHAT THIS RUN REWROTE. A Case C hash on a book whose tags
  # already agree with its path is still a working dedupe entry — the stored
  # bytes ARE the bytes anyone re-importing would hash, until something
  # rewrites them. Re-keying it would delete a live entry for a book nobody
  # touched; the key becomes wrong exactly when the bytes change, so that is
  # when it moves.
  It 'retag: --apply leaves the local.sha256 of a book it did not rewrite exactly where it was'
    rtg_seed
    rtg_book "M Author/M Book" "M Author" "M Book" "M Book" manual '{"local.sha256":"aaaa"}'
    rtg_book "A Author/B Book" "Wrong" "Wrong Album" "Wrong Title"
    When run zsh -c "source $RIPLIB && rip::ab_retag --apply"
    The status should equal 0
    The output should include "retagged 1 of 1 book(s)"
    The output should not include "re-keyed"
    The result of function rtg_ids_m should equal '{"local.sha256":"aaaa"}'
  End

  # WARNED, NEVER REFUSED (design doc, "Containers that cannot carry these
  # tags"). WAV's RIFF INFO has no album-artist chunk and raw ADTS aac has no
  # metadata container at all, so the verification can never pass — and a
  # deterministic failure cannot be cleared by a retry. A sweep that returned
  # non-zero here would report the operator's library as permanently broken
  # every single run.
  It 'retag: a container that cannot carry album_artist is skipped with a warning, never refused'
    rtg_seed
    mkdir -p "$RIP_SANDBOX/server/audiobooks/W Author/W Book"
    ffmpeg -v error -y -i "$RIP_SANDBOX/rtg-a.m4a" "$RIP_SANDBOX/server/audiobooks/W Author/W Book/book.wav"
    rtg_sidecar "W Author/W Book" libation '{}'
    before=$(rtg_tree_digest)
    When run zsh -c "source $RIPLIB && rip::ab_retag --apply"
    The status should equal 0
    The stderr should include "not retagging W Author/W Book/book.wav"
    The stderr should include "cannot carry album_artist"
    The output should include "nothing to retag"
    The result of function rtg_tree_digest should equal "$before"
  End

  # THE REMOTE SHAPE. cantina has no jq, its /bin/sh is dash, and the sweep
  # ships two multi-line scripts through ${(qq)} — the exact quoting the
  # "backfilled 0 of 245" failure came from. One connection per STAGE
  # (enumerate, probe, write), never one per book.
  # The un-spaced artist and the ABSENT one both run through the dash branch
  # here on purpose: the six-field payload, its `-` sentinel and the POSIX
  # `set --` that assembles the conditional -metadata flags have no other
  # example that exercises them under a genuinely POSIX shell.
  It 'retag: --apply drives a server with NO jq, in ONE ssh per stage'
    rtg_seed
    rtg_book_tags "A Author/B Book" "Wrong" "Wrong Album" "Wrong Title" 'J.K. Rowling' 'A.B. Comp'
    rtg_book_tags "C Author/D Book" "Wrong" "Wrong Album" "Wrong Title" - -
    fake_server_ssh
    When run zsh -c "source $RIPLIB && rip::ab_retag --apply"
    The status should equal 0
    The output should include "retagged 2 of 2 book(s)"
    # enumerate, list, probe, write — one per STAGE, not one per book.
    The result of function ssh_calls should equal "4"
    The result of function ssh_cmds should not include "jq"
    The result of function rtg_tags_ab should equal "A Author|B Book|B Book"
    The result of function rtg_extra_ab should equal "J. K. Rowling|A. B. Comp"
    The result of function rtg_has_cd should equal "false false"
    The result of function rtg_stray should equal "0"
  End

  It 'CLI: --retag is wired and dry-run by default'
    rtg_seed
    rtg_book "A Author/B Book" "J.K. Rowling" "Wrong Album" "Wrong Title"
    before=$(rtg_tree_digest)
    When run zsh "$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_rip-audiobook" --retag
    The status should equal 0
    The output should include "would retag: A Author/B Book"
    The result of function rtg_tree_digest should equal "$before"
  End

  It 'retag: a dry run against the ssh branch writes nothing and opens no write connection'
    rtg_seed
    rtg_book "A Author/B Book" "Wrong" "Wrong Album" "Wrong Title"
    fake_server_ssh
    before=$(rtg_tree_digest)
    When run zsh -c "source $RIPLIB && rip::ab_retag"
    The status should equal 0
    The output should include "re-run with --apply"
    # enumerate + list. No probe-side write, and no write connection at all.
    The result of function ssh_calls should equal "3"
    The result of function rtg_tree_digest should equal "$before"
  End

  # --- review finding F1: `source.provider` must name the row that acquired --
  #
  # rip::ab_retag's re-key gate reads `source.provider` as "which writer put
  # this local.sha256 here". The merge in rip::_book_sidecar is old-wins, and
  # `.source` was not stripped from the old side — so a stale provider could
  # outlive the row that minted the hash, and the gate's premise would be
  # merely usual rather than true.
  #
  # The interleaving needs no misuse: --import stages the book and records a
  # provider "manual" row; the push writes the manual sidecar and FAILS its
  # verify, which by documented design leaves everything staged for a retry;
  # the operator then rips the same book through the folder panel (ab_have
  # says absent, so it is offered), the folder acquire finds the files already
  # staged and copies nothing, and rip::ab_worker threads the SOURCE hash into
  # ids["local.sha256"]. Driven here as the two sequential sidecar writes that
  # sequence actually performs, not as a hand-written end state.
  It 'sidecar: a re-acquire by another provider records the provider that acquired the bytes'
    mkdir -p "$RIP_SANDBOX/stage/A Author/B Book"
    printf 'audio\n' > "$RIP_SANDBOX/stage/A Author/B Book/book.m4b"
    rtg_meta "$RIP_SANDBOX/meta-manual.json" manual '{}'
    rtg_meta "$RIP_SANDBOX/meta-folder.json" folder '{"local.sha256":"SOURCEHASH"}'
    When run zsh -c "source $RIPLIB
      SC='$RIP_SANDBOX/stage/A Author/B Book/.fleet-book.json'
      rip::_book_sidecar '$RIP_SANDBOX/stage/A Author/B Book' '$RIP_SANDBOX/meta-manual.json' || exit 9
      jq -r '.source.provider' \"\$SC\"
      rip::_book_sidecar '$RIP_SANDBOX/stage/A Author/B Book' '$RIP_SANDBOX/meta-folder.json' || exit 8
      jq -r '.source.provider' \"\$SC\"
      jq -r '.ids[\"local.sha256\"]' \"\$SC\""
    The status should equal 0
    The line 1 should equal "manual"
    The line 2 should equal "folder"
    The line 3 should equal "SOURCEHASH"
  End

  # The strip is guarded on `.source` actually being an object. A
  # hand-corrupted `"source": []` — the shape _RIP_JQ_IDS_DEF and
  # _RIP_JQ_WORK_DEF exist for — makes `del(.source.provider)` RAISE, and a
  # raise here fails the WHOLE sidecar write, turning a merge that was merely
  # wrong into a push that cannot record identity at all. Guarded, it merges
  # exactly as it did before the fix.
  It 'sidecar: a poisoned "source": [] does not turn the merge into a failed write'
    mkdir -p "$RIP_SANDBOX/stage2/A Author/B Book"
    printf 'audio\n' > "$RIP_SANDBOX/stage2/A Author/B Book/book.m4b"
    printf '%s\n' '{"schema":1,"kind":"audiobook","source":[],"ids":{"audible.asin":"B0KEEP"}}' \
      > "$RIP_SANDBOX/stage2/A Author/B Book/.fleet-book.json"
    rtg_meta "$RIP_SANDBOX/meta-folder.json" folder '{}'
    When run zsh -c "source $RIPLIB
      rip::_book_sidecar '$RIP_SANDBOX/stage2/A Author/B Book' '$RIP_SANDBOX/meta-folder.json' || exit 9
      jq -r '.ids[\"audible.asin\"]' '$RIP_SANDBOX/stage2/A Author/B Book/.fleet-book.json'"
    The status should equal 0
    The output should equal "B0KEEP"
  End

  # And the consequence the fix exists for, end to end: that book's SOURCE
  # hash must survive the sweep. The sidecar is built by the real composer
  # from the real two-step sequence rather than hand-written into the shape
  # the gate is supposed to see — a hand-written sidecar would pass whatever
  # the merge does.
  It 'retag: a book re-acquired by the folder provider keeps its source hash through the sweep'
    rtg_seed
    rtg_book "A Author/B Book" "Wrong" "Wrong Album" "Wrong Title" manual '{}'
    rtg_meta "$RIP_SANDBOX/meta-manual.json" manual '{}'
    rtg_meta "$RIP_SANDBOX/meta-folder.json" folder '{"local.sha256":"SOURCEHASH"}'
    zsh -c "source $RIPLIB
      rip::_book_sidecar '$RIP_SANDBOX/server/audiobooks/A Author/B Book' '$RIP_SANDBOX/meta-manual.json'
      rip::_book_sidecar '$RIP_SANDBOX/server/audiobooks/A Author/B Book' '$RIP_SANDBOX/meta-folder.json'"
    When run zsh -c "source $RIPLIB && rip::ab_retag --apply"
    The status should equal 0
    The output should include "retagged 1 of 1 book(s)"
    The output should not include "re-keyed"
    The result of function rtg_ids_ab should equal '{"local.sha256":"SOURCEHASH"}'
  End

  # --- review finding F3: a stored book with no sidecar is invisible --------
  #
  # rip::_server_sidecars' remote `find` matches `.fleet-book.json`, so a book
  # directory holding audio and no sidecar is never probed and never counted —
  # and "retagged N of M" would report a complete sweep over a library it did
  # not entirely look at. That population is real: it is
  # rip::ab_repair_sidecars' `norow` bucket, which that verb reports by name
  # and deliberately never repairs.
  It 'retag: a stored book with no sidecar at all is named, never counted as done'
    rtg_seed
    rtg_book "A Author/B Book" "Wrong" "Wrong Album" "Wrong Title"
    mkdir -p "$RIP_SANDBOX/server/audiobooks/Orphan Author/Orphan Book"
    ffmpeg -v error -y -i "$RIP_SANDBOX/rtg-a.m4a" -c:a copy \
      "$RIP_SANDBOX/server/audiobooks/Orphan Author/Orphan Book/book.m4b"
    orphan_before=$(rtg_orphan_sha)
    When run zsh -c "source $RIPLIB && rip::ab_retag --apply"
    The status should equal 0
    The stderr should include "no sidecar for Orphan Author/Orphan Book"
    The stderr should include "run --repair-sidecars"
    The output should include "retagged 1 of 1 book(s)"
    The result of function rtg_orphan_sha should equal "$orphan_before"
  End

End
