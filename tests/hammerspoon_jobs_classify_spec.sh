# tests/hammerspoon_jobs_classify_spec.sh
# The jobs HUD's state decision, as a pure Lua module (no hs.* dependency),
# run headless under Neovim's Lua like tests/yazi_share_spec.sh.
# Spec: docs/superpowers/specs/2026-09-29-job-waiting-phase-design.md (W4, W6)

Describe 'jobs HUD classify'
  MODDIR="$SHELLSPEC_PROJECT_ROOT/home/dot_config/hammerspoon/modules"

  lua() {  # lua <expression> — prints the expression's value
    printf 'package.path = "%s/?.lua;%s/?/init.lua;" .. package.path\nlocal c = require("jobs.classify")\nprint(%s)\n' \
      "$MODDIR" "$MODDIR" "$1" > "$SHELLSPEC_TMPBASE/classify.lua"
    nvim --headless -u NONE -l "$SHELLSPEC_TMPBASE/classify.lua" 2>&1
  }

  It 'is waiting for a waiting phase, however old the epoch'
    When call lua 'c.classify({phase="waiting", pct=-1, epoch=0, reportsProgress=true}, "running", 36000, 6)'
    The output should equal 'waiting'
  End

  It 'is preparing for an indeterminate job with no phase'
    When call lua 'c.classify({pct=-1, epoch=100, reportsProgress=true}, "running", 101, 6)'
    The output should equal 'preparing'
  End

  It 'is preparing while pueue still queues it'
    When call lua 'c.classify({pct=40, epoch=100, reportsProgress=true}, "queued", 101, 6)'
    The output should equal 'preparing'
  End

  It 'is stalled when a reporting job goes quiet while running'
    When call lua 'c.classify({pct=40, epoch=100, reportsProgress=true}, "running", 107, 6)'
    The output should equal 'stalled'
  End

  It 'is running with a fresh percent'
    When call lua 'c.classify({pct=40, epoch=100, reportsProgress=true}, "running", 103, 6)'
    The output should equal 'running'
  End

  It 'never infers a stall for a job that reports no progress'
    When call lua 'c.classify({pct=40, epoch=100, reportsProgress=false}, "running", 999, 6)'
    The output should equal 'running'
  End

  It 'lets a real percent win over a lingering waiting phase'
    When call lua 'c.classify({phase="waiting", pct=40, epoch=100, reportsProgress=true}, "running", 103, 6)'
    The output should equal 'running'
  End

  # Review focus 3
  It 'reads only the exact word as a waiting phase'
    When call lua 'tostring(c.readPhase("waiting\n")) .. "," .. tostring(c.readPhase("paused")) .. "," .. tostring(c.readPhase(nil))'
    The output should equal 'waiting,nil,nil'
  End

  # The tmux status reader compares `$(<phase)` (trailing newlines stripped,
  # nothing else) to the word: padding must read as "no phase" here too.
  It 'treats padded phase content as no phase, like the tmux reader'
    When call lua 'tostring(c.readPhase(" waiting")) .. "," .. tostring(c.readPhase("\twaiting")) .. "," .. tostring(c.readPhase("waiting ")) .. "," .. tostring(c.readPhase("waiting\n\n"))'
    The output should equal 'nil,nil,nil,waiting'
  End

  It 'formats elapsed time in minutes, hours, then days'
    When call lua 'c.elapsed(1000, 1030) .. "," .. c.elapsed(1000, 1000 + 12*60) .. "," .. c.elapsed(1000, 1000 + 3*3600) .. "," .. c.elapsed(1000, 1000 + 50*3600) .. "," .. c.elapsed(nil, 5)'
    The output should equal '1m,12m,3h,2d,'
  End
End
