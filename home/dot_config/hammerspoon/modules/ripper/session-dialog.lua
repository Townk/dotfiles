--- ripper/session-dialog.lua — the "Rip Session Review" panel.
---
--- A full hs.webview + HTML/CSS/JS UI (Assets/html/rip-session.{html,css})
--- replacing the ripper's hs.chooser naming step: a disc is not one name, it
--- is a FEATURE plus a handful of EXTRAS plus the titles worth skipping, and
--- an hs.chooser can express exactly one of those. Every row carries its own
--- role control, the feature row carries a TMDB typeahead, and each extra
--- carries a name field and an attach-to chip.
---
--- Architecture is lifted wholesale from apps/clipboard-picker.lua — the
--- house precedent for an interactive webview panel. Everything below marked
--- "(picker)" is inherited from it deliberately, not reinvented: template
--- loading + %%KEY%% substitution, json_for_script's <-escaping, the
--- explicit javaScriptEnabled flag, the focus dance, and dismiss-on-blur's
--- arm/disarm/dismissOthers with hide()'s two focus guards.
---
--- API:
---   local session = require("ripper.session-dialog")
---   session.show(data, callbacks)  -- open, or re-render in place if already open
---   session.hide()                 -- dismiss (fires callbacks.onDismiss once)
---   session.cleanup()              -- delete the webview (register with lifecycle)
---
--- `data`:
---   { volume = "U2_360_ROSE_BOWL", kind = "DVD", scanning = false,
---     titles = { { no = 0, duration = "1:58:12", seconds = 7092,
---                  size = "6.9 GB", inLibrary = nil|"Movie (Year)" }, ... },
---     library = { { title = "Movie", year = 1970 }, ... } }
---
--- `callbacks`: { onStart = fun(plan), onDismiss = fun() }; `plan`:
---   { feature = { no = 0, movie = "Movie (Year)" } | nil,
---     extras = { { no = 1, name = "…", attachTo = "Movie (Year)" }, ... },
---     skipped = { 3 } }
---
--- NOTE (Mode B): this module only produces a plan. Nothing here touches the
--- disc, pueue, makemkvcon or rip.zsh — wiring the plan into the pipeline is
--- a separate task.

local M = {}

local dismissOnBlur = require("system.dismiss-on-blur")

local ASSETS_DIR = hs.configdir .. "/Assets/html"
local RIP_TMDB = (os.getenv("HOME") or "") .. "/.local/bin/rip-tmdb-search"

--------------------------------------------------------------------------------
-- Template loading (picker: ensure_templates/substitute)
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
		cssTemplateRaw = read_file(ASSETS_DIR .. "/rip-session.css")
		assert(cssTemplateRaw, "rip-session: CSS template not found")
	end
	if not htmlTemplateRaw then
		htmlTemplateRaw = read_file(ASSETS_DIR .. "/rip-session.html")
		assert(htmlTemplateRaw, "rip-session: HTML template not found")
	end
end

-- Substitute %%KEY%% placeholders. Function-based gsub replacement values are
-- inserted verbatim (not re-interpreted as %n capture references), so no
-- extra escaping is needed here — same technique as keybindings/template.lua
-- and clipboard-picker.lua.
local function substitute(tmpl, subs)
	return (tmpl:gsub("%%%%([%w_]+)%%%%", function(key)
		local val = subs[key]
		if val ~= nil then
			return tostring(val)
		end
		hs.printf("rip-session: unresolved placeholder %%%%%s%%%%", key)
		return ""
	end))
end

--- Encode a value for embedding inside an HTML <script> element.
---
--- (picker, verbatim — this rationale is why the rule is non-negotiable.)
--- Producing JSON is not the same as embedding it in HTML. hs.json.encode
--- escapes '/' as '\/', so a value containing "</script>" cannot close the
--- element -- that much is true. But it does NOT escape '<', and the HTML
--- tokenizer gives two other sequences meaning inside script data: '<!--'
--- switches to the escaped state and '<script' to the double-escaped state.
--- Past either one, the element's real '</script>' is consumed as ordinary
--- text rather than closing it, the script element is never terminated, and
--- WebKit never executes it -- with no error event, no console line,
--- nothing. The page then renders its static chrome and stops (observed in
--- the wild on the clipboard picker; reproduced from a bare document).
---
--- Escaping every '<' as < is the standard, complete guard. JS parses
--- the escape back to '<', so no displayed text changes. A disc volume name,
--- a TMDB overview, or a library title is every bit as attacker-adjacent as
--- a clipboard entry — this is not a picker-only concern.
local function json_for_script(value)
	return (hs.json.encode(value):gsub("<", "\\u003C"))
end

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

-- Unique id this panel registers itself under with the shared
-- dismiss-on-blur module (see modules/system/dismiss-on-blur.lua).
local DISMISS_ON_BLUR_ID = "rip-session"

local PANEL_W, PANEL_H = 560, 600

local webview
local ucc
local savedWindow -- the app window focused before the panel opened
local isShown = false
local callbacks = {} -- { onStart = fun(plan), onDismiss = fun() }
local closed = true -- guards onDismiss against firing twice
local searchTask -- in-flight rip-tmdb-search hs.task (anchors it against GC)

--------------------------------------------------------------------------------
-- Payload normalization
--------------------------------------------------------------------------------

-- Shape whatever the caller passed into exactly the five keys the client
-- reads, with no nils (an absent key would simply vanish from the JSON and
-- leave the client reading undefined).
--
-- One asymmetry worth naming rather than papering over: hs.json.encode has
-- no way to distinguish an empty Lua LIST from an empty Lua MAP, and emits
-- "{}" for both — so `titles = {}` reaches JS as an object, not an array.
-- That is why every list the client receives (titles, library, and the
-- search results below) is read through its own Array.isArray guard
-- (rip-session.html's arr()); there is no producer-side fix available.
local function session_payload(data)
	data = data or {}
	return {
		volume = data.volume or "",
		kind = data.kind or "",
		scanning = data.scanning and true or false,
		titles = data.titles or {},
		library = data.library or {},
	}
end

-- Coerce a title number that has round-tripped through the JS bridge back to
-- a Lua integer. Load-bearing, and a hard-won lesson from the clipboard
-- picker (see its clip_id_int): every JS number is a double, so a title
-- number born as 0/1/2 in Lua comes BACK from webkit.messageHandlers as a
-- float — math.type == "float", tostring == "1.0". Numeric comparisons
-- shrug that off, but the moment the integration step stringifies one for
-- makemkvcon's argv it becomes "--title 1.0" and the rip aborts. Fix it at
-- the boundary, once, rather than at every consumer.
local function title_no(v)
	local n = tonumber(v)
	return n and math.tointeger(n) or n
end

-- Rebuild the plan the client posted into a Lua-native shape: integer title
-- numbers, real sequential arrays, no nil holes.
local function normalize_plan(raw)
	if type(raw) ~= "table" then
		return { extras = {}, skipped = {} }
	end
	local plan = { extras = {}, skipped = {} }
	if type(raw.feature) == "table" and raw.feature.movie then
		plan.feature = { no = title_no(raw.feature.no), movie = tostring(raw.feature.movie) }
	end
	for _, e in ipairs(raw.extras or {}) do
		if type(e) == "table" and e.name then
			plan.extras[#plan.extras + 1] = {
				no = title_no(e.no),
				name = tostring(e.name),
				attachTo = e.attachTo and tostring(e.attachTo) or nil,
			}
		end
	end
	for _, n in ipairs(raw.skipped or {}) do
		plan.skipped[#plan.skipped + 1] = title_no(n)
	end
	return plan
end

--------------------------------------------------------------------------------
-- TMDB search
--------------------------------------------------------------------------------

-- One in-flight search at a time, anchored in a module-local against GC and
-- terminated when a newer query arrives. terminate() only sends SIGTERM: the
-- terminated task's own callback still fires later, asynchronously, so the
-- anchor is cleared through an identity check against `thisTask` rather than
-- a bare `searchTask = nil` — otherwise a late callback clobbers a NEWER
-- search's anchor. Same pattern (and same bug class) as ripper/init.lua's
-- tmdbChoices; `seq` carries the same guard all the way into the client, so
-- a slow reply can never paint over a newer query's results either.
--
-- Invoked in argv form (not `/bin/zsh -lc "…"`, the picker's shell-routed
-- form) for two reasons: rip-tmdb-search's own `#!/usr/bin/env zsh` shebang
-- makes zsh read ~/.zshenv, which sources ~/.config/zsh/environment.sh and
-- through it secrets.sh — so TMDB_API_KEY and the Homebrew PATH curl/jq need
-- are already assembled by the time the script's first line runs, with no
-- login shell involved; and argv form means the operator's free-text query
-- is never handed to a shell to parse. RIP_TMDB is an absolute path
-- (hs.task never PATH-searches, and Hammerspoon's own PATH is the bare
-- system one).
local function run_search(query, seq)
	if searchTask then
		searchTask:terminate()
		searchTask = nil
	end
	local thisTask
	thisTask = hs.task.new(RIP_TMDB, function(rc, stdout)
		if searchTask == thisTask then
			searchTask = nil
		end
		-- The panel may have been dismissed (or deleted) while this ran;
		-- never evaluateJavaScript into a gone webview.
		if not webview or not isShown then
			return
		end
		local results = {}
		if rc == 0 then
			for line in (stdout or ""):gmatch("[^\n]+") do
				local ok, obj = pcall(hs.json.decode, line)
				if ok and type(obj) == "table" and obj.title then
					results[#results + 1] = {
						title = obj.title, -- "Name (Year)" — what the plan carries
						name = obj.name or obj.title,
						year = obj.year or "",
						overview = obj.overview or "",
						poster = obj.poster or "",
					}
				end
			end
		end
		local payload = {
			seq = seq,
			results = results, -- empty encodes as "{}", see session_payload

			-- exit 3 is rip-tmdb-search's "no TMDB_API_KEY" code; the client
			-- says so in the dropdown instead of a bare "no matches".
			noKey = (rc == 3),
		}
		webview:evaluateJavaScript("window.__setResults && window.__setResults(" .. json_for_script(payload) .. ")")
	end, { query })
	searchTask = thisTask
	thisTask:start()
end

--------------------------------------------------------------------------------
-- Webview lifecycle (picker)
--------------------------------------------------------------------------------

local function build_html(data)
	ensure_templates()
	return substitute(htmlTemplateRaw, {
		CSS = cssTemplateRaw,
		SESSION_JSON = json_for_script(session_payload(data)),
	})
end

-- Close the panel. `fireDismiss` is false for the Start path: starting a rip
-- is not a dismissal, and onDismiss must not fire alongside onStart.
local function close_panel(fireDismiss)
	if searchTask then
		searchTask:terminate()
		searchTask = nil
	end

	-- (picker) Only reclaim focus for savedWindow if OUR OWN window still has
	-- it right now AND we are not being dismissed because Cmd+Tab was
	-- pressed. Two distinct reasons to skip it: something else already took
	-- key-window status (stealing it back would yank it away from whatever
	-- the user just switched to), or the OS switcher is engaging and is about
	-- to own the entire focus transition itself once Cmd is released.
	local hsWin = webview and webview:hswindow()
	local currentlyFocused = hs.window.focusedWindow()
	local weStillHadFocus = hsWin ~= nil and currentlyFocused ~= nil and currentlyFocused:id() == hsWin:id()

	if webview then
		webview:hide()
	end
	isShown = false
	dismissOnBlur.disarm(DISMISS_ON_BLUR_ID)

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

	if action == "search" then
		local q = body.q
		if type(q) == "string" and q ~= "" then
			run_search(q, body.seq)
		end
	elseif action == "start" then
		local plan = normalize_plan(body.plan)
		close_panel(false)
		if callbacks.onStart then
			callbacks.onStart(plan)
		end
	elseif action == "dismiss" then
		close_panel(true)
	end
end

-- (picker) Centred frame on the screen the user is actually working on:
-- the screen holding the focused app's window, falling back to the main
-- screen. Recomputed on EVERY show(), never baked in at creation — the
-- webview is built once and reused for the process's lifetime, so a display
-- connected/disconnected afterwards would otherwise keep centring the panel
-- on the arrangement that happened to be in place the first time.
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
	ucc = hs.webview.usercontent.new("ripSession")
	ucc:setCallback(function(msg)
		handle_message(msg.body)
	end)

	-- (picker) javaScriptEnabled is declared EXPLICITLY rather than left to
	-- the default. This page's entire behaviour lives in inline <script>, and
	-- a machine was found serving a page with content JavaScript refused
	-- while evaluateJavaScript still worked: the signature of WebKit's
	-- allowsContentJavaScript being NO (the modern replacement for this
	-- deprecated flag, which blocks the document's own scripts but not
	-- API-injected ones). The panel then draws its static chrome and nothing
	-- else, with no error anywhere Hammerspoon can see. A hard requirement
	-- belongs in the request, not in an assumption about the default.
	webview = hs.webview.new(panel_frame(), { javaScriptEnabled = true }, ucc)
	webview:transparent(true)
	webview:windowStyle({ "borderless" })
	-- modalPanel: this panel must become a real, focused key window so the
	-- TMDB field and the extras' name fields can accept keyboard input.
	webview:level(hs.drawing.windowLevels.modalPanel)
	webview:allowTextEntry(true)
	webview:shadow(true)
	webview:deleteOnClose(false)
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

--- Open the panel on `data`, or — if it is already open — re-render it in
--- place with fresh data (the scanning -> titles transition). Re-rendering
--- goes through an injected window.__setSession rather than rebuilding the
--- webview: rebuilding would drop the key window, flicker, and throw away
--- the operator's in-flight typing.
--- @param data table
--- @param cbs table|nil { onStart = fun(plan), onDismiss = fun() }
function M.show(data, cbs)
	if cbs then
		callbacks = cbs
	end

	if isShown and webview then
		webview:evaluateJavaScript(
			"window.__setSession && window.__setSession(" .. json_for_script(session_payload(data)) .. ")"
		)
		return
	end

	-- Mutual exclusion between our own managed panels (WhichKey, the
	-- clipboard picker) — see dismiss-on-blur.lua's dismissOthers.
	dismissOnBlur.dismissOthers(DISMISS_ON_BLUR_ID)
	ensure_webview()
	savedWindow = hs.window.focusedWindow()
	webview:frame(panel_frame(savedWindow))
	webview:html(build_html(data))
	webview:show()
	webview:bringToFront(true)
	-- (picker) Hammerspoon is a background/accessory app: showing a window
	-- does NOT by itself make it the key window or activate the app, so
	-- keyboard input goes nowhere until the user manually clicks it.
	-- hswindow():focus() is the same call hs.window uses to raise+activate a
	-- normal app window, and works on a webview's own window too.
	local hsWin = webview:hswindow()
	if hsWin then
		hsWin:focus()
	end
	isShown = true
	closed = false

	dismissOnBlur.arm(DISMISS_ON_BLUR_ID, function(win)
		local ourWin = webview and webview:hswindow()
		return win ~= nil and ourWin ~= nil and win:id() == ourWin:id()
	end, M.hide)
end

--- Dismiss the panel. Fires callbacks.onDismiss exactly once per open.
function M.hide()
	close_panel(true)
end

--- Delete the webview outright (lifecycle teardown, before an hs.reload).
function M.cleanup()
	if searchTask then
		searchTask:terminate()
		searchTask = nil
	end
	if webview then
		webview:delete()
		webview = nil
	end
	ucc = nil
	dismissOnBlur.disarm(DISMISS_ON_BLUR_ID)
	isShown = false
	closed = true
	callbacks = {}
end

--- @return boolean true while the panel is up
function M.isShown()
	return isShown
end

-- Test/inspection helpers (not used in production paths).
M._normalize_plan = normalize_plan
M._session_payload = session_payload
M._json_for_script = json_for_script

return M
