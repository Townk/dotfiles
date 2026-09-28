# The ssh backend — the Phase 4 dev-shell experiment. Copies files to one of
# YOUR OWN boxes over an ssh hop, records a receipt, prints the remote path(s).
#
# Hermetic: `ssh` is a fake on PATH that records its argv and then does what a
# real sshd would do with the remote command — hands it to `sh -c` — inside a
# temp dir standing in for the remote $HOME. That makes the injection examples
# honest: a filename that leaked into the command string would really run.
# `scp` is a fake too, and it fails loudly: nothing may use it. No example ever
# contacts a real host.

Describe 'share:: ssh backend'
  Include home/dot_local/lib/share.zsh

  setup() {
    SB="$SHELLSPEC_TMPBASE/share-ssh"
    rm -rf "$SB"; mkdir -p "$SB/bin" "$SB/remote" "$SB/local"
    SHARE_CONFIG_DIR="$SB"
    SHARE_ENDPOINTS_FILE="$SB/endpoints.toml"
    SHARE_STATE_DIR="$SB/state"
    SHARE_PROFILE=work
    cat >"$SHARE_ENDPOINTS_FILE" <<'TOML'
[devbox]
description = "dev-shell over ssh"
backend = "ssh"
target = "me@devshell.example.com"
dir = "~/incoming"
profiles = ["work"]

[onedrive]
backend = "rclone"
remote = "onedrive:Shared/drop"
web = true
profiles = ["work"]
default_for = ["work"]
TOML
    printf 'report-bytes' >"$SB/local/Report.pdf"
    printf 'notes-bytes' >"$SB/local/Notes.txt"

    # The fake ssh: log argv (one CALL block per invocation), answer -G
    # offline like the real one, fail on request, otherwise run the remote
    # command the way sshd does — through a shell, in the remote $HOME.
    cat >"$SB/bin/ssh" <<'SH'
#!/bin/sh
{ printf 'CALL\n'; for a in "$@"; do printf '%s\n' "$a"; done; } >>"$FAKE_SSH_LOG"
n=$(grep -c '^CALL$' "$FAKE_SSH_LOG")
g=0
while [ $# -gt 0 ]; do
  case "$1" in
    --) shift; break ;;
    -G) g=1; shift ;;
    -e|-o|-p|-l|-i|-F) shift 2 ;;
    -*) shift ;;
    *) break ;;
  esac
done
target="$1"; shift
if [ "$g" = 1 ]; then
  printf 'user me\nhostname %s\nport 2222\n' "${target#*@}"
  exit 0
fi
[ -n "${FAKE_SSH_FAIL_CALL:-}" ] && [ "$n" = "$FAKE_SSH_FAIL_CALL" ] && { cat >/dev/null; exit 255; }
cd "$FAKE_REMOTE" || exit 255
HOME="$FAKE_REMOTE" exec sh -c "$*"
SH
    cat >"$SB/bin/scp" <<'SH'
#!/bin/sh
printf 'scp %s\n' "$*" >>"$FAKE_SSH_LOG"
exit 1
SH
    cat >"$SB/bin/pbcopy" <<'SH'
#!/bin/sh
cat >"$FAKE_CLIP"
SH
    chmod +x "$SB/bin/ssh" "$SB/bin/scp" "$SB/bin/pbcopy"
    FAKE_SSH_LOG="$SB/ssh.log"; FAKE_REMOTE="$SB/remote"; FAKE_CLIP="$SB/clip"
    FAKE_SSH_FAIL_CALL=""
    export FAKE_SSH_LOG FAKE_REMOTE FAKE_CLIP FAKE_SSH_FAIL_CALL
    : >"$FAKE_SSH_LOG"
    PATH="$SB/bin:$PATH"
    JOB_STATE_ROOT="$SB/jobs"; export JOB_STATE_ROOT
  }
  BeforeEach 'setup'

  add_endpoint() { cat >>"$SHARE_ENDPOINTS_FILE"; }
  ssh_calls() { grep -c '^CALL$' "$FAKE_SSH_LOG"; }
  stamp_dir() { print -r -- "$SB/remote/incoming"/*(/N[1]); }
  receipt() { jq -c '.' "$SB/state/ledger.jsonl"; }
  receipt_ref() { jq -c '.ref | fromjson' "$SB/state/ledger.jsonl"; }

  Describe 'send'
    It 'copies the file into a fresh directory under dir and prints its remote path'
      When call share::send --to devbox "$SB/local/Report.pdf"
      The status should be success
      The output should match pattern "*/remote/incoming/*/Report.pdf"
      The stderr should include 'sending to devshell.example.com'
      The contents of file "$(stamp_dir)/Report.pdf" should equal 'report-bytes'
    End

    It 'records a receipt with backend ssh and the copied paths'
      share::send --to devbox "$SB/local/Report.pdf" >/dev/null 2>&1
      When call receipt
      The output should include '"backend":"ssh"'
      The output should include '"endpoint":"devbox"'
      The output should include '"ref":'
    End

    It 'records its own target and the copied names in the ref'
      share::send --to devbox "$SB/local/Report.pdf" >/dev/null 2>&1
      When call receipt_ref
      The output should include '"target":"me@devshell.example.com"'
      The output should include '"names":["Report.pdf"]'
      The output should include '/remote/incoming/'
    End

    It 'puts a multi-file send in ONE directory and prints one line'
      When call share::send --to devbox "$SB/local/Report.pdf" "$SB/local/Notes.txt"
      The status should be success
      The lines of output should equal 1
      The output should include '/Report.pdf'
      The output should include '/Notes.txt'
      The stderr should be present
      The contents of file "$(stamp_dir)/Notes.txt" should equal 'notes-bytes'
    End

    It 'copies the pasteable line to the clipboard'
      share::send --to devbox "$SB/local/Report.pdf" >/dev/null 2>&1
      When call cat "$FAKE_CLIP"
      The output should match pattern "*/incoming/*/Report.pdf"
    End

    It 'uses ssh without a tty, non-interactively, and never scp'
      share::send --to devbox "$SB/local/Report.pdf" >/dev/null 2>&1
      When call cat "$FAKE_SSH_LOG"
      The output should include '-T'
      The output should include 'BatchMode=yes'
      The output should include 'me@devshell.example.com'
      The output should not include 'scp'
    End

    It 'creates the files private to the remote user'
      share::send --to devbox "$SB/local/Report.pdf" >/dev/null 2>&1
      When call ls -ld "$(stamp_dir)" "$(stamp_dir)/Report.pdf"
      The line 1 of output should start with 'drwx------'
      The line 2 of output should start with '-rw-------'
    End

    It 'cleans up what it already copied when a later file fails'
      FAKE_SSH_FAIL_CALL=2
      When call share::send --to devbox "$SB/local/Report.pdf" "$SB/local/Notes.txt"
      The status should be failure
      The stderr should include 'ssh copy failed for Notes.txt'
      The value "$(ls -A "$SB/remote/incoming")" should equal ''
      The path "$SB/state/ledger.jsonl" should not be exist
    End
  End

  Describe 'injection'
    # Spaces, both quote kinds, a command substitution, a backtick, a
    # semicolon and a leading `-`: every shell hazard a filename can carry.
    evil_name() { print -r -- "-rf \$(touch PWNED) \`touch PWNED2\` \"dq\" 'sq'; touch PWNED3.txt"; }

    It 'delivers a hostile filename as inert data'
      evil="$SB/local/$(evil_name)"
      printf 'evil-bytes' >"$evil"
      When call share::send --to devbox -- "$evil"
      The status should be success
      The output should include 'incoming'
      The stderr should be present
      The contents of file "$(stamp_dir)/$(evil_name)" should equal 'evil-bytes'
      The path "$SB/remote/PWNED" should not be exist
      The path "$SB/remote/PWNED2" should not be exist
      The path "$SB/remote/PWNED3.txt" should not be exist
      The path "$(stamp_dir)/PWNED" should not be exist
    End

    It 'never puts the filename on the ssh command line'
      evil="$SB/local/$(evil_name)"
      printf 'evil-bytes' >"$evil"
      share::send --to devbox -- "$evil" >/dev/null 2>&1
      When call cat "$FAKE_SSH_LOG"
      The output should not include 'touch'
      The output should not include 'sq'
    End

    It 'prints the hostile path quoted, so pasting it runs nothing'
      evil="$SB/local/$(evil_name)"
      printf 'evil-bytes' >"$evil"
      out="$(share::send --to devbox -- "$evil" 2>/dev/null)"
      When call zsh -fc "cd '$SB'; for f in $out; do print -r -- \"\${f:t}\"; done"
      The output should equal "$(evil_name)"
    End

    It 'treats a hostile configured dir as inert data too'
      add_endpoint <<'TOML'
[evildir]
backend = "ssh"
target = "me@devshell.example.com"
dir = "in $(touch PWNED) `touch PWNED2`"
profiles = ["work"]
TOML
      When call share::send --to evildir "$SB/local/Report.pdf"
      The status should be success
      The output should include 'Report.pdf'
      The stderr should be present
      The path "$SB/remote/PWNED" should not be exist
      The path "$SB/remote/PWNED2" should not be exist
      The directory "$SB/remote/in \$(touch PWNED) \`touch PWNED2\`" should be exist
    End

    It 'removes a hostile filename on revoke without running it'
      evil="$SB/local/$(evil_name)"
      printf 'evil-bytes' >"$evil"
      share::send --to devbox -- "$evil" >/dev/null 2>&1
      id="$(jq -r '.id' "$SB/state/ledger.jsonl")"
      d="$(stamp_dir)"
      When call share::revoke "$id"
      The status should be success
      The path "$d" should not be exist
      The path "$SB/remote/PWNED" should not be exist
      The path "$SB/remote/PWNED3.txt" should not be exist
    End
  End

  Describe 'revoke'
    It 'removes exactly the copied paths and nothing else'
      printf 'keep' >"$SB/remote/sibling.txt"
      share::send --to devbox "$SB/local/Report.pdf" "$SB/local/Notes.txt" >/dev/null 2>&1
      d="$(stamp_dir)"
      mkdir -p "$SB/remote/incoming/older"; printf 'old' >"$SB/remote/incoming/older/Report.pdf"
      printf 'added later' >"$d/other.txt"
      id="$(jq -r '.id' "$SB/state/ledger.jsonl")"
      When call share::revoke "$id"
      The status should be success
      The path "$d/Report.pdf" should not be exist
      The path "$d/Notes.txt" should not be exist
      The contents of file "$d/other.txt" should equal 'added later'
      The contents of file "$SB/remote/incoming/older/Report.pdf" should equal 'old'
      The contents of file "$SB/remote/sibling.txt" should equal 'keep'
    End

    It 'removes the per-share directory once it is empty, and forgets the receipt'
      share::send --to devbox "$SB/local/Report.pdf" >/dev/null 2>&1
      d="$(stamp_dir)"
      id="$(jq -r '.id' "$SB/state/ledger.jsonl")"
      When call share::revoke "$id"
      The status should be success
      The path "$d" should not be exist
      The directory "$SB/remote/incoming" should be exist
      The contents of file "$SB/state/ledger.jsonl" should equal ''
    End

    It 'uses the target recorded in the receipt, not the current manifest'
      share::send --to devbox "$SB/local/Report.pdf" >/dev/null 2>&1
      id="$(jq -r '.id' "$SB/state/ledger.jsonl")"
      sed 's/me@devshell.example.com/other@elsewhere.example.com/' "$SHARE_ENDPOINTS_FILE" >"$SB/e.toml"
      mv "$SB/e.toml" "$SHARE_ENDPOINTS_FILE"
      : >"$FAKE_SSH_LOG"
      share::revoke "$id"
      When call cat "$FAKE_SSH_LOG"
      The output should include 'me@devshell.example.com'
      The output should not include 'elsewhere'
    End

    It 'refuses a receipt whose names could escape the share directory'
      ref='{"target":"me@devshell.example.com","dir":"/tmp/x","names":["../etc"]}'
      share::ledger_add bad ssh devbox label "$ref" line 0
      When call share::revoke bad
      The status should be failure
      The stderr should include 'refusing'
      The value "$(ssh_calls)" should equal 0
    End

    It 'keeps the receipt when the remote removal fails'
      share::send --to devbox "$SB/local/Report.pdf" >/dev/null 2>&1
      id="$(jq -r '.id' "$SB/state/ledger.jsonl")"
      FAKE_SSH_FAIL_CALL=2
      When call share::revoke "$id"
      The status should be failure
      The stderr should include 'could not remove'
      The contents of file "$SB/state/ledger.jsonl" should include "$id"
    End
  End

  Describe 'refusals, before any transfer'
    It 'is never chosen implicitly, even when it claims default_for'
      add_endpoint <<'TOML'
[implicit]
backend = "ssh"
target = "me@devshell.example.com"
dir = "incoming"
profiles = ["personal"]
default_for = ["personal"]
TOML
      SHARE_PROFILE=personal
      When call share::send "$SB/local/Report.pdf"
      The status should be failure
      The stderr should include 'never chosen implicitly'
      The value "$(ssh_calls)" should equal 0
    End

    It 'rejects an ssh endpoint that claims default_for even with --to'
      add_endpoint <<'TOML'
[claims]
backend = "ssh"
target = "me@devshell.example.com"
dir = "incoming"
profiles = ["work"]
default_for = ["personal"]
TOML
      When call share::send --to claims "$SB/local/Report.pdf"
      The status should be failure
      The stderr should include 'default_for'
      The value "$(ssh_calls)" should equal 0
    End

    It 'refuses an explicit --live'
      When call share::send --to devbox --live "$SB/local/Report.pdf"
      The status should be failure
      The stderr should include 'no live mode'
      The value "$(ssh_calls)" should equal 0
    End

    It 'refuses --qr'
      When call share::send --to devbox --qr "$SB/local/Report.pdf"
      The status should be failure
      The stderr should include '--qr does not apply'
      The value "$(ssh_calls)" should equal 0
    End

    It 'refuses an explicit --expiration'
      When call share::send --to devbox --expiration 3d "$SB/local/Report.pdf"
      The status should be failure
      The stderr should include '--expiration does not apply'
      The value "$(ssh_calls)" should equal 0
    End

    It 'refuses web = true (there is no web link to make)'
      add_endpoint <<'TOML'
[webby]
backend = "ssh"
target = "me@devshell.example.com"
dir = "incoming"
web = true
profiles = ["work"]
TOML
      When call share::send --to webby "$SB/local/Report.pdf"
      The status should be failure
      The stderr should include 'web links'
      The value "$(ssh_calls)" should equal 0
    End

    It 'names the missing target'
      add_endpoint <<'TOML'
[notarget]
backend = "ssh"
dir = "incoming"
profiles = ["work"]
TOML
      When call share::send --to notarget "$SB/local/Report.pdf"
      The status should be failure
      The stderr should include 'notarget has no target'
      The value "$(ssh_calls)" should equal 0
    End

    It 'names the missing dir'
      add_endpoint <<'TOML'
[nodir]
backend = "ssh"
target = "me@devshell.example.com"
profiles = ["work"]
TOML
      When call share::send --to nodir "$SB/local/Report.pdf"
      The status should be failure
      The stderr should include 'nodir has no dir'
      The value "$(ssh_calls)" should equal 0
    End

    It 'refuses an ssh endpoint that also sets store'
      add_endpoint <<'TOML'
[withstore]
backend = "ssh"
target = "me@devshell.example.com"
dir = "incoming"
store = "https://store.example.com/drop"
profiles = ["work"]
TOML
      When call share::send --to withstore "$SB/local/Report.pdf"
      The status should be failure
      The stderr should include 'withstore sets store'
      The value "$(ssh_calls)" should equal 0
    End

    It 'refuses an ssh endpoint that also sets remote'
      add_endpoint <<'TOML'
[withremote]
backend = "ssh"
target = "me@devshell.example.com"
dir = "incoming"
remote = "onedrive:Shared/drop"
profiles = ["work"]
TOML
      When call share::send --to withremote "$SB/local/Report.pdf"
      The status should be failure
      The stderr should include 'withremote sets remote'
      The value "$(ssh_calls)" should equal 0
    End

    It 'never echoes the store host for an ssh endpoint that also sets store'
      add_endpoint <<'TOML'
[withstore2]
backend = "ssh"
target = "me@devshell.example.com"
dir = "incoming"
store = "https://wrong-host.example.com/drop"
profiles = ["work"]
TOML
      When call share::destination_host withstore2
      The status should be failure
      The stderr should include 'withstore2 sets store'
      The output should not include 'wrong-host.example.com'
    End

    It 'resolves destination_host to the target host for a clean ssh endpoint'
      When call share::destination_host devbox
      The status should be success
      The output should equal 'devshell.example.com'
    End

    It 'rejects a target that ssh would read as an option'
      add_endpoint <<'TOML'
[dashy]
backend = "ssh"
target = "-oProxyCommand=touch PWNED"
dir = "incoming"
profiles = ["work"]
TOML
      When call share::send --to dashy "$SB/local/Report.pdf"
      The status should be failure
      The stderr should include 'invalid target'
      The value "$(ssh_calls)" should equal 0
    End

    It 'refuses a directory'
      mkdir -p "$SB/local/adir"
      When call share::send --to devbox "$SB/local/adir"
      The status should be failure
      The stderr should include 'regular files only'
      The value "$(ssh_calls)" should equal 0
    End

    It 'refuses two files with the same name'
      mkdir -p "$SB/local/b"; printf 'z' >"$SB/local/b/Report.pdf"
      When call share::send --to devbox "$SB/local/Report.pdf" "$SB/local/b/Report.pdf"
      The status should be failure
      The stderr should include 'same name'
      The value "$(ssh_calls)" should equal 0
    End

    It 'refuses a backgrounded implicit send before enqueuing anything'
      add_endpoint <<'TOML'
[implicit]
backend = "ssh"
target = "me@devshell.example.com"
dir = "incoming"
profiles = ["personal"]
default_for = ["personal"]
TOML
      SHARE_PROFILE=personal
      cat >"$SB/bin/pueue" <<'SH'
#!/bin/sh
printf 'pueue %s\n' "$*" >>"$FAKE_SSH_LOG"
SH
      chmod +x "$SB/bin/pueue"
      JOB_PUEUE_BIN="$SB/bin/pueue"; export JOB_PUEUE_BIN
      When call share::send_background "$SB/local/Report.pdf"
      The status should be failure
      The stderr should include 'never chosen implicitly'
      The contents of file "$FAKE_SSH_LOG" should equal ''
    End

    It 'refuses a backgrounded --qr before enqueuing anything'
      cat >"$SB/bin/pueue" <<'SH'
#!/bin/sh
printf 'pueue %s\n' "$*" >>"$FAKE_SSH_LOG"
SH
      chmod +x "$SB/bin/pueue"
      JOB_PUEUE_BIN="$SB/bin/pueue"; export JOB_PUEUE_BIN
      When call share::send_background --to devbox --qr "$SB/local/Report.pdf"
      The status should be failure
      The stderr should include '--qr does not apply'
      The contents of file "$FAKE_SSH_LOG" should equal ''
    End
  End

  Describe 'status and list'
    It 'shows an ssh endpoint, probing the port ssh -G resolves'
      cat >"$SB/bin/nc" <<'SH'
#!/bin/sh
case "$*" in *"devshell.example.com 2222"*) exit 0 ;; esac
exit 1
SH
      chmod +x "$SB/bin/nc"
      SHARE_NC_BIN="$SB/bin/nc"
      When call share::status devbox
      The status should be success
      The output should include 'devbox'
      The output should include 'ssh'
      The output should include 'me@devshell.example.com:~/incoming'
      The output should include 'sshd reachable'
    End

    It 'reports an unreachable ssh endpoint'
      cat >"$SB/bin/nc" <<'SH'
#!/bin/sh
exit 1
SH
      chmod +x "$SB/bin/nc"
      SHARE_NC_BIN="$SB/bin/nc"
      When call share::status devbox
      The output should include 'NOT REACHABLE'
    End

    It 'lists an ssh receipt'
      share::send --to devbox "$SB/local/Report.pdf" >/dev/null 2>&1
      When call share::ledger_list
      The output should include '"backend": "ssh"'
      The output should include 'Report.pdf'
    End

    It 'names the ssh host in the pre-send echo'
      When call share::destination_host devbox
      The output should equal 'devshell.example.com'
    End
  End
End
