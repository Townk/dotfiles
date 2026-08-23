--- ripper/library-dialog.lua — the "Audiobook Library" panel.
---
--- A full hs.webview + HTML/CSS/JS UI (Assets/html/rip-library.{html,css}),
--- the primary UI for the audiobook side of the ripper: a scrollable list of
--- the Audible library (Libation's provider rows) so several titles can be
--- queued for rip-and-push in one pass. Unlike rip-session's per-disc Rip
--- Session Review, every row's control here is an INDEPENDENT Rip/Skip
--- toggle — there is no Feature, nothing demotes anything.
---
--- Architecture, structure and every hard-won mechanic (template loading +
--- %%KEY%% substitution, json_for_script's <-escaping, the explicit
--- javaScriptEnabled flag, modalPanel level, the focus dance, dismiss-on-
--- blur's dismissOthers with hide()'s two focus guards) are lifted wholesale
--- from ripper/session-dialog.lua — the shipped, live-debugged sibling panel
--- — deliberately, not re-derived. See that file for the rationale behind
--- each one.
---
--- THIS MODULE IS A SHELL: it renders whatever rows it is given and posts
--- the operator's picks back through the three callbacks below. It knows
--- nothing about Libation, the server's existing library, or the pueue
--- session worker — those are later tasks' job (see the panel's spec).
---
--- API:
---   local library = require("ripper.library-dialog")
---   library.show(data, callbacks)       -- open, or re-render in place if already open
---   library.setRows(rows)               -- additive repaint of an open panel
---   library.setServerLibrary(paths)     -- the hide-filter set (a later task fills it)
---   library.hide()                      -- dismiss (fires callbacks.onDismiss once)
---   library.isShown()                   -- true while the panel is up
---   library.cleanup()                   -- delete the webview (register with lifecycle)
---
--- `data`:
---   { rows = { <row>, ... }, loading = false, provider = "libation" }
---
--- Row shape (the provider contract's row, verbatim):
---   { id, title, subtitle, authors, narrators, duration_s, series,
---     series_position, cover, acquired, path }
---
--- `callbacks`: { onStart = fun(plan), onImport = fun(spec), onDismiss = fun() }
---   plan: { provider = "libation", items = { <row>, ... } } -- the full rows
---         for every id the operator marked Rip.
---   spec: { src = "...", author = "...", title = "..." } -- a manual/DRM-free
---         import (rip-library.html has no UI for this yet; the dispatch
---         exists so a later task can add it without touching this file).

local M = {}

local dismissOnBlur = require("system.dismiss-on-blur")

local ASSETS_DIR = hs.configdir .. "/Assets/html"

--------------------------------------------------------------------------------
-- Template loading (session-dialog: ensure_templates/substitute)
--------------------------------------------------------------------------------

local htmlTemplateRaw, cssTemplateRaw

local function read_file(path)
	local f = io.open(path, "r")
	if not f then
		return nil
	end
	local content = f:read("*a")
	f:close()
	return content
end

local function ensure_templates()
	if not cssTemplateRaw then
		cssTemplateRaw = read_file(ASSETS_DIR .. "/rip-library.css")
		assert(cssTemplateRaw, "rip-library: CSS template not found")
	end
	if not htmlTemplateRaw then
		htmlTemplateRaw = read_file(ASSETS_DIR .. "/rip-library.html")
		assert(htmlTemplateRaw, "rip-library: HTML template not found")
	end
end

-- Substitute %%KEY%% placeholders. Function-based gsub replacement values are
-- inserted verbatim (not re-interpreted as %n capture references), so no
-- extra escaping is needed here — same technique as session-dialog.lua,
-- keybindings/template.lua and clipboard-picker.lua.
local function substitute(tmpl, subs)
	return (tmpl:gsub("%%%%([%w_]+)%%%%", function(key)
		local val = subs[key]
		if val ~= nil then
			return tostring(val)
		end
		hs.printf("rip-library: unresolved placeholder %%%%%s%%%%", key)
		return ""
	end))
end

--- Encode a value for embedding inside an HTML <script> element.
---
--- (session-dialog, verbatim — see that file's json_for_script for the full
--- rationale.) hs.json.encode escapes '/' but not '<', and WebKit's HTML
--- tokenizer gives '<!--' and '<script' meaning inside script data that can
--- silently swallow the element's real closing tag. Escaping every '<' as
--- < is the standard, complete guard — JS parses it back to '<', so no
--- displayed text changes. A book title or author name is just as
--- attacker-adjacent as a clipboard entry or a disc volume name.
local function json_for_script(value)
	return (hs.json.encode(value):gsub("<", "\\u003C"))
end

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

-- Unique id this panel registers itself under with the shared
-- dismiss-on-blur module (see modules/system/dismiss-on-blur.lua).
local DISMISS_ON_BLUR_ID = "rip-library"

local PANEL_W, PANEL_H = 640, 620

local webview
local ucc
local savedWindow -- the app window focused before the panel opened
local isShown = false
local callbacks = {} -- { onStart = fun(plan), onImport = fun(spec), onDismiss = fun() }
local closed = true -- guards onDismiss against firing twice

--------------------------------------------------------------------------------
-- Payload normalization
--------------------------------------------------------------------------------

-- Shape whatever the caller passed into exactly the three keys the client
-- reads, with no nils (an absent key would simply vanish from the JSON and
-- leave the client reading undefined).
--
-- Same asymmetry rip-session.html documents at length: hs.json.encode
-- cannot distinguish an empty Lua LIST from an empty Lua MAP and emits "{}"
-- for both, so `rows = {}` reaches JS as an object, not an array — that is
-- why rip-library.html reads it through its own arr() guard rather than
-- trusting it bare.
local function library_payload(data)
	data = data or {}
	return {
		rows = data.rows or {},
		loading = data.loading and true or false,
		provider = data.provider or "libation",
	}
end

--------------------------------------------------------------------------------
-- Webview lifecycle (session-dialog)
--------------------------------------------------------------------------------

local function build_html(data)
	ensure_templates()
	return substitute(htmlTemplateRaw, {
		CSS = cssTemplateRaw,
		LIBRARY_JSON = json_for_script(library_payload(data)),
	})
end

-- Close the panel. `fireDismiss` is false for the Start path: starting a rip
-- is not a dismissal, and onDismiss must not fire alongside onStart.
local function close_panel(fireDismiss)
	-- (session-dialog) Only reclaim focus for savedWindow if OUR OWN window
	-- still has it right now AND we are not being dismissed because Cmd+Tab
	-- was pressed. Two distinct reasons to skip it: something else already
	-- took key-window status (stealing it back would yank it away from
	-- whatever the user just switched to), or the OS switcher is engaging
	-- and is about to own the entire focus transition itself once Cmd is
	-- released.
	local hsWin = webview and webview:hswindow()
	local currentlyFocused = hs.window.focusedWindow()
	local weStillHadFocus = hsWin ~= nil and currentlyFocused ~= nil and currentlyFocused:id() == hsWin:id()

	if webview then
		webview:hide()
	end
	isShown = false

	if savedWindow and weStillHadFocus and not dismissOnBlur.dismissingViaSwitcher then
		savedWindow:focus()
	end
	savedWindow = nil

	local alreadyClosed = closed
	closed = true
	if fireDismiss and not alreadyClosed and callbacks.onDismiss then
		callbacks.onDismiss()
	end
end

local function handle_message(body)
	if type(body) ~= "table" or not body.action then
		return
	end
	local action = body.action

	if action == "start" then
		local plan = { provider = body.provider, items = body.items }
		close_panel(false)
		if callbacks.onStart then
			callbacks.onStart(plan)
		end
	elseif action == "import" then
		local spec = { src = body.src, author = body.author, title = body.title }
		if callbacks.onImport then
			callbacks.onImport(spec)
		end
	elseif action == "dismiss" then
		close_panel(true)
	end
end

-- (session-dialog) Centred frame on the screen the user is actually working
-- on: the screen holding the focused app's window, falling back to the main
-- screen. Recomputed on EVERY show(), never baked in at creation.
local function panel_frame(win)
	win = win or hs.window.focusedWindow()
	local screen = (win and win:screen()) or hs.screen.mainScreen()
	local sf = screen:fullFrame()
	return {
		x = sf.x + (sf.w - PANEL_W) / 2,
		y = sf.y + (sf.h - PANEL_H) / 2,
		w = PANEL_W,
		h = PANEL_H,
	}
end

local function ensure_webview()
	if webview then
		return
	end
	ucc = hs.webview.usercontent.new("ripLibrary")
	ucc:setCallback(function(msg)
		handle_message(msg.body)
	end)

	-- (session-dialog) javaScriptEnabled is declared EXPLICITLY rather than
	-- left to the default — see session-dialog.lua's ensure_webview for the
	-- machine that was found silently serving a page with content
	-- JavaScript disabled while evaluateJavaScript still worked. A hard
	-- requirement belongs in the request, not in an assumption about the
	-- default.
	webview = hs.webview.new(panel_frame(), { javaScriptEnabled = true }, ucc)
	webview:transparent(true)
	webview:windowStyle({ "borderless" })
	-- modalPanel: this panel must become a real, focused key window so the
	-- search field can accept keyboard input.
	webview:level(hs.drawing.windowLevels.modalPanel)
	webview:allowTextEntry(true)
	webview:shadow(true)
	webview:deleteOnClose(false)
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

--- Open the panel on `data`, or — if it is already open — re-render it in
--- place with the FULL fresh payload. Re-rendering goes through the
--- injected window.__setLibrary (not window.__setRows, and not a full HTML
--- rebuild): rebuilding would drop the key window, flicker, and throw away
--- any in-flight search text; __setRows alone would forward `rows` but drop
--- `loading`/`provider` — it unconditionally ends the loading state, so a
--- caller re-showing with `loading = true` (Task 4's refresh path) would
--- otherwise see "nothing to show" instead of the loading state. Same
--- reasoning as rip-session.html's window.__setSession, which is also a
--- full reset for the scanning -> titles transition.
--- @param data table { rows = <array>, loading = <bool>, provider = "libation" }
--- @param cbs table|nil { onStart = fun(plan), onImport = fun(spec), onDismiss = fun() }
function M.show(data, cbs)
	if cbs then
		callbacks = cbs
	end

	local payload = library_payload(data)

	if isShown and webview then
		webview:evaluateJavaScript("window.__setLibrary && window.__setLibrary(" .. json_for_script(payload) .. ")")
		return
	end

	-- Mutual exclusion between our own managed panels (WhichKey, the
	-- clipboard picker, the rip-session panel) — see dismiss-on-blur.lua's
	-- dismissOthers.
	dismissOnBlur.dismissOthers(DISMISS_ON_BLUR_ID)
	ensure_webview()
	savedWindow = hs.window.focusedWindow()
	webview:frame(panel_frame(savedWindow))
	webview:html(build_html(data))
	webview:show()
	webview:bringToFront(true)
	-- (session-dialog) Hammerspoon is a background/accessory app: showing a
	-- window does NOT by itself make it the key window, so keyboard input
	-- goes nowhere until the user manually clicks it.
	local hsWin = webview:hswindow()
	if hsWin then
		hsWin:focus()
	end
	isShown = true
	closed = false

	-- DELIBERATE divergence from the clipboard picker, same as
	-- rip-session: this panel does NOT arm dismiss-on-blur. It is a review
	-- surface the operator may sit in for minutes queuing several books
	-- while macOS itself steals focus; it closes only on Esc / Not now /
	-- Start. dismissOthers above still runs so OPENING this panel closes
	-- the transient panels; they cannot close it back (dismissOthers only
	-- reaches armed ids).
end

--- Deliver fresh rows ADDITIVELY, without disturbing anything else the
--- operator is mid-way through (search text, the show-library chip, the
--- selection set). This is the ONLY way a "still loading" panel is ever
--- populated — see rip-library.html's window.__setRows, which also ends the
--- loading state the moment rows arrive.
--- @param rows table[]
function M.setRows(rows)
	if not webview or not isShown then
		return
	end
	if type(rows) ~= "table" then
		return
	end
	webview:evaluateJavaScript("window.__setRows && window.__setRows(" .. json_for_script(rows) .. ")")
end

--- Tell the panel which titles the server already holds, so the client can
--- hide them (or, once the "show library" chip is on, dim them). A later
--- task is what actually calls this with real data; the setter and its JS
--- entry point (window.__setServerLibrary) belong here regardless.
--- @param paths string[] "<Author>/<Title>" strings cantina already holds
function M.setServerLibrary(paths)
	if not webview or not isShown then
		return
	end
	if type(paths) ~= "table" then
		return
	end
	webview:evaluateJavaScript(
		"window.__setServerLibrary && window.__setServerLibrary(" .. json_for_script(paths) .. ")"
	)
end

--- Dismiss the panel. Fires callbacks.onDismiss exactly once per open.
function M.hide()
	close_panel(true)
end

--- Delete the webview outright (lifecycle teardown, before an hs.reload).
function M.cleanup()
	if webview then
		webview:delete()
		webview = nil
	end
	ucc = nil
	isShown = false
	closed = true
	callbacks = {}
end

--- @return boolean true while the panel is up
function M.isShown()
	return isShown
end

-- Test/inspection helpers (not used in production paths).
M._library_payload = library_payload
M._json_for_script = json_for_script

return M
