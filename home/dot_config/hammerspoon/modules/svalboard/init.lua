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
	if task or mode == "off" then return end
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

--- Switch the overlay to `newMode` and remember it across reloads.
---@param newMode SvalboardOverlayMode
function M.setMode(newMode)
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
