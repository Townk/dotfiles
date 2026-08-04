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

# R-batch Task A: front-matter `alias:` becomes a space-separated list of full
# entry points (Host name + hooked Match) — the FIRST token stays the primary
# ($alias/arg2: fragment filename, ssh target, theme key), every other token
# gets exactly the same treatment. These examples hand-edit the `# alias:`
# line the same way the peer-hostname examples above hand-edit
# `# peer-hostname:`, then re-render via run_write to prove system-onboard
# picks up the hand-authored list.
Describe 'system-onboard: write_ssh_conf (alias lists / R-batch Task A)'
  SCRIPT="$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_system-onboard"

  setup() {
    CONFDIR="$(mktemp -d "$SHELLSPEC_TMPBASE/ssh-conf-alias.XXXXXX")"
    export SCRIPT_PATH="$SCRIPT" CONFDIR
  }
  BeforeEach 'setup'

  run_write() {
    zsh -f -c '
      export SYSTEM_ONBOARD_NO_RUN=1
      source "$SCRIPT_PATH"
      write_ssh_conf "$@"
    ' _ "$@"
  }

  It 'renders every front-matter alias token as a full Host + hook entry point'
    conf="$CONFDIR/mac-mini.conf"
    run_write "$conf" mac-mini mac-mini.local 1 thiago-mac-mini >/dev/null
    sed -i '' 's/^# alias:.*/# alias: mac-mini mini m1/' "$conf"
    When call run_write "$conf" mac-mini mac-mini.local 1
    The status should be success
    The contents of file "$conf" should include "Host mac-mini mini m1 thiago-mac-mini thiago-mac-mini.local"
    The contents of file "$conf" should include 'Match originalhost mac-mini,mini,m1,thiago-mac-mini.local exec'
  End

  It 'drops a glob-unsafe alias token instead of letting it reach the Host/hook lines'
    conf="$CONFDIR/mac-mini.conf"
    run_write "$conf" mac-mini mac-mini.local 1 >/dev/null
    sed -i '' 's/^# alias:.*/# alias: mac-mini */' "$conf"
    When call run_write "$conf" mac-mini mac-mini.local 1
    The status should be success
    The stderr should include "not a safe ssh Host name"
    The contents of file "$conf" should include "Host mac-mini"
    The contents of file "$conf" should not include "Host mac-mini *"
    The contents of file "$conf" should not include 'Match originalhost mac-mini,*'
  End

  # The alias list carries an EXTRA name (mini) beyond primary + peer-name,
  # so this can only pass through the list renderer's dedupe path — the old
  # single-alias renderer would omit `mini` entirely. Also pins the explicit
  # opt-in judgment: a HAND-LISTED alias equal to the captured peer hostname
  # is a full configured entry point, so the bare peer name IS hooked here
  # (unlike the auto-captured-only case, which stays hook-exempt).
  It 'dedupes a front-matter alias that already names the captured peer hostname'
    conf="$CONFDIR/mac-mini.conf"
    run_write "$conf" mac-mini mac-mini.local 1 >/dev/null
    sed -i '' 's/^# alias:.*/# alias: mac-mini mini thiago-mac-mini/' "$conf"
    run_write "$conf" mac-mini mac-mini.local 1 thiago-mac-mini >/dev/null
    When run command grep -E '^Host mac-mini mini thiago-mac-mini thiago-mac-mini\.local$' "$conf"
    The status should be success
    The output should equal "Host mac-mini mini thiago-mac-mini thiago-mac-mini.local"
  End

  It 'hooks a hand-listed alias even when it equals the captured peer hostname (explicit opt-in)'
    conf="$CONFDIR/mac-mini.conf"
    run_write "$conf" mac-mini mac-mini.local 1 >/dev/null
    sed -i '' 's/^# alias:.*/# alias: mac-mini mini thiago-mac-mini/' "$conf"
    When call run_write "$conf" mac-mini mac-mini.local 1 thiago-mac-mini
    The status should be success
    The contents of file "$conf" should include 'Match originalhost mac-mini,mini,thiago-mac-mini,thiago-mac-mini.local exec'
  End
End

# MED-4: a headless box a PRIOR operator onboarded already carries an
# authoritative `secretsSlot` in its own chezmoi config, but the alias->slot
# record is per-operator (the loose operator map, never committed). A SECOND
# operator laptop — whose map has no entry for the box — must NOT treat the box
# as unallocated and mint a FRESH slot (which adds a second .sops.yaml rule and
# a new secrets/<slot> tree, orphaning the old and letting the box source BOTH
# fragments). detect_remote_self_onboard reads the box's own `chezmoi data`
# .secretsSlot (kind-agnostic), and assign_slot must reuse that slot instead of
# minting. These examples source the script (main() suppressed) and drive the
# operator-driven headless path (detect + assign_slot) with the remote read and
# slot minting stubbed, exactly as main() sequences them.
Describe 'system-onboard: headless slot reuse (MED-4)'
  SCRIPT="$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_system-onboard"

  setup() {
    WORK="$(mktemp -d "$SHELLSPEC_TMPBASE/onboard-med4.XXXXXX")"
    export SCRIPT_PATH="$SCRIPT"
    export STUB_SLOT="slot-d00d42"        # the box's authoritative slot
    export MAP="$WORK/onboard-map.yaml"   # absent => this operator's map is empty
    export SOPS="$WORK/.sops.yaml"
    export MINTED="$WORK/minted.log"      # touched iff sec::gen_slot is called
  }
  BeforeEach 'setup'

  # rexec is stubbed to serve the box's `chezmoi data` (secretsSlot + profile);
  # sec::gen_slot is instrumented so a mint leaves evidence. KIND/ALIAS/PROFILE/
  # RECIPIENT and the loose-layer paths are set AFTER sourcing (the script's own
  # top-level assignments would otherwise reset them).
  run_assign() {
    zsh -f -c '
      export SYSTEM_ONBOARD_NO_RUN=1
      source "$SCRIPT_PATH"
      rexec() { case "$*" in
        (*"chezmoi data"*) printf "secretsSlot: %s\nprofile: dev-shell\n" "$STUB_SLOT" ;;
        (*) return 0 ;;
      esac }
      sec::gen_slot() { print -r -- minted >>"$MINTED"; printf "slot-badf00"; }
      KIND=headless ALIAS=test-box PROFILE=dev-shell
      RECIPIENT="age1exampleexampleexampleexampleexampleexampleexam00000"
      OPERATOR_MAP="$MAP" SOPS_YAML="$SOPS"
      detect_remote_self_onboard
      assign_slot
      print -r -- "SLOT=$SLOT"
    ' _
  }

  It 'reuses the box own secretsSlot and never mints a fresh one'
    When call run_assign
    The status should be success
    The output should include "SLOT=slot-d00d42"
    The path "$MINTED" should not be exist
  End

  It 'sets the sops rule for the reused slot only (no second rule)'
    When call run_assign
    The status should be success
    The output should include "SLOT=slot-d00d42"
    The contents of file "$SOPS" should include "secrets/slot-d00d42/"
    The contents of file "$SOPS" should not include "slot-badf00"
  End
End

# MED-4 follow-up: MED-4 stopped a re-onboard from MINTING a second slot, but a
# box ALREADY left in the dual-fragment state still physically carries BOTH
# ~/.config/zsh/secrets.d/<slot>.sh fragments — secrets.sh globs *.sh and
# sources both, and the alphabetically-later slot silently wins overlapping
# vars. chezmoi never prunes the stale one (it is .chezmoiignore'd on this box,
# so chezmoi neither manages nor removes it). converge_remote's prune step
# removes every stale slot-*.sh that is NOT the box's active slot, over the same
# rexec channel onboarding already uses. SAFETY: an empty active slot must wipe
# NOTHING; the active fragment must be confirmed present before anything is
# pruned (a broken apply must not strip ALL secrets); only slot-shaped names are
# ever removed (a hand-placed custom.sh is left alone); --dry-run removes
# nothing; failures are logged, never fatal. These examples source the script
# (main() suppressed), stub rexec so the `test -r` active-fragment probe and the
# enumerate call are served from env (ACTIVE_PRESENT/FRAGS) and every rm is
# RECORDED (never run), then call prune_remote_fragments directly.
Describe 'system-onboard: prune stale secret fragments (MED-4 follow-up)'
  SCRIPT="$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_system-onboard"

  setup() {
    WORK="$(mktemp -d "$SHELLSPEC_TMPBASE/onboard-prune.XXXXXX")"
    export SCRIPT_PATH="$SCRIPT"
    export REMOVED="$WORK/removed.log"          # each stubbed rm records its target here
    export ACTIVE_PRESENT=1                      # `test -r <active>.sh` result (1=present)
    export FRAGS="slot-AAA.sh slot-BBB.sh"       # what the enumerate call lists
  }
  BeforeEach 'setup'

  # rexec is stubbed: the `test -r` probe returns per $ACTIVE_PRESENT, the
  # enumerate call lists $FRAGS (one per line), and every `rm` is recorded to
  # $REMOVED instead of touching a real remote. SLOT/DRY_RUN/ALIAS are set AFTER
  # sourcing (the script's own top-level assignments would otherwise reset them).
  # $1=active slot, $2=DRY_RUN.
  run_prune() {
    zsh -f -c '
      export SYSTEM_ONBOARD_NO_RUN=1
      source "$SCRIPT_PATH"
      rexec() { case "$*" in
        (*"test -r ~/.config/zsh/secrets.d/"*)
          [ "${ACTIVE_PRESENT:-1}" = 1 ] && return 0 || return 1 ;;
        (*"for f in ~/.config/zsh/secrets.d"*)
          for x in ${=FRAGS}; do print -r -- "$x"; done ;;
        (*"rm -f ~/.config/zsh/secrets.d/"*) print -r -- "$*" >>"$REMOVED" ;;
        (*) return 0 ;;
      esac }
      SLOT="$1"; DRY_RUN="$2"; ALIAS=test-box
      prune_remote_fragments
    ' _ "$@"
  }

  It 'removes only the non-active fragment and keeps the active slot'
    When call run_prune slot-AAA 0
    The status should be success
    The stdout should include "removed stale secret fragment slot-BBB.sh"
    The path "$REMOVED" should be exist
    The contents of file "$REMOVED" should include "rm -f ~/.config/zsh/secrets.d/slot-BBB.sh"
    The contents of file "$REMOVED" should not include "slot-AAA.sh"
  End

  It 'removes NOTHING when the active slot is empty (guard against a wipe)'
    When call run_prune "" 0
    The status should be success
    The stderr should include "active slot is empty"
    The path "$REMOVED" should not be exist
  End

  It 'removes NOTHING when the active fragment is absent on the remote (broken apply)'
    export ACTIVE_PRESENT=0
    When call run_prune slot-AAA 0
    The status should be success
    The stderr should include "not present on"
    The stderr should include "refusing to prune"
    The path "$REMOVED" should not be exist
  End

  It 'prunes only slot-shaped fragments and leaves a hand-placed custom.sh alone'
    export FRAGS="slot-AAA.sh slot-BBB.sh custom.sh"
    When call run_prune slot-AAA 0
    The status should be success
    The stdout should include "removed stale secret fragment slot-BBB.sh"
    The stdout should include "leaving non-slot fragment 'custom.sh'"
    The path "$REMOVED" should be exist
    The contents of file "$REMOVED" should include "rm -f ~/.config/zsh/secrets.d/slot-BBB.sh"
    The contents of file "$REMOVED" should not include "custom.sh"
    The contents of file "$REMOVED" should not include "slot-AAA.sh"
  End

  It 'removes nothing and logs the intent under --dry-run'
    When call run_prune slot-AAA 1
    The status should be success
    The stdout should include "[dry-run] would remove"
    The stdout should include "slot-BBB.sh"
    The path "$REMOVED" should not be exist
  End
End

# Profile validation for the server profile (headless, operator-onboarded).
# validate_inputs is called directly in a fresh zsh -f via the
# SYSTEM_ONBOARD_NO_RUN escape hatch; no SSH, no chezmoi state is touched.
Describe 'system-onboard: server profile validation'
  SCRIPT="$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_system-onboard"

  setup() { export SCRIPT_PATH="$SCRIPT"; }
  BeforeEach 'setup'

  # run_validate <profile> [kind] — remote-onboarding arg validation; prints
  # the resolved kind on success.
  run_validate() {
    zsh -f -c '
      export SYSTEM_ONBOARD_NO_RUN=1
      source "$SCRIPT_PATH"
      ALIAS=box HOSTNAME=box.local PROFILE="$1" KIND="${2:-}" LOCAL=0 PREPARE=""
      validate_inputs
      print -r -- "kind=$KIND"
    ' _ "$@"
  }

  It 'accepts --profile server and defaults kind to headless'
    When call run_validate server
    The status should be success
    The output should include "kind=headless"
  End

  It 'still defaults dev-shell to headless and personal to human'
    When call run_validate dev-shell
    The output should include "kind=headless"
  End

  It 'defaults personal to human'
    When call run_validate personal
    The output should include "kind=human"
  End

  It 'rejects unknown profiles'
    When call run_validate laptop
    The status should be failure
    The stderr should include "invalid profile"
  End

  It 'refuses --local for the server profile (operator-onboarded over SSH)'
    When call zsh -f -c '
      export SYSTEM_ONBOARD_NO_RUN=1
      source "$SCRIPT_PATH"
      chezmoi() { print "profile: server" }   # stub: this machine claims server
      ALIAS="" HOSTNAME="" PROFILE=server KIND="" LOCAL=1 PREPARE=""
      validate_inputs
    ' _
    The status should be failure
    The stderr should include "human-only"
  End
End
