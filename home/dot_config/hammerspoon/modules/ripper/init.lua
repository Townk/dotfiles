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
--     touches audio discs).
--   * A DVD opens the Rip Session Review panel (ripper/session-dialog.lua)
--     already scanning, so the panel IS the consent surface: every title
--     on the disc becomes a row the operator marks Feature / Extra / Skip
--     and names, Esc means "Not now" (remembered per volume path until it
--     unmounts, so nothing loops on a disc left in the drive), and Start
--     produces ONE plan that becomes one `rip-disc --session` job. The
--     disc itself is never touched by Lua: `rip-disc --scan` reads the
--     titles, `rip-disc --library` lists the movies an extra can attach to,
--     `rip-disc --have` answers the auto-extras question, and makemkvcon
--     plus the rest of the chain live in rip.zsh.
--     Spec: docs/superpowers/specs/2026-08-20-rip-session-review-design.md.
--   * The old consent alert + TMDB hs.chooser (tmdbNameAndRip,
--     plainTitlePrompt, tmdbChoices, labelToQuery) are still here but no
--     longer reachable from the DVD path; they come out once the session
--     flow has been verified against real discs (spec).
--   * M.preview(<fixture>) opens the same panel on a canned session with
--     stub callbacks that only print and toast — a UI harness: no disc is
--     read and nothing is ever enqueued. See the Mode B section near the
--     bottom.
--   * M.previewLibrary(<fixture>) is the same harness for the Audiobook
--     Library panel (ripper/library-dialog.lua): a canned row list with
--     stub callbacks, no Libation call and nothing ever enqueued. That
--     panel is currently a SHELL — it renders fixture rows only; a later
--     task feeds it real provider rows, hides books the server already
--     has, and wires Start to the session worker.
--   * The volume watcher only sees mounts that happen after M.start()
--     runs, so a disc already sitting in the drive at launch/reload needs
--     a manual nudge: M.ripDisc() rescans /Volumes for a VIDEO_TS/ dir,
--     clears its declined flag, and reopens the panel on a fresh scan.

local M = {}

local osd = require("osd")
local session = require("ripper.session-dialog")
local library = require("ripper.library-dialog")

local HOME = os.getenv("HOME")
local ROOT = HOME .. "/Depot/Rips"
local INTERMEDIATE = ROOT .. "/intermediate"
local MUSIC = ROOT .. "/music"
local AUDIOBOOKS = ROOT .. "/audiobooks"
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
-- Same invariant as MUSIC_QUIET_SECS: must exceed rip.zsh's
-- RIP_PUSH_MIN_AGE_S (default 90s), or a single quiet book could fire the
-- timer, hit "nothing settled", and leave nothing behind to re-arm it.
-- Libation moves finished files in from its own InProgress directory, so
-- partial files are never visible here — this debounce is noise control,
-- not a completeness check.
local AUDIOBOOK_QUIET_SECS = 120

local log = hs.logger.new("ripper", "info")
local declined = {} -- path -> size at decline time
local declinedVolumes = {} -- volume path -> true until unmount
local pending = {} -- path -> stability timer object while one runs (anchors it against GC)
local musicTimer = nil
local audiobookTimer = nil
local searchTask = nil -- in-flight rip-tmdb-search hs.task (anchors it, cancels the previous one)
local chooser = nil -- open TMDB hs.chooser (anchors it against GC while shown)
local chooserDebounce = nil -- debounce timer for the chooser's queryChangedCallback
local tasks = {} -- id -> hs.task object while running (anchors it against GC)
local nextTaskId = 0
local previewTimer = nil -- M.preview("scanning")'s populate timer (anchors it against GC)
local previewLibraryTimer = nil -- M.previewLibrary("loading")'s populate timer (anchors it against GC)
local scanTask = nil -- in-flight `rip-disc --scan` (anchors it against GC)
local haveTask = nil -- in-flight `rip-disc --have` (anchors it against GC)
local libraryTask = nil -- in-flight `rip-disc --library` (anchors it against GC)
local sessionVolume = nil -- the volume the open session panel is reviewing
local sessionState = nil -- the open session's payload; also the staleness token
local planSeq = 0 -- monotonic suffix for plan temp files

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

local function armAudiobookTimer()
	if audiobookTimer then
		audiobookTimer:stop()
	end
	audiobookTimer = hs.timer.doAfter(AUDIOBOOK_QUIET_SECS, function()
		enqueue(RIP_PUSH, { "audiobooks" }, "rip-push")
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

-- Same startup gap as music: a title liberated while Hammerspoon was down
-- would otherwise sit in staging until an unrelated later write. rip-push
-- audiobooks is skip-if-empty and incremental, so a false-positive sweep
-- costs nothing.
local function sweepAudiobooks()
	local iter, dir = hs.fs.dir(AUDIOBOOKS)
	if not iter then
		return
	end
	for name in iter, dir do
		if name ~= "." and name ~= ".." then
			log.f("sweep: existing audiobook content at startup, arming quiet-period timer")
			armAudiobookTimer()
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
-- AGE GATE (post-incident, 2026-08-21): this sweep runs on EVERY reload,
-- and reloads DO happen while heavy jobs run — a mid-encode hs.reload
-- unlinked the session's in-flight encode temp, HandBrake finished into a
-- deleted inode, and the publish mv found nothing (a whole disc pass
-- lost). A live temp is written constantly, so its mtime stays fresh;
-- debris from a killed job stops aging the moment the job dies. Only
-- files quiet for SWEEP_MIN_AGE_S are debris.
local SWEEP_MIN_AGE_S = 3600
local function sweepWork()
	local iter, dir = hs.fs.dir(WORK)
	if not iter then
		return
	end
	local swept = 0
	local now = os.time()
	for name in iter, dir do
		if name ~= "." and name ~= ".." then
			local p = WORK .. "/" .. name
			local a = hs.fs.attributes(p)
			if a and a.mode == "file"
				and (now - (a.modification or 0)) > SWEEP_MIN_AGE_S
				and os.remove(p)
			then
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

--------------------------------------------------------------------------------
-- Rip Session Review — the DVD flow
--------------------------------------------------------------------------------
-- One panel replaces BOTH the old consent alert and the TMDB chooser above.
-- It opens on insert already scanning, so it IS the consent surface: Esc means
-- "Not now" (remembered until the disc unmounts, exactly as the alert's did),
-- and M.ripDisc() re-offers it. Everything the panel decides comes back as one
-- plan, which becomes one `rip-disc --session` job.
--
-- Spec: docs/superpowers/specs/2026-08-20-rip-session-review-design.md.
-- The consent alert, tmdbNameAndRip and plainTitlePrompt above are left in
-- place but are no longer reachable from the DVD path; they come out once the
-- session flow has been verified against real discs (spec).

-- The volume label as the panel shows it: the raw mount-point basename, which
-- is what is physically printed on the disc (U2_360_ROSE_BOWL). Deliberately
-- NOT labelToQuery's prettified form — that exists to seed a TMDB search, and
-- the panel's header is an identification aid, not a query.
local function volLabel(vol)
	return vol:match("([^/]+)$") or vol
end

local function lastLine(s)
	local last = nil
	for line in (s or ""):gmatch("[^\n]+") do
		last = line
	end
	return last
end

-- "1 movie + 2 extras", the footer's own phrasing, for the console line and
-- the toast. Shared with the preview harness below.
local function planSummary(plan)
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

-- The plan lands in .work/ rather than /tmp: it is rip.zsh's own scratch area,
-- swept at every Hammerspoon start, and `rip-disc --session` immediately
-- copies the plan into a name of the job's own anyway (the queued job may not
-- run for minutes, and this file is not guaranteed to outlive the enqueue).
local function planTempPath()
	planSeq = planSeq + 1
	return string.format("%s/session-plan-%d-%d.json", WORK, os.time(), planSeq)
end

local sessionCallbacks = {
	-- The operator committed a TMDB pick. Ask the server whether that movie
	-- is already in the library; a confirmed yes turns the session
	-- extras-only (the feature row flips to Skip, the extras keep attaching
	-- to it). rc 1 (confirmed absent) and rc 2 (the check could not run) are
	-- BOTH silence — an unreachable cantina must never mark a disc as
	-- already-owned (spec: "check FAILURE = unknown = do nothing").
	onPick = function(movie)
		if type(movie) ~= "string" or movie == "" then
			return
		end
		if haveTask then
			haveTask:terminate()
			haveTask = nil
		end
		-- terminate() only sends SIGTERM and the terminated task's callback
		-- still fires later: clear the anchor through an identity check so a
		-- late reply cannot clobber a newer question's (tmdbChoices' rule).
		local thisTask
		thisTask = hs.task.new(RIP_DISC, function(rc)
			if haveTask == thisTask then
				haveTask = nil
			end
			if rc ~= 0 then
				return
			end
			if not session.isShown() then
				return
			end
			session.setHave({ movie = movie, have = true })
		end, { "--have", movie })
		haveTask = thisTask
		thisTask:start()
	end,

	onStart = function(plan)
		local path = planTempPath()
		local fh = io.open(path, "w")
		if not fh then
			log.ef("cannot write the session plan to %s", path)
			osd.notify("glyph:nf-md-alert", "Rip failed — cannot write the session plan", "Basso")
			hs.notify
				.new(nil, {
					title = "Rip session failed",
					informativeText = "cannot write the session plan to " .. path,
					withdrawAfter = 0,
				})
				:send()
			return
		end
		fh:write(hs.json.encode(plan))
		fh:close()

		local summary = planSummary(plan)
		nextTaskId = nextTaskId + 1
		local id = nextTaskId
		local t = hs.task.new(RIP_DISC, function(rc, stdout, stderr)
			tasks[id] = nil
			if rc == 0 then
				-- ONE short line on success (the job id), the full dump only
				-- on failure — the clipboard picker's headless_restore rule,
				-- for the same reason: console prints are not free.
				print(string.format("ripper: rip session enqueued (%s) job=%s", summary, (stdout or ""):match("[^\n]*") or ""))
				return
			end
			print(
				string.format(
					"ripper: rip session enqueue failed exit=%s\n-- stdout --\n%s\n-- stderr --\n%s",
					tostring(rc),
					stdout or "",
					stderr or ""
				)
			)
			-- The can't-miss immediate signal + the durable NC item (Focus
			-- can swallow either alone) — the picker's failure pairing.
			local reason = lastLine(stderr) or "could not enqueue the rip session"
			osd.notify("glyph:nf-md-alert", "Rip session failed — " .. reason, "Basso")
			hs.notify.new(nil, { title = "Rip session failed", informativeText = reason, withdrawAfter = 0 }):send()
		end, { "--session", path })
		tasks[id] = t
		t:start()
		osd.notify("glyph:nf-md-movie_open", "Ripping " .. summary, "Frog")
	end,

	-- Esc / click-away. Decline semantics are unchanged from UX v2: quiet
	-- until the disc unmounts, re-offered by M.ripDisc().
	onDismiss = function()
		if sessionVolume then
			declinedVolumes[sessionVolume] = true
			log.f("disc declined until eject: %s", sessionVolume)
		end
	end,
}

-- A session panel is filled by TWO independent answers — the disc scan and
-- the server's movie list — which are asked in parallel and land in either
-- order. Both write into `sessionState` and then re-render, so whichever
-- lands last paints a panel carrying both. session.show() on an open panel
-- injects __setSession rather than rebuilding the webview — but __setSession
-- is a FULL RESET of the row state, so it may only ever deliver the scan's
-- titles; the library list arrives additively via session.setLibrary
-- (re-review finding 2026-08-21: a late library reply re-rendering here
-- silently wiped roles/names the operator had already entered).
--
-- The isShown() gate is the consent guard: the panel IS the consent dialog,
-- so a reply arriving after the operator hit Esc must never reopen it and
-- steal focus back (the preview timer's guard, same reasoning).
local function renderSession()
	if not sessionState or not session.isShown() then
		return
	end
	session.show(sessionState, sessionCallbacks)
end

-- `rip-disc --scan` — makemkvcon's own title list, one JSON line per title.
-- Absolute path and identity-anchored, exactly like the TMDB search task.
-- `state` is the session this answer belongs to: a second disc replaces
-- sessionState outright, and a late reply for the previous one must not
-- write into the new session's panel.
local function runSessionScan(state)
	if scanTask then
		scanTask:terminate()
		scanTask = nil
	end
	local thisTask
	thisTask = hs.task.new(RIP_DISC, function(rc, stdout)
		if scanTask == thisTask then
			scanTask = nil
		end
		if sessionState ~= state then
			return
		end
		state.scanning = false
		if rc ~= 0 then
			log.ef("disc scan failed rc=%d: %s", rc, state.volume)
			state.scanFailed = true
			state.titles = {}
			renderSession()
			return
		end
		local titles = {}
		for line in (stdout or ""):gmatch("[^\n]+") do
			local ok, obj = pcall(hs.json.decode, line)
			if ok and type(obj) == "table" and obj.no ~= nil then
				titles[#titles + 1] = obj
			end
		end
		log.f("disc scan: %d title(s) on %s", #titles, state.volume)
		state.titles = titles
		renderSession()
	end, { "--scan" })
	scanTask = thisTask
	thisTask:start()
end

-- `rip-disc --library` — the movies the server already holds, one directory
-- name per line. This is what an extra's attach chip offers, and on an
-- EXTRAS-ONLY disc (the feature is already in the library, so there is no
-- Feature row and no TMDB pick to inherit from) it is the only way to name
-- an attach target at all: with no list, such a session cannot be started.
--
-- rc 2 means the listing could not run (unreachable server, no movies/): the
-- panel gets an empty list and renders a disabled "library unavailable" chip
-- rather than a picker that opens on nothing. Asked ONCE per session open,
-- alongside the scan — one ssh round trip against seconds of drive time.
local function runLibraryFetch(state)
	if libraryTask then
		libraryTask:terminate()
		libraryTask = nil
	end
	local thisTask
	thisTask = hs.task.new(RIP_DISC, function(rc, stdout)
		if libraryTask == thisTask then
			libraryTask = nil
		end
		if sessionState ~= state then
			return
		end
		local movies = {}
		if rc == 0 then
			for line in (stdout or ""):gmatch("[^\n]+") do
				-- Jellyfin's own layout is "<Name> (<Year>)" per directory.
				-- A name that does not match still becomes an entry, title
				-- only — the chip is a picker over what the server actually
				-- holds, not a naming validator.
				local title, year = line:match("^(.-)%s*%((%d%d%d%d)%)$")
				if title and title ~= "" then
					movies[#movies + 1] = { title = title, year = year }
				else
					movies[#movies + 1] = { title = line }
				end
			end
			log.f("library: %d movie(s) on the server", #movies)
		else
			log.f("library list unavailable (rc=%s) — the attach chip will say so", tostring(rc))
		end
		state.library = movies
		-- Additive delivery once real rows exist: renderSession is a
		-- __setSession FULL RESET that would wipe roles/names entered while
		-- this fetch was in flight (re-review finding 2026-08-21). While the
		-- scan is still pending there is nothing to lose and ITS render
		-- carries the list from sessionState — nothing more to do here.
		if state.scanning then
			return
		end
		session.setLibrary(movies)
	end, { "--library" })
	libraryTask = thisTask
	thisTask:start()
end

-- Open the panel in its scanning state, then ask the disc and the server in
-- parallel; each answer re-renders the panel in place (renderSession).
local function startSession(vol)
	sessionVolume = vol
	sessionState = { volume = volLabel(vol), kind = "DVD", scanning = true }
	session.show(sessionState, sessionCallbacks)
	runSessionScan(sessionState)
	runLibraryFetch(sessionState)
end

local function considerVolume(vol)
	if declinedVolumes[vol] then
		return
	end
	if hs.fs.attributes(vol .. "/VIDEO_TS", "mode") == "directory" then
		startSession(vol)
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
-- happen after it starts) — and the re-offer for a disc the operator said
-- "Not now" to. Scans /Volumes for a VIDEO_TS dir, clears its declined flag,
-- and reopens the session panel on a fresh scan.
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
-- The session dialog now drives the real DVD flow above; this harness stays
-- because it is the only way to judge the panel on feel — layout, keyboard,
-- the live TMDB typeahead, the auto-extras flip — without a disc in the drive
-- and without enqueueing anything. `M.preview()` opens it on a fixture with
-- stub callbacks that only print and toast.
--
-- Nothing here shares state with the live flow: the stub callbacks never
-- touch declinedVolumes, never spawn rip-disc, and never enqueue.

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

-- The fixture movie the stub onPick answers "already in your library" for —
-- it demos the auto-extras flip with no server anywhere in the loop.
local PREVIEW_HAVE = "Elvis: That's the Way It Is"

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
		osd.notify("glyph:nf-md-movie_open", "preview: would rip " .. planSummary(plan), "Frog")
	end,
	-- The real onPick shells out to `rip-disc --have`. The stub answers from
	-- a hardcoded name instead, so the auto-extras flip (feature row → Skip,
	-- green have-line, extras still attached) can be judged with no server,
	-- no network and no disc.
	onPick = function(movie)
		hs.printf("ripper.preview: picked %s (nothing asked of the server)", tostring(movie))
		if type(movie) == "string" and movie:sub(1, #PREVIEW_HAVE) == PREVIEW_HAVE then
			session.setHave({ movie = movie, have = true })
		end
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
			-- Only populate a panel that is still up: if the operator
			-- dismissed during the fake scan, firing session.show here would
			-- reopen it and steal focus back 1.5s after they declined.
			if session.isShown() then
				session.show(previewData("u2"), previewCallbacks)
			end
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

--------------------------------------------------------------------------------
-- Audiobook Library panel preview harness (library-dialog.lua). Same
-- discipline as M.preview above: `M.previewLibrary(<fixture>)` opens the
-- panel on canned rows with stub callbacks that only print and toast — no
-- Libation, no server, nothing ever enqueued.
--------------------------------------------------------------------------------

--- One provider-contract row. `path` is derived the same way a real
--- provider row's would be — "<Author>/<Title>" — since that is the exact
--- string the hide-filter (M.setServerLibrary) matches against.
local function libraryRow(id, title, subtitle, authors, narrators, durationS, seriesName, seriesPos, acquired)
	return {
		id = id,
		title = title,
		subtitle = subtitle,
		authors = authors,
		narrators = narrators,
		duration_s = durationS,
		series = seriesName,
		series_position = seriesPos,
		cover = "",
		acquired = acquired,
		path = authors[1] .. "/" .. title,
	}
end

-- Built fresh on each call so a previous preview can never leak state into
-- the next one (same discipline as previewData above).
local function previewLibrarySmallRows()
	return {
		libraryRow(
			"1",
			"Project Hail Mary",
			nil,
			{ "Andy Weir" },
			{ "Ray Porter" },
			16 * 3600 + 10 * 60,
			nil,
			nil,
			"2026-01-04"
		),
		libraryRow(
			"2",
			"The Fellowship of the Ring",
			"Being the First Part of The Lord of the Rings",
			{ "J.R.R. Tolkien" },
			{ "Rob Inglis" },
			19 * 3600 + 6 * 60,
			"The Lord of the Rings",
			1,
			"2026-02-11"
		),
		libraryRow(
			"3",
			"The Two Towers",
			"Being the Second Part of The Lord of the Rings",
			{ "J.R.R. Tolkien" },
			{ "Rob Inglis" },
			17 * 3600 + 42 * 60,
			"The Lord of the Rings",
			2,
			"2026-02-11"
		),
		libraryRow(
			"4",
			"Piranesi",
			nil,
			{ "Susanna Clarke" },
			{ "Chiwetel Ejiofor" },
			6 * 3600 + 58 * 60,
			nil,
			nil,
			"2026-03-02"
		),
		libraryRow(
			"5",
			"A Memory Called Empire",
			nil,
			{ "Arkady Martine" },
			{ "Amy Landon" },
			11 * 3600 + 22 * 60,
			"Teixcalaan",
			1,
			"2026-03-19"
		),
		libraryRow(
			"6",
			"Klara and the Sun",
			nil,
			{ "Kazuo Ishiguro" },
			{ "Sura Siu" },
			10 * 3600 + 16 * 60,
			nil,
			nil,
			"2026-04-01"
		),
	}
end

-- 460 synthetic rows — proves scrolling and filter responsiveness at real
-- scale (the client-side arr()/filter path has no pagination; a 460-row
-- .rows list is the thing that actually exercises it).
local function previewLibraryBigRows()
	local authorsPool = { "A. Author", "B. Writer", "C. Novelist", "D. Storyteller", "E. Penman" }
	local narratorsPool = { "N. Reader", "M. Voice", "P. Narrator" }
	local rows = {}
	for i = 1, 460 do
		local author = authorsPool[((i - 1) % #authorsPool) + 1]
		local narrator = narratorsPool[((i - 1) % #narratorsPool) + 1]
		local seriesIdx = math.floor((i - 1) / 5) + 1
		local seriesPos = ((i - 1) % 5) + 1
		rows[i] = libraryRow(
			tostring(i),
			string.format("Audiobook %03d", i),
			nil,
			{ author },
			{ narrator },
			3600 * (4 + (i % 12)),
			"Series " .. seriesIdx,
			seriesPos,
			nil
		)
	end
	return rows
end

-- Stub callbacks: they print and toast, and that is ALL they do. Nothing
-- here enqueues a job or talks to Libation/the server — same rule as
-- previewCallbacks above.
local previewLibraryCallbacks = {
	onStart = function(plan)
		hs.printf("ripper.previewLibrary: START (nothing enqueued)  provider=%s", tostring(plan.provider))
		local items = plan.items or {}
		for _, item in ipairs(items) do
			hs.printf("ripper.previewLibrary:   rip  id=%s  title=%s", tostring(item.id), tostring(item.title))
		end
		osd.notify(
			"glyph:nf-md-book_music",
			string.format("preview: would rip %d book%s", #items, (#items == 1) and "" or "s"),
			"Frog"
		)
	end,
	onImport = function(spec)
		hs.printf(
			"ripper.previewLibrary: import (nothing imported)  src=%s  author=%s  title=%s",
			tostring(spec.src),
			tostring(spec.author),
			tostring(spec.title)
		)
	end,
	onDismiss = function()
		hs.printf("ripper.previewLibrary: dismissed — nothing enqueued")
	end,
}

--- Open the Audiobook Library panel on a fixture. Mode B validation only:
--- no Libation call and no job is ever enqueued.
--- @param name string|nil "small" (default) | "big" | "loading"
function M.previewLibrary(name)
	name = name or "small"

	if previewLibraryTimer then
		previewLibraryTimer:stop()
		previewLibraryTimer = nil
	end

	if name == "loading" then
		-- Opens with no rows and loading=true, then populates 2.5s later via
		-- library.setRows — the ONLY path that ever ends the loading state
		-- (see rip-library.html's window.__setRows), anchored against GC
		-- exactly as previewTimer is above.
		library.show({ rows = {}, loading = true, provider = "libation" }, previewLibraryCallbacks)
		local thisTimer
		thisTimer = hs.timer.doAfter(2.5, function()
			if previewLibraryTimer == thisTimer then
				previewLibraryTimer = nil
			end
			-- Only populate a panel that is still up: if the operator
			-- dismissed during the fake load, calling setRows here would be
			-- a silent no-op on a hidden webview — fine either way, but
			-- mirrors M.preview("scanning")'s own guard for clarity.
			if library.isShown() then
				library.setRows(previewLibrarySmallRows())
			end
		end)
		previewLibraryTimer = thisTimer
		return
	end

	if name == "big" then
		library.show({ rows = previewLibraryBigRows(), loading = false, provider = "libation" }, previewLibraryCallbacks)
		return
	end

	if name ~= "small" then
		hs.printf("ripper.previewLibrary: unknown fixture %q (small | big | loading)", tostring(name))
		return
	end

	local rows = previewLibrarySmallRows()
	library.show({ rows = rows, loading = false, provider = "libation" }, previewLibraryCallbacks)
	-- Two of the six pretend to already be on the server — demonstrates the
	-- hide-filter (hidden until "show library" is toggled, then dimmed but
	-- still selectable) with no server anywhere in the loop.
	library.setServerLibrary({ rows[2].path, rows[3].path })
end

-- Teardown for the session panel's webview (registered in the root
-- init.lua via lifecycle.registerCleanup, alongside the other panels).
function M.cleanup()
	if previewTimer then
		previewTimer:stop()
		previewTimer = nil
	end
	if previewLibraryTimer then
		previewLibraryTimer:stop()
		previewLibraryTimer = nil
	end
	if scanTask then
		scanTask:terminate()
		scanTask = nil
	end
	if haveTask then
		haveTask:terminate()
		haveTask = nil
	end
	if libraryTask then
		libraryTask:terminate()
		libraryTask = nil
	end
	sessionVolume = nil
	sessionState = nil
	session.cleanup()
	library.cleanup()
end

function M.start()
	for _, d in ipairs({ ROOT, INTERMEDIATE, MUSIC, AUDIOBOOKS, WORK, ROOT .. "/movies" }) do
		hs.fs.mkdir(d)
	end
	sweepWork()
	M.movieWatcher = hs.pathwatcher.new(INTERMEDIATE, function(files)
		for _, f in ipairs(files) do
			considerMovie(f)
		end
	end):start()
	M.musicWatcher = hs.pathwatcher.new(MUSIC, armMusicTimer):start()
	M.audiobookWatcher = hs.pathwatcher.new(AUDIOBOOKS, armAudiobookTimer):start()
	M.volumeWatcher = hs.fs.volume.new(function(event, info)
		if event == hs.fs.volume.didMount and info and info.path then
			considerVolume(info.path)
		elseif event == hs.fs.volume.didUnmount and info and info.path then
			declinedVolumes[info.path] = nil
			-- The disc the open panel is reviewing just left the drive, so
			-- the panel is asking about titles that no longer exist. Close
			-- it — and clear sessionVolume FIRST, because onDismiss records
			-- a decline for whatever sessionVolume names: ejecting with the
			-- panel up and then pressing Esc would otherwise mark the disc
			-- declined AFTER its unmount already cleared that flag, and the
			-- NEXT insert of the same disc would be silently ignored (it
			-- takes an eject to clear it, so the poisoning survives exactly
			-- one insert). Decline-until-eject is unchanged for the normal
			-- case: onDismiss with a mounted sessionVolume still records it.
			if sessionVolume == info.path then
				log.f("disc ejected while the session panel was open: %s", info.path)
				sessionVolume = nil
				sessionState = nil
				session.hide()
			end
		end
	end):start()
	sweepIntermediate()
	sweepMusic()
	sweepAudiobooks()
	log.f("watching %s", ROOT)
	return M
end

return M
