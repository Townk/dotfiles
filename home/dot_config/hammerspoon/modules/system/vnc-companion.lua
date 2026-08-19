-- Companion tunnel for Screen Sharing sessions (clipboard 6c follow-up).
--
-- VNC carries pixels only — no port forwards, no prepare hook — so a
-- Screen-Sharing-only visit to a bootstrapped machine gets none of the
-- clipboard bridge. This watcher raises the same ssh carrier an interactive
-- session would (`ssh -N <alias>`: the config.d Match hook runs
-- ssh-prepare-connection, and every forward — 2490 bridge, 2491 pointer
-- push, 2493 file plane — rides along), and tears it down when Screen
-- Sharing goes away. Deliberately SESSION-GATED, never always-on: "2490 is
-- bound" must keep meaning "someone is visiting right now" — the
-- sitting/visited semantics the pickers and copy routing key off.
--
-- Title → alias resolution is delegated to vnc-companion-resolve (the
-- onboarded fragments' Host lines are the truth source); a VNC target that
-- is not one of ours simply gets no companion.
local M = {}

local RESOLVE = (os.getenv("HOME") or "") .. "/.local/libexec/vnc-companion-resolve"
local BUNDLE = "com.apple.ScreenSharing"

local tasks = {} -- alias -> hs.task (live companion tunnels)
local watcher
local rescanTimer

local function shellQuote(str)
  return "'" .. tostring(str):gsub("'", "'\\''") .. "'"
end

local function ensureCompanion(alias)
  local existing = tasks[alias]
  if existing and existing:isRunning() then
    return
  end
  -- BatchMode: this must never prompt (the hs.ipc/no-prompt disciplines both
  -- apply); a failed forward must not kill the carrier (another session may
  -- legitimately hold the same reverse forward already).
  local cmd = "exec ssh -N -o BatchMode=yes -o ConnectTimeout=10 " .. shellQuote(alias)
  local task = hs.task.new("/bin/zsh", function(exitCode)
    tasks[alias] = nil
    print(string.format("vnc-companion: %s carrier ended (rc=%s)", alias, tostring(exitCode)))
  end, { "-lc", cmd })
  task:start()
  tasks[alias] = task
  print("vnc-companion: carrier up for " .. alias)
end

-- Screen Sharing window titles name the machine ("thiago-mac-mini" etc.)
-- shortly after connecting; resolve each open window against the fragments.
-- hs.execute blocks the main thread for the resolver's few milliseconds of
-- grep — acceptable, and it keeps the scan logic trivially sequential.
local function scanWindows()
  local app = hs.application.get(BUNDLE)
  if not app then
    return
  end
  for _, win in ipairs(app:allWindows()) do
    local title = win:title() or ""
    if title ~= "" then
      local out, ok = hs.execute(RESOLVE .. " " .. shellQuote(title))
      if ok then
        local alias = tostring(out):gsub("%s+$", "")
        if alias ~= "" then
          ensureCompanion(alias)
        end
      end
    end
  end
end

local function teardownAll()
  for alias, task in pairs(tasks) do
    if task:isRunning() then
      task:terminate()
    end
    tasks[alias] = nil
    print("vnc-companion: carrier torn down for " .. alias)
  end
end

-- A slow periodic rescan for the app's whole lifetime, not a one-shot: the
-- connection window's title only appears once the connection is up (the
-- app opens its connections browser first), connecting to a second machine
-- fires no app-watcher event, and a dropped carrier (network blip) should
-- self-heal. The scan is a few window-title reads + a grep, every 5s, only
-- while Screen Sharing runs — ensureCompanion is idempotent throughout.
local function startScanning()
  if rescanTimer then
    rescanTimer:stop()
  end
  rescanTimer = hs.timer.doEvery(5, function()
    if hs.application.get(BUNDLE) then
      scanWindows()
    else
      rescanTimer:stop()
      rescanTimer = nil
      teardownAll()
    end
  end)
  -- First look quickly — a fresh connection's title usually lands within
  -- a second or two.
  hs.timer.doAfter(1.5, scanWindows)
end

function M.setup()
  watcher = hs.application.watcher.new(function(_, event, app)
    if not app or app:bundleID() ~= BUNDLE then
      return
    end
    if event == hs.application.watcher.launched or event == hs.application.watcher.activated then
      if not rescanTimer then
        startScanning()
      end
    elseif event == hs.application.watcher.terminated then
      if rescanTimer then
        rescanTimer:stop()
        rescanTimer = nil
      end
      teardownAll()
    end
  end)
  watcher:start()
  -- Screen Sharing may already be up when Hammerspoon (re)loads.
  if hs.application.get(BUNDLE) then
    startScanning()
  end
end

function M.cleanup()
  if watcher then
    watcher:stop()
    watcher = nil
  end
  if rescanTimer then
    rescanTimer:stop()
    rescanTimer = nil
  end
  teardownAll()
end

-- Test/inspection helpers (not used in production paths).
M._tasks = tasks
M._scanWindows = scanWindows

return M
