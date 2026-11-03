-- svalboard — the Svalboard's layer overlay.
--
-- The overlay itself is svaloverlay, a separate process built and installed
-- from the keyboard userspace (qmk-config/tools/svalwatch, `make install`):
-- a click-through panel in the bottom-left corner showing the current layer
-- and the keys being held, styled like the which-key overlay. It reads the
-- keyboard itself; this module only owns its lifetime and its z-order.
--
-- Three modes, kept across reloads (hs.settings):
--   "off"         no overlay. The process is not running at all, so it holds
--                 no memory and the keyboard gets no traffic from it.
--   "background"  below every window, like a desktop widget (the default).
--   "top"         above every window.
-- cycle() steps off -> background -> top -> off; the leader binding is
-- sticky, so pressing it again keeps stepping until Esc.
--
-- Lifetime while on: started here, stopped by cleanup() (reload), and it
-- exits on its own when Hammerspoon goes away, since its stdin then closes.
-- A crash restarts it after RESTART_SECS, unless it keeps dying right after
-- start. The z-order goes over the task's stdin, one command per line;
-- hs.task keeps stdin open only for tasks with a streaming callback, which
-- is why the task below has one even though the overlay prints nothing on
-- stdout.
--
-- pause(secs)/resume() exist for qmk-flash: flashing over the in-firmware
-- updater needs the keyboard's raw-HID interface, which the overlay holds
-- open, so qmk-flash pauses the overlay first and resumes it afterwards. The
-- pause lifts itself after `secs` in case qmk-flash dies before resuming.

local M = {}

local BIN = os.getenv("HOME") .. "/.local/bin/svaloverlay"
local SETTINGS_KEY = "svalboard.overlayMode"
local RESTART_SECS = 5
local QUICK_SECS = 30 -- an exit this soon after start counts as "keeps dying"
local MAX_QUICK_EXITS = 3

local log = hs.logger.new("svalboard", "info")

---@alias SvalboardOverlayMode "off"|"background"|"top"

local mode = "background" ---@type SvalboardOverlayMode
local task = nil ---@type hs.task|nil
local restartTimer = nil ---@type hs.timer|nil
local startedAt = 0
local quickExits = 0
local paused = false
local pauseTimer = nil ---@type hs.timer|nil

local start

local function cancelRestart()
	if restartTimer then
		restartTimer:stop()
		restartTimer = nil
	end
end

local function stop()
	cancelRestart()
	if task then
		local t = task
		task = nil -- before terminate(): its exit callback must not restart it
		t:terminate()
	end
end

local function scheduleRestart()
	if hs.timer.secondsSinceEpoch() - startedAt < QUICK_SECS then
		quickExits = quickExits + 1
	else
		quickExits = 0
	end
	if quickExits >= MAX_QUICK_EXITS then
		log.e("svaloverlay keeps exiting right after start; not restarting it (see the lines above)")
		return
	end
	restartTimer = hs.timer.doAfter(RESTART_SECS, function()
		restartTimer = nil
		start()
	end)
end

start = function()
	if task or paused or mode == "off" then return end
	if not hs.fs.attributes(BIN) then
		log.w("not installed: " .. BIN .. " (run `make install` in qmk-config/tools/svalwatch)")
		return
	end
	startedAt = hs.timer.secondsSinceEpoch()
	local thisTask
	thisTask = hs.task.new(BIN, function(rc)
		if task ~= thisTask then return end -- stopped on purpose
		task = nil
		log.w("svaloverlay exited with " .. tostring(rc))
		scheduleRestart()
	end, function(_, _, stderr)
		if stderr and stderr ~= "" then
			log.i((stderr:gsub("%s+$", "")))
		end
		return true
	end, mode == "top" and { "--on-top" } or {})
	task = thisTask
	task:start()
end

local function clearPause()
	paused = false
	if pauseTimer then
		pauseTimer:stop()
		pauseTimer = nil
	end
end

--- Stop the overlay (the saved mode is untouched) and bring it back by itself
--- after `maxSecs`. Pausing again while paused only resets the timer.
---@param maxSecs number
function M.pause(maxSecs)
	if pauseTimer then pauseTimer:stop() end
	paused = true
	stop()
	pauseTimer = hs.timer.doAfter(maxSecs, function()
		pauseTimer = nil
		M.resume()
	end)
end

--- End a pause and start the overlay again (if the mode wants it on).
function M.resume()
	if not paused then return end
	clearPause()
	quickExits = 0
	start()
end

--- Switch the overlay to `newMode` and remember it across reloads.
---@param newMode SvalboardOverlayMode
function M.setMode(newMode)
	clearPause()
	mode = newMode
	hs.settings.set(SETTINGS_KEY, mode)
	if mode == "off" then
		stop()
	elseif task then
		task:setInput(mode == "top" and "top\n" or "bottom\n")
	else
		quickExits = 0
		start() -- picks up the mode through --on-top
	end
end

local NEXT_MODE = { off = "background", background = "top", top = "off" }

--- Step to the next mode: off -> background -> top -> off.
function M.cycle()
	M.setMode(NEXT_MODE[mode])
end

function M.setup()
	local saved = hs.settings.get(SETTINGS_KEY)
	if saved == "off" or saved == "background" or saved == "top" then
		mode = saved
	end
	start()
end

function M.cleanup()
	stop()
end

return M
