# Tests for the Ctrl-Y copy-feedback layer (copy-feedback design,
# docs/superpowers/specs/2026-07-20-clipboard-copy-feedback-design.md):
# toast variant selection (§6), materialization progress throttling (§4.2),
# and their wiring into clip::copy_by_id / --restore-id.
#
# Same harness shape as tests/pick-clipboard-files_spec.sh: the picker is
# sourced under PICK_CLIPBOARD_NO_RUN in a zsh -f (no ~/.zshenv), against a
# sandboxed HOME + seeded store; notify/hs/rsync are captured by fake
# executables wired in via the PICK_CLIPBOARD_* test overrides.
#
# CONVERTED TO THE RECOB HARNESS (tests/recob_helper.sh): the bridge the
# copies land on is a REAL `recobd --record` per example (reached through
# the suite's own system-bridge build via recob_start's SYSTEM_BRIDGE_BIN
# export), not a fake `nc` that answered 'O' to anything. The copies these
# feedback tests ride on -- clip.set for a text row, clip.set.files{paths}
# after a pull -- are therefore really served, against a private sandboxed
# pasteboard; the daemon also writes its own post-write snapshot row into
# the shared store, which none of these assertions key on (they read rows by
# the picked id, never by MAX(id)).
Describe 'pick-clipboard: copy feedback'
  Include tests/recob_helper.sh

  SCRIPT="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_pick-clipboard"
  LIB_DIR="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib"

  setup() {
    unset SSH_CONNECTION SSH_CLIENT SSH_TTY
    BINDIR="$SHELLSPEC_TMPBASE/bin"; mkdir -p "$BINDIR"
    export HOME="$SHELLSPEC_TMPBASE/home"; rm -rf "$HOME"; mkdir -p "$HOME"
    export TMPDIR="$SHELLSPEC_TMPBASE/tmp"; rm -rf "$TMPDIR"; mkdir -p "$TMPDIR"
    # Real daemon, pinned identity: mac-mini via the sandboxed self-name file
    # recob_start writes (it outranks scutil in clip::self_host, so the old
    # scutil fake is gone). The picker and the daemon share ONE store under
    # recob_start's XDG_DATA_HOME.
    RECOB_SELF_NAME=mac-mini
    recob_start
    DB="$XDG_DATA_HOME/pick-clipboard/history.db"
    export PICK_CLIPBOARD_DB="$DB"
    mkdir -p "$XDG_DATA_HOME/pick-clipboard"
    rm -f "$DB"
    sqlite3 "$DB" '
      CREATE TABLE clips (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        text_preview TEXT,
        text_plain TEXT,
        len INTEGER,
        first_ts REAL,
        last_ts REAL,
        source_app TEXT,
        source_bundle_id TEXT,
        type_kind TEXT,
        regtype TEXT,
        pinned INTEGER DEFAULT 0,
        type_hash TEXT,
        source_host TEXT
      );
      CREATE TABLE clip_types (
        clip_id INTEGER,
        uti TEXT,
        blob BLOB,
        PRIMARY KEY (clip_id, uti)
      );
      CREATE TABLE file_authorities (
        clip_id INTEGER,
        item_index INTEGER,
        path BLOB,
        PRIMARY KEY (clip_id, item_index)
      );
    '

    # Fake pbcopy: clip::copy_by_id's last-resort fallback. With the daemon
    # answering it is never reached, but a spec must NEVER be one failure
    # path away from writing the human's real pasteboard.
    cat > "$BINDIR/pbcopy" <<'EOF'
#!/bin/sh
cat > /dev/null
EOF
    chmod +x "$BINDIR/pbcopy"

    NOTIFYLOG="$SHELLSPEC_TMPBASE/notifylog"; : > "$NOTIFYLOG"
    # Fake notify front-end: logs its argv, one line per call.
    cat > "$BINDIR/notify" <<EOF
#!/bin/sh
echo "\$*" >> "$NOTIFYLOG"
EOF
    chmod +x "$BINDIR/notify"
    export PICK_CLIPBOARD_NOTIFY="$BINDIR/notify"

    HSLOG="$SHELLSPEC_TMPBASE/hslog"; : > "$HSLOG"
    # Fake hs CLI: accepts only the production `-q -c` shape with stdin
    # redirected from /dev/null, so every payload assertion regression-tests
    # both isolation requirements. Hammerspoon 1.1.1's console mirror can
    # recursively flood warnings from an unrelated print during a request,
    # blocking its event taps; -q bypasses that mirror. The real CLI also
    # reads stdin, which otherwise steals records from rsync's progress pipe.
    # printf '%s\n', not echo: /bin/sh's echo builtin is XSI-compliant on this box (verified:
    # `sh -c 'x="a\\\\b"; echo "$x"'` prints a single backslash) and would
    # silently collapse the label-escaping test's literal backslash pairs
    # before they ever reach the log -- printf never reinterprets its
    # argument, so the log holds the exact -c payload byte-for-byte, same as
    # what real Hammerspoon's `hs -q -c` would receive.
    cat > "$BINDIR/hs" <<EOF
#!/bin/sh
[ -c /dev/fd/0 ] && [ "\$1" = "-q" ] && [ "\$2" = "-c" ] && printf '%s\n' "\$3" >> "$HSLOG"
EOF
    chmod +x "$BINDIR/hs"
    export PICK_CLIPBOARD_HS="$BINDIR/hs"

    RSYNCLOG="$SHELLSPEC_TMPBASE/rsynclog"; : > "$RSYNCLOG"
    # Fake rsync: logs argv, emits three CR-separated progress2-style
    # updates on stdout (like the real --info=progress2), then fabricates
    # the pulled file -- same dst/base extraction as
    # tests/pick-clipboard-files_spec.sh's fake.
    cat > "$BINDIR/rsync" <<EOF
#!/bin/sh
echo "\$*" >> "$RSYNCLOG"
printf '     1,000  10%%    1.00MB/s    0:00:09\\r'
printf '     5,000  50%%    1.00MB/s    0:00:05\\r'
printf '    10,000 100%%    1.00MB/s    0:00:00\\r'
argc=\$#
eval "src=\\\${\$((argc - 1))}"
eval "dst=\\\${\$argc}"
name="\${src##*:}"
base="\${name##*/}"
mkdir -p "\$dst"
printf 'pulled:%s' "\$base" > "\$dst/\$base"
EOF
    chmod +x "$BINDIR/rsync"
    export PICK_CLIPBOARD_RSYNC="$BINDIR/rsync"

    export PATH="$BINDIR:$PATH"
    export PICK_COMMON_LIB="$LIB_DIR/pick-common.zsh"
    export PICK_BRIDGE_CLIENT_LIB="$LIB_DIR/clipboard-bridge-client.zsh"
    export PICK_CLIPBOARD_CORE_LIB="$LIB_DIR/clipboard-store-core.zsh"
    export PICK_CLIPBOARD_NO_RUN=1
    export SCRIPT_PATH="$SCRIPT"
    # Phase 4: the sidecar sink's job-state sandbox.
    export JOBROOT="$SHELLSPEC_TMPBASE/jobs"
    mkdir -p "$JOBROOT"
    rm -rf "$JOBROOT/j1"
  }
  BeforeEach 'setup'
  AfterEach 'recob_stop'

  # Calls a sourced picker function with the given argv, zsh -f sandboxed.
  run_fn() {
    zsh -f -c '
      source "$SCRIPT_PATH"
      fn=$1; shift
      "$fn" "$@"
    ' _ "$@"
  }

  run_restore_id() {
    zsh -f "$SCRIPT" --restore-id "$1"
  }

  # Seeds a remote files row with a single-path x-file-manifest.
  seed_remote_manifest_row() {
    _id=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, last_ts) VALUES ('files','work-laptop',100); SELECT last_insert_rowid();")
    printf '/pick-clipboard-remote-src/big.bin' > "$SHELLSPEC_TMPBASE/manifest-blob"
    sqlite3 "$DB" "INSERT INTO clip_types (clip_id, uti, blob) VALUES ($_id, 'x-file-manifest', readfile('$SHELLSPEC_TMPBASE/manifest-blob'));"
    printf '%s' "$_id"
  }

  # Exact-match checker for clip::toast_spec output: the expected string
  # contains a raw US (0x1f) separator, which must never appear inside a
  # shellspec DSL argument (it collides with shellspec's own internal
  # field separator and corrupts the assertion). Comparison happens
  # entirely in-shell instead.
  check_toast_spec() {  # <kind> <host> <expected-icon> <expected-message>
    local out
    out=$(zsh -f -c '
      source "$SCRIPT_PATH"
      clip::toast_spec "$1" "$2"
    ' _ "$1" "$2")
    [ "$out" = "$3$(printf '\x1f')$4" ]
  }

  Describe 'clip::toast_spec (§6 variant selection, pure)'
    It 'remote text row -> text glyph + Copied from <host>'
      When call check_toast_spec text work-laptop glyph:nf-md-text_box "Copied from work-laptop"
      The status should be success
    End

    It 'remote files row -> file_multiple glyph'
      When call check_toast_spec files work-laptop glyph:nf-md-file_multiple "Copied from work-laptop"
      The status should be success
    End

    It 'remote image/file/directory rows -> their kind glyphs'
      When call check_toast_spec image work-laptop glyph:nf-md-image "Copied from work-laptop"
      The status should be success
    End

    It 'unknown kind falls back to the text glyph'
      When call check_toast_spec url work-laptop glyph:nf-md-text_box "Copied from work-laptop"
      The status should be success
    End

    It 'own-host row -> local acknowledgment variant'
      When call check_toast_spec text mac-mini glyph:fa-clipboard-list "Clipboard moved to top"
      The status should be success
    End

    It 'empty host (legacy row) reads as local'
      When call check_toast_spec files '' glyph:fa-clipboard-list "Clipboard moved to top"
      The status should be success
    End
  End

  Describe 'clip::copy_by_id toast wiring (§6)'
    It 'remote text row: bridge copy succeeds and toasts Copied from <host>'
      id=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, text_plain, source_host, last_ts) VALUES ('text','hello','work-laptop',100); SELECT last_insert_rowid();")
      When call run_fn clip::copy_by_id "$id"
      The status should be success
      The contents of file "$NOTIFYLOG" should include "--icon glyph:nf-md-text_box --sound Frog Copied from work-laptop"
    End

    It 'local text row: toasts the moved-to-top acknowledgment'
      id=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, text_plain, source_host, last_ts) VALUES ('text','hello','mac-mini',100); SELECT last_insert_rowid();")
      When call run_fn clip::copy_by_id "$id"
      The status should be success
      The contents of file "$NOTIFYLOG" should include "--icon glyph:fa-clipboard-list --sound Frog Clipboard moved to top"
    End

    It 'missing notify binary is a silent no-op, copy still succeeds'
      rm -f "$BINDIR/notify"
      id=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, text_plain, source_host, last_ts) VALUES ('text','hello','work-laptop',100); SELECT last_insert_rowid();")
      When call run_fn clip::copy_by_id "$id"
      The status should be success
      The contents of file "$NOTIFYLOG" should equal ""
    End

    It 'files-restore failure with text fallback does NOT toast (W2 hold owns that)'
      # files kind + no recorded paths -> clip::copy_files_by_id fails fast,
      # copy_by_id falls through to the text fallback (a real clip.set the
      # daemon serves) -- CLIP_RESTORE_FAILURE is set, so no toast.
      id=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, text_plain, source_host, last_ts) VALUES ('files','/tmp/x','work-laptop',100); SELECT last_insert_rowid();")
      When call run_fn clip::copy_by_id "$id"
      The stderr should include 'no file paths recorded'
      The contents of file "$NOTIFYLOG" should equal ""
    End
  End

  Describe 'clip::progress_pct (§4.2 aggregate, pure)'
    It 'single path mirrors the current transfer percent'
      When call run_fn clip::progress_pct 0 1 45
      The output should equal 45
    End

    It 'aggregates completed paths over an N-path manifest'
      # 2 of 4 paths done, current one at 50% -> (200+50)/4 = 62
      When call run_fn clip::progress_pct 2 4 50
      The output should equal 62
    End

    It 'zero total degrades to 0, not a division error'
      When call run_fn clip::progress_pct 0 0 50
      The output should equal 0
    End
  End

  Describe 'clip::progress_stream (phase 4: the job sidecar sink)'
    # The sink writes $JOB_STATE_ROOT/$JOB_ID/progress — one atomic
    # `<epoch> <pct> <label>` line per distinct aggregate percent. Outside
    # a job (no JOB_ID env) it drains rsync and writes nothing. The old
    # throttle/stall/hs machinery retired with the bespoke HUD driver
    # (phase 4); staleness is the reader's business via the epoch.
    sidecar() { cat "$JOBROOT/j1/progress" 2>/dev/null; }

    It 'writes the aggregate to the sidecar under a job'
      When call zsh -f -c '
        export JOB_ID=j1 JOB_STATE_ROOT="$JOBROOT"
        mkdir -p "$JOBROOT/j1"
        source "$SCRIPT_PATH"
        clip::progress_begin
        printf "  5,000  50%%\r" | clip::progress_stream 2 4 work-laptop
      '
      The status should be success
      The result of function sidecar should match pattern "[0-9]* 62 work-laptop"
    End

    It 'the last distinct percent wins (one line, atomic rename)'
      When call zsh -f -c '
        export JOB_ID=j1 JOB_STATE_ROOT="$JOBROOT"
        mkdir -p "$JOBROOT/j1"
        source "$SCRIPT_PATH"
        clip::progress_begin
        printf "  1,000  10%%\r  5,000  50%%\r 10,000 100%%\r" | clip::progress_stream 0 1 work-laptop
      '
      The status should be success
      The result of function sidecar should match pattern "[0-9]* 100 work-laptop"
    End

    It 'never regresses: a lower record keeps the high-water percent'
      When call zsh -f -c '
        export JOB_ID=j1 JOB_STATE_ROOT="$JOBROOT"
        mkdir -p "$JOBROOT/j1"
        source "$SCRIPT_PATH"
        clip::progress_begin
        printf "  9,000  90%%\r  2,000  20%%\r" | clip::progress_stream 0 1 work-laptop
      '
      The status should be success
      The result of function sidecar should match pattern "[0-9]* 90 work-laptop"
    End

    It 'outside a job: drains stdin, writes no sidecar'
      When call zsh -f -c '
        unset JOB_ID JOB_STATE_ROOT
        source "$SCRIPT_PATH"
        clip::progress_begin
        printf "  5,000  50%%\r" | clip::progress_stream 0 1 work-laptop
      '
      The status should be success
      The path "$JOBROOT/j1/progress" should not be exist
    End
  End

  Describe '--restore-id headless pull with progress plumbing (§4.2)'
    It 'pull succeeds; sub-grace transfer emits no HUD calls; toast still fires'
      id=$(seed_remote_manifest_row)
      When call run_restore_id "$id"
      The status should be success
      # Outside a job (no JOB_ID env in this harness) the sink is inert:
      # nothing is written anywhere; the engine toast is the only feedback.
      The contents of file "$HSLOG" should equal ""
      The contents of file "$NOTIFYLOG" should include "--icon glyph:nf-md-file_multiple --sound Frog Copied from work-laptop"
    End
  End

  Describe 'cancellation + resumable staging lifecycle (§4.4)'
    It 'rsync failure removes the partial cache dir'
      id=$(seed_remote_manifest_row)
      cat > "$BINDIR/rsync-fail" <<EOF
#!/bin/sh
argc=\$#
eval "dst=\\\${\$argc}"
mkdir -p "\$dst/partial-dir"
printf partial > "\$dst/partial-dir/chunk"
exit 23
EOF
      chmod +x "$BINDIR/rsync-fail"
      export PICK_CLIPBOARD_RSYNC="$BINDIR/rsync-fail"
      When call run_restore_id "$id"
      The status should equal 1
      The stderr should include 'rsync failed pulling'
      The path "$HOME/.cache/pick-clipboard/files/$id/1" should not be exist
      The contents of file "$NOTIFYLOG" should equal ""
    End

    It 'a failed pull does not poison the cache: the next pick re-pulls and succeeds'
      id=$(seed_remote_manifest_row)
      cat > "$BINDIR/rsync-fail" <<EOF
#!/bin/sh
argc=\$#
eval "dst=\\\${\$argc}"
mkdir -p "\$dst/partial-dir"
exit 23
EOF
      chmod +x "$BINDIR/rsync-fail"
      export PICK_CLIPBOARD_RSYNC="$BINDIR/rsync-fail"
      run_restore_id "$id" 2>/dev/null || true
      export PICK_CLIPBOARD_RSYNC="$BINDIR/rsync"
      When call run_restore_id "$id"
      The status should be success
      The contents of file "$NOTIFYLOG" should include "Copied from work-laptop"
    End

    It 'TERM mid-pull runs the cancel path: exit 130, partial retained, quiet toast'
      id=$(seed_remote_manifest_row)
      cat > "$BINDIR/rsync-slow" <<EOF
#!/bin/sh
for arg in "\$@"; do
  case "\$arg" in --partial-dir=*) partial=\${arg#*=} ;; esac
done
mkdir -p "\$partial"
printf partial > "\$partial/chunk"
sleep 1
exit 0
EOF
      chmod +x "$BINDIR/rsync-slow"
      export PICK_CLIPBOARD_RSYNC="$BINDIR/rsync-slow"
      run_cancelled_restore() {
        zsh -f "$SCRIPT" --restore-id "$1" &
        _pid=$!
        sleep 0.4
        kill -TERM "$_pid" 2>/dev/null
        wait "$_pid"
      }
      When call run_cancelled_restore "$id"
      The status should equal 130
      The path "$HOME/.cache/pick-clipboard/files/$id/.partial/1" should be exist
      The path "$HOME/.cache/pick-clipboard/files/$id/.partial-data/1/chunk" should be exist
      The contents of file "$NOTIFYLOG" should include "--icon glyph:nf-md-close Transfer cancelled"
      The contents of file "$NOTIFYLOG" should not include "Copied from"
    End

    It 'the next pull reuses a retained partial and clears its staging marker'
      id=$(seed_remote_manifest_row)
      sub="$HOME/.cache/pick-clipboard/files/$id/1"
      partial="$HOME/.cache/pick-clipboard/files/$id/.partial-data/1"
      marker="$HOME/.cache/pick-clipboard/files/$id/.partial/1"
      mkdir -p "$sub" "$partial" "${marker:h}"
      printf partial > "$partial/chunk"
      : > "$marker"
      cat > "$BINDIR/rsync-resume" <<EOF
#!/bin/sh
partial=""
for arg in "\$@"; do
  case "\$arg" in --partial-dir=*) partial=\${arg#*=} ;; esac
done
[ "\$partial" = "$partial" ] || exit 98
argc=\$#
eval "src=\\\${\$((argc - 1))}"
eval "dst=\\\${\$argc}"
[ -f "\$partial/chunk" ] || exit 97
base="\${src##*/}"
printf resumed > "\$dst/\$base"
rm -f "\$partial/chunk"
EOF
      chmod +x "$BINDIR/rsync-resume"
      export PICK_CLIPBOARD_RSYNC="$BINDIR/rsync-resume"
      When call run_restore_id "$id"
      The status should be success
      The path "$sub/big.bin" should be exist
      The path "$marker" should not be exist
      The path "$partial" should not be exist
      The contents of file "$NOTIFYLOG" should include "Copied from"
    End

    It '24-hour sweep removes expired bytes and their un-restorable localized row'
      sub="$HOME/.cache/pick-clipboard/files/77/1"
      iddir="${sub:h}"
      mkdir -p "$sub" "$iddir/.authorized" "$iddir/.partial" "$iddir/.partial-data/1"
      printf staged > "$sub/report.bin"
      : > "$iddir/.authorized/1"
      : > "$iddir/.partial/1"
      printf partial > "$iddir/.partial-data/1/chunk"
      printf '%s' "$sub/report.bin" > "$SHELLSPEC_TMPBASE/localized-blob"
      localized_id=$(sqlite3 "$DB" "INSERT INTO clips (type_kind, source_host, last_ts) VALUES ('file','peer',100); SELECT last_insert_rowid();")
      sqlite3 "$DB" "INSERT INTO clip_types (clip_id, uti, blob) VALUES ($localized_id, 'x-resolved-path', readfile('$SHELLSPEC_TMPBASE/localized-blob'));"
      touch -t 202001010000 "$sub"
      export PICK_CLIPBOARD_CACHE_TTL=1
      export LOCALIZED_ID="$localized_id"
      When call zsh -f -c '
        source "$SCRIPT_PATH"
        clip::cache_sweep
        sqlite3 "$DB_FILE" "SELECT count(*) FROM clips WHERE id=$LOCALIZED_ID;"
      '
      The status should be success
      The output should equal "0"
      The path "$sub" should not be exist
      The path "$iddir" should not be exist
    End
  End

  Describe 'clip::progress_label (§4.2a, pure)'
    It 'single path -> Copying <basename> from <host>…'
      When call run_fn clip::progress_label 1 work-laptop /remote/src/big-clip.bin
      The output should equal 'Copying big-clip.bin from work-laptop…'
    End

    It 'multi path -> Copying N files from <host>…'
      When call run_fn clip::progress_label 3 work-laptop /remote/src/first.txt
      The output should equal 'Copying 3 files from work-laptop…'
    End
  End

  Describe 'clip::render_restore_failure (Wave 2: shared gum_style env)'
    # Returns 0 iff the GUM_STYLE_* the function exported both equal the
    # canonical danger accent (C_HEX_DIALOG_DANGER). The gum stub's /dev/tty
    # write is expected to fail headless and is swallowed — the export happens
    # first, which is the point of the assertion.
    render_uses_shared_env() {
      printf '#!/bin/sh\nexit 0\n' > "$BINDIR/gum"; chmod +x "$BINDIR/gum"
      local out fg rest border canon
      out=$(zsh -f -c '
        source "$SCRIPT_PATH"
        clip::render_restore_failure "boom" 2>/dev/null || true
        print -r -- "$GUM_STYLE_FOREGROUND|$GUM_STYLE_BORDER_FOREGROUND|$C_HEX_DIALOG_DANGER"
      ')
      fg=${out%%|*}; rest=${out#*|}; border=${rest%%|*}; canon=${rest#*|}
      [ -n "$canon" ] && [ "$fg" = "$canon" ] && [ "$border" = "$canon" ]
    }
    It 'exports GUM_STYLE_* set to the canonical danger accent'
      When call render_uses_shared_env
      The status should be success
    End
  End
End
