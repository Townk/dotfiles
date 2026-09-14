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
    # 6c: the clipboard block carries BOTH directions — the reverse forward
    # (their reads of our clipboard) and the visited-direction LocalForward
    # (our pointer pushes to their bridge at copy time).
    The contents of file "$conf" should include "RemoteForward 127.0.0.1:2490 127.0.0.1:2489"
    The contents of file "$conf" should include "LocalForward 127.0.0.1:2491 127.0.0.1:2489"
    # 6c part 2: the visiting machine's read-only file plane rides along.
    The contents of file "$conf" should include "RemoteForward 127.0.0.1:2493 127.0.0.1:2492"
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
    The contents of file "$conf" should not include "LocalForward 127.0.0.1:2491 127.0.0.1:2489"
    The contents of file "$conf" should not include "RemoteForward 127.0.0.1:2493 127.0.0.1:2492"
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

  setup() { export SCRIPT_PATH="$SCRIPT" SRC_HOME="$SHELLSPEC_PROJECT_ROOT/home" LIB_PATH="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib/system-secrets-common.zsh"; }
  BeforeEach 'setup'

  # run_validate <profile> [kind] — remote-onboarding arg validation; prints
  # the resolved kind on success. SECRETS_SRC_DIR feeds the traits lookup
  # (main() sets it via sec::repo_paths; the harness never runs main).
  run_validate() {
    zsh -f -c '
      export SYSTEM_ONBOARD_NO_RUN=1 SYSTEM_SECRETS_LIB="$LIB_PATH"
      source "$SCRIPT_PATH"
      SECRETS_SRC_DIR="$SRC_HOME"
      ALIAS=box HOSTNAME=box.local PROFILE="$1" KIND="${2:-}" LOCAL=0 PREPARE="" LOGIN_USER=""
      validate_inputs
      print -r -- "kind=$KIND prepare=$PREPARE"
    ' _ "$@"
  }

  # Default prep steps follow the kind: the pickers' symbols DB and the gpg
  # forward only reach a headless box through the pre-connect steps.
  It 'defaults --prepare to all for a headless target'
    When call run_validate server
    The output should include "prepare=all"
  End

  It 'defaults --prepare to theme for a human target'
    When call run_validate personal
    The output should include "prepare=theme"
  End

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
      export SYSTEM_ONBOARD_NO_RUN=1 SYSTEM_SECRETS_LIB="$LIB_PATH"
      source "$SCRIPT_PATH"
      SECRETS_SRC_DIR="$SRC_HOME"
      # stub: `chezmoi data` says this machine is server; every other chezmoi
      # call (the traits lookup) runs the real binary.
      chezmoi() { if [[ "$1" == data ]]; then print "profile: server"; else command chezmoi "$@"; fi }
      ALIAS="" HOSTNAME="" PROFILE=server KIND="" LOCAL=1 PREPARE="" LOGIN_USER=""
      validate_inputs
    ' _
    The status should be failure
    The stderr should include "human-only"
  End

  It 'has no profile-name case for kind: a headless answer from the helper is enough'
    When call grep -nE 'dev-shell \| server\) KIND' "$SCRIPT"
    The status should be failure
  End
End

# `--user`: the ssh login user for the target, stored as `# user:` front
# matter (preserve-once, hand-editable, like alias/prepare) and rendered as a
# `User` line right after HostName. Nothing in the committed layer carries it.
Describe 'system-onboard: write_ssh_conf (--user)'
  SCRIPT="$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_system-onboard"

  setup() {
    CONFDIR="$(mktemp -d "$SHELLSPEC_TMPBASE/ssh-user.XXXXXX")"
    export SCRIPT_PATH="$SCRIPT" CONFDIR
  }
  BeforeEach 'setup'

  # run_write_as <user> <conf> <alias> <hostname> <want_clip>
  run_write_as() {
    zsh -f -c '
      export SYSTEM_ONBOARD_NO_RUN=1
      source "$SCRIPT_PATH"
      LOGIN_USER="$1"; shift
      write_ssh_conf "$@"
    ' _ "$@"
  }

  It 'renders User directly after HostName when a login user is given'
    conf="$CONFDIR/box.conf"
    run_write_as admin "$conf" box box.example 0
    When call awk 'tolower($1)=="hostname"{h=NR} tolower($1)=="user"{print $2, NR-h}' "$conf"
    The output should equal "admin 1"
  End

  It 'seeds the user into the front matter and preserves it on a re-render without LOGIN_USER'
    conf="$CONFDIR/box.conf"
    run_write_as admin "$conf" box box.example 0
    run_write_as "" "$conf" box box.example 0
    When call grep -c -E '^# user: admin$|^    User admin$' "$conf"
    The output should equal 2
  End

  It 'renders no User line when no login user is known'
    conf="$CONFDIR/box.conf"
    run_write_as "" "$conf" box box.example 0
    When call grep -i '^    User ' "$conf"
    The status should be failure
  End

  It 'ignores a hand-edited unsafe user value instead of rendering it'
    conf="$CONFDIR/box.conf"
    # A hand-authored fragment whose front matter carries an unsafe value;
    # write_ssh_conf preserves the front matter and re-renders from Host down.
    printf '%s\n' '# ---' '# alias: box' '# prepare: theme' '# user: bad user' '# ---' \
      'Host box' '    HostName box.example' >"$conf"
    # 2>/dev/null: the invalid front-matter value trips a log_warn we don't
    # assert on here — only that the unsafe value never reaches the render.
    run_write_as "" "$conf" box box.example 0 2>/dev/null
    When call grep -i '^    User ' "$conf"
    The status should be failure
  End
End

Describe 'system-onboard: --user validation'
  SCRIPT="$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_system-onboard"
  setup() { export SCRIPT_PATH="$SCRIPT" SRC_HOME="$SHELLSPEC_PROJECT_ROOT/home" LIB_PATH="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib/system-secrets-common.zsh" }
  BeforeEach 'setup'

  validate_with_user() {   # <user> <local 0|1>
    zsh -f -c '
      export SYSTEM_ONBOARD_NO_RUN=1 SYSTEM_SECRETS_LIB="$LIB_PATH"
      source "$SCRIPT_PATH"
      SECRETS_SRC_DIR="$SRC_HOME"
      chezmoi() { if [[ "$1" == data ]]; then print "profile: personal"; else command chezmoi "$@"; fi }
      ALIAS=box HOSTNAME=box.local PROFILE=personal KIND="" LOCAL="$2" PREPARE="" LOGIN_USER="$1"
      (( LOCAL )) && HOSTNAME=""
      validate_inputs
      print -r -- "user=$LOGIN_USER"
    ' _ "$@"
  }

  It 'accepts a filename-safe login user'
    When call validate_with_user admin 0
    The status should be success
    The output should include "user=admin"
  End

  It 'rejects an unsafe login user'
    When call validate_with_user "bad user" 0
    The status should be failure
    The stderr should include "user must be"
  End

  It 'refuses --user together with --local'
    When call validate_with_user admin 1
    The status should be failure
    The stderr should include "--user is not used with --local"
  End
End

# Auto-bootstrap: a headless target missing chezmoi/mise/zsh gets the
# operator's checked-out .setup.sh streamed over the session; a human target
# keeps the refusal (its bootstrap needs a person at the keyboard). rexec is
# stubbed: the tool probe answers "all missing" until the stream ran.
Describe 'system-onboard: reconcile_remote_basics (auto-bootstrap)'
  SCRIPT="$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_system-onboard"
  LIB_PATH="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib/system-secrets-common.zsh"

  setup() {
    WORK="$(mktemp -d "$SHELLSPEC_TMPBASE/onboard-boot.XXXXXX")"
    printf '#!/bin/bash\necho SETUP_BODY\n' >"$WORK/.setup.sh"
    export SCRIPT_PATH="$SCRIPT" LIB_PATH WORK
  }
  BeforeEach 'setup'

  # run_basics <kind> <missing 0|1> — DRY_RUN off; REPO_ROOT is $WORK.
  run_basics() {
    zsh -f -c '
      export SYSTEM_ONBOARD_NO_RUN=1 SYSTEM_SECRETS_LIB="$LIB_PATH"
      source "$SCRIPT_PATH"
      ALIAS=box PROFILE=server KIND="$1" DRY_RUN=0 REPO_ROOT="$WORK"
      MARK="$WORK/streamed"
      (( $2 )) || : >"$MARK"
      rexec() {
        case "$*" in
          *"for t in"*) [[ -e "$MARK" ]] || print "chezmoi mise zsh " ;;
          *"bash -s"*)  print "STREAM: $*"; cat >"$WORK/stdin.txt"; : >"$MARK" ;;
        esac
        return 0
      }
      reconcile_remote_basics
    ' _ "$@"
  }

  It 'streams .setup.sh with the profile when a headless target lacks the tools'
    When call run_basics headless 1
    The status should be success
    The output should include "STREAM: bash -s -- --profile server"
    The output should include "bootstrap tools present"
    The contents of file "$WORK/stdin.txt" should include "SETUP_BODY"
  End

  It 'does not stream when every tool is present'
    When call run_basics headless 0
    The status should be success
    The output should not include "STREAM:"
  End

  It 'refuses a human target that lacks the tools, pointing at .setup.sh'
    When call run_basics human 1
    The status should be failure
    The stderr should include ".setup.sh --profile server"
  End

  It 'filters shell-rc noise out of the probe, keeping only real tool names'
    # rexec's stdout is whatever the target's shell prints before our command
    # runs (motd, an apt nag, an rc-file echo). Only "chezmoi" here is one of
    # BOOTSTRAP_TOOLS; the noise must never surface as a phantom missing tool.
    When call zsh -f -c '
      export SYSTEM_ONBOARD_NO_RUN=1 SYSTEM_SECRETS_LIB="$LIB_PATH"
      source "$SCRIPT_PATH"
      ALIAS=box PROFILE=server KIND=headless DRY_RUN=0 REPO_ROOT="$WORK"
      MARK="$WORK/streamed"
      rexec() {
        case "$*" in
          *"for t in"*) [[ -e "$MARK" ]] || print "Message of the day: updates available chezmoi " ;;
          *"bash -s"*)  print "STREAM: $*"; cat >"$WORK/stdin.txt"; : >"$MARK" ;;
        esac
        return 0
      }
      reconcile_remote_basics
    ' _
    The status should be success
    The output should include "(missing: chezmoi)"
    The output should not include "Message"
    The output should not include "updates"
  End

  It 'reports the intent under --dry-run without touching the remote'
    When call zsh -f -c '
      export SYSTEM_ONBOARD_NO_RUN=1 SYSTEM_SECRETS_LIB="$LIB_PATH"
      source "$SCRIPT_PATH"
      ALIAS=box PROFILE=server KIND=headless DRY_RUN=1 REPO_ROOT="$WORK"
      rexec() { print "MUST_NOT_RUN"; return 1 }
      reconcile_remote_basics
    ' _
    The status should be success
    The output should include "[dry-run]"
    The output should include ".setup.sh --profile server"
    The output should not include "MUST_NOT_RUN"
  End
End

# check_working_tree must tolerate the tool's OWN artifacts — a run that died
# mid-way (e.g. during secret entry) leaves the sops rule and blob dir dirty,
# and the rerun must reconcile them, not refuse itself. Unrelated tracked
# changes still block, naming the path. A throwaway git repo stands in for
# REPO_ROOT; signing is forced off so the fixture commit never touches gpg.
Describe 'system-onboard: check_working_tree (own artifacts vs unrelated dirt)'
  SCRIPT="$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_system-onboard"

  setup() {
    WORK="$(mktemp -d "$SHELLSPEC_TMPBASE/onboard-wt.XXXXXX")"
    export SCRIPT_PATH="$SCRIPT" WORK \
      LIB_PATH="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib/system-secrets-common.zsh"
    (
      cd "$WORK" &&
        git init -q &&
        mkdir -p secrets home/.chezmoidata home/dot_config/zsh/private_secrets.d &&
        printf 'creation_rules: []\n' >.sops.yaml &&
        printf 'secrets: []\n' >home/.chezmoidata/secrets.yaml &&
        printf '{}\n' >secrets/generations.yaml &&
        printf 'x\n' >README.md &&
        git add .sops.yaml home/.chezmoidata/secrets.yaml secrets/generations.yaml README.md &&
        git -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false \
          commit -q -m init
    ) >/dev/null 2>&1
  }
  BeforeEach 'setup'

  run_check() {
    zsh -f -c '
      export SYSTEM_ONBOARD_NO_RUN=1 SYSTEM_SECRETS_LIB="$LIB_PATH"
      source "$SCRIPT_PATH"
      REPO_ROOT="$WORK"
      SOPS_YAML="$WORK/.sops.yaml"
      MANIFEST="$WORK/home/.chezmoidata/secrets.yaml"
      GENERATIONS="$WORK/secrets/generations.yaml"
      SECRETS_BLOB_DIR="$WORK/secrets"
      FRAGMENT_DIR="$WORK/home/dot_config/zsh/private_secrets.d"
      NO_COMMIT=0 DRY_RUN=0
      check_working_tree && print clean-enough
    ' _
  }

  It 'passes a clean tree'
    When call run_check
    The status should be success
    The output should equal clean-enough
  End

  It 'tolerates a dirty sops rule, a staged manifest, and a new blob dir left by a failed run'
    printf 'creation_rules: [x]\n' >"$WORK/.sops.yaml"
    printf 'secrets: [y]\n' >"$WORK/home/.chezmoidata/secrets.yaml"
    git -C "$WORK" add home/.chezmoidata/secrets.yaml
    mkdir -p "$WORK/secrets/slot-abc123"
    printf 'blob\n' >"$WORK/secrets/slot-abc123/NAME.sops.sh"
    When call run_check
    The status should be success
    The output should equal clean-enough
  End

  It 'refuses an unrelated tracked change and names the path'
    printf 'y\n' >"$WORK/README.md"
    When call run_check
    The status should be failure
    The stderr should include "README.md"
  End

  It 'refuses an unrelated STAGED change too'
    printf 'y\n' >"$WORK/README.md"
    git -C "$WORK" add README.md
    When call run_check
    The status should be failure
    The stderr should include "README.md"
  End
End

# `--prepare` accepts a comma or space list; the fragment must carry the
# canonical space-separated form so the pre-connect hook (which reads it on
# every ssh) sees one token per step.
Describe 'system-onboard: --prepare is written space-separated'
  SCRIPT="$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_system-onboard"

  setup() {
    CONFDIR="$(mktemp -d "$SHELLSPEC_TMPBASE/ssh-prep.XXXXXX")"
    export SCRIPT_PATH="$SCRIPT" CONFDIR
  }
  BeforeEach 'setup'

  run_write_prepare() {   # <PREPARE> <conf>
    zsh -f -c '
      export SYSTEM_ONBOARD_NO_RUN=1
      source "$SCRIPT_PATH"
      PREPARE="$1"; shift
      write_ssh_conf "$@"
    ' _ "$@"
  }

  It 'normalizes a comma list in the seeded front matter and still renders the gpg forward'
    conf="$CONFDIR/box.conf"
    run_write_prepare "gpg,theme" "$conf" box box.example 0
    When call sh -c 'grep -c "^# prepare: gpg theme$" "$1"; grep -c "S.gpg-agent" "$1"' _ "$conf"
    The line 1 of output should equal 1
    The line 2 of output should equal 1
  End
End

# The gpg forward's listen path can only be resolved once the target has the
# provisioning script deployed (after the first apply). Rendering the pending
# placeholder from the start made every pre-apply connection print "remote
# port forwarding failed for listen path /nonexistent/…". During a first
# onboarding the line is deferred; an already-healed line is never dropped;
# once deferral ends the pending line renders and main() resolves it once.
Describe 'system-onboard: gpg forward deferral (first onboarding)'
  SCRIPT="$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_system-onboard"

  setup() {
    CONFDIR="$(mktemp -d "$SHELLSPEC_TMPBASE/ssh-gpgdefer.XXXXXX")"
    export SCRIPT_PATH="$SCRIPT" CONFDIR
  }
  BeforeEach 'setup'

  run_write_defer() {   # <GPG_FORWARD_DEFER 0|1> <conf> <alias> <host> <clip>
    zsh -f -c '
      export SYSTEM_ONBOARD_NO_RUN=1
      source "$SCRIPT_PATH"
      GPG_FORWARD_DEFER="$1"; shift
      PREPARE="gpg,theme"
      write_ssh_conf "$@"
    ' _ "$@"
  }

  It 'defers the gpg line and the visited-direction clipboard route, keeps prepare, the hook and the reverse forwards'
    conf="$CONFDIR/box.conf"
    run_write_defer 1 "$conf" box box.example 1
    When call sh -c 'grep -c "S.gpg-agent" "$1"; grep -c "^# prepare: gpg theme$" "$1"; grep -c "^Match originalhost" "$1"; grep -c "^    LocalForward" "$1"; grep -c "^    RemoteForward 127.0.0.1" "$1"' _ "$conf"
    The line 1 of output should equal 0
    The line 2 of output should equal 1
    The line 3 of output should equal 1
    The line 4 of output should equal 0
    The line 5 of output should equal 2
  End

  It 'renders the visited-direction route once deferral ends'
    conf="$CONFDIR/box.conf"
    run_write_defer 1 "$conf" box box.example 1
    run_write_defer 0 "$conf" box box.example 1
    When call grep -c "^    LocalForward 127.0.0.1:2491" "$conf"
    The output should equal 1
  End

  It 'keeps an already-healed gpg line even while deferring'
    conf="$CONFDIR/box.conf"
    run_write_defer 0 "$conf" box box.example 0
    sed 's|RemoteForward /nonexistent/S.gpg-agent.pending-first-connect|RemoteForward /run/user/0/gnupg/d.abc/S.gpg-agent|' "$conf" >"$conf.new" && mv "$conf.new" "$conf"
    run_write_defer 1 "$conf" box box.example 0
    When call grep -c "RemoteForward /run/user/0/gnupg/d.abc/S.gpg-agent" "$conf"
    The output should equal 1
  End

  It 'renders the pending gpg line once deferral ends'
    conf="$CONFDIR/box.conf"
    run_write_defer 1 "$conf" box box.example 0
    run_write_defer 0 "$conf" box box.example 0
    When call grep -c "RemoteForward /nonexistent/S.gpg-agent.pending-first-connect" "$conf"
    The output should equal 1
  End

  It 'finalize_gpg_forward resolves the line through the pre-connect hook and reports it'
    conf="$CONFDIR/box.conf"
    run_write_defer 1 "$conf" box box.example 0
    # Stub hook: record its argument and heal the line the way the real one does.
    cat >"$CONFDIR/hook" <<'STUB'
#!/bin/sh
printf '%s\n' "$@" >"$HOOK_LOG"
sed -i.bak 's|/nonexistent/S.gpg-agent.pending-first-connect|/run/user/0/gnupg/d.abc/S.gpg-agent|' "$1"
STUB
    chmod +x "$CONFDIR/hook"
    export HOOK_LOG="$CONFDIR/hook-calls"
    When call zsh -f -c '
      export SYSTEM_ONBOARD_NO_RUN=1
      source "$SCRIPT_PATH"
      ALIAS=box HOSTNAME=box.example PREPARE="gpg,theme" NO_CLIPBOARD=1 DRY_RUN=0
      HOME="$CONFDIR/home"; mkdir -p "$HOME/.ssh/config.d" "$HOME/.local/libexec"
      cp "$1" "$HOME/.ssh/config.d/box.conf"
      cp "$CONFDIR/hook" "$HOME/.local/libexec/ssh-prepare-connection"
      finalize_gpg_forward
      grep -c "d.abc/S.gpg-agent" "$HOME/.ssh/config.d/box.conf"
    ' _ "$conf"
    The status should be success
    The output should include "gpg-agent forward resolved for box"
    The output should include "1"
    The contents of file "$CONFDIR/hook-calls" should include "box.conf"
  End

  It 'finalize_gpg_forward is a no-op when gpg is not in prepare'
    conf="$CONFDIR/box.conf"
    zsh -f -c 'export SYSTEM_ONBOARD_NO_RUN=1; source "$SCRIPT_PATH"; PREPARE=theme; write_ssh_conf "$@"' _ "$conf" box box.example 0
    When call zsh -f -c '
      export SYSTEM_ONBOARD_NO_RUN=1
      source "$SCRIPT_PATH"
      ALIAS=box HOSTNAME=box.example PREPARE=theme NO_CLIPBOARD=1 DRY_RUN=0
      HOME="$CONFDIR/home"; mkdir -p "$HOME/.ssh/config.d"; cp "$1" "$HOME/.ssh/config.d/box.conf"
      finalize_gpg_forward; print "rc=$?"; grep -c "S.gpg-agent" "$HOME/.ssh/config.d/box.conf"
    ' _ "$conf"
    The status should equal 1
    The output should equal "rc=0
0"
  End
End

# converge_remote primes sops/age with a TARGETED apply of the mise toolbox
# conf. A targeted apply never creates parent directories, and on a fresh box
# ~/.config/mise/conf.d does not exist yet, so the priming failed with
# "stat …/conf.d: no such file or directory". The directory is created first.
Describe 'system-onboard: converge_remote priming (fresh target)'
  SCRIPT="$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_system-onboard"

  setup() {
    WORK="$(mktemp -d "$SHELLSPEC_TMPBASE/onboard-prime.XXXXXX")"
    export SCRIPT_PATH="$SCRIPT" WORK \
      LIB_PATH="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib/system-secrets-common.zsh"
  }
  BeforeEach 'setup'

  # sops/age come from GitHub releases and the box has no token yet (the
  # fragment needs sops to render), so the operator lends its own
  # MISE_GITHUB_TOKEN for that one command — over stdin, never on the command
  # line, so it shows in no process list or history.
  It 'lends the operator token to the sops/age install over stdin, never in argv'
    When call zsh -f -c '
      export SYSTEM_ONBOARD_NO_RUN=1 SYSTEM_SECRETS_LIB="$LIB_PATH"
      source "$SCRIPT_PATH"
      ALIAS=box PROFILE=server KIND=headless SLOT=slot-abc123 DRY_RUN=0 SECRETS_REBUILT=0
      REPO_ROOT="$WORK" OPERATOR_MAP="$WORK/map.yaml"
      export MISE_GITHUB_TOKEN=lent-token
      git() { print -r -- "git@example.invalid:x/y.git" }
      sec::map_get() { print -r -- "" }
      rexec() {
        print -r -- "ARGV: $*" >>"$WORK/rexec.log"
        if [[ "$*" == *"mise install sops age"* ]]; then
          local t; IFS= read -r t; print -r -- "STDIN: $t" >>"$WORK/rexec.log"
        fi
        return 0
      }
      converge_remote >/dev/null 2>&1
      print -r -- "argv-hits=$(grep -c "ARGV:.*lent-token" "$WORK/rexec.log" || true)"
      grep "^STDIN:" "$WORK/rexec.log"
    ' _
    The status should be success
    The line 1 of output should equal "argv-hits=0"
    The line 2 of output should equal "STDIN: lent-token"
  End

  # The apply renders the secrets fragment through the sops shim, and mise
  # resolves the whole toolset (rust@latest, …) before running any shim —
  # anonymously, since the only token on the box is inside the file being
  # decrypted. The headless apply borrows the operator token the same way.
  It 'lends the operator token to the headless apply over stdin, never in argv'
    When call zsh -f -c '
      export SYSTEM_ONBOARD_NO_RUN=1 SYSTEM_SECRETS_LIB="$LIB_PATH"
      source "$SCRIPT_PATH"
      ALIAS=box PROFILE=server KIND=headless SLOT=slot-abc123 DRY_RUN=0 SECRETS_REBUILT=0
      REPO_ROOT="$WORK" OPERATOR_MAP="$WORK/map.yaml"
      export MISE_GITHUB_TOKEN=lent-token
      git() { print -r -- "git@example.invalid:x/y.git" }
      sec::map_get() { print -r -- "" }
      rexec() {
        print -r -- "ARGV: $*" >>"$WORK/rexec.log"
        if [[ "$*" == *"chezmoi apply --force"* && "$*" != *"conf.d"* ]]; then
          local t; IFS= read -r t; print -r -- "APPLY-STDIN: $t" >>"$WORK/rexec.log"
        fi
        return 0
      }
      converge_remote >/dev/null 2>&1
      print -r -- "argv-hits=$(grep -c "ARGV:.*lent-token" "$WORK/rexec.log" || true)"
      grep "^APPLY-STDIN:" "$WORK/rexec.log"
    ' _
    The status should be success
    The line 1 of output should equal "argv-hits=0"
    The line 2 of output should equal "APPLY-STDIN: lent-token"
  End

  It 'installs sops/age anonymously when the operator has no token'
    When call zsh -f -c '
      export SYSTEM_ONBOARD_NO_RUN=1 SYSTEM_SECRETS_LIB="$LIB_PATH"
      source "$SCRIPT_PATH"
      unset MISE_GITHUB_TOKEN
      ALIAS=box PROFILE=server KIND=headless SLOT=slot-abc123 DRY_RUN=0 SECRETS_REBUILT=0
      REPO_ROOT="$WORK" OPERATOR_MAP="$WORK/map.yaml"
      git() { print -r -- "git@example.invalid:x/y.git" }
      sec::map_get() { print -r -- "" }
      rexec() { print -r -- "REXEC: $*" >>"$WORK/rexec.log"; return 0 }
      converge_remote >/dev/null 2>&1
      print -r -- "plain=$(grep -c "mise install sops age" "$WORK/rexec.log" || true) stdin=$(grep -c "read -r" "$WORK/rexec.log" || true)"
    ' _
    The status should be success
    The output should equal "plain=1 stdin=0"
  End

  It 'creates the conf.d directory on the target before the targeted apply'
    When call zsh -f -c '
      export SYSTEM_ONBOARD_NO_RUN=1 SYSTEM_SECRETS_LIB="$LIB_PATH"
      source "$SCRIPT_PATH"
      ALIAS=box PROFILE=server KIND=headless SLOT=slot-abc123 DRY_RUN=0 SECRETS_REBUILT=0
      REPO_ROOT="$WORK" OPERATOR_MAP="$WORK/map.yaml"
      git() { print -r -- "git@example.invalid:x/y.git" }
      sec::map_get() { print -r -- "" }
      rexec() { print -r -- "REXEC: $*" >>"$WORK/rexec.log"; return 0 }
      converge_remote >/dev/null 2>&1
      grep -c "mkdir -p ~/.config/mise/conf.d && chezmoi apply --force ~/.config/mise/conf.d/headless-linux.toml" "$WORK/rexec.log"
    ' _
    The output should equal 1
  End
End

# `system-onboard decommission <alias>` — the reverse of onboarding: (headless)
# tear the target down over ssh, then clear this operator's loose layer, then
# retire the slot's committed artifacts in one commit. Exercised against a
# throwaway repo, map and HOME; rexec and the confirmation prompt are stubbed.
Describe 'system-onboard: decommission'
  SCRIPT="$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_system-onboard"

  setup() {
    WORK="$(mktemp -d "$SHELLSPEC_TMPBASE/decom.XXXXXX")"
    export SCRIPT_PATH="$SCRIPT" WORK \
      LIB_PATH="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib/system-secrets-common.zsh"
    mkdir -p "$WORK/home/.ssh/config.d" "$WORK/repo/secrets/slot-aaaaaa" "$WORK/repo/secrets/slot-bbbbbb" \
      "$WORK/repo/home/dot_config/zsh/private_secrets.d" "$WORK/repo/home/.chezmoidata"
    printf 'Host box\n' >"$WORK/home/.ssh/config.d/box.conf"
    printf 'slot-aaaaaa:\n  alias: box\n  profile: server\n  kind: headless\nslot-bbbbbb:\n  alias: other\n  profile: server\n  kind: headless\nslot-cccccc:\n  alias: mac\n  profile: personal\n  kind: human\n' >"$WORK/map.yaml"
    (
      cd "$WORK/repo" && git init -q &&
        printf 'blob\n' >secrets/slot-aaaaaa/NAME.sops.sh && printf 'blob\n' >secrets/slot-bbbbbb/NAME.sops.sh &&
        printf 'tmpl\n' >home/dot_config/zsh/private_secrets.d/private_slot-aaaaaa.sh.tmpl &&
        printf 'tmpl\n' >home/dot_config/zsh/private_secrets.d/private_slot-bbbbbb.sh.tmpl &&
        printf 'tmpl\n' >home/dot_config/zsh/private_secrets.d/private_slot-cccccc.sh.tmpl &&
        printf 'creation_rules:\n  - path_regex: secrets/slot-aaaaaa/.*\\.sops\\.sh$\n    age: age1a\n  - path_regex: secrets/slot-bbbbbb/.*\\.sops\\.sh$\n    age: age1b\n' >.sops.yaml &&
        printf 'slot-aaaaaa:\n  NAME: 1\nslot-bbbbbb:\n  NAME: 2\n' >secrets/generations.yaml &&
        printf 'secrets: []\n' >home/.chezmoidata/secrets.yaml &&
        git add -A && git -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false commit -q -m seed &&
        git config user.name t && git config user.email t@example.invalid && git config commit.gpgsign false
    ) >/dev/null 2>&1
  }
  BeforeEach 'setup'

  # decom <args…> — runs cmd_decommission with everything pointed at $WORK.
  decom() {
    zsh -f -c '
      export SYSTEM_ONBOARD_NO_RUN=1 SYSTEM_SECRETS_LIB="$LIB_PATH"
      source "$SCRIPT_PATH"
      HOME="$WORK/home"
      REPO_ROOT="$WORK/repo"; SECRETS_SRC_DIR="$WORK/repo/home"
      SOPS_YAML="$REPO_ROOT/.sops.yaml"; MANIFEST="$REPO_ROOT/home/.chezmoidata/secrets.yaml"
      GENERATIONS="$REPO_ROOT/secrets/generations.yaml"; SECRETS_BLOB_DIR="$REPO_ROOT/secrets"
      FRAGMENT_DIR="$REPO_ROOT/home/dot_config/zsh/private_secrets.d"
      OPERATOR_MAP="$WORK/map.yaml"; LEAK_PATTERNS="$WORK/no-such-patterns"
      DRY_RUN=0
      prompt::confirm() { print -r -- "CONFIRM: $1" >>"$WORK/log"; return 0 }
      rexec() {
        print -r -- "REXEC: $*" >>"$WORK/log"
        [[ "$*" == *"bash -s"* ]] && cat >"$WORK/streamed"
        return 0
      }
      cmd_decommission "$@"
    ' _ "$@"
  }

  It 'dry-run prints the plan and touches nothing'
    When call decom box --dry-run
    The status should be success
    The output should include "[dry-run] would tear down box"
    The output should include "[dry-run] would remove"
    The output should include "[dry-run] would remove the committed artifacts of slot-aaaaaa"
    The path "$WORK/home/.ssh/config.d/box.conf" should be exist
    The path "$WORK/repo/secrets/slot-aaaaaa/NAME.sops.sh" should be exist
    The path "$WORK/log" should not be exist
  End

  last_commit_subject() { git -C "$WORK/repo" log -1 --format=%s; }
  tree_is_clean() { [ -z "$(git -C "$WORK/repo" status --porcelain)" ] && echo clean || echo dirty; }

  It 'headless: streams the teardown, clears the loose layer, retires the slot in one commit'
    When call decom box --yes --no-push
    The status should be success
    The output should include "torn down box"
    The output should include "decommissioned box (slot-aaaaaa)"
    The contents of file "$WORK/log" should include "REXEC: PURGE_TOOLS=0 MANAGED_CONFIG_DIRS='zsh' MANAGED_SHARE_DIRS='' bash -s"
    The contents of file "$WORK/streamed" should include "== user units"
    The path "$WORK/home/.ssh/config.d/box.conf" should not be exist
    The contents of file "$WORK/map.yaml" should not include "slot-aaaaaa"
    The contents of file "$WORK/map.yaml" should include "slot-bbbbbb"
    The path "$WORK/repo/secrets/slot-aaaaaa" should not be exist
    The path "$WORK/repo/home/dot_config/zsh/private_secrets.d/private_slot-aaaaaa.sh.tmpl" should not be exist
    The path "$WORK/repo/secrets/slot-bbbbbb/NAME.sops.sh" should be exist
    The result of function last_commit_subject should equal "chore(secrets): decommission slot-aaaaaa"
    The result of function tree_is_clean should equal "clean"
  End

  It 'headless --purge-tools passes the flag to the streamed script'
    When call decom box --yes --no-push --purge-tools
    The status should be success
    The output should include "torn down box"
    The contents of file "$WORK/log" should include "REXEC: PURGE_TOOLS=1 MANAGED_CONFIG_DIRS='zsh' MANAGED_SHARE_DIRS='' bash -s"
  End

  It 'asks for confirmation before touching a headless target unless --yes'
    When call decom box --no-push
    The status should be success
    The output should include "decommissioned box"
    The contents of file "$WORK/log" should include "CONFIRM: Tear down box (slot-aaaaaa)"
  End

  It '--keep-target never reaches for ssh'
    When call decom box --yes --no-push --keep-target
    The status should be success
    The output should include "leaving box untouched"
    The path "$WORK/log" should not be exist
    The path "$WORK/repo/secrets/slot-aaaaaa" should not be exist
  End

  It 'a human machine is decommissioned on the operator side only'
    When call decom mac --yes --no-push
    The status should be success
    The output should include "owns its own config"
    The path "$WORK/log" should not be exist
    The contents of file "$WORK/map.yaml" should not include "slot-cccccc"
    The path "$WORK/repo/home/dot_config/zsh/private_secrets.d/private_slot-cccccc.sh.tmpl" should not be exist
  End

  It 'refuses an alias the operator map does not know'
    When call decom nobody --yes --no-push
    The status should be failure
    The stderr should include "no slot for alias 'nobody'"
  End
End

# The streamed teardown script itself, run in a sandbox HOME with the system
# commands it touches stubbed: proves the ssh-config surgery (drop only the
# `Match all` + `Include ~/.ssh/config.d/*` pair onboarding appended) and that
# it survives a box with no chezmoi at all.
Describe 'system-onboard: decommission remote script'
  SCRIPT="$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_system-onboard"

  setup() {
    WORK="$(mktemp -d "$SHELLSPEC_TMPBASE/decom-remote.XXXXXX")"
    H="$WORK/home"
    # The script sets its own PATH with ~/.local/bin first, so stubs live there.
    mkdir -p "$H/.ssh" "$H/.local/bin"
    ln -s "$H/.local/bin" "$WORK/bin"
    printf 'Ciphers aes256-gcm@openssh.com\n\nMatch all\nInclude ~/.ssh/config.d/*\n' >"$H/.ssh/config"
    printf '#!/bin/sh\nexit 0\n' >"$H/.local/bin/systemctl"
    printf '#!/bin/sh\necho "root:x:0:0:root:/root:/bin/bash"\n' >"$H/.local/bin/getent"
    printf '#!/bin/sh\nexit 0\n' >"$H/.local/bin/chsh"
    chmod +x "$H/.local/bin/"*
    export SCRIPT_PATH="$SCRIPT" WORK H
  }
  BeforeEach 'setup'

  # A managed tree the way chezmoi lays it out: a stub `chezmoi managed` lists
  # it, and the source dir must exist for the script to consult it at all.
  lay_managed_tree() {
    mkdir -p "$H/.local/share/chezmoi/.git" "$H/.config/zsh" "$H/.config/chromium" "$H/.ssh/config.d" \
      "$H/.local/state/zsh" "$H/.local/state/clipboard" "$H/.local/share/atuin" "$H/.local/share/Trash" "$H/.cache/yazi" \
      "$WORK/tmp"
    printf 'managed\n' >"$H/.config/zsh/.zshrc"
    printf 'compiled at runtime\n' >"$H/.config/zsh/.zshrc.zwc"     # unmanaged, but inside a managed dir
    printf 'pre-existing app\n' >"$H/.config/chromium/Local State"  # unmanaged neighbor in a shared container
    printf 'managed\n' >"$H/.ssh/config.d/personal.config"
    printf 'managed\n' >"$H/.local/bin/managed-tool"
    printf 'mine\n' >"$H/.local/bin/user-own-tool"                    # unmanaged neighbor in a shared container
    printf 'history\n' >"$H/.local/state/zsh/history"
    cat >"$H/.local/bin/chezmoi" <<'STUB'
#!/bin/sh
case "$*" in
  "managed --include=files,symlinks") printf '%s\n' .config/zsh/.zshrc .ssh/config.d/personal.config .local/bin/managed-tool ;;
  "managed --include=dirs")           printf '%s\n' .config .config/zsh .ssh .ssh/config.d .local .local/bin ;;
esac
exit 0
STUB
    chmod +x "$H/.local/bin/chezmoi"
  }

  run_remote() {
    zsh -f -c 'export SYSTEM_ONBOARD_NO_RUN=1; source "$SCRIPT_PATH"; print -r -- "$DECOMMISSION_SCRIPT"' |
      env -i HOME="$H" PATH="$H/.local/bin:/usr/bin:/bin" PURGE_TOOLS="${1:-0}" \
        MANAGED_CONFIG_DIRS="${MANAGED_CONFIG_DIRS:-}" MANAGED_SHARE_DIRS="${MANAGED_SHARE_DIRS:-}" bash -s
  }
  run_remote_with_names() { MANAGED_CONFIG_DIRS="zsh nvim" MANAGED_SHARE_DIRS="zsh" run_remote; }

  It 'strips only the appended Include pair from ~/.ssh/config and finishes without chezmoi'
    When call run_remote
    The status should be success
    The output should include "== done"
    The contents of file "$H/.ssh/config" should include "Ciphers aes256-gcm@openssh.com"
    The contents of file "$H/.ssh/config" should not include "Include"
    The contents of file "$H/.ssh/config" should not include "Match all"
  End

  It 'removes managed dirs whole, keeps shared containers and their unmanaged neighbors, drops our state'
    lay_managed_tree
    When call run_remote
    The status should be success
    The output should include "== done"
    The path "$H/.config/zsh" should not be exist
    The path "$H/.ssh/config.d" should not be exist
    The path "$H/.config/chromium/Local State" should be exist
    The path "$H/.local/bin/user-own-tool" should be exist
    The path "$H/.local/bin/managed-tool" should not be exist
    The path "$H/.local/state/zsh" should not be exist
    The path "$H/.local/state/clipboard" should not be exist
    The path "$H/.local/share/atuin" should not be exist
    The path "$H/.local/share/Trash" should not be exist
    The path "$H/.cache/yazi" should not be exist
    The path "$H/.local/share/chezmoi" should not be exist
  End

  It '--purge-tools additionally removes the tool homes and ~/.local/bin'
    lay_managed_tree
    mkdir -p "$H/.local/share/mise" "$H/.local/share/cargo"
    When call run_remote 1
    The status should be success
    The output should include "== done"
    The path "$H/.local/share/mise" should not be exist
    The path "$H/.local/share/cargo" should not be exist
    The path "$H/.local/bin" should not be exist
    The path "$H/.config/chromium/Local State" should be exist
  End

  It 'without chezmoi on the box, removes the managed dirs the operator names plus runtime .config state'
    mkdir -p "$H/.config/zsh" "$H/.config/nvim" "$H/.config/chromium" "$H/.config/theme" "$H/.config/go" \
      "$H/.local/share/zsh" "$H/.local/share/nano"
    printf 'left behind by a partial teardown\n' >"$H/.config/zsh/.zshrc.zwc"
    printf 'pre-existing app\n' >"$H/.config/chromium/Local State"
    printf 'pre-existing\n' >"$H/.local/share/nano/x"
    When call run_remote_with_names
    The status should be success
    The output should include "== done"
    The path "$H/.config/zsh" should not be exist
    The path "$H/.config/nvim" should not be exist
    The path "$H/.config/theme" should not be exist
    The path "$H/.config/go" should not be exist
    The path "$H/.local/share/zsh" should not be exist
    The path "$H/.config/chromium/Local State" should be exist
    The path "$H/.local/share/nano/x" should be exist
  End
End
