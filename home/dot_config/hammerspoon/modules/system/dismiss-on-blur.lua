--- system/dismiss-on-blur.lua
--- Shared "dismiss this panel when focus moves away from it" primitive.
--- Used by any floating panel (clipboard picker, WhichKey, ...) that needs
--- to auto-close when the user's attention moves elsewhere -- whether via a
--- normal app switch, a non-activating launcher panel (e.g. Raycast)
--- stealing key-window status without a formal app-activation transition,
--- or the OS Cmd+Tab switcher HUD (which grabs neither app-activation nor
--- key-window status while held -- confirmed empirically, see below).
---
--- Usage:
---   local dismissOnBlur = require("system.dismiss-on-blur")
---   dismissOnBlur.arm("my-panel", function(win) return win == myWindow end, M.hide)
---   ...
---   dismissOnBlur.disarm("my-panel")
---   dismissOnBlur.suppress("my-panel", true)  -- deliberate focus shuffle, don't dismiss
---   dismissOnBlur.suppress("my-panel", false)
---   dismissOnBlur.dismissOthers("my-panel")  -- call at the top of show(): mutual
---                                             -- exclusion between OUR OWN panels
---                                             -- (e.g. WhichKey opening while the
---                                             -- clipboard picker is up -- neither
---                                             -- competes for key-window status
---                                             -- with the other, so isExpected
---                                             -- alone would never notice)

local M = {}

---------------------------------------------------------------------------
-- Configuration
---------------------------------------------------------------------------

--- Debugging escape hatch: flip to false to keep every armed panel open
--- regardless of focus changes (e.g. while grabbing a live screenshot of a
--- panel for debugging, which requires switching focus away without it
--- auto-closing). Restore to true afterward.
--- TODO(cleanup): remove once dismiss-on-blur is proven reliable and no more
--- live-debugging sessions are expected (end of the universal-clipboard
--- project).
M.enabled = true

--- Poll interval for the focused-window check. Cheap (a single id
--- comparison), so a short interval is fine.
local POLL_INTERVAL = 0.15

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------

--- @type table<string, { isExpected: fun(win: hs.window|nil): boolean, onDismiss: fun(), suppressed: boolean, pendingMismatch: boolean }>
local guards = {}

--- @type hs.timer|nil
local poller = nil

--- @type hs.eventtap|nil
local switcherTap = nil

---------------------------------------------------------------------------
-- Private
---------------------------------------------------------------------------

--- Check every armed, non-suppressed panel against the current focused
--- window and dismiss any whose `isExpected` predicate now fails -- but only
--- on the SECOND consecutive mismatched tick, not the first.
---
--- This debounce exists because hs.window.focusedWindow() briefly returns
--- nil right after a panel calls hswindow():focus() to claim key-window
--- status on show() (confirmed empirically: it reads nil ~100ms after
--- focus(), then recovers by ~300ms) -- a one-tick false positive that would
--- otherwise self-dismiss a panel within one poll interval of ever showing
--- it. A real focus change (app switch, Raycast, ...) persists across
--- multiple ticks, so requiring two in a row still catches it with no
--- perceptible added latency (one extra ~150ms poll interval), while
--- filtering out this single-tick transient.
--- @private
local function checkAll()
	if not M.enabled then return end
	local win = hs.window.focusedWindow()
	for _, g in pairs(guards) do
		if g.suppressed then
			g.pendingMismatch = false
		elseif not g.isExpected(win) then
			if g.pendingMismatch then
				g.onDismiss()
			else
				g.pendingMismatch = true
			end
		else
			g.pendingMismatch = false
		end
	end
end

--- True while a Cmd+Tab-triggered dismissal is running. Panels' onDismiss
--- (typically their own hide()) can check this to skip any focus-touching
--- cleanup: the OS is about to own the entire focus transition itself once
--- Cmd is released, and doing any Hammerspoon-side work of our own (window
--- focus, starting/stopping other eventtaps) synchronously while the OS is
--- still deciding what to do with this exact keydown is the likely cause of
--- a reported bug where the switcher HUD behaved as if the key were held
--- down, rapid-cycling to the last app in the list -- this is reasoned from
--- the timing (focus hasn't moved yet at keydown time, so the picker's own
--- savedWindow:focus() call was landing mid-keydown-processing) rather than
--- a directly reproduced repro, since the visual symptom isn't something
--- this test harness can observe programmatically.
M.dismissingViaSwitcher = false

--- Unconditionally dismiss every armed, non-suppressed panel, with no
--- isExpected check involved.
---
--- Holding Cmd+Tab shows the OS app-switcher HUD without changing the
--- frontmost app OR the key window: verified empirically that neither
--- hs.application.watcher nor hs.window.focusedWindow() change while Cmd is
--- held, only once it's released. That means checkAll()'s isExpected
--- comparison genuinely has nothing to detect yet at keydown time (the
--- focused window hasn't moved) -- Cmd+Tab being pressed at all, while a
--- panel is showing, is itself the dismiss signal, independent of any
--- focused-window state.
--- @private
local function dismissAllArmed()
	M.dismissingViaSwitcher = true
	for _, g in pairs(guards) do
		if not g.suppressed then
			g.onDismiss()
		end
	end
	M.dismissingViaSwitcher = false
end

--- @param e hs.eventtap.event
--- @return boolean
--- @private
local function onKeyEvent(e)
	if M.enabled then
		local flags = e:getFlags()
		if flags.cmd and e:getKeyCode() == hs.keycodes.map.tab then
			-- Deferred, not called synchronously from here: this callback is
			-- running WHILE the OS is still deciding what to do with this
			-- exact keydown (it waits for our return value). Doing panel
			-- teardown synchronously -- hiding webviews, stopping/starting
			-- other eventtaps (WhichKey's own dispatcher), touching window
			-- focus -- all from inside that window confuses the switcher's
			-- own state. Returning immediately and deferring the real work to
			-- the next runloop tick lets this keydown finish its normal
			-- journey through the OS untouched first.
			hs.timer.doAfter(0, dismissAllArmed)
		end
	end
	return false -- never swallow -- the OS switcher must still see the keystroke untouched
end

--- Lazily start the shared poller/tap on first registration.
--- @private
local function ensureStarted()
	if not poller then
		poller = hs.timer.doEvery(POLL_INTERVAL, checkAll)
	end
	if not switcherTap then
		switcherTap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, onKeyEvent)
		switcherTap:start()
	end
end

--- Stop the shared poller/tap once no panel is armed anymore.
--- @private
local function stopIfIdle()
	if next(guards) then return end
	if poller then
		poller:stop()
		poller = nil
	end
	if switcherTap then
		switcherTap:stop()
		switcherTap = nil
	end
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

--- Register a panel to be auto-dismissed when focus moves away from it.
--- @param id string  Unique key for this panel (e.g. "clipboard-picker")
--- @param isExpected fun(win: hs.window|nil): boolean  True if the given
---   focused window is consistent with "nothing has interrupted this panel"
--- @param onDismiss fun()  Called to hide the panel
function M.arm(id, isExpected, onDismiss)
	guards[id] = { isExpected = isExpected, onDismiss = onDismiss, suppressed = false, pendingMismatch = false }
	ensureStarted()
end

--- Unregister a panel. Call this from the panel's own hide().
--- @param id string
function M.disarm(id)
	guards[id] = nil
	stopIfIdle()
end

--- Suppress (or resume) dismissal for a deliberate, expected focus shuffle
--- (e.g. the clipboard picker's Alt+Enter paste-and-keep-open flow, or a
--- WhichKey sticky action that legitimately needs to touch another window).
--- @param id string
--- @param val boolean
function M.suppress(id, val)
	if guards[id] then
		guards[id].suppressed = val
	end
end

--- Dismiss every OTHER currently-armed panel. Call this at the top of a
--- panel's own show(), before arming itself, so two of our own managed
--- panels never coexist -- neither the clipboard picker nor WhichKey ever
--- takes key-window status away from the other (the picker keeps it, and
--- WhichKey never wants it), so isExpected()/checkAll() alone would never
--- notice one opening while the other is already up. Ignores `suppressed`
--- (another panel explicitly opening is a stronger signal than any
--- in-flight deliberate focus shuffle) but still respects the `enabled`
--- escape hatch.
--- @param exceptId string  Don't dismiss this panel (the one about to show)
function M.dismissOthers(exceptId)
	if not M.enabled then return end
	for id, g in pairs(guards) do
		if id ~= exceptId then
			g.onDismiss()
		end
	end
end

return M
