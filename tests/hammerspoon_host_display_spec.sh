# system/host-display.lua — the Lua twin of host::display (peer-alias spec H6),
# used by Hammerspoon's clipboard copy toast. Pure Lua, run under plain `lua`.
Describe 'Hammerspoon host-display'
  setup() {
    SB="$SHELLSPEC_TMPBASE/hs-host"; rm -rf "$SB"; mkdir -p "$SB/home"
    long="$(printf 'a%.0s' $(seq 1 65))"
    ok64="$(printf 'b%.0s' $(seq 1 64))"
    printf 'peer-key-01 peer-laptop\npeer-key-02 bad-alias\r\npeer-key-03 %s\npeer-key-04 %s\npeer-key-05  spaced  \n' \
      "$long" "$ok64" >"$SB/aliases"
    printf 'desk-box\n' >"$SB/home/.hostname-alias"
  }
  BeforeEach 'setup'

  # disp <key> [self-key]
  disp() {
    HOME="$SB/home" HOST_ALIASES_FILE="$SB/aliases" SPEC_ROOT="$SHELLSPEC_PROJECT_ROOT" \
      lua - "$@" <<'LUA'
package.path = os.getenv("SPEC_ROOT") .. "/home/dot_config/hammerspoon/modules/?.lua;" .. package.path
local hd = require("system.host-display")
io.write(hd.display(arg[1], arg[2]))
LUA
  }

  # zdisp <key> [self-key] — the zsh original, for parity checks
  zdisp() {
    HOME="$SB/home" HOST_ALIASES_FILE="$SB/aliases" \
      zsh -c 'source "$1/home/dot_local/lib/host.zsh"; shift; host::display "$@"' _ "$SHELLSPEC_PROJECT_ROOT" "$@"
  }

  It 'names a mapped machine by its alias'
    When call disp peer-key-01
    The output should equal 'peer-laptop'
  End

  It 'names this machine by its own alias'
    When call disp self-key self-key
    The output should equal 'desk-box'
  End

  It 'keeps an unknown key'
    When call disp stranger-9
    The output should equal 'stranger-9'
  End

  # both <key> — "lua|zsh" answers for the same key
  both() { disp "$1"; printf '|'; zdisp "$1"; }

  It 'rejects a CRLF-terminated alias, as host.zsh does'
    When call both peer-key-02
    The output should equal 'peer-key-02|peer-key-02'
  End

  It 'rejects a 65-char alias, as host.zsh does'
    When call both peer-key-03
    The output should equal 'peer-key-03|peer-key-03'
  End

  It 'accepts a 64-char alias, as host.zsh does'
    When call both peer-key-04
    The output should equal "${ok64}|${ok64}"
  End

  # bothself <key> — same, with <key> as this machine's own key
  bothself() { disp "$1" "$1"; printf '|'; zdisp "$1" "$1"; }

  It 'trims a CRLF own-alias file like host.zsh'
    printf '  desk-box \t\r\n' >"$SB/home/.hostname-alias"
    When call bothself self-key
    The output should equal 'desk-box|desk-box'
  End

  It 'keeps the key for an own alias with inner whitespace, as host.zsh does'
    printf 'desk box\n' >"$SB/home/.hostname-alias"
    When call bothself self-key
    The output should equal 'self-key|self-key'
  End

  It 'trims surrounding spaces like host.zsh'
    When call disp peer-key-05
    The output should equal 'spaced'
  End

  It 'falls back to HOME/.local/state without XDG_STATE_HOME'
    fallback() {
      mkdir -p "$SB/home/.local/state/hosts"
      printf 'peer-key-09 fallback-name\n' >"$SB/home/.local/state/hosts/aliases"
      env -u XDG_STATE_HOME -u HOST_ALIASES_FILE HOME="$SB/home" SPEC_ROOT="$SHELLSPEC_PROJECT_ROOT" \
        lua -e 'package.path = os.getenv("SPEC_ROOT") .. "/home/dot_config/hammerspoon/modules/?.lua;" .. package.path
io.write(require("system.host-display").display("peer-key-09"))'
    }
    When call fallback
    The output should equal 'fallback-name'
  End
End
