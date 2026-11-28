# Tests for the nvim half of Rex pane navigation —
# home/dot_config/nvim/lua/plugins/nav.lua.
#
# smart-splits v3 ships no multiplexer backends; nav.lua carries one for Rex.
# Core calls its `move` when a motion runs out of nvim windows and its
# `resize` when the nvim window fills the whole axis. In a Rex pane the
# backend must detect and hand both to Rex (`rex focus <direction>`,
# `rex do pane_resize_by …`); anywhere else it must NOT detect, so core does
# what it does with no backend at all. The plugin file is loaded as plain
# Lua in a headless nvim; one example checks the table against the real
# plugin's validator.
Describe 'nvim → Rex pane navigation and resize'
  nvim_missing() { ! command -v nvim >/dev/null 2>&1; }
  Skip if 'nvim is not installed' nvim_missing

  # The fake rex and the driver are the same for every example: written once.
  # The fake logs into the example's own directory, named by $NV_TMP, and
  # then leaves rex.done beside the log: the driver below waits for THAT, not
  # for half a second, so "handled" is printed once the detached rex has run.
  fixtures() {
    NV_FIX="$SHELLSPEC_TMPBASE/nv-fix"
    mkdir -p "$NV_FIX"
    cat >"$NV_FIX/rex" <<'EOS'
#!/bin/sh
echo "$*" >>"$NV_TMP/rex.log"
: >"$NV_TMP/rex.done"
EOS
    chmod +x "$NV_FIX/rex"
    "$NV_FIX/rex" >/dev/null 2>&1   # first exec of the inode, outside the examples
    cat >"$NV_FIX/run.lua" <<'EOS'
-- The backend is reached the way smart-splits reaches it: through the opts.
local opts = dofile(os.getenv("NAV_LUA"))[1].opts
local backend = opts.mux.backend
local op, dir = os.getenv("NAV_OP"), os.getenv("NAV_DIR")
if op == "validate" then
  vim.opt.rtp:append(os.getenv("NAV_PLUGIN"))
  local err = require("smart-splits.backend").validate(backend)
  io.write(err or "valid", " step=", tostring(opts.resize.amount), " warn=", tostring(opts.mux.warn_if_unusable), "\n")
  return
end
if not backend.detect() then
  io.write("not-detected\n")
  return
end
local handled
if op == "resize" then
  local amount = tonumber(os.getenv("NAV_AMOUNT") or "")
  handled = backend.resize(dir, amount and { amount = amount } or nil)
else
  handled = backend.move(dir, {})
end
-- The rex call is detached and asynchronous: give it up to 500 ms, as
-- before, but stop as soon as the fake says it has run. An example whose rex
-- never runs (the missing binary) still sits out the whole window.
local done = os.getenv("NV_TMP") .. "/rex.done"
vim.wait(500, function() return (vim.uv or vim.loop).fs_stat(done) ~= nil end, 2)
io.write(handled == true and "handled" or "declined", "\n")
EOS
  }
  BeforeAll 'fixtures'
  setup() {
    spec_sandbox nv; NV_TMP=$SANDBOX
    mkdir "$NV_TMP/bin" && ln "$NV_FIX/rex" "$NV_TMP/bin/rex"
  }
  BeforeEach 'setup'

  # edge <op> <direction> [VAR=value...] — run the backend in a clean environment.
  edge() {
    local op=$1 dir=$2; shift 2
    env -i HOME="$NV_TMP" NV_TMP="$NV_TMP" PATH="/usr/bin:/bin:${commands[nvim]:h}" \
      NAV_LUA="$PWD/home/dot_config/nvim/lua/plugins/nav.lua" NAV_OP="$op" NAV_DIR="$dir" "$@" \
      nvim --headless -u NONE -l "$NV_FIX/run.lua" 2>&1
  }
  plugin_dir() { print -r -- "${XDG_DATA_HOME:-$HOME/.local/share}/nvim/lazy/smart-splits.nvim"; }
  plugin_missing() { [[ ! -d "$(plugin_dir)" ]]; }

  It 'hands a move to Rex in a Rex pane'
    When call edge move left REX_BLOCK=block:b REX_SESSION=session:s REX_BIN_DIR="$NV_TMP/bin"
    The output should equal "handled"
    The contents of file "$NV_TMP/rex.log" should equal "--autostart=false focus left -s session:s"
  End

  It 'passes the direction through'
    When call edge move down REX_BLOCK=block:b REX_BIN_DIR="$NV_TMP/bin"
    The output should equal "handled"
    The contents of file "$NV_TMP/rex.log" should equal "--autostart=false focus down"
  End

  It 'hands a resize to the Rex action, for this pane, with the amount core passed'
    When call edge resize right REX_BLOCK=block:b REX_SESSION=session:s REX_BIN_DIR="$NV_TMP/bin" NAV_AMOUNT=6
    The output should equal "handled"
    The contents of file "$NV_TMP/rex.log" should equal "--autostart=false do pane_resize_by -b block:b direction=right cells=6 -s session:s"
  End

  It 'falls back to its own step when called without an amount'
    When call edge resize up REX_BLOCK=block:b REX_BIN_DIR="$NV_TMP/bin"
    The output should equal "handled"
    The contents of file "$NV_TMP/rex.log" should equal "--autostart=false do pane_resize_by -b block:b direction=up cells=2"
  End

  It 'does not detect outside Rex'
    When call edge move left REX_BIN_DIR="$NV_TMP/bin"
    The output should equal "not-detected"
    The path "$NV_TMP/rex.log" should not be exist
  End

  It 'does not detect when tmux runs inside a Rex pane'
    When call edge move left REX_BLOCK=block:b TMUX=/tmp/s,1,0 REX_BIN_DIR="$NV_TMP/bin"
    The output should equal "not-detected"
    The path "$NV_TMP/rex.log" should not be exist
  End

  It 'does not raise when the rex binary is missing'
    Skip if 'complete-only: sits out the real 500 ms window in which a failed spawn could still raise' spec_complete_only
    When call edge move left REX_BLOCK=block:b REX_BIN_DIR="$NV_TMP/nowhere"
    The output should equal "handled"
  End

  # The step must equal Rex's own (RESIZE_STEP in init.lua.tmpl), and a
  # backend that does not detect is the normal case outside Rex, not a warning.
  It 'is a backend the installed smart-splits accepts, with the shared step and no warning'
    Skip if 'smart-splits is not installed' plugin_missing
    When call edge validate - NAV_PLUGIN="$(plugin_dir)"
    The output should equal "valid step=2 warn=false"
  End

  It 'uses the same resize step as the Rex config'
    steps() {
      print -r -- "$(sed -n 's/^M\.RESIZE_STEP = \([0-9]*\).*/\1/p' home/dot_config/nvim/lua/plugins/nav.lua)" \
        "$(sed -n 's/^local RESIZE_STEP = \([0-9]*\).*/\1/p' home/dot_config/rex/init.lua.tmpl)"
    }
    When call steps
    The output should equal "2 2"
  End
End
