# The receipt ledger. croc keeps its own store-receipts.json, but it has no
# notion of WHICH endpoint a transfer went to, and rclone leaves no receipt at
# all — so this is the union view that `share list` and `share revoke` read.
#
# `ref` is the backend handle (a croc transfer id, or an rclone remote path);
# `id` is our own key. Keeping them separate is what lets one revoke path
# dispatch to two very different backends.

Describe 'share:: receipt ledger'
  Include home/dot_local/lib/share.zsh

  setup() {
    SB="$SHELLSPEC_TMPBASE/share-ledger"
    rm -rf "$SB"; mkdir -p "$SB"
    SHARE_STATE_DIR="$SB"
    SHARE_PROFILE=personal
  }
  BeforeEach 'setup'

  It 'generates unique ids on consecutive calls'
    a="$(share::gen_id)"; b="$(share::gen_id)"
    When call test "$a" != "$b"
    The status should be success
  End

  It 'round-trips an entry'
    share::ledger_add id1 croc public 'R.pdf (1 B)' ref1 'https://x/s/ref1#v1.k' 9999999999
    When call share::ledger_get id1
    The output should include '"backend": "croc"'
    The output should include '"ref": "ref1"'
    The output should include '"endpoint": "public"'
  End

  It 'lists newest first'
    share::ledger_add id1 croc public 'a' r1 'u1' 9999999999
    share::ledger_add id2 rclone onedrive 'b' r2 'u2' 9999999999
    When call share::ledger_list
    The output should include 'id2'
    # The `result` modifier requires a bare function name matching
    # [a-zA-Z_][a-zA-Z0-9_]* (see shellspec_is_function in
    # core/utils.sh) — a `share::`-namespaced name or an inline
    # "cmd | jq ..." string both fail that check. Wrap in a
    # same-scope helper with a plain identifier instead.
    newest_ledger_id() { share::ledger_list | jq -r '.[0].id'; }
    The result of function newest_ledger_id should equal 'id2'
  End

  It 'removes an entry without disturbing its neighbours'
    share::ledger_add id1 croc public 'a' r1 'u1' 9999999999
    share::ledger_add id2 croc public 'b' r2 'u2' 9999999999
    share::ledger_remove id1
    When call share::ledger_list
    The output should not include '"id": "id1"'
    The output should include '"id": "id2"'
  End

  It 'fails to get a removed entry'
    share::ledger_add id1 croc public 'a' r1 'u1' 9999999999
    share::ledger_remove id1
    When run share::ledger_get id1
    The status should be failure
  End

  It 'reports overdue entries only'
    share::ledger_add old croc public 'a' r1 'u1' 1
    share::ledger_add new croc public 'b' r2 'u2' 9999999999
    When call share::ledger_overdue
    The output should equal 'old'
  End

  It 'returns an empty array when no ledger file exists'
    When call share::ledger_list
    The output should equal '[]'
  End

  # F5 fix: the ledger holds every stored-mode URL (key in the fragment) and
  # every live-mode code phrase in cleartext — secrets on disk, not just in
  # argv. It is created under a scoped `umask 077`, not the process default
  # (0644 before this fix), so it is readable by nobody but the owner.
  It 'creates the ledger file with mode 0600'
    share::ledger_add id1 croc public 'a' r1 'u1' 9999999999
    perm() { stat -f '%Lp' "$SB/ledger.jsonl" 2>/dev/null || stat -c '%a' "$SB/ledger.jsonl"; }
    When call perm
    The output should equal '600'
  End

  # F5 fix: `ref` and `url` used to ride jq's OWN argv (`--arg ref "$5" --arg
  # url "$6"`) — and both can carry a secret (a stored-mode URL's key, or a
  # live-mode code phrase). On Linux /proc/<pid>/cmdline is world-readable
  # for the life of the jq process, however brief. A logging jq shim that
  # records its own invocation argv is the direct evidence: the secret must
  # show up in the JSON it wrote, never in what it was called with.
  It 'never puts the url or ref on the jq invocation that writes the ledger row'
    mkdir -p "$SB/bin"
    real_jq="$(command -v jq)"
    cat >"$SB/bin/jq" <<SH
#!/bin/sh
printf '%s\n' "\$*" >>"\$SHARE_JQ_ARGV_LOG"
exec "$real_jq" "\$@"
SH
    chmod +x "$SB/bin/jq"
    PATH="$SB/bin:$PATH"
    SHARE_JQ_ARGV_LOG="$SB/jq-argv.log"; export SHARE_JQ_ARGV_LOG
    share::ledger_add id1 croc public 'a' 'live-code-phrase-xyz' 'https://x/s/a#v1.SECRETKEY' 0
    check() {
      grep -q 'SECRETKEY' "$SHARE_JQ_ARGV_LOG" && return 1
      grep -q 'live-code-phrase-xyz' "$SHARE_JQ_ARGV_LOG" && return 1
      grep -q 'SECRETKEY' "$SB/ledger.jsonl" || return 1
      return 0
    }
    When call check
    The status should be success
  End
End
