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
---   library.setRows(rows, kind)         -- additive repaint; `kind` tags the source
---   library.setServerLibrary(paths)     -- the hide-filter set, fed by `rip-audiobook --server-library`
---   library.setServerEditions(list)     -- the edition-mark set, fed by `rip-audiobook --server-editions`
---   library.setSource(kind, root)       -- switch source ("library" | "folder"), enter loading
---   library.sourceFailed()              -- a switched-to source failed to load: undo setSource
---   library.hide()                      -- dismiss (fires callbacks.onDismiss once)
---   library.isShown()                   -- true while the panel is up
---   library.cleanup()                   -- delete the webview (register with lifecycle)
---
--- `data`:
---   { rows = { <row>, ... }, loading = false, provider = "libation",
---     source = { kind = "library" | "folder", root = "<path>" } }
---
--- `source` names WHICH library the rows came from. "library" is Libation's
--- Audible catalogue (the default, and the only source this panel had);
--- "folder" is a local tree the operator browsed to, listed by
--- rip-provider-folder. Files mode renders each row's author/title as
--- editable fields, because a folder row's identity is DERIVED rather than
--- catalogued — see rip-library.html's editHtml.
---
--- Row shape: the FULL provider row rides through unmodified end to end —
--- `ids` (e.g. `audible.asin`), `provider`, `provider_version`, `format`,
--- `language`, `abridged`, `acquired_utc`, and anything else a provider
--- ever adds all survive past this module into the plan `onStart` hands
--- back (a 2026-08-23 Critical: an earlier display-only whitelist here on
--- the CLIENT side silently dropped them, and the sidecar recorded a
--- false "provider: unknown" for every book queued through this panel —
--- do not reintroduce that shape). What rip-library.html's DOM actually
--- renders is this subset of the row:
---   { id, title, subtitle, authors, narrators, duration_s, series,
---     series_position, cover, acquired, path }
---
--- `callbacks`: { onStart = fun(plan), onImport = fun(spec), onBrowse = fun(),
---                onLibrary = fun(), onDismiss = fun() }
---   plan: { provider = "libation" | "folder", items = { <row>, ... } } --
---         the full rows for every id the operator marked Rip. `provider`
---         follows the SOURCE, not the payload: it is what rip::ab_worker
---         dispatches acquire on, so a browsed book always names `folder`.
---   spec: { src = "...", author = "...", title = "..." } -- a manual/DRM-free
---         import (rip-library.html's collapsed "Import a file you already
---         have" disclosure is that UI; this module only relays the spec).
---   onBrowse:  the "Browse…" chip. The caller owns the folder picker and
---         the fetch; this module never opens a dialog of its own.
---   onLibrary: the source bar's "Audible library" way back.

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
-- INLINE THE COVERS (live 2026-08-23, second attempt). The provider hands us
-- `file://` URLs into Libation's thumbnail cache, and WebKit will not load
-- them: a page built with webview:html() has no usable origin for file://
-- subresources, and giving it a file:// base URL in the cache directory did
-- NOT change that — hs.webview never sets the WebKit prefs
-- (allowFileAccessFromFileURLs / allowUniversalAccessFromFileURLs) that would.
-- Verified by trying it: every cover stayed blank, and the <img>'s onerror
-- swallowed the failure into the book glyph so nothing said why.
--
-- So the bytes travel with the page instead. At ~2.8 KB per 80x80 thumbnail
-- and 460 titles that is ~1.7 MB of base64 in the payload, which a local
-- webview carries without complaint — and unlike the obvious alternative
-- (rewriting each cover to its Amazon CDN URL) it needs no network, works
-- offline, and does not fire 460 requests at Amazon every time the panel
-- opens.
--
-- Anything that is not a readable file:// URL is passed through untouched:
-- the provider's own https fallback still works, and a missing cache file
-- just keeps the glyph it would have had anyway.
--
-- The folder provider (rip-provider-folder) emits `file://` covers too, and
-- for the same reason: a sibling image next to the .m4b. Those are the SAME
-- path through this function, deliberately — WebKit cannot load a local file
-- for either provider, and the fix is not per-provider.
--
-- The one thing a browsed cover adds is that it may be a PNG (the provider
-- globs jpg|jpeg|png), so the data URI's media type is chosen from the
-- extension rather than always claiming JPEG. This is not a change to the
-- inlining mechanism — the bytes still travel with the page — only an
-- honest label on them; JPEG stays the fallback, which is what every
-- Libation thumbnail already is.
local function inline_cover(url)
	if type(url) ~= "string" or url:sub(1, 7) ~= "file://" then
		return url
	end
	local path = url:sub(8):gsub("%%(%x%x)", function(hex)
		return string.char(tonumber(hex, 16))
	end)
	local fh = io.open(path, "rb")
	if not fh then
		return url
	end
	local bytes = fh:read("*a")
	fh:close()
	if not bytes or bytes == "" then
		return url
	end
	local mime = path:lower():match("%.png$") and "image/png" or "image/jpeg"
	return "data:" .. mime .. ";base64," .. hs.base64.encode(bytes)
end

-- Copy each row with its cover inlined. Copies rather than mutates: the
-- preview fixtures hand us tables they rebuild per call, and a caller's row
-- is not ours to rewrite.
local function with_inline_covers(rows)
	if type(rows) ~= "table" then
		return rows
	end
	local out = {}
	for i, r in ipairs(rows) do
		if type(r) == "table" then
			local copy = {}
			for k, v in pairs(r) do
				copy[k] = v
			end
			copy.cover = inline_cover(r.cover)
			out[i] = copy
		else
			out[i] = r
		end
	end
	return out
end

-- Shape a source descriptor with no nils, whatever the caller passed. An
-- absent/unknown kind is the Audible library: that is the panel's default
-- and the only mode with nothing to edit, so an unrecognised value must
-- never be the one that turns identity editing on.
local function source_payload(src)
	src = type(src) == "table" and src or {}
	local kind = src.kind == "folder" and "folder" or "library"
	local root = src.root
	return { kind = kind, root = type(root) == "string" and root or "" }
end

local function library_payload(data)
	data = data or {}
	return {
		rows = with_inline_covers(data.rows or {}),
		loading = data.loading and true or false,
		provider = data.provider or "libation",
		source = source_payload(data.source),
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
	elseif action == "browse" then
		-- The panel stays OPEN and unchanged here. The caller owns the
		-- folder picker, and the operator may cancel it — a panel that had
		-- already flipped itself into "scanning" would then have to be
		-- talked back out of a source it never got.
		if callbacks.onBrowse then
			callbacks.onBrowse()
		end
	elseif action == "library" then
		if callbacks.onLibrary then
			callbacks.onLibrary()
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
--- `kind` TAGS the delivery with the source that asked for it ("library" or
--- "folder"), and the client drops a payload whose kind is not the one on
--- screen. The two row fetches are separately anchored, so each one\'s own
--- identity guard only defends it against its OWN successor — nothing
--- otherwise stops a browse that was still walking a tree from landing its
--- rows in library mode after the operator switched back (and being posted
--- under the wrong provider). Omit it only from a caller with no source
--- opinion; an untagged delivery is always accepted.
--- @param rows table[]
--- @param kind string|nil "library" | "folder"
function M.setRows(rows, kind)
	if not webview or not isShown then
		return
	end
	if type(rows) ~= "table" then
		return
	end
	-- Same cover inlining as library_payload: this is the path the real
	-- provider fetch lands on, so it is the one that matters most.
	-- The tag is appended as a SECOND argument only when there is one; an
	-- omitted argument is exactly what the client reads as "untagged".
	--
	-- Written as a LITERAL, never through json_for_script: hs.json.encode
	-- requires a table (LS_TTABLE) and RAISES on a bare string, which would
	-- abort this task callback before evaluateJavaScript ever ran — the
	-- panel would then sit on "loading library…" forever, since only a row
	-- delivery clears LOADING. That is exactly the regression 1845a71b was
	-- landed to fix, and every other json_for_script call site in this repo
	-- passes a table. The whitelist below is what makes the literal safe:
	-- nothing but these two words can ever reach the page.
	local tag = ""
	if kind == "library" or kind == "folder" then
		tag = ', "' .. kind .. '"'
	end
	webview:evaluateJavaScript(
		"window.__setRows && window.__setRows(" .. json_for_script(with_inline_covers(rows)) .. tag .. ")"
	)
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

--- Tell the panel which stored books carry a `published` date, so the client
--- can mark a row when the server already holds the same work under a
--- different edition. Same tri-state discipline as setServerLibrary: an
--- absent or failed fetch simply never calls this, and the panel's
--- SERVER_EDITIONS_KNOWN flag (rip-library.html) stays false rather than
--- guessing.
--- @param list table[] { author, title, published, path } rows, JSON-lines
--- from `rip-audiobook --server-editions`
function M.setServerEditions(list)
	if not webview or not isShown then
		return
	end
	if type(list) ~= "table" then
		return
	end
	webview:evaluateJavaScript(
		"window.__setServerEditions && window.__setServerEditions(" .. json_for_script(list) .. ")"
	)
end

--- Switch the panel to a different source and put it into the loading state
--- for the fetch that is about to land.
---
--- The client CLEARS its rows and selection here (they belong to the source
--- being left) but stashes them, so sourceFailed() below can put the whole
--- switch back. Not folded into setRows: the source has to be on screen
--- while the scan runs, which is exactly when there are no rows to carry it.
--- @param kind string "library" (Libation's Audible catalogue) or "folder"
--- @param root string|nil the browsed root, for kind == "folder"
function M.setSource(kind, root)
	if not webview or not isShown then
		return
	end
	webview:evaluateJavaScript(
		"window.__setSource && window.__setSource(" .. json_for_script(source_payload({ kind = kind, root = root })) .. ")"
	)
end

--- Undo the last setSource because the fetch it was waiting on failed.
---
--- Deliberately NOT setRows({}): the fetch produced nothing, which is not
--- the same as "the library is empty". Replacing a good list of rows with
--- "nothing to show" would cost the operator the library they were already
--- working through, on top of the load they did not get. This restores what
--- setSource displaced — rows, selection and source — and ends the loading
--- state, which nothing else would, since only a row delivery ever clears it.
---
--- Symmetric on purpose: the way BACK to the Audible library loses just as
--- much as a browse does (400 browsed books and 40 marks, against one
--- mid-update LibationCli). With no switch pending it degrades to exactly
--- what setRows({}) did, so it is also the right failure call for a cold
--- open.
function M.sourceFailed()
	if not webview or not isShown then
		return
	end
	webview:evaluateJavaScript("window.__sourceFailed && window.__sourceFailed()")
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
