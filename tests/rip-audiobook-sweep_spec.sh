# rip-audiobook, part 3 of 4 — the author sweep and --repair-sidecars.
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

  # fake_server_ssh_probe_fails — fake_server_ssh whose `test -f` probe exits
  # 255, the rc a real ssh gives when the connection itself never happened.
  # rip::_remote_has_file's tri-state turns that into 2 ("the check did not
  # run"), which is the branch whose closing line must not claim a sidecar
  # exists. Every other remote command still runs normally, so the sweep
  # reaches that branch the way it would live.
  fake_server_ssh_probe_fails() {
    fake_server_ssh || return 1
    local dash_bin
    dash_bin=$(command -v dash 2>/dev/null || true)
    cat > "$RIP_SANDBOX/ssh" <<EOF
#!/bin/sh
echo 1 >> "$RIP_SANDBOX/ssh.count"
cmd=""
for a in "\$@"; do cmd="\$a"; done
printf '%s\n' "\$cmd" >> "$RIP_SANDBOX/ssh.cmds"
case "\$cmd" in
  "test -f"*) exit 255 ;;
esac
PATH="$RIP_SANDBOX/remotebin"; export PATH
exec "$dash_bin" -c "\$cmd"
EOF
    chmod +x "$RIP_SANDBOX/ssh"
  }

  fake_provider_two() {
    export RIP_LIBEXEC_DIR="$RIP_SANDBOX/libexec"
    mkdir -p "$RIP_LIBEXEC_DIR"
    cat > "$RIP_LIBEXEC_DIR/rip-provider-libation" <<'EOF'
#!/bin/sh
if [ "$1" = list ]; then
  printf '%s\n' '{"id":"X1","path":"A/B","title":"B","published":"2019-05-07T07:00:00"}'
  printf '%s\n' '{"id":"X2","path":"C/D","title":"D","published":"2021-11-30T08:00:00"}'
fi
exit 0
EOF
    chmod +x "$RIP_LIBEXEC_DIR/rip-provider-libation"
  }

  two_dates() {
    printf '%s %s\n' \
      "$(jq -r '.published' "$RIP_SANDBOX/server/audiobooks/A/B/.fleet-book.json")" \
      "$(jq -r '.published' "$RIP_SANDBOX/server/audiobooks/C/D/.fleet-book.json")"
  }

  It 'backfill: --apply writes through a server with NO jq, in ONE ssh for the whole batch'
    fake_provider_two
    mkbook "A" "B" X1 "" B
    mkbook "C" "D" X2 "" D
    fake_server_ssh
    When run zsh -c "source $RIPLIB && rip::ab_backfill_published --apply"
    The status should equal 0
    The output should include "backfilled 2 of 2 sidecar(s)"
    The result of function two_dates should equal "2019-05-07T07:00:00 2021-11-30T08:00:00"
    # TWO ssh calls for two books, not three: one to enumerate the sidecars,
    # ONE for the whole write batch. 245 books must not be 245 round-trips.
    The result of function ssh_calls should equal "2"
    # …and nothing the server was asked to run mentions jq. The restricted
    # PATH above already makes a remote jq fail; this names the regression.
    The result of function ssh_cmds should not include "jq"
  End

  # The trap this fix had to dodge: rip::_server_sidecars ANNOTATES each row
  # it emits with a `_path` key that is NOT in the stored file. Composing the
  # replacement from that annotated object — the obvious way to do it once
  # the compose moved local — would permanently add a bogus `_path` field to
  # every sidecar the sweep touches, on the only copy of every book's
  # identity. Everything else must survive the round trip byte for byte,
  # including a false-valued field, a null, nested objects, and a title full
  # of characters that would wreck an unquoted remote command line.
  RICH_JSON='{"schema":1,"kind":"audiobook","title":"Elantris: 10th $Ann - Omega","authors":["Sanderson, B. \"Bran\""],"ids":{"audible.asin":"X1","isbn":null},"series":{"name":"The Cosmere","order":"1"},"work":{"language":"english","abridged":false},"source":{"provider":"libation","fetched":"2026-08-22"}}'
  RICH_AUTHOR='Sanderson, B. "Bran"'
  RICH_TITLE='Elantris: 10th $Ann - Omega'
  rich_file() { printf '%s' "$RIP_SANDBOX/server/audiobooks/$RICH_AUTHOR/$RICH_TITLE/.fleet-book.json"; }
  rich_without_published() { jq -c 'del(.published)' "$(rich_file)"; }
  rich_published() { jq -r '.published' "$(rich_file)"; }
  rich_has_path() { jq -r 'has("_path")' "$(rich_file)"; }

  It 'backfill: the written sidecar gains ONLY published — no _path, nothing else altered'
    export RIP_LIBEXEC_DIR="$RIP_SANDBOX/libexec"
    mkdir -p "$RIP_LIBEXEC_DIR" "$RIP_SANDBOX/server/audiobooks/$RICH_AUTHOR/$RICH_TITLE"
    printf '%s' "$RICH_JSON" > "$(rich_file)"
    cat > "$RIP_LIBEXEC_DIR/rip-provider-libation" <<'EOF'
#!/bin/sh
[ "$1" = list ] && printf '%s\n' '{"id":"X1","path":"x","title":"x","published":"2019-05-07T07:00:00"}'
exit 0
EOF
    chmod +x "$RIP_LIBEXEC_DIR/rip-provider-libation"
    fake_server_ssh
    When run zsh -c "source $RIPLIB && rip::ab_backfill_published --apply"
    The status should equal 0
    The output should include "backfilled 1 of 1 sidecar(s)"
    The result of function rich_published should equal "2019-05-07T07:00:00"
    The result of function rich_has_path should equal "false"
    The result of function rich_without_published should equal "$RICH_JSON"
  End

  It 'backfill: a write that fails leaves the good sidecar untouched and reports the book failed'
    # The book directory is made unwritable, so the remote script's temp
    # file cannot be created at all. The pre-existing sidecar must survive
    # exactly as it was, no temp file may be left behind, and the book must
    # be counted as NOT filled — the server holds the only copy.
    fake_provider_two
    mkbook "A" "B" X1 "" B
    fake_server_ssh
    When run zsh -c "source $RIPLIB
      chmod 555 '$RIP_SANDBOX/server/audiobooks/A/B'
      rip::ab_backfill_published --apply; rc=\$?
      chmod 755 '$RIP_SANDBOX/server/audiobooks/A/B'
      exit \$rc"
    The status should equal 1
    The output should include "backfilled 0 of 1 sidecar(s)"
    The output should include "1 sidecar(s) could not be written"
    The stderr should include "could not backfill A/B"
    The contents of file "$RIP_SANDBOX/server/audiobooks/A/B/.fleet-book.json" should include '"published":null'
    The result of function stray_tmp_files should equal "0"
  End

  It 'backfill: a write connection that never answers fills nothing and says so'
    # The enumeration succeeds and the write ssh dies (255, an unreachable
    # host). Nothing may be reported as filled on the strength of the call
    # having been made — only on a per-book "ok" coming back.
    fake_provider_two
    mkbook "A" "B" X1 "" B
    fake_server_ssh
    # Same POSIX-shell rationale as fake_server_ssh above: the login shell
    # must be real dash, not macOS's bash-flavored /bin/sh.
    local dash_bin
    dash_bin=$(command -v dash 2>/dev/null || true)
    if [ -z "$dash_bin" ]; then
      print -u2 -- "no dash on PATH — refusing to fall back to /bin/sh"
      return 1
    fi
    cat > "$RIP_SANDBOX/ssh" <<EOF
#!/bin/sh
cmd=""
for a in "\$@"; do cmd="\$a"; done
case "\$cmd" in *base64*) exit 255 ;; esac
PATH="$RIP_SANDBOX/remotebin"; export PATH
exec "$dash_bin" -c "\$cmd"
EOF
    chmod +x "$RIP_SANDBOX/ssh"
    When run zsh -c "source $RIPLIB && rip::ab_backfill_published --apply"
    The status should equal 1
    The output should include "backfilled 0 of 1 sidecar(s)"
    The stderr should include "could not backfill A/B"
    The contents of file "$RIP_SANDBOX/server/audiobooks/A/B/.fleet-book.json" should include '"published":null'
  End

  It 'backfill: a dry run against the ssh branch writes nothing and opens no write connection'
    fake_provider_two
    mkbook "A" "B" X1 "" B
    fake_server_ssh
    When run zsh -c "source $RIPLIB && rip::ab_backfill_published"
    The status should equal 0
    The output should include "re-run with --apply"
    The contents of file "$RIP_SANDBOX/server/audiobooks/A/B/.fleet-book.json" should include '"published":null'
    # The enumeration ssh, and nothing else.
    The result of function ssh_calls should equal "1"
  End

  # --- retire + author canonicalization sweep (destructive operators) -------
  #
  # Both default to a DRY RUN. The server holds the only copy of every book
  # (staging is emptied after each verified push, and the audio cannot be
  # re-derived), so --apply is required before anything is deleted or moved.
  #
  # fake_abs_ops_bin — stands in for the Task 7 verbs on
  # $RIP_BIN_DIR/rip-abs-authors and logs its full argv, so an example can
  # assert exactly which ABS calls were made AND, just as importantly, that
  # none were made when the operator was refused.
  fake_abs_ops_bin() {
    cat > "$RIP_BIN_DIR/rip-abs-authors" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$RIP_SANDBOX/absbin.log"
case "\$1" in
  --find-item)
    case "\$2" in
      "A/B") echo item-1 ;;
      *"/The Hobbit") echo item-1 ;;
      *) exit 1 ;;
    esac
    ;;
  --author-id) echo auth-9 ;;
esac
exit 0
EOF
    chmod +x "$RIP_BIN_DIR/rip-abs-authors"
  }

  It 'retire: dry-run prints the plan and changes nothing'
    fake_abs_ops_bin
    mkdir -p "$RIP_SANDBOX/server/audiobooks/A/B"
    printf 'x\n' > "$RIP_SANDBOX/server/audiobooks/A/B/B.m4b"
    When run zsh -c "source $RIPLIB && rip::ab_retire 'A/B'"
    The status should equal 0
    The output should include "would remove"
    The output should include "A/B"
    The path "$RIP_SANDBOX/server/audiobooks/A/B/B.m4b" should be exist
    # A dry run may LOOK the book up, but must never ask ABS to delete it.
    The contents of file "$RIP_SANDBOX/absbin.log" should not include "--delete-item"
  End

  It 'retire: --apply removes the files and deletes the ABS item'
    fake_abs_ops_bin
    mkdir -p "$RIP_SANDBOX/server/audiobooks/A/B"
    printf 'x\n' > "$RIP_SANDBOX/server/audiobooks/A/B/B.m4b"
    When run zsh -c "source $RIPLIB && rip::ab_retire 'A/B' --apply"
    The status should equal 0
    The output should include "retired A/B"
    The path "$RIP_SANDBOX/server/audiobooks/A/B" should not be exist
    The contents of file "$RIP_SANDBOX/absbin.log" should include "--delete-item item-1"
  End

  # CLAIM ONLY WHAT ACTUALLY HAPPENED (review finding 3A, 2026-08-24). The
  # ABS delete's failure used to be warned about and then followed,
  # unconditionally, by "rip: retired $rel" and rc 0 — files gone, item
  # alive, stdout announcing a clean retire. That is exactly the
  # half-retired state this function's header resolves the item early to
  # avoid (Audiobookshelf keeps an item whose files vanished and marks it
  # missing; a rescan does not drop it), reported as a success. This is the
  # most destructive verb in the module.
  It 'retire: a failed ABS item delete is reported as such, never as a completed retire'
    cat > "$RIP_BIN_DIR/rip-abs-authors" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$RIP_SANDBOX/absbin.log"
case "\$1" in
  --find-item) echo item-1 ;;
  --delete-item) exit 1 ;;
esac
exit 0
EOF
    chmod +x "$RIP_BIN_DIR/rip-abs-authors"
    mkdir -p "$RIP_SANDBOX/server/audiobooks/A/B"
    printf 'x\n' > "$RIP_SANDBOX/server/audiobooks/A/B/B.m4b"
    When run zsh -c "source $RIPLIB && rip::ab_retire 'A/B' --apply"
    The status should equal 1
    The output should not include "retired A/B"
    The stderr should include "could NOT be deleted"
    The stderr should include "item-1"
    # The delete WAS attempted, and the files really are gone — the point is
    # that the message and the rc tell the truth about what remains.
    The contents of file "$RIP_SANDBOX/absbin.log" should include "--delete-item item-1"
    The path "$RIP_SANDBOX/server/audiobooks/A/B" should not be exist
  End

  # A book the server does not hold is NOT a book whose files we may guess
  # at. Membership is tested against rip::ab_server_library — the server's
  # own listing — not against a guessed "<Title>/<Title>.m4b", which is only
  # Libation's naming convention: a manually imported book carries whatever
  # filename it was given and would otherwise read as "not stored" forever.
  It 'retire: refuses a path the server does not hold'
    fake_abs_ops_bin
    When run zsh -c "source $RIPLIB && rip::ab_retire 'No/Such' --apply"
    The status should equal 2
    The stderr should include "not stored"
    # Refused before ABS was touched at all.
    The path "$RIP_SANDBOX/absbin.log" should not be exist
  End

  # An unreachable server must refuse, never guess: rip::ab_server_library
  # returns 2 and prints nothing, so membership cannot be established and
  # nothing is deleted.
  It 'retire: an unreachable server refuses rather than guessing'
    fake_abs_ops_bin
    export RIP_REMOTE_BASE="fakehost:/srv/media"
    cat > "$RIP_SANDBOX/ssh" <<'EOF'
#!/bin/sh
exit 255
EOF
    chmod +x "$RIP_SANDBOX/ssh"
    export RIP_SSH_BIN="$RIP_SANDBOX/ssh"
    When run zsh -c "source $RIPLIB && rip::ab_retire 'A/B' --apply"
    The status should equal 2
    The stderr should include "not stored"
    The path "$RIP_SANDBOX/absbin.log" should not be exist
  End

  # THE ordering invariant. Audiobookshelf keeps an item whose files have
  # vanished and marks it "missing" — a rescan does not drop it — so a
  # half-retired book (files gone, item present) is worse than one left
  # alone. The item is resolved BEFORE anything is deleted, and an
  # unresolvable item refuses and touches nothing.
  It 'retire: refuses when the ABS item cannot be resolved, leaving files intact'
    fake_abs_ops_bin
    mkdir -p "$RIP_SANDBOX/server/audiobooks/A/Orphan"
    printf 'x\n' > "$RIP_SANDBOX/server/audiobooks/A/Orphan/Orphan.m4b"
    When run zsh -c "source $RIPLIB && rip::ab_retire 'A/Orphan' --apply"
    The status should equal 2
    The stderr should include "could not resolve"
    The path "$RIP_SANDBOX/server/audiobooks/A/Orphan/Orphan.m4b" should be exist
    The contents of file "$RIP_SANDBOX/absbin.log" should not include "--delete-item"
  End

  It 'sweep: dry-run reports the collision and changes nothing'
    fake_abs_ops_bin
    mkdir -p "$RIP_SANDBOX/server/audiobooks/J. R. R. Tolkien/Two Towers" \
             "$RIP_SANDBOX/server/audiobooks/J.R.R. Tolkien/The Hobbit"
    When run zsh -c "source $RIPLIB && rip::ab_canonicalize_authors"
    The status should equal 0
    The output should include "J.R.R. Tolkien"
    The output should include "J. R. R. Tolkien"
    The path "$RIP_SANDBOX/server/audiobooks/J.R.R. Tolkien/The Hobbit" should be exist
    The path "$RIP_SANDBOX/absbin.log" should not be exist
  End

  # Renaming the folder is NOT enough for Audiobookshelf: it matches the
  # moved item by inode and updates its path, but keeps the item's STORED
  # author, so the split survives in its database until the item is
  # repointed (verified live 2026-08-23). Move, then repoint, then delete
  # the emptied author record.
  It 'sweep: --apply moves the book, repoints the ABS item and deletes the emptied author'
    fake_abs_ops_bin
    mkdir -p "$RIP_SANDBOX/server/audiobooks/J. R. R. Tolkien/Two Towers" \
             "$RIP_SANDBOX/server/audiobooks/J.R.R. Tolkien/The Hobbit"
    When run zsh -c "source $RIPLIB && rip::ab_canonicalize_authors --apply"
    The status should equal 0
    The output should include "author variants"
    The output should include "J.R.R. Tolkien"
    The path "$RIP_SANDBOX/server/audiobooks/J. R. R. Tolkien/The Hobbit" should be exist
    The path "$RIP_SANDBOX/server/audiobooks/J.R.R. Tolkien" should not be exist
    The contents of file "$RIP_SANDBOX/absbin.log" should include "--repoint-item"
    The contents of file "$RIP_SANDBOX/absbin.log" should include "--delete-author"
  End

  It 'sweep: a library with no collisions reports nothing to do'
    fake_abs_ops_bin
    mkdir -p "$RIP_SANDBOX/server/audiobooks/Ann Leckie/Ancillary Justice"
    When run zsh -c "source $RIPLIB && rip::ab_canonicalize_authors"
    The status should equal 0
    The output should include "nothing to do"
  End

  It 'CLI: --retire and --canonicalize-authors are wired and dry-run by default'
    fake_abs_ops_bin
    mkdir -p "$RIP_SANDBOX/server/audiobooks/A/B"
    printf 'x\n' > "$RIP_SANDBOX/server/audiobooks/A/B/B.m4b"
    When run zsh "$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_rip-audiobook" --retire "A/B"
    The status should equal 0
    The output should include "would remove"
    The path "$RIP_SANDBOX/server/audiobooks/A/B/B.m4b" should be exist
  End

  # --- the sweep's ssh branch (review findings 1-3, 2026-08-24) -------------
  #
  # Every sweep example above runs the plain-local-dir branch, which is why
  # three defects lived in the ssh and failure paths unnoticed. These
  # exercise the branch the real server actually takes.
  #
  # fake_ssh_server — a fake ssh that behaves like the real one in the two
  # ways that matter here:
  #   1. IT READS STDIN. Real ssh does, and that is the whole of finding 1:
  #      an ssh reached from inside a `while read … done <<< "$variants"`
  #      loop swallows the remaining variants. A fake that ignores stdin
  #      cannot reproduce the bug, so the regression guard would be
  #      worthless. Guarded by `[ -t 0 ]` so an interactive shellspec run
  #      cannot hang on a terminal.
  #   2. It RUNS the command it is given, against the sandbox, after
  #      rewriting the remote root — so the ${(q)} quoting, the `mv -n`
  #      no-clobber semantics and `rmdir`'s exit status are all the real
  #      ones, not a mock's opinion of them.
  fake_ssh_server() {
    cat > "$RIP_SANDBOX/ssh" <<EOF
#!/bin/sh
[ -t 0 ] || cat > /dev/null
printf '%s\n' "\$*" >> "$RIP_SANDBOX/ssh.log"
cmd=""
while [ \$# -gt 0 ]; do cmd="\$1"; shift; done
sh -c "\$(printf '%s' "\$cmd" | sed 's|/srv/media|$RIP_SANDBOX/server|g')"
EOF
    chmod +x "$RIP_SANDBOX/ssh"
    export RIP_SSH_BIN="$RIP_SANDBOX/ssh"
    export RIP_REMOTE_BASE="media@cantina:/srv/media"
  }

  # fake_abs_ops_bin_any — resolves every --find-item and --author-id, so an
  # example can assert on WHICH destructive verbs were issued rather than on
  # a lookup failing.
  fake_abs_ops_bin_any() {
    cat > "$RIP_BIN_DIR/rip-abs-authors" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$RIP_SANDBOX/absbin.log"
case "\$1" in
  --find-item) echo item-x ;;
  --author-id) echo auth-x ;;
esac
exit 0
EOF
    chmod +x "$RIP_BIN_DIR/rip-abs-authors"
  }

  # FINDING 1 regression guard. Four spellings of one author: the plan lists
  # three variants, and every one of them must actually be swept. Against
  # the pre-fix code the first ssh drains the here-string and exactly ONE
  # variant is processed — silently, rc 0, no warning.
  It 'sweep (ssh): every variant in a group is swept, not just the first'
    fake_abs_ops_bin_any
    fake_ssh_server
    mkdir -p "$RIP_SANDBOX/server/audiobooks/J. R. R. Tolkien/Two Towers" \
             "$RIP_SANDBOX/server/audiobooks/J. R. R. Tolkien/Return of the King" \
             "$RIP_SANDBOX/server/audiobooks/J.R.R. Tolkien/The Hobbit" \
             "$RIP_SANDBOX/server/audiobooks/J R R Tolkien/Leaf by Niggle" \
             "$RIP_SANDBOX/server/audiobooks/JRR Tolkien/Farmer Giles"
    When run zsh -c "source $RIPLIB && rip::ab_canonicalize_authors --apply"
    The status should equal 0
    The output should include "author variants"
    The path "$RIP_SANDBOX/server/audiobooks/J. R. R. Tolkien/The Hobbit" should be exist
    The path "$RIP_SANDBOX/server/audiobooks/J. R. R. Tolkien/Leaf by Niggle" should be exist
    The path "$RIP_SANDBOX/server/audiobooks/J. R. R. Tolkien/Farmer Giles" should be exist
    The path "$RIP_SANDBOX/server/audiobooks/J.R.R. Tolkien" should not be exist
    The path "$RIP_SANDBOX/server/audiobooks/J R R Tolkien" should not be exist
    The path "$RIP_SANDBOX/server/audiobooks/JRR Tolkien" should not be exist
  End

  # FINDING 2. `mv -n` exits 0 when it REFUSES, so a same-title collision
  # leaves the book under the old spelling while every command reports
  # success. Deleting the variant's author record there would leave the
  # library asserting something false: book present, its item still storing
  # the variant spelling, and the record that spelling pointed at gone.
  # Audio is never at risk — mv -n and rmdir both refuse correctly — but the
  # ABS record must survive too.
  It 'sweep (ssh): a same-title collision keeps the book AND its author record'
    fake_abs_ops_bin_any
    fake_ssh_server
    mkdir -p "$RIP_SANDBOX/server/audiobooks/J. R. R. Tolkien/The Hobbit" \
             "$RIP_SANDBOX/server/audiobooks/J.R.R. Tolkien/The Hobbit"
    printf 'canon\n' > "$RIP_SANDBOX/server/audiobooks/J. R. R. Tolkien/The Hobbit/h.m4b"
    printf 'variant\n' > "$RIP_SANDBOX/server/audiobooks/J.R.R. Tolkien/The Hobbit/h.m4b"
    When run zsh -c "source $RIPLIB && rip::ab_canonicalize_authors --apply"
    The status should equal 1
    The output should include "author variants"
    The stderr should include "still holds books"
    # The only copy of the variant's audio is untouched, and unchanged.
    The contents of file "$RIP_SANDBOX/server/audiobooks/J.R.R. Tolkien/The Hobbit/h.m4b" should equal "variant"
    The contents of file "$RIP_SANDBOX/server/audiobooks/J. R. R. Tolkien/The Hobbit/h.m4b" should equal "canon"
    # …and the author record it still points at was NOT deleted.
    The contents of file "$RIP_SANDBOX/absbin.log" should not include "--delete-author"
  End

  # FINDING 2, second reachable path: the books move, but the canonical
  # author cannot be resolved, so nothing gets repointed. Deleting the
  # variant record then strands every moved item on a record that no longer
  # exists.
  # AMENDED 2026-08-26 (coordinator ruling). The record is still kept — items
  # Audiobookshelf knows still name the variant, and deleting it would strand
  # them — but the exit status is no longer 1. "There is no author record to
  # repoint to" is an outcome, not an error: nothing failed, the books moved
  # and the path is correct. This example used to assert rc 1 and the
  # "could not be repointed" wording, both of which belonged to the OTHER
  # branch (a repoint that was attempted and refused).
  It 'sweep (ssh): an unresolvable canonical author keeps the variant record, without failing'
    fake_ssh_server
    cat > "$RIP_BIN_DIR/rip-abs-authors" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$RIP_SANDBOX/absbin.log"
case "\$1" in
  --find-item) echo item-x ;;
  --author-id) case "\$2" in "J. R. R. Tolkien") exit 1 ;; *) echo auth-x ;; esac ;;
esac
exit 0
EOF
    chmod +x "$RIP_BIN_DIR/rip-abs-authors"
    mkdir -p "$RIP_SANDBOX/server/audiobooks/J. R. R. Tolkien/Two Towers" \
             "$RIP_SANDBOX/server/audiobooks/J.R.R. Tolkien/The Hobbit"
    When run zsh -c "source $RIPLIB && rip::ab_canonicalize_authors --apply"
    The status should equal 0
    The output should include "author variants"
    The stderr should include "still name it in Audiobookshelf"
    # NOT the wording of a genuine failure.
    The stderr should not include "could not be repointed"
    The path "$RIP_SANDBOX/server/audiobooks/J. R. R. Tolkien/The Hobbit" should be exist
    The contents of file "$RIP_SANDBOX/absbin.log" should not include "--delete-author"
  End

  # FINDING 3. An unreachable server must refuse, not assert a clean
  # library: stderr alone is invisible to a wrapper or a cron job checking
  # the exit status.
  It 'sweep: an unreachable server refuses instead of claiming a clean library'
    fake_abs_ops_bin_any
    export RIP_REMOTE_BASE="media@cantina:/srv/media"
    cat > "$RIP_SANDBOX/ssh" <<'EOF'
#!/bin/sh
exit 255
EOF
    chmod +x "$RIP_SANDBOX/ssh"
    export RIP_SSH_BIN="$RIP_SANDBOX/ssh"
    When run zsh -c "source $RIPLIB && rip::ab_canonicalize_authors"
    The status should equal 2
    The output should not include "nothing to do"
    The stderr should include "could not list the audiobook library"
    The path "$RIP_SANDBOX/absbin.log" should not be exist
  End

  # FINDING (round 2). `rmdir` failing is NOT the same fact as "books remain".
  # rip::ab_server_library lists only depth-2 DIRECTORIES, so a stray
  # .DS_Store — reachable through any Finder mount of the share — sits
  # directly under the author folder, defeats `rmdir` after every book has
  # already moved, and made the sweep warn something untrue. It also drops
  # the variant out of the listing for good (nothing at depth 2 any more),
  # so a kept author record would be unreachable by every future sweep.
  # The record is therefore removed once no books remain, and the leftover
  # directory is named rather than misdescribed.
  It 'sweep (ssh): a stray .DS_Store is reported accurately, not as "still holds books"'
    fake_abs_ops_bin_any
    fake_ssh_server
    mkdir -p "$RIP_SANDBOX/server/audiobooks/J. R. R. Tolkien/Two Towers" \
             "$RIP_SANDBOX/server/audiobooks/J.R.R. Tolkien/The Hobbit"
    printf 'x\n' > "$RIP_SANDBOX/server/audiobooks/J.R.R. Tolkien/.DS_Store"
    When run zsh -c "source $RIPLIB && rip::ab_canonicalize_authors --apply"
    # Not a clean sweep: a directory is left behind for the operator.
    The status should equal 1
    The output should include "author variants"
    # The book really did move.
    The path "$RIP_SANDBOX/server/audiobooks/J. R. R. Tolkien/The Hobbit" should be exist
    The path "$RIP_SANDBOX/server/audiobooks/J.R.R. Tolkien/The Hobbit" should not be exist
    # The message states what is actually true…
    The stderr should include "holds no books but is not empty"
    The stderr should include "left the directory for you to clean up"
    # …and never the falsehood.
    The stderr should not include "still holds books"
    # The bookless author record is removed — the variant will never appear in
    # the server listing again, so this is the last chance to reach it.
    The contents of file "$RIP_SANDBOX/absbin.log" should include "--delete-author"
    # The leftover is left alone, not deleted blind.
    The path "$RIP_SANDBOX/server/audiobooks/J.R.R. Tolkien/.DS_Store" should be exist
  End

  # FINDING (round 3). The state-11 branch announced a deletion that may
  # never have occurred: $stale can be empty (the id never resolved), and
  # --delete-author's own exit status was discarded. Both are PERMANENT
  # here — by this point the variant has left rip::ab_server_library's
  # listing, so no future sweep will ever see this author again — which is
  # precisely the artifact the state-11 branch exists to prevent, and
  # claiming success would hide it.

  It 'sweep (ssh): an unresolvable variant author id is reported, never claimed as removed'
    fake_ssh_server
    cat > "$RIP_BIN_DIR/rip-abs-authors" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$RIP_SANDBOX/absbin.log"
case "\$1" in
  --find-item) echo item-x ;;
  --author-id) case "\$2" in "J.R.R. Tolkien") exit 1 ;; *) echo auth-canon ;; esac ;;
esac
exit 0
EOF
    chmod +x "$RIP_BIN_DIR/rip-abs-authors"
    mkdir -p "$RIP_SANDBOX/server/audiobooks/J. R. R. Tolkien/Two Towers" \
             "$RIP_SANDBOX/server/audiobooks/J.R.R. Tolkien/The Hobbit"
    printf 'x\n' > "$RIP_SANDBOX/server/audiobooks/J.R.R. Tolkien/.DS_Store"
    When run zsh -c "source $RIPLIB && rip::ab_canonicalize_authors --apply"
    The status should equal 1
    The output should include "author variants"
    # The book still moved and was repointed — only the record is unaccounted for.
    The path "$RIP_SANDBOX/server/audiobooks/J. R. R. Tolkien/The Hobbit" should be exist
    The stderr should include "could not resolve its Audiobookshelf author record"
    The stderr should include "no future sweep will see"
    # …and NOT the claim that it was removed.
    The stderr should not include "removed its Audiobookshelf author record"
    The contents of file "$RIP_SANDBOX/absbin.log" should not include "--delete-author"
  End

  It 'sweep (ssh): a --delete-author that fails is reported, never claimed as removed'
    fake_ssh_server
    cat > "$RIP_BIN_DIR/rip-abs-authors" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$RIP_SANDBOX/absbin.log"
case "\$1" in
  --find-item) echo item-x ;;
  --author-id) echo auth-x ;;
  --delete-author) exit 4 ;;
esac
exit 0
EOF
    chmod +x "$RIP_BIN_DIR/rip-abs-authors"
    mkdir -p "$RIP_SANDBOX/server/audiobooks/J. R. R. Tolkien/Two Towers" \
             "$RIP_SANDBOX/server/audiobooks/J.R.R. Tolkien/The Hobbit"
    printf 'x\n' > "$RIP_SANDBOX/server/audiobooks/J.R.R. Tolkien/.DS_Store"
    When run zsh -c "source $RIPLIB && rip::ab_canonicalize_authors --apply"
    The status should equal 1
    The output should include "author variants"
    The stderr should include "could not remove its Audiobookshelf author record"
    The stderr should include "remove it in the Audiobookshelf UI"
    The stderr should not include "removed its Audiobookshelf author record"
    # It WAS attempted — this is a real failure, not a skipped call.
    The contents of file "$RIP_SANDBOX/absbin.log" should include "--delete-author"
  End

  # The same exposure on the state-0 path: the variant directory is gone
  # entirely, so a record that failed to delete is just as unreachable. A
  # silent rc 0 there would be the same false success.
  It 'sweep (ssh): a fully-swept variant whose record will not delete still reports it'
    fake_ssh_server
    cat > "$RIP_BIN_DIR/rip-abs-authors" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$RIP_SANDBOX/absbin.log"
case "\$1" in
  --find-item) echo item-x ;;
  --author-id) echo auth-x ;;
  --delete-author) exit 4 ;;
esac
exit 0
EOF
    chmod +x "$RIP_BIN_DIR/rip-abs-authors"
    mkdir -p "$RIP_SANDBOX/server/audiobooks/J. R. R. Tolkien/Two Towers" \
             "$RIP_SANDBOX/server/audiobooks/J.R.R. Tolkien/The Hobbit"
    When run zsh -c "source $RIPLIB && rip::ab_canonicalize_authors --apply"
    The status should equal 1
    The output should include "author variants"
    # The sweep itself worked: the book moved and the variant folder is gone.
    The path "$RIP_SANDBOX/server/audiobooks/J. R. R. Tolkien/The Hobbit" should be exist
    The path "$RIP_SANDBOX/server/audiobooks/J.R.R. Tolkien" should not be exist
    The stderr should include "could not remove its Audiobookshelf author record"
    The stderr should include "no future sweep will see"
  End

  # --- the canonical initials form (Task 5, 2026-08-26) --------------------
  #
  # The sweep used to act ONLY on collisions, so a library holding exactly
  # ONE spelling of "J.K. Rowling" — the operator's, across seven Harry
  # Potter books — printed "nothing to do" and exited 0. `--retag` mirrors
  # whatever the PATH says into the audio, so leaving the path uncanonical
  # bakes the wrong author into every one of those files and repairing it
  # afterwards costs a second full-library remux of ~248 multi-gigabyte
  # files. The canonical form has to reach the PATH first, which is what
  # these examples pin.

  # ca_book <Author/Title> <sidecar-author> — a stored book with audio and a
  # schema-shaped sidecar. TWO authors deliberately: the sweep re-spells
  # authors[0] and must leave every other field, authors[1] included, alone.
  # Written with jq's default PRETTY printer, which is also what makes the
  # byte-comparisons below discriminate: anything that rewrites this file
  # emits compact JSON, so "unchanged" cannot be faked by a rewrite that
  # happens to preserve the values.
  ca_book() {
    mkdir -p "$RIP_SANDBOX/server/audiobooks/$1"
    printf 'audio-%s\n' "$1" > "$RIP_SANDBOX/server/audiobooks/$1/${1##*/}.m4b"
    jq -n --arg t "${1##*/}" --arg a "$2" \
      '{schema:1,kind:"audiobook",title:$t,subtitle:null,
        authors:[$a,"Second Author"],narrators:["N"],series:null,
        duration_s:1,language:"english",abridged:false,
        published:"2000-01-01T00:00:00",ids:{"audible.asin":"B0CA000001"},
        work:null,
        source:{provider:"libation",provider_version:"13",acquired_utc:null,format:"m4b"}}' \
      > "$RIP_SANDBOX/server/audiobooks/$1/.fleet-book.json"
  }

  # ca_tree — every path under the served tree, each file with the sha256 of
  # its CONTENTS. "The dry run wrote nothing" is only proved by comparing
  # paths AND bytes: a comparison of paths alone passes against a sweep that
  # rewrote every sidecar in place, and re-reading a field passes against a
  # rewrite that happened to preserve it.
  ca_tree() {
    ( cd "$RIP_SANDBOX/server" && find . | LC_ALL=C sort | while IFS= read -r p; do
        if [ -f "$p" ]; then
          printf '%s\t%s\n' "$p" "$(shasum -a 256 < "$p" | cut -d' ' -f1)"
        else
          printf '%s\tDIR\n' "$p"
        fi
      done )
  }
  ca_snap_tree() { ca_tree > "$RIP_SANDBOX/tree.before"; }
  ca_tree_unchanged() {
    ca_tree > "$RIP_SANDBOX/tree.after"
    if cmp -s "$RIP_SANDBOX/tree.before" "$RIP_SANDBOX/tree.after"; then
      echo "tree-identical"
    else
      echo "TREE CHANGED"
    fi
  }

  # ca_snap_hallows / ca_hallows_unchanged — the same byte-level guard aimed
  # at ONE file: the sidecar of the book already sitting under the canonical
  # spelling when a same-titled variant tries to merge into it.
  # ca_abs_bin <case-body> — an ABS double whose every verb the example
  # dictates. The WHOLE case body is the argument, with no arm supplied here:
  # an earlier version hardcoded `--find-item) echo item-x ;;` first, which
  # silently SHADOWED an example's own --find-item arm (first match wins in a
  # POSIX case) and left that example passing for the wrong reason. Nothing a
  # fixture supplies may be quietly overridden by the fixture builder.
  ca_abs_bin() {
    {
      printf '#!/bin/sh\n'
      printf 'printf "%%s\\n" "$*" >> "%s/absbin.log"\n' "$RIP_SANDBOX"
      printf 'case "$1" in\n%b\nesac\nexit 0\n' "$1"
    } > "$RIP_BIN_DIR/rip-abs-authors"
    chmod +x "$RIP_BIN_DIR/rip-abs-authors"
  }

  # ca_snap_variant / ca_variant_unchanged — the same guard aimed at the
  # sidecar under the RAW spelling: the file review finding 2 showed --apply
  # rewriting backwards, and review finding F3 showed it rewriting FORWARD
  # into a directory that never moved.
  ca_snap_variant() {
    cp "$RIP_SANDBOX/server/audiobooks/J.K. Rowling/Deathly Hallows/.fleet-book.json" \
       "$RIP_SANDBOX/variant.before"
  }
  ca_variant_unchanged() {
    if cmp -s "$RIP_SANDBOX/variant.before" \
              "$RIP_SANDBOX/server/audiobooks/J.K. Rowling/Deathly Hallows/.fleet-book.json"; then
      echo "byte-identical"
    else
      echo "CHANGED"
    fi
  }

  ca_snap_hallows() {
    cp "$RIP_SANDBOX/server/audiobooks/J. K. Rowling/Deathly Hallows/.fleet-book.json" \
       "$RIP_SANDBOX/hallows.before"
  }
  ca_hallows_unchanged() {
    if cmp -s "$RIP_SANDBOX/hallows.before" \
              "$RIP_SANDBOX/server/audiobooks/J. K. Rowling/Deathly Hallows/.fleet-book.json"; then
      echo "byte-identical"
    else
      echo "CHANGED"
    fi
  }

  # PIN, green before and after this feature by design: the collision rule
  # ran against the operator's real library on 2026-08-23 and must not shift
  # underneath the new one.
  #
  # The fixture makes the two halves of that rule DISAGREE — "Ursula K Le
  # Guin" has more books, "Ursula K. Le Guin" is the longer string — so the
  # example pins their PRECEDENCE: book count decides, length is only the
  # tie-break. Nothing in the suite pinned that before, and a pin whose two
  # candidates agree would pass against a rule with the order reversed.
  # Neither spelling contains a bare initial ("K" carries no letter straight
  # after its period), so the canonical-form rule has nothing to add here and
  # must not disturb the answer.
  It 'sweep: book count still beats string length when picking the canonical spelling (pin)'
    fake_abs_ops_bin_any
    mkdir -p "$RIP_SANDBOX/server/audiobooks/Ursula K Le Guin/A Wizard of Earthsea" \
             "$RIP_SANDBOX/server/audiobooks/Ursula K Le Guin/The Tombs of Atuan" \
             "$RIP_SANDBOX/server/audiobooks/Ursula K. Le Guin/The Farthest Shore"
    When run zsh -c "source $RIPLIB && rip::ab_canonicalize_authors --apply"
    The status should equal 0
    The output should include "author variants"
    The path "$RIP_SANDBOX/server/audiobooks/Ursula K Le Guin/The Farthest Shore" should be exist
    The path "$RIP_SANDBOX/server/audiobooks/Ursula K. Le Guin" should not be exist
  End

  It 'sweep: a lone non-canonical spelling is reported, and the dry run writes nothing'
    fake_abs_ops_bin_any
    ca_book 'J.K. Rowling/Deathly Hallows' 'J.K. Rowling'
    ca_book 'J.K. Rowling/Goblet of Fire' 'J.K. Rowling'
    ca_snap_tree
    When run zsh -c "source $RIPLIB && rip::ab_canonicalize_authors"
    The status should equal 0
    # The canonical form is NOT a substring of the stored one, so this cannot
    # pass on an echo of the input.
    The output should include "J. K. Rowling"
    The output should include '"J.K. Rowling" (2 book(s))'
    The output should include "re-run with --apply"
    The output should not include "nothing to do"
    # Whole tree, paths AND contents.
    The result of function ca_tree_unchanged should equal "tree-identical"
    # …and the snapshot really did hold the library (an empty snapshot would
    # make the comparison above pass against anything).
    The contents of file "$RIP_SANDBOX/tree.before" should include "J.K. Rowling"
    The path "$RIP_SANDBOX/absbin.log" should not be exist
  End

  It 'sweep (ssh): --apply renames a lone non-canonical author, directory and sidecar together'
    fake_abs_ops_bin_any
    fake_server_ssh
    ca_book 'J.K. Rowling/Deathly Hallows' 'J.K. Rowling'
    When run zsh -c "source $RIPLIB && rip::ab_canonicalize_authors --apply"
    The status should equal 0
    The path "$RIP_SANDBOX/server/audiobooks/J. K. Rowling/Deathly Hallows/Deathly Hallows.m4b" should be exist
    The path "$RIP_SANDBOX/server/audiobooks/J.K. Rowling" should not be exist
    # The sidecar moved WITH the directory — authors[0] re-spelled, authors[1]
    # untouched. --retag compares tags against the PATH, so a library whose
    # sidecar and path disagree is internally inconsistent.
    The contents of file "$RIP_SANDBOX/server/audiobooks/J. K. Rowling/Deathly Hallows/.fleet-book.json" should include '"authors":["J. K. Rowling","Second Author"]'
    # Identity survives the rewrite: this is the only copy of who the book is.
    The contents of file "$RIP_SANDBOX/server/audiobooks/J. K. Rowling/Deathly Hallows/.fleet-book.json" should include '"audible.asin":"B0CA000001"'
    # `_path` is rip::_server_sidecars' annotation, never a schema field.
    The contents of file "$RIP_SANDBOX/server/audiobooks/J. K. Rowling/Deathly Hallows/.fleet-book.json" should not include "_path"
    The output should include "re-spelled 1 of 1"
    # cantina has no jq: nothing the server was asked to run may mention it.
    The result of function ssh_cmds should not include "jq"
  End

  It 'sweep: an already-canonical author is left byte-for-byte identical'
    fake_abs_ops_bin_any
    ca_book 'J. K. Rowling/Deathly Hallows' 'J. K. Rowling'
    ca_snap_tree
    When run zsh -c "source $RIPLIB && rip::ab_canonicalize_authors --apply"
    The status should equal 0
    The output should include "nothing to do"
    The result of function ca_tree_unchanged should equal "tree-identical"
    The contents of file "$RIP_SANDBOX/tree.before" should include "J. K. Rowling"
    The path "$RIP_SANDBOX/absbin.log" should not be exist
  End

  It 'sweep (ssh): a second --apply has nothing left to do and changes nothing'
    fake_abs_ops_bin_any
    fake_server_ssh
    ca_book 'J.K. Rowling/Deathly Hallows' 'J.K. Rowling'
    zsh -c "source $RIPLIB && rip::ab_canonicalize_authors --apply" >/dev/null 2>&1
    ca_snap_tree
    When run zsh -c "source $RIPLIB && rip::ab_canonicalize_authors --apply"
    The status should equal 0
    The output should include "nothing to do"
    The result of function ca_tree_unchanged should equal "tree-identical"
    # The first pass really did converge — without this the example would
    # pass against a sweep that never renamed anything at all.
    The contents of file "$RIP_SANDBOX/tree.before" should include "J. K. Rowling"
    The contents of file "$RIP_SANDBOX/tree.before" should not include "./audiobooks/J.K. Rowling"
  End

  # THE MERGE THE NEW RULE CREATES. Canonicalizing sends a variant into a
  # directory that already exists, and the destination is chosen by the
  # canonical FORM even though the raw spelling holds more books — which is
  # exactly the case the old "most books" rule alone would have decided the
  # other way.
  It 'sweep (ssh): the canonical form wins over the more populous raw spelling and merges into it'
    fake_abs_ops_bin_any
    fake_server_ssh
    ca_book 'J.K. Rowling/Deathly Hallows' 'J.K. Rowling'
    ca_book 'J.K. Rowling/Goblet of Fire' 'J.K. Rowling'
    ca_book 'J. K. Rowling/Order of the Phoenix' 'J. K. Rowling'
    When run zsh -c "source $RIPLIB && rip::ab_canonicalize_authors --apply"
    The status should equal 0
    The path "$RIP_SANDBOX/server/audiobooks/J. K. Rowling/Deathly Hallows/Deathly Hallows.m4b" should be exist
    The path "$RIP_SANDBOX/server/audiobooks/J. K. Rowling/Goblet of Fire/Goblet of Fire.m4b" should be exist
    The path "$RIP_SANDBOX/server/audiobooks/J. K. Rowling/Order of the Phoenix/Order of the Phoenix.m4b" should be exist
    The path "$RIP_SANDBOX/server/audiobooks/J.K. Rowling" should not be exist
    # Exactly the two that needed it, and no more.
    The output should include "re-spelled 2 of 2"
  End

  # THE MOST LIKELY WAY THIS TASK DAMAGES A REAL LIBRARY: the destination
  # directory already holds a book of the SAME title. `mv -n` refuses, the
  # variant's book stays where it is, `rmdir` refuses, and the sweep says so
  # and returns 1 — the only copy of an audiobook is never overwritten to
  # tidy a folder name. The sidecar half must refuse in step: writing the
  # variant's corrected sidecar to the destination path would land it on top
  # of a DIFFERENT book's identity file.
  It 'sweep (ssh): a title already present under the canonical spelling is never clobbered'
    fake_abs_ops_bin_any
    fake_server_ssh
    ca_book 'J.K. Rowling/Deathly Hallows' 'J.K. Rowling'
    ca_book 'J.K. Rowling/Goblet of Fire' 'J.K. Rowling'
    ca_book 'J. K. Rowling/Deathly Hallows' 'J. K. Rowling'
    printf 'variant-copy\n' > "$RIP_SANDBOX/server/audiobooks/J.K. Rowling/Deathly Hallows/Deathly Hallows.m4b"
    printf 'canonical-copy\n' > "$RIP_SANDBOX/server/audiobooks/J. K. Rowling/Deathly Hallows/Deathly Hallows.m4b"
    ca_snap_hallows
    ca_snap_variant
    When run zsh -c "source $RIPLIB && rip::ab_canonicalize_authors --apply"
    The status should equal 1
    The stderr should include "still holds books"
    # Neither copy of the audio moved or changed.
    The contents of file "$RIP_SANDBOX/server/audiobooks/J. K. Rowling/Deathly Hallows/Deathly Hallows.m4b" should equal "canonical-copy"
    The contents of file "$RIP_SANDBOX/server/audiobooks/J.K. Rowling/Deathly Hallows/Deathly Hallows.m4b" should equal "variant-copy"
    # The resident book's identity file was not written over.
    The result of function ca_hallows_unchanged should equal "byte-identical"
    # The refused book's OWN sidecar is left exactly as it was: it still sits
    # under the RAW directory, so writing the canonical spelling into it would
    # leave the sidecar naming an author its own directory does not have —
    # permanently, since a later --apply would then find them equal and skip
    # it forever (review finding F3, 2026-08-26). It is named as left alone
    # instead, and never counted.
    The result of function ca_variant_unchanged should equal "byte-identical"
    The contents of file "$RIP_SANDBOX/server/audiobooks/J.K. Rowling/Deathly Hallows/.fleet-book.json" should include '"J.K. Rowling"'
    The output should include "left alone: J.K. Rowling/Deathly Hallows did not move"
    # The refusal is described accurately. (The false "moved" CLAIM needs a
    # downstream message to ride on, so it is pinned in its own example
    # below, where one actually fires.)
    The stderr should include 'is already stored under "J. K. Rowling"'
    # The book that COULD move did, sidecar and all.
    The path "$RIP_SANDBOX/server/audiobooks/J. K. Rowling/Goblet of Fire/Goblet of Fire.m4b" should be exist
    The contents of file "$RIP_SANDBOX/server/audiobooks/J. K. Rowling/Goblet of Fire/.fleet-book.json" should include '"authors":["J. K. Rowling","Second Author"]'
    # Counted: one written, and the refused one is NOT in the denominator.
    The output should include "re-spelled 1 of 1"
    # …and the variant's Audiobookshelf author record survives, because a
    # book still points at it.
    The contents of file "$RIP_SANDBOX/absbin.log" should not include "--delete-author"
  End

  # REVIEW FINDING F4 (2026-08-26), the same root as F3. This function's own
  # header records that `mv -n` exits 0 when it REFUSES — and every line
  # downstream then described a book that had not moved. With --find-item
  # missing, the refused book got "moved Deathly Hallows, but Audiobookshelf
  # does not know this book yet" while it sat, untouched, in the variant
  # directory. That is this subsystem's recurring defect in a new message: a
  # verdict reached because control got here, not because anything
  # established it. The source's absence is now tested in the same
  # round-trip.
  #
  # This is also the example that exercises the whole refusal path at once:
  # sidecar untouched, warning accurate, author record kept.
  It 'sweep (ssh): a refused move is never described as a move'
    fake_server_ssh
    ca_abs_bin '  --find-item) exit 1 ;;\n  --author-id) echo auth-x ;;'
    ca_book 'J.K. Rowling/Deathly Hallows' 'J.K. Rowling'
    ca_book 'J. K. Rowling/Deathly Hallows' 'J. K. Rowling'
    ca_snap_variant
    When run zsh -c "source $RIPLIB && rip::ab_canonicalize_authors --apply"
    The status should equal 1
    # THE CLAIM. Nothing may say this book moved.
    The stderr should not include "moved Deathly Hallows"
    # What is true, said instead.
    The stderr should include 'is already stored under "J. K. Rowling"'
    The stderr should include "still holds books"
    # Sidecar untouched — bytes, not wording.
    The result of function ca_variant_unchanged should equal "byte-identical"
    # Author record kept: a book still names it.
    The contents of file "$RIP_SANDBOX/absbin.log" should not include "--delete-author"
  End

  # COUNTS NEVER OVERSTATE. rip::_sidecars_write reports ok/fail per book so
  # the caller can count what LANDED; a count of what was attempted would
  # claim a repair that never happened and leave the path and the sidecar
  # disagreeing with nothing said about it.
  #
  # "Order of the Phoenix" is already under the canonical spelling, so it is
  # never renamed — only its sidecar is wrong — and a read-only book
  # directory therefore fails the WRITE without also failing a move. (The
  # first shape of this example chmod'd a directory that then had to be
  # renamed: moving a directory to a new parent needs write permission on the
  # directory itself, because its `..` entry is rewritten, so it failed at
  # `mv` instead and proved nothing about the count.)
  It 'sweep (ssh): a sidecar that could not be written is never counted as re-spelled'
    fake_abs_ops_bin_any
    fake_server_ssh
    ca_book 'J.K. Rowling/Deathly Hallows' 'J.K. Rowling'
    ca_book 'J. K. Rowling/Order of the Phoenix' 'J.K. Rowling'
    chmod 500 "$RIP_SANDBOX/server/audiobooks/J. K. Rowling/Order of the Phoenix"
    When run zsh -c "source $RIPLIB && rip::ab_canonicalize_authors --apply"
    chmod 700 "$RIP_SANDBOX/server/audiobooks/J. K. Rowling/Order of the Phoenix" 2>/dev/null
    The status should equal 1
    The output should include "re-spelled 1 of 2"
    The stderr should include "could not be re-spelled"
    # The one that DID land is real…
    The contents of file "$RIP_SANDBOX/server/audiobooks/J. K. Rowling/Deathly Hallows/.fleet-book.json" should include '"authors":["J. K. Rowling","Second Author"]'
    # …and the one that did not still says the old spelling, untouched.
    The contents of file "$RIP_SANDBOX/server/audiobooks/J. K. Rowling/Order of the Phoenix/.fleet-book.json" should include '"J.K. Rowling"'
  End

  # rip::_server_sidecars' status is CAPTURED, never read through
  # `< <(...)`. This same file already learned that once: a sweep printed
  # "nothing to backfill" and exited 0 on a dropped VPN. Here the library
  # listing succeeds and only the sidecar enumeration fails, so the verb
  # would otherwise sail past it with an empty index and a clean report.
  It 'sweep: a sidecar enumeration that fails refuses rather than reporting a clean library'
    fake_abs_ops_bin_any
    export RIP_REMOTE_BASE="media@cantina:/srv/media"
    cat > "$RIP_SANDBOX/ssh" <<EOF
#!/bin/sh
[ -t 0 ] || cat > /dev/null
cmd=""
while [ \$# -gt 0 ]; do cmd="\$1"; shift; done
case "\$cmd" in *fleet-book.json*) exit 255 ;; esac
sh -c "\$(printf '%s' "\$cmd" | sed 's|/srv/media|$RIP_SANDBOX/server|g')"
EOF
    chmod +x "$RIP_SANDBOX/ssh"
    export RIP_SSH_BIN="$RIP_SANDBOX/ssh"
    mkdir -p "$RIP_SANDBOX/server/audiobooks/Ann Leckie/Ancillary Justice"
    When run zsh -c "source $RIPLIB && rip::ab_canonicalize_authors"
    The status should equal 2
    The output should not include "nothing to do"
    The stderr should include "could not read the stored sidecars"
  End

  # A sidecar naming a DIFFERENT person is not a spelling variant. The guard
  # is rip::_author_norm equality, the same comparison key the collision rule
  # uses — anything else and this sweep would quietly rewrite a pen name.
  It 'sweep: a sidecar author who is a different person is left alone'
    fake_abs_ops_bin_any
    ca_book 'J. K. Rowling/Deathly Hallows' 'Robert Galbraith'
    ca_snap_tree
    When run zsh -c "source $RIPLIB && rip::ab_canonicalize_authors --apply"
    The status should equal 0
    The output should include "nothing to do"
    The result of function ca_tree_unchanged should equal "tree-identical"
    The contents of file "$RIP_SANDBOX/tree.before" should include "J. K. Rowling"
  End

  # --- "nothing to repoint" vs "the repoint failed" (coordinator ruling,
  # 2026-08-26) ------------------------------------------------------------
  #
  # These two used to share one counter, so the ORDINARY case for the
  # canonical-initials rule — a rename into a spelling Audiobookshelf has
  # never seen — exited 1 even though every book moved correctly. Reporting
  # failure for "there was nothing to do here" trains the operator to ignore
  # the exit status. The pair below is what stops them collapsing back
  # together: one asserts rc 0, the other rc 1, and neither passes with the
  # other's wording.

  It 'sweep (ssh): a rename into a spelling Audiobookshelf has never seen is NOT a failure'
    fake_server_ssh
    ca_abs_bin '  --find-item) echo item-x ;;\n  --author-id) case "$2" in "J. K. Rowling") exit 1 ;; *) echo auth-x ;; esac ;;'
    ca_book 'J.K. Rowling/Deathly Hallows' 'J.K. Rowling'
    When run zsh -c "source $RIPLIB && rip::ab_canonicalize_authors --apply"
    # Nothing went wrong. The files are where they should be.
    The status should equal 0
    The path "$RIP_SANDBOX/server/audiobooks/J. K. Rowling/Deathly Hallows/Deathly Hallows.m4b" should be exist
    The path "$RIP_SANDBOX/server/audiobooks/J.K. Rowling" should not be exist
    The contents of file "$RIP_SANDBOX/server/audiobooks/J. K. Rowling/Deathly Hallows/.fleet-book.json" should include '"authors":["J. K. Rowling","Second Author"]'
    # …and the operator is told, in the summary and not only on stderr, that
    # one thing is left for them to do somewhere this verb cannot reach.
    The output should include "renamed on disk but NOT repointed"
    The stderr should include 'has no author record named "J. K. Rowling"'
    The stderr should include "still name it in Audiobookshelf"
    # NOT the wording of a genuine failure.
    The stderr should not include "could not be repointed"
    # There was nothing to repoint TO, so nothing was attempted…
    The contents of file "$RIP_SANDBOX/absbin.log" should not include "--repoint-item"
    # …and the variant's record survives, because items still name it.
    The contents of file "$RIP_SANDBOX/absbin.log" should not include "--delete-author"
  End

  It 'sweep (ssh): a repoint that was attempted and refused is still a failure'
    fake_server_ssh
    ca_abs_bin '  --find-item) echo item-x ;;\n  --author-id) echo auth-x ;;\n  --repoint-item) exit 1 ;;'
    ca_book 'J.K. Rowling/Deathly Hallows' 'J.K. Rowling'
    When run zsh -c "source $RIPLIB && rip::ab_canonicalize_authors --apply"
    The status should equal 1
    The stderr should include "could not repoint its ABS item"
    The stderr should include "could not be repointed"
    # NOT the outcome wording, and NOT the summary line: a real error must
    # never be filed under "there was nothing to do here".
    The stderr should not include "still name it in Audiobookshelf"
    The output should not include "renamed on disk but NOT repointed"
    # It WAS attempted — this is a refusal, not a skipped call…
    The contents of file "$RIP_SANDBOX/absbin.log" should include "--repoint-item"
    # …and the record the un-repointed item still names is kept.
    The contents of file "$RIP_SANDBOX/absbin.log" should not include "--delete-author"
    # The filesystem half is an ABS-side failure's business to leave alone:
    # the book moved and its sidecar followed.
    The path "$RIP_SANDBOX/server/audiobooks/J. K. Rowling/Deathly Hallows/Deathly Hallows.m4b" should be exist
    The contents of file "$RIP_SANDBOX/server/audiobooks/J. K. Rowling/Deathly Hallows/.fleet-book.json" should include '"authors":["J. K. Rowling","Second Author"]'
  End

  # REVIEW FINDING 1 (2026-08-26). The ruling that "nothing to repoint" is not
  # a failure was implemented on the $aid-empty branch and not on the
  # $item-empty one, which left the latter routed nowhere at all: nothing
  # incremented, `rmdir` succeeded, and control reached the delete block.
  #
  # --find-item matches Audiobookshelf's STORED relPath, and it runs
  # milliseconds after the `mv` — ABS only learns the new path on its next
  # scan. So an empty $item here is the NORMAL reading during that window, and
  # it does not mean ABS has nothing filed under the old author; it usually
  # means the opposite. Deleting the variant record there strands every item
  # that still names it, reporting rc 0 — review finding 2 (2026-08-24)
  # reproduced, and a regression of the collision behaviour that predates this
  # whole feature.
  It 'sweep (ssh): a book Audiobookshelf has not scanned yet keeps the variant author record, without failing'
    fake_server_ssh
    ca_abs_bin '  --find-item) exit 1 ;;\n  --author-id) echo auth-x ;;'
    ca_book 'J.K. Rowling/Deathly Hallows' 'J.K. Rowling'
    When run zsh -c "source $RIPLIB && rip::ab_canonicalize_authors --apply"
    # Nothing went wrong: there was simply nothing to repoint.
    The status should equal 0
    The stderr should include "does not know this book yet"
    The stderr should include "were left unrepointed"
    # NOT the wording of a genuine failure, and NOT the no-author-record one
    # either — Audiobookshelf HAS a record for the canonical name here.
    The stderr should not include "could not be repointed"
    The stderr should not include "no author record called"
    # THE FIX. The record the un-repointed items may still name survives.
    The contents of file "$RIP_SANDBOX/absbin.log" should not include "--delete-author"
    The output should include "renamed on disk but NOT repointed"
    # The filesystem half completed regardless.
    The path "$RIP_SANDBOX/server/audiobooks/J. K. Rowling/Deathly Hallows/Deathly Hallows.m4b" should be exist
    The contents of file "$RIP_SANDBOX/server/audiobooks/J. K. Rowling/Deathly Hallows/.fleet-book.json" should include '"authors":["J. K. Rowling","Second Author"]'
  End

  # REVIEW FINDING 2 (2026-08-26). --apply derived the target spelling from the
  # post-move DIRECTORY, which is the canonical spelling for every book that
  # moved but the RAW one for a book whose `mv -n` was refused. A staged book
  # can arrive with an already-canonical sidecar under a raw-spelled directory
  # — the panel canonicalises the author field on blur, while
  # rip::_canonicalize_staged_authors renames the staged DIRECTORY to whatever
  # spelling the server already holds and never touches the sidecar — so
  # --apply rewrote a CORRECT sidecar backwards, to a spelling the dry run had
  # named neither the file nor the change for.
  #
  # The dry run is captured first and asserted silent about sidecars: "--apply
  # wrote nothing the dry run did not name" cannot be checked against the
  # apply run alone.
  It 'sweep (ssh): --apply never rewrites a sidecar the dry run did not name'
    fake_abs_ops_bin_any
    fake_server_ssh
    ca_book 'J.K. Rowling/Deathly Hallows' 'J. K. Rowling'
    ca_book 'J. K. Rowling/Deathly Hallows' 'J. K. Rowling'
    zsh -c "source $RIPLIB && rip::ab_canonicalize_authors" > "$RIP_SANDBOX/dry.txt" 2>/dev/null
    ca_snap_variant
    When run zsh -c "source $RIPLIB && rip::ab_canonicalize_authors --apply"
    # The same-title collision still refuses, exactly as before.
    The status should equal 1
    The stderr should include "still holds books"
    # The dry run had nothing to say about any sidecar…
    The contents of file "$RIP_SANDBOX/dry.txt" should not include "sidecar author spellings to correct"
    # …so --apply must write none, and must not claim to have.
    The result of function ca_variant_unchanged should equal "byte-identical"
    The output should not include "re-spelled"
    # The dry run really did run and really did see the collision — without
    # this the "should not include" above would pass against an empty file.
    The contents of file "$RIP_SANDBOX/dry.txt" should include "author variants"
  End


  # --- sidecar repair: --repair-sidecars / --adopt-asin ---------------------
  #
  # Four outcomes, discriminated on EVIDENCE (is a provider row findable?)
  # rather than on the sidecar's own `provider` field, which is the least
  # trustworthy thing about a book whose identity was lost:
  #
  #   A  no sidecar + exact-path row      -> written (the only automatic write)
  #   B  empty ids + a findable row       -> REPORTED ONLY, never written
  #   C  empty ids + no row + "manual"    -> fleet.uid + local.stored.sha256
  #   4  empty ids + no row + not manual  -> unidentifiable, nothing written
  #
  # Every example here runs the SSH branch through fake_server_ssh: the two
  # defects live validation found on 2026-08-24 (a remote `jq`, and ${(q)}'s
  # $'\n' reaching a real POSIX sh) were both invisible to the plain-local-dir
  # branch, and both of these verbs write to the only copy of a book's
  # identity.

  # fake_provider_rows <json-lines> — a provider whose `list` prints exactly
  # the given rows. RIP_LIBEXEC_DIR is redirected into the sandbox first:
  # setup() points it at the REAL tracked libexec, and a fake written there
  # would be a write into the repo.
  fake_provider_rows() {
    export RIP_LIBEXEC_DIR="$RIP_SANDBOX/libexec"
    mkdir -p "$RIP_LIBEXEC_DIR"
    {
      printf '#!/bin/sh\n[ "$1" = list ] || exit 0\ncat <<%s\n' "'ROWS'"
      printf '%s\n' "$1"
      printf 'ROWS\n'
    } > "$RIP_LIBEXEC_DIR/rip-provider-libation"
    chmod +x "$RIP_LIBEXEC_DIR/rip-provider-libation"
  }

  # A full provider row for the book that started this: 1.7 GB on cantina with
  # no sidecar at all, and a `path` composed exactly the way the server stores
  # it (verified live 2026-08-24).
  WIND='Brandon Sanderson/Wind and Truth: Book Five of the Stormlight Archive'
  ROW_WIND='{"id":"B0CQ3759C3","path":"Brandon Sanderson/Wind and Truth: Book Five of the Stormlight Archive","title":"Wind and Truth","subtitle":"Book Five of the Stormlight Archive","authors":["Brandon Sanderson"],"narrators":["Michael Kramer","Kate Reading"],"duration_s":220320,"series":"The Stormlight Archive","series_position":"5","language":"english","abridged":false,"published":"2024-12-06T08:00:00","ids":{"audible.asin":"B0CQ3759C3"},"provider":"libation","provider_version":"13.7.10","format":"m4b"}'

  # Case B, from real data: Libation files the pair under "Shawn Speakman -
  # editor" while the server has "Shawn Speakman", so the exact-path join
  # misses and normalized author matching fails too. What matches exactly is
  # the composed TITLE.
  UNF='Shawn Speakman/Unfettered III: New Tales by Masters of Fantasy'
  ROW_UNF='{"id":"B07PX3DC46","path":"Shawn Speakman - editor/Unfettered III: New Tales by Masters of Fantasy","title":"Unfettered III","subtitle":"New Tales by Masters of Fantasy","authors":["Shawn Speakman"],"narrators":["Nick Podehl","Kate Rudd"],"duration_s":93600,"series":"Unfettered","series_position":"3","language":"english","abridged":false,"published":"2019-05-07T07:00:00","ids":{"audible.asin":"B07PX3DC46"},"provider":"libation","provider_version":"13.7.10","format":"m4b"}'
  ROW_UNF_TWIN='{"id":"B0AMBIG999","path":"Someone Else/Unfettered III: New Tales by Masters of Fantasy","title":"Unfettered III","authors":["Someone Else"],"published":"2011-01-01T07:00:00","ids":{"audible.asin":"B0AMBIG999"},"provider":"libation","format":"m4b"}'

  # TWO SERVER BOOKS, ONE PROVIDER ROW — the inverse ambiguity. The
  # author-variant collision --canonicalize-authors exists for ("J. R. R.
  # Tolkien" vs "J.R.R. Tolkien") gives the library two folders for one work;
  # one joins the row by exact path and the other by the title fallback, and
  # both are handed the SAME ASIN.
  HOB_A='J.R.R. Tolkien/The Hobbit'
  HOB_B='J. R. R. Tolkien/The Hobbit'
  ROW_HOB='{"id":"B0DUP00001","path":"J.R.R. Tolkien/The Hobbit","title":"The Hobbit","authors":["J.R.R. Tolkien"],"published":"2012-01-01T00:00:00","ids":{"audible.asin":"B0DUP00001"},"provider":"libation","format":"m4b"}'

  RPO='Ernest Cline/Ready Player One'
  sidecar_unchanged() {
    if cmp -s "$RIP_SANDBOX/snapshot.json" "$(sidecar_at "$SNAP_REL")"; then
      echo "byte-identical"
    else
      echo "CHANGED"
    fi
  }

  wind_identity() {
    jq -c '[.ids["audible.asin"],.published,.narrators[0],.duration_s,.series.name,
            .language,.abridged,.source.provider,.work,has("_path")]' "$(sidecar_at "$WIND")"
  }

  It 'repair: a book with NO sidecar and an exact-path provider row is created, through a server with no jq'
    fake_provider_rows "$ROW_WIND"
    mkbook_bare "$WIND"
    fake_server_ssh
    When run zsh -c "source $RIPLIB && rip::ab_repair_sidecars --apply"
    The status should equal 0
    The output should include "repaired: $WIND"
    The output should include "repaired 1 of 1 sidecar(s)"
    # The WHOLE row lands, not just the ASIN, and `_path` — the annotation
    # rip::_server_sidecars adds — never reaches the file.
    The result of function wind_identity should equal '["B0CQ3759C3","2024-12-06T08:00:00","Michael Kramer",220320,"The Stormlight Archive","english",false,"libation",null,false]'
    # FOUR ssh calls for one book: enumerate the library, enumerate the
    # sidecars, ONE `test -f` confirming the sidecar really is absent before
    # Case A composes over that path (review finding 2, 2026-08-24), ONE write
    # batch. 247 books must never be 247 round-trips.
    The result of function ssh_calls should equal "4"
    # …and nothing the server was asked to run mentions jq. cantina has none.
    The result of function ssh_cmds should not include "jq"
  End

  It 'repair: a dry run writes nothing and opens no write connection'
    fake_provider_rows "$ROW_WIND"
    mkbook_bare "$WIND"
    fake_server_ssh
    When run zsh -c "source $RIPLIB && rip::ab_repair_sidecars"
    The status should equal 0
    The output should include "would create sidecar: $WIND"
    The output should include "re-run with --apply"
    The path "$(sidecar_at "$WIND")" should not be exist
    # The two enumerations plus the Case A absence re-check — and NO write
    # batch: `mv --` appears only in rip::_sidecars_write's remote script, so
    # its absence from the command log is the proof, independent of the count.
    The result of function ssh_calls should equal "3"
    The contents of file "$RIP_SANDBOX/ssh.cmds" should not include "mv -- "
  End

  It 'repair: a dry run states the plan but NEVER a write tally — nothing was attempted'
    # Review finding 1, 2026-08-24. The dry-run caller passes repaired=0
    # because a dry run deliberately opens no write connection, and the
    # summary printed that as "repaired 0 of 2 sidecar(s)" followed by
    # "2 sidecar(s) could not be written" — two failures reported for two
    # writes nobody attempted, on the first command an operator runs, exiting
    # 0 while saying it. The seventh line in this subsystem to state an
    # outcome nothing captured; there must not be an eighth. One Case A and
    # one Case C candidate, so `intended` is 2 and the old tally is
    # unmistakable if it comes back.
    fake_provider_rows "$ROW_WIND"
    mkbook_bare "$WIND"
    mkbook_empty "$RPO" manual
    fake_server_ssh
    When run zsh -c "source $RIPLIB && rip::ab_repair_sidecars"
    The status should equal 0
    The output should include "would create sidecar: $WIND"
    The output should include "would assign local identity: $RPO"
    The output should include "(2 book(s); re-run with --apply)"
    The output should not include "repaired 0 of"
    The output should not include "could not be written"
    The path "$(sidecar_at "$WIND")" should not be exist
    The contents of file "$RIP_SANDBOX/ssh.cmds" should not include "mv -- "
  End

  It 'repair: a book with no sidecar and NO provider row is named, skipped, and the run exits non-zero'
    # The provider answers (a non-empty library), it simply has no row for
    # this book. Refuse rather than guess: a wrong identity is worse than a
    # missing one.
    fake_provider_rows "$ROW_WIND"
    mkbook_bare "Nobody At All/Orphan Book"
    fake_server_ssh
    When run zsh -c "source $RIPLIB && rip::ab_repair_sidecars --apply"
    The status should equal 1
    The output should include "unrepairable (no sidecar, no provider row): Nobody At All/Orphan Book"
    The output should include "1 book(s) have no sidecar and no provider row"
    The path "$(sidecar_at "Nobody At All/Orphan Book")" should not be exist
  End

  It 'repair: a MALFORMED sidecar is reported as unreadable, left BYTE-IDENTICAL, and the run exits non-zero'
    # Review finding 2, 2026-08-24. sc_state is built only from sidecars
    # rip::_server_sidecars could parse, so an unparseable one arrived at the
    # classifier as "absent" and fell into Case A — which composed a fresh
    # sidecar and moved it over the only copy, printing "repaired" on stdout
    # while stderr said "malformed sidecar … skipped" and the run exited 0.
    # A stray trailing comma is recoverable by a human right up until this
    # verb overwrites it. The design forbids it twice: never overwrite an
    # existing sidecar, and repairing a malformed one is out of scope.
    fake_provider_rows "$ROW_WIND"
    mkbook_malformed "$WIND"
    snapshot "$WIND"
    fake_server_ssh
    When run zsh -c "source $RIPLIB && rip::ab_repair_sidecars --apply"
    The status should equal 1
    # THE load-bearing assertion: the bytes on disk, not a re-read field.
    The result of function sidecar_unchanged should equal "byte-identical"
    The output should include "unreadable sidecar (not repaired): $WIND"
    The output should include "does not parse"
    The output should include "1 book(s) have a sidecar that could not be read"
    # …and never the contradicting success line the defect printed alongside.
    The output should not include "repaired: $WIND"
    The output should not include "repaired 1 of"
    The stderr should include "malformed sidecar"
    # No write batch was ever opened.
    The contents of file "$RIP_SANDBOX/ssh.cmds" should not include "mv -- "
  End

  It 'repair: an already-identified sidecar is left byte-identical and the run reports the count'
    fake_provider_rows "$ROW_WIND"
    mkbook "Brandon Sanderson" "Steelheart" B00ECDZ08I 2013-09-24T07:00:00 Steelheart
    snapshot "Brandon Sanderson/Steelheart"
    fake_server_ssh
    When run zsh -c "source $RIPLIB && rip::ab_repair_sidecars --apply"
    The status should equal 0
    The output should include "nothing to repair (1 book(s) checked, 1 already identified)"
    The result of function sidecar_unchanged should equal "byte-identical"
    # No write connection was opened at all.
    The result of function ssh_calls should equal "2"
  End

  # NFC vs NFD. The server is NFC (the push's rsync --iconv guarantees it) and
  # macOS composes NFD, so a provider row for an accented author must still
  # join the server's folder. Without rip::_nfc on BOTH sides this book reads
  # as "no provider row" and is silently skipped — the exact bug
  # rip::_remote_has_file was bitten by.
  NFC_AUTHOR=$(printf '\303\211mile Zola')
  NFD_AUTHOR=$(printf 'E\314\201mile Zola')
  nfd_row() {
    jq -nc --arg p "$NFD_AUTHOR/Germinal" \
      '{id:"B0NFD00001",path:$p,title:"Germinal",authors:["Emile Zola"],
        published:"2020-01-01T00:00:00",ids:{"audible.asin":"B0NFD00001"},
        provider:"libation",format:"m4b"}'
  }
  nfd_asin() { jq -r '.ids["audible.asin"] // "MISSING"' "$(sidecar_at "$NFC_AUTHOR/Germinal")"; }

  It 'repair: an NFD provider row still matches the NFC folder the server holds'
    fake_provider_rows "$(nfd_row)"
    mkbook_bare "$NFC_AUTHOR/Germinal"
    fake_server_ssh
    When run zsh -c "source $RIPLIB && rip::ab_repair_sidecars --apply"
    The status should equal 0
    The output should include "repaired 1 of 1 sidecar(s)"
    The result of function nfd_asin should equal "B0NFD00001"
  End

  It 'repair: --apply leaves a Case B book BYTE-IDENTICAL while still reporting it'
    # The load-bearing assertion of the whole verb. Case B is REPORT-ONLY, and
    # "report-only" quietly becoming "writes anyway" in a future refactor is
    # exactly what this catches: the title fallback is looser than an exact
    # path match, and the cost of being wrong is a book permanently stamped
    # with another book's ASIN.
    fake_provider_rows "$ROW_UNF"
    mkbook_empty "$UNF" unknown
    snapshot "$UNF"
    fake_server_ssh
    When run zsh -c "source $RIPLIB && rip::ab_repair_sidecars --apply"
    The status should equal 1
    The result of function sidecar_unchanged should equal "byte-identical"
    The output should include "recoverable (needs confirmation): $UNF"
    The output should include "proposed ASIN : B07PX3DC46"
    The output should include "matched row   : Shawn Speakman - editor/Unfettered III: New Tales by Masters of Fantasy"
    The output should include "matched on    : title (author differs)"
    The output should include "confirm with  : rip-audiobook --adopt-asin \"$UNF\" B07PX3DC46"
    The output should include "1 book(s) need confirmation"
    # No write batch was ever opened: the two enumerations only.
    The result of function ssh_calls should equal "2"
  End

  It 'repair: two provider rows sharing one title are reported as ambiguous and nothing is written'
    fake_provider_rows "$(printf '%s\n%s' "$ROW_UNF" "$ROW_UNF_TWIN")"
    mkbook_empty "$UNF" unknown
    snapshot "$UNF"
    fake_server_ssh
    When run zsh -c "source $RIPLIB && rip::ab_repair_sidecars --apply"
    The status should equal 1
    The output should include "ambiguous (nothing written): $UNF"
    The output should include "B07PX3DC46"
    The output should include "B0AMBIG999"
    The output should include "pick one with : rip-audiobook --adopt-asin"
    The result of function sidecar_unchanged should equal "byte-identical"
  End

  It 'repair: one ASIN proposed for TWO books is ambiguous on both, never a high-confidence proposal'
    # Review finding 3, 2026-08-24. Ambiguity was detected in one direction
    # only — one server book, two provider rows. The inverse (two server
    # books, one row) went unnoticed, and the author-variant collision this
    # module already knows about produces it: the exact-path join claims one
    # folder and the title fallback claims the other, both proposing
    # B0DUP00001, and one of them labelled "matched on: path (exact)", which
    # reads as high confidence. Adopting both would leave two folders carrying
    # one audible.asin — the duplicated edition identity the sidecar exists to
    # prevent. A proposal that is not unique is an ambiguity.
    fake_provider_rows "$ROW_HOB"
    mkbook_empty "$HOB_A" unknown
    mkbook_empty "$HOB_B" unknown
    snapshot "$HOB_A"
    fake_server_ssh
    When run zsh -c "source $RIPLIB && rip::ab_repair_sidecars --apply"
    The status should equal 1
    The output should include "ambiguous (nothing written): $HOB_A"
    The output should include "ambiguous (nothing written): $HOB_B"
    The output should include "also proposed for 1 other book(s)"
    The output should not include "recoverable (needs confirmation)"
    The output should not include "confirm with"
    The output should include "2 book(s) are ambiguous"
    The result of function sidecar_unchanged should equal "byte-identical"
  End

  rpo_uid_ok() {
    jq -r '.ids["fleet.uid"] // ""' "$(sidecar_at "$RPO")" \
      | grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' \
      && echo "uuidv4" || echo "NOT A UUIDV4"
  }
  rpo_sha_ok() {
    want=$(shasum -a 256 "$RIP_SANDBOX/server/audiobooks/$RPO/Ready Player One.m4b" | cut -d' ' -f1)
    got=$(jq -r '.ids["local.stored.sha256"] // ""' "$(sidecar_at "$RPO")")
    if [ -n "$got" ] && [ "$want" = "$got" ]; then echo "hash matches the audio"; else echo "MISMATCH want=$want got=$got"; fi
  }
  # THE KEY MATTERS, not just the value. local.sha256 is the hash of the
  # SOURCE that was imported, and rip::ab_worker's byte-dedupe compares a
  # about-to-be-imported source file against exactly that. Case C has no
  # source to hash — it can only ever hash the STORED bytes, which the retag
  # rewrites — so recording its answer under local.sha256 would hand the
  # dedupe a value it can never match and silently stop it firing for every
  # repaired book.
  rpo_no_source_sha() {
    if jq -e '.ids | has("local.sha256")' "$(sidecar_at "$RPO")" >/dev/null 2>&1; then
      echo "CLAIMED A SOURCE HASH IT NEVER SAW"
    else
      echo "no source hash claimed"
    fi
  }
  rpo_untouched_fields() { jq -c '[.title,.source.provider,.published,.work]' "$(sidecar_at "$RPO")"; }

  It 'repair: a manual book with no provider row is assigned fleet.uid + a server-computed local.stored.sha256'
    # Case C. Both keys deliberately: a minted uid alone repeats the exposure
    # that started this work (lose the sidecar, lose the id forever), and a
    # hash alone dies at the next re-encode. The uid is the join key; the hash
    # is the recovery anchor, and it is computed where the bytes are.
    fake_provider_rows "$ROW_WIND"
    mkbook_empty "$RPO" manual
    fake_server_ssh
    When run zsh -c "source $RIPLIB && rip::ab_repair_sidecars --apply"
    The status should equal 0
    The output should include "repaired: $RPO"
    The output should include "repaired 1 of 1 sidecar(s)"
    The result of function rpo_uid_ok should equal "uuidv4"
    The result of function rpo_sha_ok should equal "hash matches the audio"
    The result of function rpo_no_source_sha should equal "no source hash claimed"
    # Additive: nothing else on the sidecar is rewritten.
    The result of function rpo_untouched_fields should equal '["Ready Player One","manual",null,null]'
    # library + sidecars + hash + write.
    The result of function ssh_calls should equal "4"
    # The hash is sha256sum's job, not jq's — the server has no jq.
    The result of function ssh_cmds should not include "jq"
  End

  # THE REASON THE KEY WAS SPLIT, stated as behaviour rather than as a field
  # name. rip::_stored_sha_index is the byte-dedupe's whole input, and
  # rip::ab_worker feeds it the sha256 of the SOURCE FILE it is about to
  # copy. A Case C hash is of the STORED bytes — which the enrichment's
  # retag rewrites — so listing it there would offer the dedupe a value no
  # source can ever match, and dedupe would silently stop firing for every
  # repaired book with nothing on screen to say so. The control book beside
  # it is what stops this reading as "the index came back empty".
  It 'stored-sha index: a Case C repair contributes nothing — its hash is of the stored bytes, not of an imported source'
    fake_provider_rows "$ROW_WIND"
    mkbook_empty "$RPO" manual
    mkdir -p "$RIP_SANDBOX/server/audiobooks/Z Control/Book"
    printf 'ctl\n' > "$RIP_SANDBOX/server/audiobooks/Z Control/Book/Book.m4b"
    printf '%s\n' '{"schema":1,"kind":"audiobook","title":"Book","authors":["Z Control"],"ids":{"fleet.uid":"u1","local.sha256":"deadbeef"}}' \
      > "$RIP_SANDBOX/server/audiobooks/Z Control/Book/.fleet-book.json"
    fake_server_ssh
    When run zsh -c "source $RIPLIB
      rip::ab_repair_sidecars --apply >/dev/null 2>&1
      rip::_stored_sha_index"
    The status should equal 0
    # a book whose local.sha256 really is a source hash still indexes
    The output should include "deadbeef"
    The output should include "Z Control/Book"
    # the Case C book does not
    The output should not include "Ready Player One"
    The stderr should not include "malformed"
  End

  It 'repair: re-running --apply on a repaired Case C book mints no second uid'
    fake_provider_rows "$ROW_WIND"
    mkbook_empty "$RPO" manual
    fake_server_ssh
    When run zsh -c "source $RIPLIB
      rip::ab_repair_sidecars --apply >/dev/null 2>&1
      u1=\$(jq -r '.ids[\"fleet.uid\"] // \"\"' '$RIP_SANDBOX/server/audiobooks/$RPO/.fleet-book.json')
      rip::ab_repair_sidecars --apply
      u2=\$(jq -r '.ids[\"fleet.uid\"] // \"\"' '$RIP_SANDBOX/server/audiobooks/$RPO/.fleet-book.json')
      [ -n \"\$u1\" ] && [ \"\$u1\" = \"\$u2\" ] && print -r -- 'uid stable' || print -r -- 'UID CHANGED'"
    The status should equal 0
    The output should include "uid stable"
    The output should include "nothing to repair"
  End

  ghost_ids() { jq -c '.ids' "$(sidecar_at "Ghost Author/Returned Book")"; }

  It 'repair: an empty-identity book with no provider row and a non-manual provider is unidentifiable, never minted'
    # THE FOURTH OUTCOME. A Libation book that was returned or removed from
    # the account lands here. Minting a fleet.uid would permanently disconnect
    # it from an ASIN it may still be entitled to, so it is named and left
    # exactly as it is.
    fake_provider_rows "$ROW_WIND"
    mkbook_empty "Ghost Author/Returned Book" unknown
    snapshot "Ghost Author/Returned Book"
    fake_server_ssh
    When run zsh -c "source $RIPLIB && rip::ab_repair_sidecars --apply"
    The status should equal 1
    The output should include "unidentifiable (empty identity, no provider row, provider \"unknown\"): Ghost Author/Returned Book"
    The output should include "1 book(s) are unidentifiable"
    The result of function sidecar_unchanged should equal "byte-identical"
    The result of function ghost_ids should equal "{}"
  End

  It 'repair: a provider that answers with nothing refuses the whole sweep rather than guessing'
    # An empty provider list cannot be told apart from "Libation did not
    # answer", and that difference decides whether a book is stamped with a
    # locally minted uid it can never lose.
    fake_provider_rows ""
    mkbook_empty "$RPO" manual
    snapshot "$RPO"
    fake_server_ssh
    When run zsh -c "source $RIPLIB && rip::ab_repair_sidecars --apply"
    The status should equal 2
    The stderr should include "returned no rows"
    The result of function sidecar_unchanged should equal "byte-identical"
  End

  # The verbs through the REAL CLI, not just the functions. The executable
  # runs under `set -eu -o pipefail`, which the sourced-function examples
  # above do not: an unset array or associative-array read that is harmless in
  # a plain zsh -c aborts the whole command here.
  It 'cli: --repair-sidecars --apply reaches the function and repairs under set -eu'
    fake_provider_rows "$ROW_WIND"
    mkbook_bare "$WIND"
    fake_server_ssh
    When run zsh "$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_rip-audiobook" --repair-sidecars --apply
    The status should equal 0
    The output should include "repaired 1 of 1 sidecar(s)"
    The result of function wind_identity should equal '["B0CQ3759C3","2024-12-06T08:00:00","Michael Kramer",220320,"The Stormlight Archive","english",false,"libation",null,false]'
  End

  # --- --adopt-asin: the confirmation verb ----------------------------------

  unf_identity() {
    jq -c '[.ids["audible.asin"],.published,.narrators,.duration_s,.series.name,
            .series.position,.language,.abridged,.source.provider,.title,.authors,.work,has("_path")]' \
      "$(sidecar_at "$UNF")"
  }

  It 'adopt: an ASIN the provider does not know is refused and nothing is written'
    fake_provider_rows "$ROW_UNF"
    mkbook_empty "$UNF" unknown
    snapshot "$UNF"
    fake_server_ssh
    When run zsh -c "source $RIPLIB && rip::ab_adopt_asin '$UNF' B0NOTREAL01 --apply"
    The status should equal 2
    The stderr should include "has no B0NOTREAL01"
    The stderr should include "resolves to nothing"
    The result of function sidecar_unchanged should equal "byte-identical"
  End

  It 'adopt: a sidecar that already carries an ASIN is refused and nothing is written'
    fake_provider_rows "$ROW_WIND"
    mkbook "Brandon Sanderson" "Wind and Truth: Book Five of the Stormlight Archive" B0OLDASIN1 "" "Wind and Truth"
    snapshot "$WIND"
    fake_server_ssh
    When run zsh -c "source $RIPLIB && rip::ab_adopt_asin '$WIND' B0CQ3759C3 --apply"
    The status should equal 2
    The stderr should include "already carries audible.asin B0OLDASIN1"
    The stderr should include "never overwrites"
    The result of function sidecar_unchanged should equal "byte-identical"
  End

  It 'adopt: an ASIN ANOTHER stored sidecar already carries is refused (guard 5)'
    # Review finding 3(b), 2026-08-24. Guard 2 only ever inspected the TARGET
    # book's sidecar, so the same proposed ASIN could be adopted for two
    # different folders one command at a time — no guard, no warning. The
    # rows index is already in hand for guard 2, so seeing every row costs
    # nothing.
    fake_provider_rows "$ROW_UNF"
    mkbook_empty "$UNF" unknown
    mkbook "Shawn Speakman" "Unfettered II" B07PX3DC46 2016-01-01T07:00:00 "Unfettered II"
    snapshot "$UNF"
    fake_server_ssh
    When run zsh -c "source $RIPLIB && rip::ab_adopt_asin '$UNF' B07PX3DC46 --apply"
    The status should equal 2
    The stderr should include "Shawn Speakman/Unfettered II already carries audible.asin B07PX3DC46"
    The stderr should include "one ASIN identifies one book"
    The output should not include "adopted"
    The result of function sidecar_unchanged should equal "byte-identical"
  End

  It 'adopt: --apply populates the FULL row and corrects source.provider away from unknown'
    fake_provider_rows "$ROW_UNF"
    mkbook_empty "$UNF" unknown
    fake_server_ssh
    When run zsh -c "source $RIPLIB && rip::ab_adopt_asin '$UNF' B07PX3DC46 --apply"
    The status should equal 0
    The output should include "rip: adopted B07PX3DC46 for $UNF"
    # published, narrators, duration_s, series, language and abridged all
    # arrive — recovering the ASIN alone would leave the book half-identified.
    # The SERVER's author spelling survives (the row says "Shawn Speakman -
    # editor" only because that is how Libation files it), `work` stays null,
    # and `_path` never reaches the file.
    The result of function unf_identity should equal '["B07PX3DC46","2019-05-07T07:00:00",["Nick Podehl","Kate Rudd"],93600,"Unfettered","3","english",false,"libation","Unfettered III: New Tales by Masters of Fantasy",["Shawn Speakman"],null,false]'
  End

  It 'adopt: a dry run reports the plan and writes nothing'
    fake_provider_rows "$ROW_UNF"
    mkbook_empty "$UNF" unknown
    snapshot "$UNF"
    fake_server_ssh
    When run zsh -c "source $RIPLIB && rip::ab_adopt_asin '$UNF' B07PX3DC46"
    The status should equal 0
    The output should include "would adopt: $UNF"
    The output should include "ASIN         : B07PX3DC46"
    The output should include "re-run with --apply"
    The result of function sidecar_unchanged should equal "byte-identical"
  End

  It 'adopt: a write the server never confirms reports failure and leaves the sidecar alone'
    # Outcome-gated, like every other success line in this module: "adopted"
    # is printed only when the remote loop said ok for THIS book's key.
    fake_provider_rows "$ROW_UNF"
    mkbook_empty "$UNF" unknown
    snapshot "$UNF"
    fake_server_ssh
    When run zsh -c "source $RIPLIB
      chmod 555 '$RIP_SANDBOX/server/audiobooks/$UNF'
      rip::ab_adopt_asin '$UNF' B07PX3DC46 --apply; rc=\$?
      chmod 755 '$RIP_SANDBOX/server/audiobooks/$UNF'
      exit \$rc"
    The status should equal 1
    The stderr should include "could not write the sidecar"
    The output should not include "adopted"
    The result of function sidecar_unchanged should equal "byte-identical"
  End

  # --- review round 3, 2026-08-24 ------------------------------------------

  # THREE bare books, so the order `find` happens to return them in cannot
  # decide whether the bug shows: every one of them is a Case A candidate, so
  # whichever comes first probes the server and — pre-fix — ate the rest of
  # the here-string the classification loop reads from.
  ROW_FD1='{"id":"B0FD000001","path":"Ann Leckie/Ancillary Justice","title":"Ancillary Justice","authors":["Ann Leckie"],"published":"2013-10-01T00:00:00","ids":{"audible.asin":"B0FD000001"},"provider":"libation","format":"m4b"}'
  ROW_FD2='{"id":"B0FD000002","path":"Becky Chambers/A Closed and Common Orbit","title":"A Closed and Common Orbit","authors":["Becky Chambers"],"published":"2016-10-20T00:00:00","ids":{"audible.asin":"B0FD000002"},"provider":"libation","format":"m4b"}'
  ROW_FD3='{"id":"B0FD000003","path":"Cixin Liu/The Three-Body Problem","title":"The Three-Body Problem","authors":["Cixin Liu"],"published":"2014-11-11T00:00:00","ids":{"audible.asin":"B0FD000003"},"provider":"libation","format":"m4b"}'

  It 'repair: an ssh probe inside the classification loop does NOT eat the library — every book is classified'
    # THE BLOCKER (review finding 1, 2026-08-24). rip::_remote_has_file ran
    # `ssh … "test -f …"` with no -n and no stdin redirect, from inside the
    # loop fed by `done <<< "$lib"`. ssh(1) without -n reads local stdin
    # eagerly and forwards it; `test -f` never consumes it; the whole
    # remaining library (~10 KB live, one read) vanished into the first probe
    # and the loop ended after ONE book — rc 0, a report that looked complete,
    # and every other book never examined. Third appearance of this fd-0
    # family in this subsystem, so the fix is in the helper, not the call
    # site, and this example is the guard: its fake ssh READS STDIN the way
    # the real one does.
    fake_provider_rows "$ROW_FD1"$'\n'"$ROW_FD2"$'\n'"$ROW_FD3"
    mkbook_bare "Ann Leckie/Ancillary Justice"
    mkbook_bare "Becky Chambers/A Closed and Common Orbit"
    mkbook_bare "Cixin Liu/The Three-Body Problem"
    fake_server_ssh_reads_stdin
    When run zsh -c "source $RIPLIB && rip::ab_repair_sidecars < /dev/null"
    The status should equal 0
    The output should include "would create sidecar: Ann Leckie/Ancillary Justice"
    The output should include "would create sidecar: Becky Chambers/A Closed and Common Orbit"
    The output should include "would create sidecar: Cixin Liu/The Three-Body Problem"
    # The count is the assertion that cannot be satisfied by a truncated
    # sweep: pre-fix this said "(1 book(s); …)".
    The output should include "(3 book(s); re-run with --apply)"
    # library + sidecars + one absence probe per candidate. Pre-fix: 3.
    The result of function ssh_calls should equal "5"
  End

  It 'repair: one provider row proposed for a Case A book AND a Case B book is ambiguous on both — nothing is written'
    # Review finding 2, 2026-08-24. The dedupe pre-pass counted proposals
    # across b_report ONLY, and a Case A candidate never enters b_report. One
    # row, two folders: "J.R.R. Tolkien/The Hobbit" is bare (Case A, exact
    # path, the AUTOMATIC write) and "J. R. R. Tolkien/The Hobbit" carries an
    # empty-ids sidecar (Case B, title fallback). The dry run presented one as
    # a high-confidence adopt and the other as a write, both B0DUP00001, and
    # an operator following the printed instructions in the printed order got
    # two folders with one edition identity, rc 0, no warning. Guard 5 only
    # catches the reverse order.
    fake_provider_rows "$ROW_HOB"
    mkbook_bare "$HOB_A"
    mkbook_empty "$HOB_B" unknown
    snapshot "$HOB_B"
    fake_server_ssh
    When run zsh -c "source $RIPLIB && rip::ab_repair_sidecars --apply"
    The status should equal 1
    The output should include "ambiguous (nothing written): $HOB_A"
    The output should include "ambiguous (nothing written): $HOB_B"
    The output should include "also proposed for 1 other book(s)"
    The output should include "2 book(s) are ambiguous"
    # The Case A half never becomes a plan, a write, or a "repaired" line…
    The output should not include "would create sidecar"
    The output should not include "repaired"
    # …and the Case B half is never dressed up as high confidence.
    The output should not include "recoverable (needs confirmation)"
    The output should not include "confirm with"
    The path "$(sidecar_at "$HOB_A")" should not be exist
    The result of function sidecar_unchanged should equal "byte-identical"
    The contents of file "$RIP_SANDBOX/ssh.cmds" should not include "mv -- "
  End

  It 'repair: a Case A row whose ASIN another STORED sidecar already carries is refused, not written'
    # The same collision one run later: the second folder is no longer a
    # proposal, it is a stored fact. An ASIN identifies one book, so the bare
    # folder gets nothing — the automatic write is the one nobody is asked
    # about.
    fake_provider_rows "$ROW_HOB"
    mkbook_bare "$HOB_A"
    mkbook "J. R. R. Tolkien" "The Hobbit" B0DUP00001 2012-01-01T00:00:00 "The Hobbit"
    fake_server_ssh
    When run zsh -c "source $RIPLIB && rip::ab_repair_sidecars --apply"
    The status should equal 1
    The output should include "ambiguous (nothing written): $HOB_A"
    The output should include "already carried by $HOB_B"
    The output should not include "would create sidecar"
    The output should not include "repaired"
    The path "$(sidecar_at "$HOB_A")" should not be exist
    The contents of file "$RIP_SANDBOX/ssh.cmds" should not include "mv -- "
  End

  It 'repair: a probe that never ran is reported as an unconfirmed absence, never as a sidecar that exists'
    # Review finding 3, 2026-08-24. The rc-2 branch is right to refuse — an
    # absence that was not established is never written over — but the closing
    # line said "N book(s) have a sidecar that could not be read", asserting
    # the existence of a file nothing established. Eighth instance of this
    # subsystem's recurring defect: a line stating an outcome nothing
    # captured. The two causes now have two counts and two sentences.
    fake_provider_rows "$ROW_WIND"
    mkbook_bare "$WIND"
    fake_server_ssh_probe_fails
    When run zsh -c "source $RIPLIB && rip::ab_repair_sidecars --apply"
    The status should equal 1
    The output should include "unreadable sidecar (not repaired): $WIND"
    The output should include "could not confirm whether a sidecar is there"
    The output should include "1 book(s) were left alone: whether a sidecar is there could not be confirmed"
    # The sentence the refusal could not support.
    The output should not include "have a sidecar that could not be read"
    The output should not include "does not parse"
    The path "$(sidecar_at "$WIND")" should not be exist
    The contents of file "$RIP_SANDBOX/ssh.cmds" should not include "mv -- "
  End

  # Two id-less rows: rip-provider-libation composes `id: (.AudibleProductId
  # // "")`, empty for a book the account no longer lists, and
  # rip::_provider_index turns that into its never-empty filler "-".
  ROW_NIL1='{"path":"Nil One/Alpha","title":"Alpha","authors":["Nil One"],"published":"2001-01-01T00:00:00","provider":"libation","format":"m4b"}'
  ROW_NIL2='{"path":"Nil Two/Beta","title":"Beta","authors":["Nil Two"],"published":"2002-02-02T00:00:00","provider":"libation","format":"m4b"}'

  It 'repair: two books with their OWN id-less provider rows do not cross-match on the "-" filler'
    # Review finding 4, 2026-08-24. "-" is a placeholder, not an identifier,
    # and counting it collapsed every id-less row onto one key: two unrelated
    # books were reported as sharing an ASIN, with an unusable
    # `--adopt-asin "<the one book that is ->" -` remedy line to match.
    fake_provider_rows "$ROW_NIL1"$'\n'"$ROW_NIL2"
    mkbook_empty "Nil One/Alpha" unknown
    mkbook_empty "Nil Two/Beta" unknown
    fake_server_ssh
    When run zsh -c "source $RIPLIB && rip::ab_repair_sidecars --apply"
    The status should equal 1
    The output should include "recoverable (needs confirmation): Nil One/Alpha"
    The output should include "recoverable (needs confirmation): Nil Two/Beta"
    The output should include "2 book(s) need confirmation"
    The output should not include "ambiguous"
    The output should not include "also proposed for"
    The output should not include "the one book that is -"
  End

  It 'cli: --adopt-asin refuses an ASIN the provider does not know'
    fake_provider_rows "$ROW_UNF"
    mkbook_empty "$UNF" unknown
    snapshot "$UNF"
    fake_server_ssh
    When run zsh "$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_rip-audiobook" --adopt-asin "$UNF" B0NOTREAL01 --apply
    The status should equal 2
    The stderr should include "resolves to nothing"
    The result of function sidecar_unchanged should equal "byte-identical"
  End
End
