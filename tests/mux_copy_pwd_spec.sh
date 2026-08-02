# Tests for copy-pwd — copies the focused pane's cwd to the clipboard.
#
# copy-pwd resolves a pane's cwd from a PID via the real /usr/sbin/lsof (a
# hardcoded absolute path — it runs headless with no PATH), so these tests hand
# it a live background process whose cwd we control and let lsof do its job.
#
# Group D of the shared-lib consolidation: the clipboard write must route
# through the pbcopy SHIM ($HOME/.local/bin/pbcopy, absolute — the shim owns the
# SSH/bridge/OSC-52 tiers) instead of hand-rolling /usr/bin/pbcopy + a
# `tmux load-buffer` OSC-52 mirror, falling back to /usr/bin/pbcopy when the
# shim is missing.
Describe 'copy-pwd (clipboard shim routing)'
  CP_SCRIPT="$SHELLSPEC_PROJECT_ROOT/home/dot_config/mux/scripts/executable_copy-pwd"

  setup() {
    # Canonicalize to the PHYSICAL path (macOS symlinks /var → /private/var):
    # lsof (and thus copy-pwd) reports the physical cwd, and copy-pwd's own
    # $HOME-relative collapse compares against $HOME, so both must be physical.
    CP_TMP=$(cd "$(mktemp -d)" && pwd -P)
    export HOME="$CP_TMP/home"
    mkdir -p "$HOME/.local/bin"
    CP_KNOWN="$CP_TMP/known"
    mkdir -p "$CP_KNOWN"
    # A live process whose cwd is CP_KNOWN, so lsof(1) resolves it for copy-pwd.
    zsh -c 'cd "$1"; exec sleep 30' _ "$CP_KNOWN" &
    CP_PID=$!
    # Wait until the exec'd process actually reports the cwd (bounded).
    i=0
    while [ "$i" -lt 50 ]; do
      seen=$(/usr/sbin/lsof -a -p "$CP_PID" -d cwd -Fn 2>/dev/null | awk '/^n/{print substr($0,2);exit}')
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
      seen=$(/usr/sbin/lsof -a -p "$CP_PID" -d cwd -Fn 2>/dev/null | awk '/^n/{print substr($0,2);exit}')
      [ "$seen" = "$UNDER" ] && break
      sleep 0.05; i=$((i + 1))
    done
    make_shim
    When run zsh "$CP_SCRIPT" "$CP_PID"
    The status should be success
    The result of function copied should equal "~/proj"
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
