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
--   * M.preview(<fixture>) opens the Rip Session Review panel
--     (ripper/session-dialog.lua) — the webview that will eventually
--     REPLACE the chooser above — on a canned session, with stub callbacks
--     that only print and toast. It is a UI harness: no disc is read and
--     nothing is ever enqueued. See the Mode B section near the bottom.
--   * The volume watcher only sees mounts that happen after M.start()
--     runs, so a disc already sitting in the drive at launch/reload needs
--     a manual nudge: M.ripDisc() rescans /Volumes for a VIDEO_TS/ dir,
--     clears its declined flag, and re-runs the same consent flow.

local M = {}

local osd = require("osd")
local session = require("ripper.session-dialog")

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
-- INVARIANT: this must exceed rip.zsh's RIP_PUSH_MIN_AGE_S (default 90s).
-- If it didn't, a fully-quiet album (a single track, or just a fast rip)
-- could fire this timer, run `rip-push music`, and hit the age gate before
-- any file is old enough — "nothing settled", exit 0 — with NOTHING left
-- to re-arm the timer. That's silent, unbounded stranding: the album sits
-- in staging forever until some unrelated later write in music/ happens to
-- restart the timer. Keeping this above the age gate guarantees the timer
-- can never fire before the gate would already admit the content.
local MUSIC_QUIET_SECS = 120

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
local previewTimer = nil -- M.preview("scanning")'s populate timer (anchors it against GC)

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
	-- terminate() only sends SIGTERM; the terminated task's own callback
	-- still fires later, asynchronously. Identity-check against `thisTask`
	-- (not a bare `searchTask = nil`) so that late callback can't clobber
	-- a newer search's anchor — same precedent as enqueue()'s tasks[id].
	local thisTask
	thisTask = hs.task.new(RIP_TMDB, function(rc, stdout)
		if searchTask == thisTask then
			searchTask = nil
		end
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
	end, { query })
	searchTask = thisTask
	thisTask:start()
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
					-- key missing: fall back once, but only if the chooser
					-- session is still alive. A dismissed chooser doesn't
					-- stop an in-flight search, so this callback can still
					-- land after Escape — it must resurrect nothing.
					if chooser then
						chooser:hide()
						chooser = nil
						plainTitlePrompt(q)
					end
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

--------------------------------------------------------------------------------
-- Rip Session Review — Mode B preview harness
--------------------------------------------------------------------------------
-- The session dialog (ripper/session-dialog.lua) is the replacement for the
-- hs.chooser naming step above, but it is NOT wired into the consent/rip
-- flow yet: this harness exists so the panel can be judged on feel — layout,
-- keyboard, the live TMDB typeahead — without a disc in the drive and
-- without enqueueing anything. `M.preview()` opens it on a fixture with stub
-- callbacks that only print and toast.
--
-- The consent/chooser/watcher flow above is deliberately untouched; when the
-- integration lands it replaces tmdbNameAndRip's chooser, not this harness.

-- Fixture sessions, one per mockup shape. Built fresh on each call so a
-- previous preview can never leak state into the next one.
local function previewData(name)
	local u2Library = {
		{ title = "U2 360° at the Rose Bowl", year = 2010 },
		{ title = "Elvis: That's the Way It Is", year = 1970 },
	}
	if name == "single" then
		-- FastPath mockup: one title, nothing to decide but the movie.
		return {
			volume = "INCEPTION",
			kind = "DVD",
			titles = {
				{ no = 0, duration = "1:51:47", seconds = 6707, size = "5.6 GB" },
			},
			library = u2Library,
		}
	elseif name == "extras" then
		-- ExtrasOnly mockup: the feature is already on the server, so the
		-- longest title defaults to Skip and the session has no Feature row
		-- at all — the two remaining titles are extras looking for a movie
		-- to attach to.
		return {
			volume = "ELVIS_TTWII",
			kind = "DVD",
			titles = {
				{
					no = 0,
					duration = "1:37:02",
					seconds = 5822,
					size = "5.8 GB",
					inLibrary = "Elvis: That's the Way It Is (1970)",
				},
				{ no = 1, duration = "0:57:20", seconds = 3440, size = "2.6 GB" },
				{ no = 2, duration = "0:12:05", seconds = 725, size = "520 MB" },
			},
			library = u2Library,
		}
	end
	-- Main mockup (default): feature + two extras + one sub-2-minute title
	-- that defaults to Skip.
	return {
		volume = "U2_360_ROSE_BOWL",
		kind = "DVD",
		titles = {
			{ no = 0, duration = "1:58:12", seconds = 7092, size = "6.9 GB" },
			{ no = 1, duration = "0:26:14", seconds = 1574, size = "1.1 GB" },
			{ no = 2, duration = "0:07:41", seconds = 461, size = "340 MB" },
			{ no = 3, duration = "0:01:12", seconds = 72, size = "58 MB" },
		},
		library = u2Library,
	}
end

local function previewSummary(plan)
	local parts = {}
	if plan.feature then
		table.insert(parts, "1 movie")
	end
	local n = #plan.extras
	if n > 0 then
		table.insert(parts, string.format("%d extra%s", n, n == 1 and "" or "s"))
	end
	if #parts == 0 then
		return "nothing"
	end
	return table.concat(parts, " + ")
end

-- Stub callbacks: they print and toast, and that is ALL they do. Nothing
-- here enqueues a job, spawns rip-disc, or touches the disc.
local previewCallbacks = {
	onStart = function(plan)
		hs.printf("ripper.preview: START (nothing enqueued)")
		if plan.feature then
			hs.printf("ripper.preview:   feature  title=%s  movie=%s", tostring(plan.feature.no), plan.feature.movie)
		end
		for _, e in ipairs(plan.extras) do
			hs.printf(
				"ripper.preview:   extra    title=%s  name=%s  attach=%s",
				tostring(e.no),
				e.name,
				tostring(e.attachTo)
			)
		end
		for _, no in ipairs(plan.skipped) do
			hs.printf("ripper.preview:   skip     title=%s", tostring(no))
		end
		osd.notify("glyph:nf-md-movie_open", "preview: would rip " .. previewSummary(plan), "Frog")
	end,
	onDismiss = function()
		hs.printf("ripper.preview: dismissed — nothing enqueued")
	end,
}

--- Open the Rip Session Review panel on a fixture. Mode B validation only:
--- no disc is read and no job is ever enqueued.
--- @param name string|nil "u2" (default) | "single" | "extras" | "scanning"
function M.preview(name)
	name = name or "u2"

	if name == "scanning" then
		-- The scanning -> populated transition: open with no titles, then
		-- hand the same panel a full session 2.5s later (session.show
		-- re-renders in place rather than rebuilding the webview).
		session.show({ volume = "U2_360_ROSE_BOWL", kind = "DVD", scanning = true }, previewCallbacks)
		if previewTimer then
			previewTimer:stop()
			previewTimer = nil
		end
		-- Anchored in a module-local against GC, and cleared through an
		-- identity check rather than a bare `previewTimer = nil` — the same
		-- discipline pending[path] and tmdbChoices' `thisTask` already use
		-- above, so a second M.preview("scanning") started while this one is
		-- still counting down can't have its anchor cleared by the older
		-- timer's callback.
		local thisTimer
		thisTimer = hs.timer.doAfter(2.5, function()
			if previewTimer == thisTimer then
				previewTimer = nil
			end
			session.show(previewData("u2"), previewCallbacks)
		end)
		previewTimer = thisTimer
		return
	end

	if name ~= "u2" and name ~= "single" and name ~= "extras" then
		hs.printf("ripper.preview: unknown fixture %q (u2 | single | extras | scanning)", tostring(name))
		return
	end
	session.show(previewData(name), previewCallbacks)
end

-- Teardown for the session panel's webview. Not registered anywhere yet —
-- ripper has no lifecycle cleanup of its own, and the root init.lua is out
-- of this task's scope; add `lifecycle.registerCleanup(ripper.cleanup)` there
-- when the dialog is wired into the real flow.
function M.cleanup()
	if previewTimer then
		previewTimer:stop()
		previewTimer = nil
	end
	session.cleanup()
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
