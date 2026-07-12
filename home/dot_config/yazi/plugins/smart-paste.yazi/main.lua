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

-- local_host() -- this machine's hostname, via the SAME convention pbpaste
-- itself uses for the manifest-host comparison (`scutil --get
-- LocalHostName`, falling back to `hostname -s`) so the remote/local
-- decision below agrees with the shim it's driving. Not memoized at module
-- scope -- callers that need it more than once per `entry()` invocation
-- compute it once locally and reuse the value (see `is_remote_manifest`'s
-- callers in `resolve`), matching the brief's "cached once per invocation"
-- (a fresh yazi Lua state per keypress isn't guaranteed either way, so
-- module-level memoization would be a stale-cache risk for no real gain --
-- one `scutil` call per `p` keypress is not a meaningful cost).
local function local_host()
	local out = Command("scutil"):arg({ "--get", "LocalHostName" }):output()
	if out and out.status.success then
		local h = out.stdout:gsub("%s+$", "")
		if h ~= "" then
			return h
		end
	end
	out = Command("hostname"):arg({ "-s" }):output()
	if out and out.status.success then
		return (out.stdout:gsub("%s+$", ""))
	end
	return ""
end

-- is_remote_manifest(m) -- true iff the manifest's files live on a DIFFERENT
-- machine than this one. An empty m.host is treated as LOCAL, explicitly --
-- not merely by falling through an unevaluated comparison -- mirroring the
-- same fix in pbpaste's own MANIFEST_HOST check (a row predating
-- source_host tracking, or a same-host synthetic x-resolved-path row,
-- carries no host at all and certainly didn't cross a bridge from another
-- machine).
local function is_remote_manifest(m)
	return m.host ~= "" and m.host ~= local_host()
end

-- basename(path) -- last path component, for naming the in-flight item in a
-- progress toast ("Pasting notes.txt… 42%" reads better than the full
-- manifest path).
local function basename(path)
	return path:match("([^/]+)/?$") or path
end

-- human_size(bytes) -- compact size for the completion notify. Mirrors the
-- tiers of pbpaste's own pbpaste_files_human, but doesn't need to match it
-- byte-for-byte: this only feeds a toast, never the porcelain contract.
local function human_size(bytes)
	if bytes >= 1073741824 then
		return string.format("%.1fG", bytes / 1073741824)
	elseif bytes >= 1048576 then
		return string.format("%.1fM", bytes / 1048576)
	elseif bytes >= 1024 then
		return string.format("%.1fK", bytes / 1024)
	end
	return bytes .. "B"
end

-- split_tabs(line) -- tab-separated fields of one porcelain line. Trailing
-- match against an appended tab keeps a lone trailing field from being
-- dropped; extra trailing fields (a future porcelain column -- the contract
-- may only GROW columns, never reshape existing ones) are simply ignored by
-- callers that only read fields[1..N], so this plugin stays forward
-- compatible without knowing about them.
local function split_tabs(line)
	local fields = {}
	for f in (line .. "\t"):gmatch("([^\t]*)\t") do
		fields[#fields + 1] = f
	end
	return fields
end

-- parse_porcelain_line(line) -- `pbpaste --files --porcelain`'s two line
-- shapes (design §8): `progress\t<path>\t<done>\t<total>` per update, and a
-- terminal `done\t<files>\t<bytes>\t<seconds>`. Returns nil for anything
-- that doesn't match either shape (a malformed/truncated line should never
-- explode the read loop -- just gets silently skipped, same "defensive nil"
-- posture as this file's own manifest() parser).
local function parse_porcelain_line(line)
	local fields = split_tabs(line)
	local kind = fields[1]
	if kind == "progress" and fields[2] and fields[3] and fields[4] then
		return {
			kind = "progress",
			path = fields[2],
			done = tonumber(fields[3]),
			total = tonumber(fields[4]),
		}
	elseif kind == "done" and fields[2] and fields[3] and fields[4] then
		return {
			kind = "done",
			files = tonumber(fields[2]),
			bytes = tonumber(fields[3]),
			seconds = tonumber(fields[4]),
		}
	end
	return nil
end

-- paste_system_remote(force) -- R1 rework of the remote branch (design §8,
-- as originally written, deferred a background-pull option; a live
-- validation session found the ORIGINAL implementation -- a blocking
-- foreground `shell --block` -- pulled yazi off its alternate screen for the
-- whole transfer, so a FAST paste read as a blank-screen crash). Bytes cross
-- machines via the bridge's F/A streams, which can take a while, so this
-- streams `pbpaste --files --porcelain` INCREMENTALLY off a background
-- `Command` -- `Command:spawn()` + `Child:read_line()` in a loop, verified
-- against yazi 26.5.6's types.yazi package (`Child:read_line` -> `string?,
-- integer`, event 0 = stdout line, 1 = stderr line, 2 = EOF on both) and
-- against ouch.yazi's own `spawn()`/`read_line()` preview loop, which uses
-- exactly this pattern to stream a running child's output. `Command:output()`
-- / `Child:wait_with_output()` both wait for the child to exit and would
-- forfeit live progress entirely, so neither is an option here. Progress
-- surfaces via throttled `ya.notify` updates -- one per completed item, or
-- every ~10% of a large in-flight item -- never per 64 KiB tick (the shim's
-- own internal cadence; a toast per tick would spam the screen far worse
-- than the blank flash this replaces). Percent is clamped at 100: an `A`
-- (directory) total is only a `du` estimate, so an in-flight item's `done`
-- can transiently exceed `total`. `touch_last_paste` runs after this
-- returns, same "regardless of outcome" rule as the local branch below.
local function paste_system_remote(force)
	local args = { "--files", "--porcelain" }
	if force then
		args[#args + 1] = "--force"
	end
	local child, spawn_err = Command("pbpaste"):arg(args):stdout(Command.PIPED):stderr(Command.PIPED):spawn()
	if not child then
		ya.notify({
			title = "Clipboard",
			content = "Paste failed: " .. tostring(spawn_err or "could not start pbpaste --files"),
			timeout = 5,
			level = "error",
		})
		return
	end

	local stderr_lines = {}
	local cur_path, cur_pct = nil, -1
	local summary -- {kind="done", files, bytes, seconds}, set by the terminal line

	while true do
		local line, event = child:read_line()
		if event == 2 then -- EOF on both stdout and stderr: nothing left to read
			break
		elseif event == 1 then -- stderr line: captured for the failure notify only
			if line and line ~= "" then
				stderr_lines[#stderr_lines + 1] = line
			end
		elseif event == 0 and line then -- stdout: the porcelain contract
			local parsed = parse_porcelain_line(line)
			if parsed and parsed.kind == "progress" then
				if parsed.path ~= cur_path then
					cur_path, cur_pct = parsed.path, -1 -- new item: reset the throttle
				end
				local pct = 0
				if parsed.total > 0 then
					pct = math.floor(parsed.done * 100 / parsed.total)
					if pct > 100 then
						pct = 100
					end
				end
				local item_done = parsed.total > 0 and parsed.done >= parsed.total
				if item_done or pct - cur_pct >= 10 then
					ya.notify({
						title = "Clipboard",
						content = string.format("Pasting %s… %d%%", basename(parsed.path), pct),
						timeout = 2,
					})
					cur_pct = pct
				end
			elseif parsed and parsed.kind == "done" then
				summary = parsed
			end
		end
	end

	local status = child:wait()
	if status and status.success and summary then
		ya.notify({
			title = "Clipboard",
			content = string.format(
				"Pasted %d file(s), %s in %ds",
				summary.files,
				human_size(summary.bytes),
				summary.seconds
			),
			timeout = 3,
		})
	else
		local reason = (#stderr_lines > 0 and table.concat(stderr_lines, "\n"))
			or "pbpaste --files --porcelain failed to run"
		ya.notify({
			title = "Clipboard",
			content = "Paste failed: " .. reason,
			timeout = 5,
			level = "error",
		})
	end
end

-- paste_system(force, remote) -- the system-clipboard branch: materializes
-- the current file clip into cwd via `pbpaste --files`. Both branches now
-- run as a background `Command` (R1: the remote branch no longer leaves
-- yazi's alternate screen -- see paste_system_remote above).
--   Local manifest (remote == false, unchanged from M1/T8): local clone
--   tiers are instant, so a single ya.notify on completion/failure is
--   enough -- no porcelain stream needed.
--   Remote manifest (remote == true): see paste_system_remote.
local function paste_system(force, remote)
	if remote then
		paste_system_remote(force)
		touch_last_paste()
		return
	end

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
			return paste_system(force, is_remote_manifest(m))
		end
		return native_paste(force)
	end
	if m.ts > mtime(d .. "/last-yank") then -- rule 5
		return paste_system(force, is_remote_manifest(m))
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
