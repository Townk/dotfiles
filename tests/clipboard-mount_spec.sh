# Tests for clipboard-mount — the owner of clipboard peer mounts (rclone SFTP
# on MacFUSE). Spec: docs/superpowers/specs/2026-07-13-clipboard-mount-subsystem-design.md
# All invocations use `zsh -f` (see Global Constraints: ~/.zshenv clobbers the
# sandbox XDG override otherwise).
Describe 'clipboard-mount: map + host validation'
  CM="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_clipboard-mount"

  setup() {
    export XDG_STATE_HOME="$SHELLSPEC_TMPBASE/state"
    MNT_ROOT="$XDG_STATE_HOME/clipboard/mnt"
  }
  BeforeEach 'setup'

  It 'maps one absolute path under the host mountpoint'
    When run command zsh -f "$CM" map peer-mini /Users/thiago/big.bin
    The status should be success
    The output should equal "$MNT_ROOT/peer-mini/Users/thiago/big.bin"
  End

  It 'maps several paths, one per line, preserving spaces and unicode'
    When run command zsh -f "$CM" map peer-mini "/tmp/a b.txt" "/tmp/é.png"
    The status should be success
    The line 1 of output should equal "$MNT_ROOT/peer-mini/tmp/a b.txt"
    The line 2 of output should equal "$MNT_ROOT/peer-mini/tmp/é.png"
  End

  It 'rejects a relative path'
    When run command zsh -f "$CM" map peer-mini not/abs
    The status should be failure
    The stderr should include "not absolute"
  End

  It 'rejects a traversal-shaped host (defense: host comes off the wire)'
    When run command zsh -f "$CM" map "../evil" /tmp/x
    The status should be failure
    The stderr should include "invalid host"
  End

  It 'rejects an empty host'
    When run command zsh -f "$CM" map "" /tmp/x
    The status should be failure
    The stderr should include "invalid host"
  End

  It 'prints usage and fails on an unknown subcommand'
    When run command zsh -f "$CM" frobnicate
    The status should be failure
    The stderr should include "usage"
  End
End

Describe 'clipboard-mount: unmount + sweep'
  CM="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_clipboard-mount"

  setup() {
    export XDG_STATE_HOME="$SHELLSPEC_TMPBASE/state"
    MNT_ROOT="$XDG_STATE_HOME/clipboard/mnt"
    STUBS="$SHELLSPEC_TMPBASE/bin"
    export PATH="$STUBS:$PATH"
    mkdir -p "$STUBS" "$MNT_ROOT"
    rm -f "$SHELLSPEC_TMPBASE/mount-table" "$SHELLSPEC_TMPBASE/calls"
    # $SHELLSPEC_TMPBASE (and $STUBS) is shared across Describes in one run;
    # several examples below install a `stat` stub to pin cm::probe's
    # outcome (healthy/dead/hung) — reset it here so no example inherits
    # another's.
    rm -f "$STUBS/stat"
    : > "$SHELLSPEC_TMPBASE/mount-table"
    # `mount` prints the fixture table; umount/diskutil/kill-targets record.
    printf '#!/bin/sh\ncat "%s"\n' "$SHELLSPEC_TMPBASE/mount-table" > "$STUBS/mount"
    printf '#!/bin/sh\necho "umount $*" >> "%s"\nexit 0\n' "$SHELLSPEC_TMPBASE/calls" > "$STUBS/umount"
    printf '#!/bin/sh\necho "diskutil $*" >> "%s"\nexit 0\n' "$SHELLSPEC_TMPBASE/calls" > "$STUBS/diskutil"
    printf '#!/bin/sh\nexit 1\n' > "$STUBS/pgrep"   # no rclone pids by default
    chmod +x "$STUBS/mount" "$STUBS/umount" "$STUBS/diskutil" "$STUBS/pgrep"
  }
  BeforeEach 'setup'

  It 'unmount tears down and removes the mountpoint dir'
    mkdir -p "$MNT_ROOT/peer-mini"
    When run command zsh -f "$CM" unmount peer-mini
    The status should be success
    The contents of file "$SHELLSPEC_TMPBASE/calls" should include "umount $MNT_ROOT/peer-mini"
    The path "$MNT_ROOT/peer-mini" should not be exist
  End

  It 'sweep leaves a healthy mount alone'
    mkdir -p "$MNT_ROOT/peer-mini"
    printf '%s\n' "mini-clip on $MNT_ROOT/peer-mini (macfuse, nodev)" > "$SHELLSPEC_TMPBASE/mount-table"
    # Healthy signature under the new probe: the child-lookup completes with
    # ENOENT, proving a real daemon round-trip (not an attr-cache answer).
    printf '#!/bin/sh\necho "stat: x: stat: No such file or directory" >&2\nexit 1\n' > "$STUBS/stat"; chmod +x "$STUBS/stat"
    When run command zsh -f "$CM" sweep
    The status should be success
    The path "$MNT_ROOT/peer-mini" should be exist
    The path "$SHELLSPEC_TMPBASE/calls" should not be exist
  End

  It 'sweep reaps a mounted volume whose daemon died (attr-cache trap: lookup gets ENXIO, not ENOENT)'
    mkdir -p "$MNT_ROOT/peer-mini"
    printf '%s\n' "mini-clip on $MNT_ROOT/peer-mini (macfuse, nodev)" > "$SHELLSPEC_TMPBASE/mount-table"
    # THE live regression this task fixes: a ROOT stat is answered from the
    # kernel's attribute cache with no daemon round-trip at all, so the old
    # probe (root stat) passed this corpse as healthy and `ls` then hit
    # ENXIO. The new probe's lookup of a nonexistent CHILD forces a real
    # round-trip; with the daemon gone, the kernel/fs layer answers ENXIO
    # instead of ENOENT, and that must read as DEAD so sweep reaps it.
    printf '#!/bin/sh\necho "stat: x: stat: Device not configured" >&2\nexit 1\n' > "$STUBS/stat"; chmod +x "$STUBS/stat"
    When run command zsh -f "$CM" sweep
    The status should be success
    The path "$MNT_ROOT/peer-mini" should not be exist
  End

  It 'sweep leaves alone a probe that bizarrely succeeds (rc 0 -- the probe child exists)'
    mkdir -p "$MNT_ROOT/peer-mini"
    printf '%s\n' "mini-clip on $MNT_ROOT/peer-mini (macfuse, nodev)" > "$SHELLSPEC_TMPBASE/mount-table"
    # rc 0 can only mean the daemon answered a real lookup either way, so
    # this counts as healthy even though the not-supposed-to-exist probe
    # child apparently does.
    printf '#!/bin/sh\nexit 0\n' > "$STUBS/stat"; chmod +x "$STUBS/stat"
    When run command zsh -f "$CM" sweep
    The status should be success
    The path "$MNT_ROOT/peer-mini" should be exist
    The path "$SHELLSPEC_TMPBASE/calls" should not be exist
  End

  It 'sweep reaps a mountpoint dir with no mount-table entry (orphan)'
    mkdir -p "$MNT_ROOT/peer-mini"
    When run command zsh -f "$CM" sweep
    The status should be success
    The path "$MNT_ROOT/peer-mini" should not be exist
  End

  It 'sweep reaps a mounted-but-hung volume (probe timeout) with force escalation'
    mkdir -p "$MNT_ROOT/peer-mini"
    printf '%s\n' "mini-clip on $MNT_ROOT/peer-mini (macfuse, nodev)" > "$SHELLSPEC_TMPBASE/mount-table"
    # stat hangs -> probe must time out (bounded), then teardown runs.
    printf '#!/bin/sh\nsleep 20\n' > "$STUBS/stat"; chmod +x "$STUBS/stat"
    # first umount "fails" so the diskutil force escalation is exercised
    printf '#!/bin/sh\necho "umount $*" >> "%s"\nexit 1\n' "$SHELLSPEC_TMPBASE/calls" > "$STUBS/umount"
    When run command zsh -f "$CM" sweep
    The status should be success
    The contents of file "$SHELLSPEC_TMPBASE/calls" should include "diskutil unmount force $MNT_ROOT/peer-mini"
  End

  It 'teardown (via unmount) skips when another process holds the per-host lock'
    mkdir -p "$MNT_ROOT/peer-mini"
    printf '%s\n' "mini-clip on $MNT_ROOT/peer-mini (macfuse, nodev)" > "$SHELLSPEC_TMPBASE/mount-table"
    # Same pattern as the ensure-side busy-lock example (Describe 'ensure'
    # below): a background zsh takes the SAME per-host flock cm::teardown now
    # acquires, drops a ready-sentinel, and this example's teardown (via
    # `unmount`, teardown's only CLI-reachable caller) must see it busy and
    # bail WITHOUT ever calling umount -- an in-flight `ensure` owns settling
    # this mount's health, teardown must never fight it.
    When run command sh -c 'zsh -fc "zmodload zsh/system; : >> \"$1\"; zsystem flock \"$1\"; : > \"$2\"; sleep 5" & h=$!; i=0; while [ ! -f "$2" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done; zsh -f "$3" unmount peer-mini; rc=$?; kill $h 2>/dev/null; exit $rc' _ "$MNT_ROOT/.peer-mini.lock" "$SHELLSPEC_TMPBASE/lock-held" "$CM"
    The status should be success
    The path "$SHELLSPEC_TMPBASE/calls" should not be exist
    The path "$MNT_ROOT/peer-mini" should be directory
  End
End

# cm::rclone_pids_for's whole-argv-word matching, tested at its real seam: a
# bare *"$mp"* substring match would also hit a prefix-sharing sibling
# mountpoint (tearing down host `peer` would kill the rclone serving
# `peer-mini` too). `kill` is a zsh BUILTIN (not found on PATH), so a stub
# can't intercept it to observe which pids cm::teardown actually signals --
# and the pids here are fake anyway, so a real kill -9 on them just fails
# silently (`2>/dev/null || true`), leaving nothing externally observable
# through teardown's own CLI surface. The honest seam is cm::rclone_pids_for
# itself: `source` the script (harmlessly, with a no-op `sweep` argv so the
# case-dispatch at file-scope doesn't error/exit) into the CURRENT shell --
# zsh restores the caller's own positional params once `source` returns (
# confirmed empirically), so the function definitions stick around and can
# be called directly afterward, no subprocess/kill interception needed.
Describe 'clipboard-mount: cm::rclone_pids_for word-matching'
  CM="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_clipboard-mount"

  setup() {
    export XDG_STATE_HOME="$SHELLSPEC_TMPBASE/state"
    MNT_ROOT="$XDG_STATE_HOME/clipboard/mnt"
    STUBS="$SHELLSPEC_TMPBASE/bin"
    export PATH="$STUBS:$PATH"
    mkdir -p "$STUBS" "$MNT_ROOT"
    rm -f "$STUBS/stat"
    : > "$SHELLSPEC_TMPBASE/mount-table"
    printf '#!/bin/sh\ncat "%s"\n' "$SHELLSPEC_TMPBASE/mount-table" > "$STUBS/mount"
    # Two fake rclone-mount pids: 111 serves .../peer, 222 serves the
    # prefix-sharing .../peer-mini -- exactly the collision the substring
    # match used to cause.
    printf '#!/bin/sh\necho 111\necho 222\n' > "$STUBS/pgrep"
    cat > "$STUBS/ps" <<STUB
#!/bin/sh
case "\$2" in
  111) echo "rclone mount :sftp,ssh=xxx $MNT_ROOT/peer --daemon --read-only" ;;
  222) echo "rclone mount :sftp,ssh=xxx $MNT_ROOT/peer-mini --daemon --read-only" ;;
esac
STUB
    chmod +x "$STUBS/mount" "$STUBS/pgrep" "$STUBS/ps"
  }
  BeforeEach 'setup'

  It 'matches only the exact mountpoint word, not a prefix-sharing sibling'
    When run command zsh -c 'source "$1" sweep >/dev/null 2>&1; cm::rclone_pids_for "$2"' _ "$CM" "$MNT_ROOT/peer"
    The status should be success
    The output should equal "111"
  End

  It 'the sibling mountpoint only ever matches its own pid'
    When run command zsh -c 'source "$1" sweep >/dev/null 2>&1; cm::rclone_pids_for "$2"' _ "$CM" "$MNT_ROOT/peer-mini"
    The status should be success
    The output should equal "222"
  End
End

Describe 'clipboard-mount: check'
  CM="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_clipboard-mount"

  setup() {
    export XDG_STATE_HOME="$SHELLSPEC_TMPBASE/state"
    MNT_ROOT="$XDG_STATE_HOME/clipboard/mnt"
    STUBS="$SHELLSPEC_TMPBASE/bin"
    export PATH="$STUBS:$PATH"
    mkdir -p "$STUBS" "$MNT_ROOT"
    # $STUBS is shared across Describes: the sweep block's hung-volume example
    # leaves a sleeping `stat` stub behind, which would wedge cm::probe here.
    rm -f "$STUBS/stat" "$SHELLSPEC_TMPBASE/stat-argv"
    : > "$SHELLSPEC_TMPBASE/mount-table"
    printf '#!/bin/sh\ncat "%s"\n' "$SHELLSPEC_TMPBASE/mount-table" > "$STUBS/mount"
    printf '#!/bin/sh\nexit 0\n' > "$STUBS/umount"
    printf '#!/bin/sh\nexit 0\n' > "$STUBS/diskutil"
    printf '#!/bin/sh\nexit 1\n' > "$STUBS/pgrep"
    chmod +x "$STUBS/mount" "$STUBS/umount" "$STUBS/diskutil" "$STUBS/pgrep"
  }
  BeforeEach 'setup'

  It 'prints the mountpoint and succeeds when mounted and answering'
    mkdir -p "$MNT_ROOT/peer-mini"
    printf '%s\n' "mini-clip on $MNT_ROOT/peer-mini (macfuse, nodev)" > "$SHELLSPEC_TMPBASE/mount-table"
    # Healthy signature under the new probe: ENOENT on the child lookup.
    printf '#!/bin/sh\necho "stat: x: stat: No such file or directory" >&2\nexit 1\n' > "$STUBS/stat"; chmod +x "$STUBS/stat"
    When run command zsh -f "$CM" check peer-mini
    The status should be success
    The output should equal "$MNT_ROOT/peer-mini"
  End

  It 'probes by looking up a nonexistent CHILD of the mountpoint, never the bare root (the attr-cache defeat mechanism)'
    mkdir -p "$MNT_ROOT/peer-mini"
    printf '%s\n' "mini-clip on $MNT_ROOT/peer-mini (macfuse, nodev)" > "$SHELLSPEC_TMPBASE/mount-table"
    # A recording stub that exits 0 reads as healthy under BOTH the old
    # (root-stat) and new (child-lookup) probes, so the recorded argv is
    # the only discriminator here — it pins the MECHANISM itself. A revert
    # to stat-ing the bare mountpoint would record exactly
    # $MNT_ROOT/peer-mini and fail the child-suffix assertions below while
    # every classification example still passed.
    cat > "$STUBS/stat" <<STUB
#!/bin/sh
printf '%s\n' "\$@" > "$SHELLSPEC_TMPBASE/stat-argv"
exit 0
STUB
    chmod +x "$STUBS/stat"
    When run command zsh -f "$CM" check peer-mini
    The status should be success
    The output should equal "$MNT_ROOT/peer-mini"
    # probe invokes: stat -f %i -- <path>; line 4 of the recorded argv is
    # the probed path.
    The line 4 of contents of file "$SHELLSPEC_TMPBASE/stat-argv" should start with "$MNT_ROOT/peer-mini/.clipboard-mount-probe."
    The line 4 of contents of file "$SHELLSPEC_TMPBASE/stat-argv" should not equal "$MNT_ROOT/peer-mini"
  End

  It 'fails when mounted but the daemon died (root-stat attr-cache trap: lookup gets ENXIO, not ENOENT)'
    mkdir -p "$MNT_ROOT/peer-mini"
    printf '%s\n' "mini-clip on $MNT_ROOT/peer-mini (macfuse, nodev)" > "$SHELLSPEC_TMPBASE/mount-table"
    printf '#!/bin/sh\necho "stat: x: stat: Device not configured" >&2\nexit 1\n' > "$STUBS/stat"; chmod +x "$STUBS/stat"
    # the async sweep must reap the corpse; poll briefly for it
    When run command sh -c 'zsh -f "$1" check peer-mini; rc=$?; i=0; while [ -d "$2" ] && [ $i -lt 30 ]; do sleep 0.1; i=$((i+1)); done; exit $rc' _ "$CM" "$MNT_ROOT/peer-mini"
    The status should be failure
    The output should equal ""
    The path "$MNT_ROOT/peer-mini" should not be exist
  End

  It 'fails instantly when the mountpoint dir does not exist'
    When run command zsh -f "$CM" check peer-mini
    The status should be failure
    The output should equal ""
  End

  It 'fails and sweeps when the dir exists but nothing is mounted'
    mkdir -p "$MNT_ROOT/peer-mini"
    # the async sweep must reap the orphan dir; poll briefly for it
    When run command sh -c 'zsh -f "$1" check peer-mini; rc=$?; i=0; while [ -d "$2" ] && [ $i -lt 30 ]; do sleep 0.1; i=$((i+1)); done; exit $rc' _ "$CM" "$MNT_ROOT/peer-mini"
    The status should be failure
    The path "$MNT_ROOT/peer-mini" should not be exist
  End

  It 'rejects an invalid host'
    When run command zsh -f "$CM" check "../evil"
    The status should be failure
    The stderr should include "invalid host"
  End
End

Describe 'clipboard-mount: ensure'
  CM="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_clipboard-mount"

  setup() {
    export XDG_STATE_HOME="$SHELLSPEC_TMPBASE/state"
    export XDG_CACHE_HOME="$SHELLSPEC_TMPBASE/cache"
    MNT_ROOT="$XDG_STATE_HOME/clipboard/mnt"
    STUBS="$SHELLSPEC_TMPBASE/bin"
    export PATH="$STUBS:$PATH"
    # rclone resolution now checks the shim BEFORE PATH; pin it to a path
    # that can never exist so the plain PATH-stub examples below (which don't
    # care about shim resolution at all) stay hermetic regardless of this
    # real machine's own mise install state. Examples that DO exercise shim
    # resolution override this per-invocation.
    export CLIPBOARD_MOUNT_RCLONE_SHIM="$SHELLSPEC_TMPBASE/no-such-shim"
    mkdir -p "$STUBS" "$MNT_ROOT"
    : > "$SHELLSPEC_TMPBASE/mount-table"
    rm -f "$SHELLSPEC_TMPBASE/rclone-argv" "$SHELLSPEC_TMPBASE/rclone-env" \
          "$SHELLSPEC_TMPBASE/lock-held"
    printf '#!/bin/sh\ncat "%s"\n' "$SHELLSPEC_TMPBASE/mount-table" > "$STUBS/mount"
    printf '#!/bin/sh\nexit 0\n' > "$STUBS/umount"
    printf '#!/bin/sh\nexit 0\n' > "$STUBS/diskutil"
    printf '#!/bin/sh\nexit 1\n' > "$STUBS/pgrep"
    # rclone stub: record argv + _SYNCREMOTE, then "mount" by appending a
    # mount-table line for the mountpoint arg (argv position 3: rclone mount
    # <remote> <mountpoint> ...).
    cat > "$STUBS/rclone" <<STUB
#!/bin/sh
printf '%s\n' "\$@" > "$SHELLSPEC_TMPBASE/rclone-argv"
printf '%s\n' "\${_SYNCREMOTE:-}" > "$SHELLSPEC_TMPBASE/rclone-env"
echo "mini-clip on \$3 (macfuse, nodev)" >> "$SHELLSPEC_TMPBASE/mount-table"
exit 0
STUB
    chmod +x "$STUBS/mount" "$STUBS/umount" "$STUBS/diskutil" "$STUBS/pgrep" "$STUBS/rclone"
  }
  BeforeEach 'setup'

  It 'mounts with the pinned rclone argv, _SYNCREMOTE set, alias defaulting to host'
    When run command zsh -f "$CM" ensure peer-mini
    The status should be success
    The path "$MNT_ROOT/peer-mini" should be directory
    The line 1 of contents of file "$SHELLSPEC_TMPBASE/rclone-argv" should equal "mount"
    The line 2 of contents of file "$SHELLSPEC_TMPBASE/rclone-argv" should equal ":sftp,ssh='ssh -o ControlPath=none -o ClearAllForwardings=yes -o BatchMode=yes -o ConnectTimeout=5 peer-mini':/"
    The line 3 of contents of file "$SHELLSPEC_TMPBASE/rclone-argv" should equal "$MNT_ROOT/peer-mini"
    The contents of file "$SHELLSPEC_TMPBASE/rclone-argv" should include "--read-only"
    The contents of file "$SHELLSPEC_TMPBASE/rclone-argv" should include "--daemon"
    The contents of file "$SHELLSPEC_TMPBASE/rclone-argv" should include "nobrowse"
    The contents of file "$SHELLSPEC_TMPBASE/rclone-env" should equal "1"
  End

  It 'uses the explicit alias for ssh while keying the mountpoint by host'
    When run command zsh -f "$CM" ensure peer-mini mini
    The status should be success
    The line 2 of contents of file "$SHELLSPEC_TMPBASE/rclone-argv" should equal ":sftp,ssh='ssh -o ControlPath=none -o ClearAllForwardings=yes -o BatchMode=yes -o ConnectTimeout=5 mini':/"
    The line 3 of contents of file "$SHELLSPEC_TMPBASE/rclone-argv" should equal "$MNT_ROOT/peer-mini"
  End

  It 'is a no-op when already healthy (rclone not re-invoked)'
    mkdir -p "$MNT_ROOT/peer-mini"
    printf '%s\n' "mini-clip on $MNT_ROOT/peer-mini (macfuse, nodev)" > "$SHELLSPEC_TMPBASE/mount-table"
    When run command zsh -f "$CM" ensure peer-mini
    The status should be success
    The path "$SHELLSPEC_TMPBASE/rclone-argv" should not be exist
  End

  It 'fails soft with a warning when rclone is not installed'
    rm -f "$STUBS/rclone"
    # Hermetic: pin the shim-fallback seam to a path that can never exist,
    # regardless of this real machine's own mise install state.
    When run command sh -c 'PATH="$1:/usr/bin:/bin" CLIPBOARD_MOUNT_RCLONE_SHIM="$3/no-such-shim" zsh -f "$2" ensure peer-mini' _ "$STUBS" "$CM" "$SHELLSPEC_TMPBASE"
    The status should be failure
    The stderr should include "rclone not installed"
    The path "$SHELLSPEC_TMPBASE/rclone-argv" should not be exist
  End

  It 'falls back to the mise shim path when rclone is off PATH (headless launchd context)'
    rm -f "$STUBS/rclone"
    # A recording stub standing in for the mise shim, at a path OTHER than
    # $STUBS (which is on PATH) — proves resolution really used the
    # fallback, not PATH.
    mkdir -p "$SHELLSPEC_TMPBASE/shim-dir"
    cat > "$SHELLSPEC_TMPBASE/shim-dir/rclone" <<STUB
#!/bin/sh
printf '%s\n' "\$@" > "$SHELLSPEC_TMPBASE/rclone-argv"
printf '%s\n' "\${_SYNCREMOTE:-}" > "$SHELLSPEC_TMPBASE/rclone-env"
echo "mini-clip on \$3 (macfuse, nodev)" >> "$SHELLSPEC_TMPBASE/mount-table"
exit 0
STUB
    chmod +x "$SHELLSPEC_TMPBASE/shim-dir/rclone"
    When run command sh -c 'PATH="$1:/usr/bin:/bin" CLIPBOARD_MOUNT_RCLONE_SHIM="$3/shim-dir/rclone" zsh -f "$2" ensure peer-mini' _ "$STUBS" "$CM" "$SHELLSPEC_TMPBASE"
    The status should be success
    The path "$MNT_ROOT/peer-mini" should be directory
    The line 1 of contents of file "$SHELLSPEC_TMPBASE/rclone-argv" should equal "mount"
    The contents of file "$SHELLSPEC_TMPBASE/rclone-env" should equal "1"
  End

  It 'tears down and fails when the mount comes up unhealthy'
    # rclone "succeeds" but never lands a mount-table entry
    printf '#!/bin/sh\nexit 0\n' > "$STUBS/rclone"; chmod +x "$STUBS/rclone"
    When run command zsh -f "$CM" ensure peer-mini
    The status should be failure
    The stderr should include "unhealthy"
    The path "$MNT_ROOT/peer-mini" should not be exist
  End

  It "ensure's unhealthy path still tears down (umount runs) even when teardown's lock reacquire loses a race to a waiting contender (fcntl close-drops-all regression guard)"
    # rclone "succeeds" but never lands a mount-table entry (the standard
    # "came up unhealthy" fixture) -> ensure's unhealthy path calls
    # cm::teardown INTERNALLY while ensure itself still holds the per-host
    # lock. teardown's lockfile touch used to be an unconditional open+close
    # (`: >> "$lock"`); under zsystem flock's fcntl semantics, closing ANY fd
    # a process has open on a locked file drops ALL of that process's locks
    # on it -- so that touch silently released ensure's own lock
    # mid-teardown, and a contender that wins the freed lock in that instant
    # makes teardown's own re-acquire (`-t 0`, non-blocking) lose and bail
    # via `return 0` WITHOUT ever calling umount.
    #
    # The real touch-then-reacquire gap is two back-to-back syscalls in the
    # SAME process with no scheduling opportunity in between (confirmed
    # empirically: zsystem flock's default poll interval is 1s -- see
    # zshmodules(1) -- so an external contender polling naturally never
    # lands inside a microsecond-scale gap). To exercise the guard
    # deterministically without touching production code, this example
    # sources the script to get the real cm::teardown body (harmless
    # `sweep` dispatch on source, same technique as the rclone_pids_for
    # block above) and shadows the `zsystem` builtin with a function for the
    # duration of this process only -- a plain zsh function always wins over
    # a same-named builtin, and the wrapper delegates to the real thing via
    # `builtin zsystem "$@"`, so every call except the one under test
    # behaves identically. The wrapper recognizes ONLY teardown's exact
    # non-blocking reacquire call (`flock -t 0 ...`) and, right before
    # delegating to it, drops a ready sentinel and sleeps 1s -- giving a
    # contender (already parked, polling every 20ms, woken by the sentinel)
    # a wide, deterministic window to grab the lock IF (and only if) the
    # preceding line actually dropped it.
    #
    # Discrimination evidence (see task report): reverting this fix line
    # locally and re-running this example reproduces the bug every time --
    # the contender grabs the lock, no umount call is recorded, and the
    # mountpoint directory survives; restoring the fix flips it back to the
    # contender never grabbing, with umount always recorded and the
    # mountpoint gone.
    printf '#!/bin/sh\nexit 0\n' > "$STUBS/rclone"; chmod +x "$STUBS/rclone"
    printf '#!/bin/sh\necho "umount $*" >> "%s"\nexit 0\n' "$SHELLSPEC_TMPBASE/calls" > "$STUBS/umount"
    chmod +x "$STUBS/umount"
    rm -f "$SHELLSPEC_TMPBASE/ready" "$SHELLSPEC_TMPBASE/grabbed"
    When run command zsh -f -c '
      source "$1" sweep >/dev/null 2>&1
      lock="$2/.peer-mini.lock"
      : > "$lock"
      ready="$3"; grabbed="$4"
      zsh -fc "
        zmodload zsh/system
        while [ ! -f \"$ready\" ]; do sleep 0.01; done
        if zsystem flock -t 3 -i 0.02 \"$lock\" 2>/dev/null; then
          : > \"$grabbed\"
          sleep 2
        fi
      " &
      contender=$!
      zsystem() {
        if [[ "$1" == "flock" && "$2" == "-t" && "$3" == "0" ]]; then
          : > "$ready"
          sleep 1
        fi
        builtin zsystem "$@"
      }
      cm::ensure peer-mini
      rc=$?
      kill $contender 2>/dev/null
      wait $contender 2>/dev/null
      exit $rc
    ' _ "$CM" "$MNT_ROOT" "$SHELLSPEC_TMPBASE/ready" "$SHELLSPEC_TMPBASE/grabbed"
    The status should be failure
    The stderr should include "unhealthy"
    The contents of file "$SHELLSPEC_TMPBASE/calls" should include "umount $MNT_ROOT/peer-mini"
    The path "$MNT_ROOT/peer-mini" should not be exist
  End

  It 'rejects an invalid alias (it lands inside the rclone connection string)'
    When run command zsh -f "$CM" ensure peer-mini "bad'alias"
    The status should be failure
    The stderr should include "invalid"
  End

  It 'fails busy when another process holds the per-host lock (rclone never invoked)'
    # A background zsh takes the flock, then drops a ready-sentinel; the test
    # waits for the sentinel (no acquire race), runs ensure with the lock
    # timeout dialed to 1s (test seam; default stays 10s), and reaps the
    # holder before exiting so nothing leaks past the example.
    When run command sh -c 'zsh -fc "zmodload zsh/system; : >> \"$1\"; zsystem flock \"$1\"; : > \"$2\"; sleep 5" & h=$!; i=0; while [ ! -f "$2" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done; CLIPBOARD_MOUNT_LOCK_TIMEOUT_S=1 zsh -f "$3" ensure peer-mini; rc=$?; kill $h 2>/dev/null; exit $rc' _ "$MNT_ROOT/.peer-mini.lock" "$SHELLSPEC_TMPBASE/lock-held" "$CM"
    The status should be failure
    The stderr should include "busy"
    The path "$SHELLSPEC_TMPBASE/rclone-argv" should not be exist
  End

  It 'tears down and fails when rclone itself exits nonzero'
    printf '#!/bin/sh\nexit 1\n' > "$STUBS/rclone"; chmod +x "$STUBS/rclone"
    When run command zsh -f "$CM" ensure peer-mini
    The status should be failure
    The stderr should include "failed"
    The path "$MNT_ROOT/peer-mini" should not be exist
  End
End
