# Tests for copy-pwd — copies the focused pane's cwd to the clipboard.
#
# copy-pwd resolves a pane's cwd from a PID straight from the kernel (/proc on
# Linux, /usr/sbin/lsof on macOS — an absolute path, since it runs headless with
# no PATH), so these tests hand it a live background process whose cwd we
# control and let that resolution do its job. cp_cwd_of mirrors it.
#
# Group D of the shared-lib consolidation: the clipboard write must route
# through the pbcopy SHIM ($HOME/.local/bin/pbcopy, absolute — the shim owns the
# SSH/bridge/OSC-52 tiers) instead of hand-rolling /usr/bin/pbcopy + a
# `tmux load-buffer` OSC-52 mirror, falling back to /usr/bin/pbcopy when the
# shim is missing.
Describe 'copy-pwd (clipboard shim routing)'
  CP_SCRIPT="$SHELLSPEC_PROJECT_ROOT/home/dot_config/mux/scripts/executable_copy-pwd"

  # Same resolution copy-pwd uses, so the readiness probes below agree with the
  # script under test on either platform.
  cp_cwd_of() {
    if [ -L "/proc/$1/cwd" ]; then
      readlink "/proc/$1/cwd" 2>/dev/null
    else
      /usr/sbin/lsof -a -p "$1" -d cwd -Fn 2>/dev/null |
        awk '/^n/{print substr($0,2);exit}'
    fi
  }

  setup() {
    # Canonicalize to the PHYSICAL path (macOS symlinks /var → /private/var):
    # lsof (and thus copy-pwd) reports the physical cwd, and copy-pwd's own
    # $HOME-relative collapse compares against $HOME, so both must be physical.
    CP_TMP=$(cd "$(mktemp -d)" && pwd -P)
    export HOME="$CP_TMP/home"
    mkdir -p "$HOME/.local/bin"
    CP_KNOWN="$CP_TMP/known"
    mkdir -p "$CP_KNOWN"
    # A live process whose cwd is CP_KNOWN, so the kernel resolves it for copy-pwd.
    zsh -c 'cd "$1"; exec sleep 30' _ "$CP_KNOWN" &
    CP_PID=$!
    # Wait until the exec'd process actually reports the cwd (bounded).
    i=0
    while [ "$i" -lt 50 ]; do
      seen=$(cp_cwd_of "$CP_PID")
      [ "$seen" = "$CP_KNOWN" ] && break
      sleep 0.05; i=$((i + 1))
    done
  }
  cleanup() {
    [ -n "$CP_PID" ] && kill "$CP_PID" 2>/dev/null
    [ -n "$CP_TMP" ] && rm -rf "$CP_TMP"
  }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  # Recording pbcopy shim: captures stdin so we can assert exactly what copy-pwd
  # sent to the clipboard, and proves the write went through the SHIM path.
  make_shim() {
    { printf '#!/bin/sh\n'; printf 'cat >"%s/copied"\n' "$CP_TMP"; } >"$HOME/.local/bin/pbcopy"
    chmod +x "$HOME/.local/bin/pbcopy"
  }
  copied() { cat "$CP_TMP/copied" 2>/dev/null; }

  # Recording notify: copy-pwd gets it by sourcing common.zsh out of $HOME, which
  # the temp HOME above lets us replace wholesale. One log line per call, in call
  # order, with the flags — which is exactly what the two-phase toast is about.
  make_notify() {
    mkdir -p "$HOME/.local/lib"
    printf 'notify() { print -r -- "$*" >> "%s/notifylog" }\n' "$CP_TMP" \
      >"$HOME/.local/lib/common.zsh"
  }
  notifylog() { cat "$CP_TMP/notifylog" 2>/dev/null; }

  # The final toast is sent from a BACKGROUND job (an OSD hiccup must not fail the
  # copy), so it can land after the script has exited — poll for it.
  wait_notify() {
    i=0
    while [ "$i" -lt 100 ]; do
      n=$(grep -c . "$CP_TMP/notifylog" 2>/dev/null || echo 0)
      [ "$n" -ge "$1" ] && return 0
      sleep 0.02; i=$((i + 1))
    done
    return 1
  }

  It 'routes the copied path through the pbcopy shim (absolute mode)'
    make_shim
    When run zsh "$CP_SCRIPT" --absolute "$CP_PID"
    The status should be success
    The result of function copied should equal "$CP_KNOWN"
  End

  It 'copies the path with no trailing newline'
    make_shim
    run_copy() { zsh "$CP_SCRIPT" --absolute "$CP_PID" >/dev/null 2>&1; wc -c <"$CP_TMP/copied" | tr -d ' '; }
    # "$CP_KNOWN" is N bytes; a trailing newline would make it N+1.
    expected_len() { printf '%s' "$CP_KNOWN" | wc -c | tr -d ' '; }
    When call run_copy
    The output should equal "$(expected_len)"
  End

  It 'collapses $HOME to ~ in relative mode (value + routing through the shim)'
    # Point the live process at a dir under HOME so relative mode collapses it.
    kill "$CP_PID" 2>/dev/null
    UNDER="$HOME/proj"; mkdir -p "$UNDER"
    zsh -c 'cd "$1"; exec sleep 30' _ "$UNDER" &
    CP_PID=$!
    i=0
    while [ "$i" -lt 50 ]; do
      seen=$(cp_cwd_of "$CP_PID")
      [ "$seen" = "$UNDER" ] && break
      sleep 0.05; i=$((i + 1))
    done
    make_shim
    When run zsh "$CP_SCRIPT" "$CP_PID"
    The status should be success
    The result of function copied should equal "~/proj"
  End

  # TMUX is unset in every feedback example below so the branch is decided only by
  # NOTIFY_VIA_BRIDGE: with TMUX set (running the suite from inside tmux) copy-pwd
  # would also probe list-clients and the status-line fallback could fire.
  It 'announces the copy first, then replaces the toast when it lands (bridge)'
    make_shim; make_notify
    unset TMUX
    export NOTIFY_VIA_BRIDGE=1
    two_phase() { zsh "$CP_SCRIPT" --absolute "$CP_PID" >/dev/null 2>&1; wait_notify 2; notifylog; }
    When call two_phase
    The status should be success
    The line 1 of output should include 'Copying path'
    # The sound is the acknowledgement of the KEYPRESS, so it rides on the first
    # toast and the completion one is silent.
    The line 1 of output should include '--sound Frog'
    The line 2 of output should include 'Absolute path copied to clipboard'
    The line 2 of output should not include 'Frog'
  End

  It 'shows one toast only when the OSD is local'
    make_shim; make_notify
    unset TMUX
    unset NOTIFY_VIA_BRIDGE
    # Settle before reading: the assertion is that a second toast never arrives,
    # and wait_notify can only prove that the first one did.
    single() { zsh "$CP_SCRIPT" --absolute "$CP_PID" >/dev/null 2>&1; wait_notify 1; sleep 0.2; notifylog; }
    When call single
    The lines of output should equal 1
    # With no announcement to carry it, the lone toast keeps the sound.
    The output should include '--sound Frog'
  End

  It 'reports a failed copy with the error icon, the error sound, and rc 1'
    # A shim that refuses the copy — the bridge-down, sink-unopenable case, which
    # used to reach tmux as a bare "returned 2" with nothing on screen.
    printf '#!/bin/sh\necho "pbcopy: cannot deliver the copy" >&2\nexit 1\n' \
      >"$HOME/.local/bin/pbcopy"
    chmod +x "$HOME/.local/bin/pbcopy"
    make_notify
    unset TMUX
    export NOTIFY_VIA_BRIDGE=1
    failed() { zsh "$CP_SCRIPT" --absolute "$CP_PID" >/dev/null 2>&1; rc=$?; wait_notify 2; notifylog; return "$rc"; }
    When call failed
    The status should eq 1
    The line 2 of output should include 'glyph:nf-cod-error'
    The line 2 of output should include 'Basso'
    The line 2 of output should include 'cannot deliver the copy'
  End

  It 'falls back to /usr/bin/pbcopy when the shim is absent'
    # No shim in $HOME/.local/bin → copy-pwd must use the system pbcopy. Guard
    # on a working system pasteboard (a headless box has none) and preserve the
    # real clipboard around the check.
    fallback() {
      [ -x /usr/bin/pbcopy ] && [ -x /usr/bin/pbpaste ] || return 0   # skip → pass
      /usr/bin/pbpaste >/dev/null 2>&1 || return 0                    # no pasteboard → skip
      rm -f "$HOME/.local/bin/pbcopy"
      local saved; saved=$(/usr/bin/pbpaste 2>/dev/null)
      zsh "$CP_SCRIPT" --absolute "$CP_PID" >/dev/null 2>&1; local rc=$?
      local got; got=$(/usr/bin/pbpaste 2>/dev/null)
      printf '%s' "$saved" | /usr/bin/pbcopy 2>/dev/null              # restore
      [ "$rc" -eq 0 ] && [ "$got" = "$CP_KNOWN" ]
    }
    When call fallback
    The status should be success
  End
End
