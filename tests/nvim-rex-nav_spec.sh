# Tests for the nvim half of Rex pane navigation —
# home/dot_config/nvim/lua/plugins/nav.lua.
#
# smart-splits has no Rex backend, so past nvim's last split it calls its
# `move.at_edge` hook. In a Rex pane that hook must hand the motion to Rex
# (`rex focus <direction>`); anywhere else it must do what smart-splits did
# before the hook existed (wrap). The plugin file is loaded as plain Lua in a
# headless nvim — the hook's logic does not need the plugin itself.
Describe 'nvim → Rex pane navigation'
  nvim_missing() { ! command -v nvim >/dev/null 2>&1; }
  Skip if 'nvim is not installed' nvim_missing

  setup() {
    NV_TMP=$(mktemp -d)
    mkdir -p "$NV_TMP/bin"
    cat >"$NV_TMP/bin/rex" <<EOS
#!/bin/sh
echo "\$*" >>"$NV_TMP/rex.log"
EOS
    chmod +x "$NV_TMP/bin/rex"
    cat >"$NV_TMP/run.lua" <<'EOS'
-- The hook is reached the way smart-splits reaches it: through the spec's opts.
local at_edge = dofile(os.getenv("NAV_LUA"))[1].opts.move.at_edge
local wrapped = false
at_edge({ direction = os.getenv("NAV_DIR"), wrap = function() wrapped = true end })
vim.wait(500, function() return false end)
io.write(wrapped and "wrapped" or "handed-off", "\n")
EOS
  }
  cleanup() { rm -rf "$NV_TMP"; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  # edge <direction> [VAR=value...] — run the hook in a clean environment.
  edge() {
    local dir=$1; shift
    env -i HOME="$NV_TMP" PATH="/usr/bin:/bin:${commands[nvim]:h}" \
      NAV_LUA="$PWD/home/dot_config/nvim/lua/plugins/nav.lua" NAV_DIR="$dir" "$@" \
      nvim --headless -u NONE -l "$NV_TMP/run.lua" 2>&1
  }
  rex_calls() { cat "$NV_TMP/rex.log" 2>/dev/null; }

  It 'hands the motion to Rex in a Rex pane'
    When call edge left REX_BLOCK=block:b REX_SESSION=session:s REX_BIN_DIR="$NV_TMP/bin"
    The output should equal "handed-off"
    The contents of file "$NV_TMP/rex.log" should equal "--autostart=false focus left -s session:s"
  End

  It 'passes the direction through'
    When call edge down REX_BLOCK=block:b REX_BIN_DIR="$NV_TMP/bin"
    The output should equal "handed-off"
    The contents of file "$NV_TMP/rex.log" should equal "--autostart=false focus down"
  End

  It 'wraps, as before, outside Rex'
    When call edge left REX_BIN_DIR="$NV_TMP/bin"
    The output should equal "wrapped"
    The path "$NV_TMP/rex.log" should not be exist
  End

  It 'leaves tmux its own backend when tmux runs inside a Rex pane'
    When call edge left REX_BLOCK=block:b TMUX=/tmp/s,1,0 REX_BIN_DIR="$NV_TMP/bin"
    The output should equal "wrapped"
    The path "$NV_TMP/rex.log" should not be exist
  End

  It 'does not raise when the rex binary is missing'
    When call edge left REX_BLOCK=block:b REX_BIN_DIR="$NV_TMP/nowhere"
    The output should equal "handed-off"
  End
End
