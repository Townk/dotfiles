-- ripper — watch ~/Depot/Rips, turn finished rips into pipeline jobs; also
-- watch for disc inserts and drive the hands-off rip-disc flow.
-- Spec: docs/superpowers/specs/2026-08-19-rip-ux-v2-design.md (builds on
-- 2026-08-19-rip-push-design.md, rev 5).
--
-- Thin by design (all real behavior lives in rip.zsh / the rip-* bins):
--   * intermediate/*.mkv: MakeMKV writes progressively, so a new file must
--     hold its size for STABLE_SECS before we prompt "Title (Year)?" and
--     enqueue rip-pipeline. Declined files are remembered by (path, size)
--     and never re-prompted until they change — no dialog loops. This is
--     the fallback path for a disc ripped by hand in the MakeMKV GUI.
--   * music/: XLD writes an album over minutes; any event just re-arms a
--     quiet-period timer that fires `rip-push music` (incremental and
--     skip-if-empty, so late or duplicate fires are harmless).
--   * hs.pathwatcher only fires on new filesystem events, so a rip that
--     finished while Hammerspoon was down (or reloading) would otherwise
--     sit unnoticed forever: M.start() sweeps both trees once at startup
--     to pick up whatever is already sitting there.
--   * .work/ is rip.zsh's scratch area (the in-progress encode, the push
--     stamps). It is deliberately unwatched and never pushed; startup
--     just clears whatever a killed job stranded there.
--   * Disc insert: an hs.fs.volume watcher classifies the new volume —
--     a VIDEO_TS/ dir means a DVD, an .aiff track means an audio CD
--     (opened in XLD, which owns the rest of that flow; nothing else here
--     touches audio discs). A DVD gets a blocking "Rip this disc?" alert;
--     "Not now" is remembered per volume path until it unmounts, so the
--     dialog never loops on a disc left sitting in the drive.
--   * Naming happens BEFORE the rip, not after: accepting the alert opens
--     an hs.chooser wired to `rip-tmdb-search` (300ms debounced per
--     keystroke, one in-flight hs.task at a time) so the operator picks
--     the exact TMDB title+year while the disc spins up. No TMDB key
--     configured degrades to the same plain hs.dialog.textPrompt the
--     manual MakeMKV-GUI path uses. Either way the result is one
--     `rip-disc "<Title (Year)>"` enqueue — the disc itself is never
--     touched by Lua; makemkvcon and the rest of the chain live in
--     rip.zsh.
--   * The volume watcher only sees mounts that happen after M.start()
--     runs, so a disc already sitting in the drive at launch/reload needs
--     a manual nudge: M.ripDisc() rescans /Volumes for a VIDEO_TS/ dir,
--     clears its declined flag, and re-runs the same consent flow.

local M = {}

local HOME = os.getenv("HOME")
local ROOT = HOME .. "/Depot/Rips"
local INTERMEDIATE = ROOT .. "/intermediate"
local MUSIC = ROOT .. "/music"
local WORK = ROOT .. "/.work"
local RIP_PIPELINE = HOME .. "/.local/bin/rip-pipeline"
local RIP_PUSH = HOME .. "/.local/bin/rip-push"
local RIP_DISC = HOME .. "/.local/bin/rip-disc"
local RIP_TMDB = HOME .. "/.local/bin/rip-tmdb-search"
local STABLE_SECS = 30
local MUSIC_QUIET_SECS = 60

local log = hs.logger.new("ripper", "info")
local declined = {} -- path -> size at decline time
local declinedVolumes = {} -- volume path -> true until unmount
local pending = {} -- path -> stability timer object while one runs (anchors it against GC)
local musicTimer = nil
local searchTask = nil -- in-flight rip-tmdb-search hs.task (anchors it, cancels the previous one)
local chooser = nil -- open TMDB hs.chooser (anchors it against GC while shown)
local chooserDebounce = nil -- debounce timer for the chooser's queryChangedCallback
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

local function armMusicTimer()
	if musicTimer then
		musicTimer:stop()
	end
	musicTimer = hs.timer.doAfter(MUSIC_QUIET_SECS, function()
		enqueue(RIP_PUSH, { "music" }, "rip-push")
	end)
end

-- hs.pathwatcher only sees events after it starts; sweep once at startup
-- so a rip that finished while Hammerspoon was down/reloading isn't
-- stranded. considerMovie already filters non-.mkv and zero-size entries,
-- and the stability timer handles a file still mid-write.
local function sweepIntermediate()
	local iter, dir = hs.fs.dir(INTERMEDIATE)
	if not iter then
		return
	end
	local found = 0
	for name in iter, dir do
		if name ~= "." and name ~= ".." then
			if name:match("%.mkv$") then
				found = found + 1
			end
			considerMovie(INTERMEDIATE .. "/" .. name)
		end
	end
	if found > 0 then
		log.f("sweep: %d existing .mkv file(s) in intermediate at startup", found)
	end
end

-- Same startup gap for music: any pre-existing content arms the same
-- quiet-period debounce an event would. rip-push music is skip-if-empty
-- and incremental, so a false-positive sweep is harmless.
local function sweepMusic()
	local iter, dir = hs.fs.dir(MUSIC)
	if not iter then
		return
	end
	for name in iter, dir do
		if name ~= "." and name ~= ".." then
			log.f("sweep: existing music content at startup, arming quiet-period timer")
			armMusicTimer()
			return
		end
	end
end

-- .work holds rip.zsh's in-progress encode and each push's start-of-transfer
-- stamp; nothing in there is meant to outlive the job that wrote it. A
-- cancelled encode is SIGKILLed (that is what `pueue kill` sends), so the
-- worker gets no chance to tidy up and its half-written temp sits there until
-- some later rip happens to overwrite it. Clearing it at startup means a
-- reload is enough. Sweeping under a push that is somehow still running is
-- safe: rip.zsh treats a missing stamp as "keep everything local".
local function sweepWork()
	local iter, dir = hs.fs.dir(WORK)
	if not iter then
		return
	end
	local swept = 0
	for name in iter, dir do
		if name ~= "." and name ~= ".." then
			local p = WORK .. "/" .. name
			local a = hs.fs.attributes(p)
			if a and a.mode == "file" and os.remove(p) then
				swept = swept + 1
			end
		end
	end
	if swept > 0 then
		log.f("sweep: cleared %d stale file(s) from .work", swept)
	end
end

-- Clean a DVD volume label into a chooser seed: underscores/dots to
-- spaces, drop disc-numbering noise, title-case-ish is left to TMDB.
local function labelToQuery(vol)
	local name = vol:match("([^/]+)$") or vol
	name = name:gsub("[._]", " "):gsub("%s+[dD]%d+$", ""):gsub("%s+", " ")
	return name
end

local function tmdbChoices(query, cb)
	if searchTask then
		searchTask:terminate()
		searchTask = nil
	end
	searchTask = hs.task.new(RIP_TMDB, function(rc, stdout)
		searchTask = nil
		if rc == 3 then
			cb(nil) -- no key: caller degrades to the plain prompt
			return
		end
		local choices = {}
		for line in (stdout or ""):gmatch("[^\n]+") do
			local ok, obj = pcall(hs.json.decode, line)
			if ok and obj and obj.title then
				local c = { text = obj.title, subText = "TMDB", title = obj.title }
				if obj.poster and obj.poster ~= "" then
					c.image = hs.image.imageFromURL(obj.poster)
				end
				table.insert(choices, c)
			end
		end
		cb(choices)
	end, { query }):start()
end

local function plainTitlePrompt(seed)
	local btn, title = hs.dialog.textPrompt(
		"Name this disc",
		"Title (Year) — exact Jellyfin naming",
		seed,
		"Rip",
		"Cancel"
	)
	if btn == "Rip" and title ~= "" and not title:find("/") then
		enqueue(RIP_DISC, { title }, "rip-disc")
		hs.alert.show("Ripping: " .. title)
	end
end

local function tmdbNameAndRip(seed)
	chooser = hs.chooser.new(function(choice)
		chooser = nil
		if choice and choice.title then
			enqueue(RIP_DISC, { choice.title }, "rip-disc")
			hs.alert.show("Ripping: " .. choice.title)
		end
	end)
	chooser:placeholderText("Search TMDB — pick the exact movie")
	chooser:queryChangedCallback(function(q)
		if chooserDebounce then
			chooserDebounce:stop()
		end
		if q == "" then
			return
		end
		chooserDebounce = hs.timer.doAfter(0.3, function()
			tmdbChoices(q, function(choices)
				if choices == nil then
					-- key missing: fall back once, close the chooser
					if chooser then
						chooser:hide()
						chooser = nil
					end
					plainTitlePrompt(q)
					return
				end
				if chooser then
					chooser:choices(choices)
				end
			end)
		end)
	end)
	chooser:query(seed)
	chooser:show()
end

local function considerVolume(vol)
	if declinedVolumes[vol] then
		return
	end
	if hs.fs.attributes(vol .. "/VIDEO_TS", "mode") == "directory" then
		local btn = hs.dialog.blockAlert("Rip this disc?", vol, "Yes", "Not now")
		if btn == "Yes" then
			tmdbNameAndRip(labelToQuery(vol))
		else
			declinedVolumes[vol] = true
			log.f("disc declined until eject: %s", vol)
		end
		return
	end
	-- audio CD: macOS mounts them as cddafs with .aiff track files
	local iter, dir = hs.fs.dir(vol)
	if iter then
		for name in iter, dir do
			if name:match("%.aiff$") then
				log.f("audio CD detected, opening XLD: %s", vol)
				hs.application.launchOrFocus("XLD")
				return
			end
		end
	end
end

-- Manual re-trigger for a disc that was already in the drive before
-- M.start() armed the volume watcher (hs.fs.volume only sees mounts that
-- happen after it starts). Scans /Volumes for a VIDEO_TS dir, clears its
-- declined flag so a "Not now" from a previous session doesn't stick, and
-- re-runs the same consent flow an insert would have triggered.
function M.ripDisc()
	local iter, dir = hs.fs.dir("/Volumes")
	if not iter then
		return
	end
	for name in iter, dir do
		if name ~= "." and name ~= ".." then
			local vol = "/Volumes/" .. name
			if hs.fs.attributes(vol .. "/VIDEO_TS", "mode") == "directory" then
				declinedVolumes[vol] = nil
				considerVolume(vol)
				return
			end
		end
	end
	hs.alert.show("No DVD volume found")
end

function M.start()
	for _, d in ipairs({ ROOT, INTERMEDIATE, MUSIC, WORK, ROOT .. "/movies" }) do
		hs.fs.mkdir(d)
	end
	sweepWork()
	M.movieWatcher = hs.pathwatcher.new(INTERMEDIATE, function(files)
		for _, f in ipairs(files) do
			considerMovie(f)
		end
	end):start()
	M.musicWatcher = hs.pathwatcher.new(MUSIC, armMusicTimer):start()
	M.volumeWatcher = hs.fs.volume.new(function(event, info)
		if event == hs.fs.volume.didMount and info and info.path then
			considerVolume(info.path)
		elseif event == hs.fs.volume.didUnmount and info and info.path then
			declinedVolumes[info.path] = nil
		end
	end):start()
	sweepIntermediate()
	sweepMusic()
	log.f("watching %s", ROOT)
	return M
end

return M
