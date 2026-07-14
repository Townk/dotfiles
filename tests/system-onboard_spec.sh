# Tests for system-onboard's write_ssh_conf (R2: emit the peer's LocalHostName
# as an extra ssh alias). The clipboard store stamps a file clip's
# `source_host` with the ORIGIN machine's own LocalHostName (see pbcopy's
# `scutil --get LocalHostName || hostname -s`), not the alias this machine
# calls it by, so a puller's `rsync -e ssh $source_host:...` only resolves if
# this machine's ssh config also answers to that exact name. write_ssh_conf
# seeds it into the fragment's front matter (`# peer-hostname: <name>`) the
# first time a caller passes a hint, then preserves it verbatim on every later
# render (same "preserve once, then hands-off" contract as `alias`/`prepare`),
# so `system-onboard update <alias> --clipboard|--prepare` can reconstruct the
# extra `Host` name without reconnecting.
#
# system-onboard is a zsh script that runs `main "$@"` unconditionally at the
# bottom -- SYSTEM_ONBOARD_NO_RUN is a test-only escape hatch (mirrors
# PICK_CLIPBOARD_NO_RUN in executable_pick-clipboard) that returns before
# main() so a test can `source` the file and call write_ssh_conf directly.
# write_ssh_conf only ever writes to the $conf path it's given -- it never
# touches the real ~/.ssh, so no HOME sandboxing is needed here.
Describe 'system-onboard: write_ssh_conf (peer-hostname / R2)'
  SCRIPT="$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_system-onboard"

  setup() {
    # mktemp, not $RANDOM: each example's setup runs in its own subshell with
    # the same seed, so a $RANDOM-suffixed path repeats and leaks a previous
    # example's fragment into the next.
    CONFDIR="$(mktemp -d "$SHELLSPEC_TMPBASE/ssh-conf.XXXXXX")"
    export SCRIPT_PATH="$SCRIPT" CONFDIR
  }
  BeforeEach 'setup'

  # Runs write_ssh_conf <conf> <alias> <hostname> <want_clip> [peer_hint] in a
  # fresh zsh -f (no rc files) that sources the script under
  # SYSTEM_ONBOARD_NO_RUN, then calls the function directly.
  run_write() {
    zsh -f -c '
      export SYSTEM_ONBOARD_NO_RUN=1
      source "$SCRIPT_PATH"
      write_ssh_conf "$@"
    ' _ "$@"
  }

  It 'renders a bare Host line when no peer hint is given yet (fresh onboarding, pre-verify_access)'
    conf="$CONFDIR/mac-mini.conf"
    When call run_write "$conf" mac-mini mac-mini.local 1
    The status should be success
    The contents of file "$conf" should include "Host mac-mini"
    The contents of file "$conf" should not include "Host mac-mini thiago-mac-mini"
  End

  It 'adds the peer LocalHostName as a second Host name the first time a hint is captured'
    conf="$CONFDIR/mac-mini.conf"
    run_write "$conf" mac-mini mac-mini.local 1 >/dev/null   # simulates reconcile_ssh
    When call run_write "$conf" mac-mini mac-mini.local 1 thiago-mac-mini
    The status should be success
    The contents of file "$conf" should include "Host mac-mini thiago-mac-mini"
    The contents of file "$conf" should include "# peer-hostname: thiago-mac-mini"
  End

  It 'renders the mDNS .local form as a third Host name and a hooked entry point'
    conf="$CONFDIR/mac-mini.conf"
    run_write "$conf" mac-mini mac-mini.local 1 >/dev/null
    When call run_write "$conf" mac-mini mac-mini.local 1 thiago-mac-mini
    The status should be success
    The contents of file "$conf" should include "Host mac-mini thiago-mac-mini thiago-mac-mini.local"
    # The hook's originalhost list ends at ' exec', so this single substring
    # pins the ENTIRE list: alias + .local hooked, bare peer hostname (the
    # machine-to-machine pull identity) deliberately absent. The retired
    # clipboard.config scoped its forward to the .local name; quick-launch /
    # human FQDN sessions must keep getting the forwards AND the prep hook.
    The contents of file "$conf" should include 'Match originalhost mac-mini,thiago-mac-mini.local exec'
  End

  It 'keeps the alias-only hook when no peer hostname is known'
    conf="$CONFDIR/fresh.conf"
    When call run_write "$conf" fresh fresh.local 1
    The status should be success
    The contents of file "$conf" should include 'Match originalhost fresh exec'
    The contents of file "$conf" should not include ".local exec"
  End

  It 'reconciles with the hand-fixed laptop fragment: alias mac-mini + peer thiago-mac-mini both resolve'
    conf="$CONFDIR/mac-mini.conf"
    run_write "$conf" mac-mini mac-mini.local 1 thiago-mac-mini >/dev/null
    When run command grep -E '^Host mac-mini thiago-mac-mini thiago-mac-mini\.local$' "$conf"
    The status should be success
    The output should equal "Host mac-mini thiago-mac-mini thiago-mac-mini.local"
  End

  It 'preserves the extra Host alias on a later re-render with no hint (system-onboard update)'
    conf="$CONFDIR/mac-mini.conf"
    run_write "$conf" mac-mini mac-mini.local 1 thiago-mac-mini >/dev/null
    # `update --clipboard`/`--prepare` never re-derives peer_hint (no rexec) --
    # simulate that by calling write_ssh_conf with the 5th arg omitted.
    When call run_write "$conf" mac-mini mac-mini.local 0
    The status should be success
    The contents of file "$conf" should include "Host mac-mini thiago-mac-mini"
    The contents of file "$conf" should not include "RemoteForward 127.0.0.1:2490 127.0.0.1:2489"
  End

  It 'skips the extra Host name when the peer LocalHostName equals the alias'
    conf="$CONFDIR/same-name.conf"
    When call run_write "$conf" same-name host.local 0 same-name
    The status should be success
    The contents of file "$conf" should include "Host same-name"
    The contents of file "$conf" should not include "Host same-name same-name"
  End

  It 'hooks the human entry points (alias + .local) but never the bare peer name (pull identity)'
    conf="$CONFDIR/mac-mini.conf"
    When call run_write "$conf" mac-mini mac-mini.local 1 thiago-mac-mini
    The status should be success
    # The originalhost list ends at ' exec', so this substring pins the whole
    # list: bare thiago-mac-mini (rsync/GUI pull identity) cannot be in it.
    The contents of file "$conf" should include 'Match originalhost mac-mini,thiago-mac-mini.local exec'
    The contents of file "$conf" should not include 'Match originalhost thiago-mac-mini'
  End

  It 'hand-edited front matter wins: a later hint never overrides an existing peer-hostname line'
    conf="$CONFDIR/mac-mini.conf"
    run_write "$conf" mac-mini mac-mini.local 1 thiago-mac-mini >/dev/null
    sed -i '' 's/^# peer-hostname:.*/# peer-hostname: hand-edited-name/' "$conf"
    When call run_write "$conf" mac-mini mac-mini.local 1 some-other-hint
    The status should be success
    The contents of file "$conf" should include "Host mac-mini hand-edited-name"
    The contents of file "$conf" should not include "some-other-hint"
  End

  # ssh `Host` patterns GLOB: an unvalidated `*` would match every outgoing
  # host and silently extend this fragment's RemoteForwards (clipboard
  # bridge, gpg agent) to all of them. valid_peer_hostname allowlists
  # [A-Za-z0-9][A-Za-z0-9.-]* at BOTH ends — hint acceptance and front-matter
  # read-back (front matter is hand-editable, so persisted values are
  # re-checked on every render).
  It 'rejects a glob peer-hostname hint: never persisted, never on the Host line'
    conf="$CONFDIR/mac-mini.conf"
    When call run_write "$conf" mac-mini mac-mini.local 1 '*'
    The status should be success
    The stderr should include "not a safe ssh Host name"
    The contents of file "$conf" should not include "peer-hostname"
    The contents of file "$conf" should include "Host mac-mini"
    The contents of file "$conf" should not include "Host mac-mini *"
  End

  It 'ignores a hand-edited glob peer-hostname in front matter (defense in depth): bare Host line'
    conf="$CONFDIR/mac-mini.conf"
    run_write "$conf" mac-mini mac-mini.local 1 thiago-mac-mini >/dev/null
    sed -i '' 's/^# peer-hostname:.*/# peer-hostname: */' "$conf"
    When call run_write "$conf" mac-mini mac-mini.local 1
    The status should be success
    The stderr should include "not a safe ssh Host name"
    The contents of file "$conf" should not include "Host mac-mini *"
    The contents of file "$conf" should include "Host mac-mini"
  End

  It 'rejects a leading-dash capture: no peer-hostname persisted'
    conf="$CONFDIR/shapes.conf"
    When call run_write "$conf" shapes host.local 0 '-lead'
    The status should be success
    The stderr should include "not a safe ssh Host name"
    The contents of file "$conf" should not include "peer-hostname"
    The contents of file "$conf" should not include "Host shapes -lead"
  End

  It 'accepts a valid dotted peer hostname on the Host line — with no bogus .local variant'
    conf="$CONFDIR/shapes.conf"
    run_write "$conf" shapes host.local 0 'peer.example.com' >/dev/null
    When run command grep -E '^Host ' "$conf"
    The status should be success
    The output should equal "Host shapes peer.example.com"
  End
End
