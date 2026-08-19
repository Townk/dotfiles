-- ripper — watch ~/Depot/Rips, turn finished rips into pipeline jobs.
-- Spec: docs/superpowers/specs/2026-08-19-rip-push-design.md (rev 4).
--
-- Thin by design (all real behavior lives in rip.zsh):
--   * intermediate/*.mkv: MakeMKV writes progressively, so a new file must
--     hold its size for STABLE_SECS before we prompt "Title (Year)?" and
--     enqueue rip-pipeline. Declined files are remembered by (path, size)
--     and never re-prompted until they change — no dialog loops.
--   * music/: XLD writes an album over minutes; any event just re-arms a
--     quiet-period timer that fires `rip-push music` (incremental and
--     skip-if-empty, so late or duplicate fires are harmless).

local M = {}

local HOME = os.getenv("HOME")
local ROOT = HOME .. "/Depot/Rips"
local INTERMEDIATE = ROOT .. "/intermediate"
local MUSIC = ROOT .. "/music"
local RIP_PIPELINE = HOME .. "/.local/bin/rip-pipeline"
local RIP_PUSH = HOME .. "/.local/bin/rip-push"
local STABLE_SECS = 30
local MUSIC_QUIET_SECS = 60

local log = hs.logger.new("ripper", "info")
local declined = {} -- path -> size at decline time
local pending = {} -- path -> stability timer object while one runs (anchors it against GC)
local musicTimer = nil
local tasks = {} -- id -> hs.task object while running (anchors it against GC)
local nextTaskId = 0

local function fileSize(p)
	local a = hs.fs.attributes(p)
	return a and a.size or nil
end

local function enqueue(bin, args, what)
	nextTaskId = nextTaskId + 1
	local id = nextTaskId
	local t = hs.task.new(bin, function(rc, _, stderr)
		tasks[id] = nil
		if rc ~= 0 then
			log.ef("%s enqueue failed rc=%d: %s", what, rc, stderr or "")
		end
	end, args)
	tasks[id] = t
	t:start()
end

local function promptFor(path)
	local stem = path:match("([^/]+)%.mkv$") or "Title (Year)"
	local btn, title = hs.dialog.textPrompt(
		"Rip detected",
		"Title (Year) for\n" .. path,
		stem,
		"Encode + push",
		"Not now"
	)
	if btn == "Encode + push" and title ~= "" and not title:find("/") then
		enqueue(RIP_PIPELINE, { path, title }, "rip-pipeline")
	else
		declined[path] = fileSize(path)
		log.f("declined: %s", path)
	end
end

local function considerMovie(path)
	if not path:match("%.mkv$") then
		return
	end
	local size = fileSize(path)
	if not size or size == 0 then
		return
	end
	if declined[path] == size then
		return
	end
	if pending[path] then
		return
	end
	pending[path] = hs.timer.doAfter(STABLE_SECS, function()
		pending[path] = nil
		local now = fileSize(path)
		if not now then
			return -- vanished (handled manually, or pipeline already took it)
		end
		if now ~= size then
			considerMovie(path) -- still growing: re-arm
		else
			promptFor(path)
		end
	end)
end

function M.start()
	for _, d in ipairs({ ROOT, INTERMEDIATE, MUSIC, ROOT .. "/movies" }) do
		hs.fs.mkdir(d)
	end
	M.movieWatcher = hs.pathwatcher.new(INTERMEDIATE, function(files)
		for _, f in ipairs(files) do
			considerMovie(f)
		end
	end):start()
	M.musicWatcher = hs.pathwatcher.new(MUSIC, function()
		if musicTimer then
			musicTimer:stop()
		end
		musicTimer = hs.timer.doAfter(MUSIC_QUIET_SECS, function()
			enqueue(RIP_PUSH, { "music" }, "rip-push")
		end)
	end):start()
	log.f("watching %s", ROOT)
	return M
end

return M
