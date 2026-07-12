-- smart-paste.yazi — universal clipboard Phase 6, spec §6 resolution table
-- (docs/superpowers/specs/2026-07-11-clipboard-phase6-files-yazi-design.md).
-- Zero new keybindings: `p`/`P` decide between yazi's own native paste and
-- `pbpaste --files` (the system/Finder clipboard), based on whether the
-- current system-clipboard entry is a files clip and how it relates to
-- yazi's own internal yank list (`cx.yanked`).
--
-- Runs async by default (no `@sync entry` annotation), matching the plugin
-- API's async-first default; `Command:output()` and friends are only legal
-- in that context. `cx` itself is only reachable through `ya.sync` blocks
-- (see `get_yanked` below), same pattern as backnav.yazi / nice-sidebar.yazi.

local function state_dir()
	local s = os.getenv("XDG_STATE_HOME") or (os.getenv("HOME") .. "/.local/state")
	return s .. "/yazi"
end

-- Reduce cx.yanked to plain absolute paths for rule-3 comparison. `Url.path`
-- is a `Path` object whose own __tostring drops any scheme; tostring(Url)
-- itself would keep a scheme prefix for anything non-regular (e.g.
-- sftp://host//path), which would never match a local manifest path anyway.
local get_yanked = ya.sync(function()
	local urls, is_cut = {}, cx.yanked.is_cut
	for _, u in pairs(cx.yanked) do
		urls[#urls + 1] = tostring(u.path)
	end
	return urls, is_cut
end)

-- mtime <path> -- epoch seconds, or 0 if the marker doesn't exist / stat
-- fails (matches the brief's "missing marker = 0" rule).
local function mtime(path)
	local out = Command("stat"):arg({ "-f", "%m", path }):output()
	if out and out.status.success then
		return tonumber(out.stdout) or 0
	end
	return 0
end

-- manifest() -- parses `pbpaste --manifest`'s four-line format (kind/host/ts/
-- path*, tab-separated). Returns nil on ANY failure: the shim itself exits 1
-- for both rule 1 (bridge down) and rule 2 (current clip isn't a files
-- clip) -- collapsing both into a single "no manifest" signal is correct,
-- both resolve to native paste. Also nil if the output doesn't parse into a
-- `kind` line at all (defensive: malformed/truncated stdout).
local function manifest()
	local out = Command("pbpaste"):arg({ "--manifest" }):output()
	if not out or not out.status.success then
		return nil
	end
	local m = { paths = {} }
	for line in out.stdout:gmatch("[^\n]+") do
		local k, v = line:match("^(%a+)\t(.*)$")
		if k == "kind" then
			m.kind = v
		elseif k == "host" then
			m.host = v
		elseif k == "ts" then
			m.ts = tonumber(v)
		elseif k == "path" then
			m.paths[#m.paths + 1] = v
		end
	end
	if not m.kind or not m.ts then
		return nil
	end
	return m
end

-- same_set(a, b) -- unordered set equality over plain path strings.
local function same_set(a, b)
	if #a ~= #b then
		return false
	end
	local set = {}
	for _, p in ipairs(a) do
		set[p] = true
	end
	for _, p in ipairs(b) do
		if not set[p] then
			return false
		end
	end
	return true
end

-- touch_last_paste() -- stamps the rule-4 guard marker. Best-effort: a
-- failure here must not fail the paste itself (mirrors y/x's own mkdir/touch
-- shell, which is also best-effort).
local function touch_last_paste()
	local d = state_dir()
	Command("sh"):arg({ "-c", 'mkdir -p "$1" && touch "$1/last-paste"', "_", d }):output()
end

-- paste_system(force) -- the system-clipboard branch: materializes the
-- current file clip into cwd via `pbpaste --files`. Local manifest only
-- (this task's scope, spec §6/§8) -- run as a background Command: local
-- clone tiers are instant, so there is nothing to show beyond a single
-- ya.notify on completion or failure. The remote manifest's foreground
-- `shell --block` path (progress meter) is Task 13's.
local function paste_system(force)
	local args = { "--files" }
	if force then
		args[#args + 1] = "--force"
	end
	local out = Command("pbpaste"):arg(args):output()
	-- Stamp the guard regardless of outcome: a failed paste must not be
	-- silently retried by a reflexive second `p` once the underlying cause
	-- (e.g. a name conflict) is fixed by hand -- the marker only guards
	-- against re-pasting the SAME manifest instant, not against retries in
	-- general, and the spec's own rule 4 phrasing ("prevents a reflexive
	-- second `p`") only concerns the case that already succeeded.
	touch_last_paste()
	if out and out.status.success then
		ya.notify({ title = "Clipboard", content = "Pasted from system clipboard", timeout = 3 })
	else
		local reason = (out and out.stderr and out.stderr ~= "" and out.stderr) or "pbpaste --files failed to run"
		ya.notify({
			title = "Clipboard",
			content = "Paste failed: " .. reason,
			timeout = 5,
			level = "error",
		})
	end
end

local function native_paste(force)
	return ya.emit("paste", { force = force })
end

-- resolve(force) -- the spec §6 five-rule table, first match wins:
--   1. Manifest query fails (bridge down / no bridge)        -> native paste
--   2. Current clipboard entry is not a files clip            -> native paste
--      (1 and 2 both surface as `manifest()` returning nil -- the shim
--      itself can't distinguish them from its own exit code, and neither
--      needs to: both mean "nothing for smart-paste to do differently".)
--   3. Yank list non-empty AND set(yank) == set(manifest paths) -> native
--      paste (the clip is `y`'s own mirror; cut/move semantics survive
--      because yazi's own task engine runs)
--   4. Yank list empty AND manifest ts > last-paste marker      -> pbpaste
--      --files (the stale-guard: an unchanged/older manifest after a
--      completed system paste does NOT re-trigger)
--   5. Both present, different sets: newer of manifest ts vs last-yank
--      mtime wins -> native paste or pbpaste --files
local function resolve(force)
	local yanked, _is_cut = get_yanked()
	local m = manifest()
	if not m then -- rules 1 + 2
		return native_paste(force)
	end
	if #yanked > 0 and same_set(yanked, m.paths) then -- rule 3
		return native_paste(force)
	end
	local d = state_dir()
	if #yanked == 0 then -- rule 4 (+ stale guard)
		if m.ts > mtime(d .. "/last-paste") then
			return paste_system(force)
		end
		return native_paste(force)
	end
	if m.ts > mtime(d .. "/last-yank") then -- rule 5
		return paste_system(force)
	end
	return native_paste(force)
end

return {
	entry = function(_, job)
		local force = (job.args and job.args.force) or false
		-- Fallback safety: any unexpected error anywhere in resolution (a
		-- malformed manifest line, a Command that errors instead of merely
		-- failing, etc.) must still leave `p` doing yazi's ordinary paste --
		-- never a silent no-op. The specific, expected failure modes
		-- (manifest command failure, non-files clip) are already handled by
		-- plain nil-checks above; this is the last-resort net around
		-- anything not anticipated.
		local ok, err = pcall(resolve, force)
		if not ok then
			ya.notify({
				title = "Clipboard",
				content = "smart-paste: unexpected error, falling back to native paste (" .. tostring(err) .. ")",
				timeout = 5,
				level = "error",
			})
			return native_paste(force)
		end
	end,
}
