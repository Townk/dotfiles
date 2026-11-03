# tests/hammerspoon_svalboard_spec.sh
# The svalboard module's pause/resume (used by qmk-flash around an updater
# flash), run headless under Neovim's Lua with a stub `hs`.

Describe 'svalboard overlay pause/resume'
  MODDIR="$SHELLSPEC_PROJECT_ROOT/home/dot_config/hammerspoon/modules"

  # scenario <saved-mode> <lua body> — prints whatever the body prints.
  # The body sees: M (the module), tasks (every task created), timers
  # (every doAfter recorded), started() (count of started tasks).
  scenario() {
    cat > "$SHELLSPEC_TMPBASE/svalboard.lua" <<LUA
package.path = "$MODDIR/?.lua;$MODDIR/?/init.lua;" .. package.path
tasks, timers = {}, {}
hs = {
  task = { new = function(_, cb)
    local t = { exit = cb, started = false, terminated = false }
    function t:start() self.started = true end
    function t:terminate() self.terminated = true end
    function t:setInput() end
    tasks[#tasks + 1] = t
    return t
  end },
  timer = {
    doAfter = function(secs, fn)
      local tm = { secs = secs, fn = fn, stopped = false }
      function tm:stop() self.stopped = true end
      timers[#timers + 1] = tm
      return tm
    end,
    secondsSinceEpoch = function() return 0 end,
  },
  settings = { get = function() return "$1" ~= "" and "$1" or nil end, set = function() end },
  fs = { attributes = function() return {} end },
  logger = { new = function() return { i = function() end, w = function() end, e = function() end } end },
}
function started() local n = 0 for _, t in ipairs(tasks) do if t.started then n = n + 1 end end return n end
M = require("svalboard")
M.setup()
$2
LUA
    nvim --headless -u NONE -l "$SHELLSPEC_TMPBASE/svalboard.lua" 2>&1
  }

  It 'pause stops a running overlay'
    When call scenario background 'M.pause(300) print(tasks[1].terminated, #timers, timers[1].secs)'
    The output should equal 'true 1 300'
  End

  It 'resume restarts it'
    When call scenario background 'M.pause(300) M.resume() print(started(), timers[1].stopped)'
    The output should equal '2 true'
  End

  It 'resumes on its own after maxSecs'
    When call scenario background 'M.pause(300) timers[1].fn() print(started())'
    The output should equal '2'
  End

  It 'resume does nothing when not paused'
    When call scenario background 'M.resume() print(started(), #timers)'
    The output should equal '1 0'
  End

  It 'stays off when the mode is off'
    When call scenario off 'M.pause(300) M.resume() print(started())'
    The output should equal '0'
  End

  It 'a crash during pause does not restart it'
    When call scenario background 'local t = tasks[1] M.pause(300) t.exit(1) print(#timers, started())'
    The output should equal '1 1'
  End
End
