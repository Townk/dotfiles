-- jobs — stacked progress capsules for the job runner (spec
-- docs/superpowers/specs/2026-08-15-job-runner-design.md §5).
--
-- Files + ONE long-lived timer, zero per-tick process spawns: an
-- hs.pathwatcher on ~/.local/state/jobs arms a ~4 Hz hs.timer that reads
-- each active job's single-line sidecar; pueue is polled asynchronously
-- (hs.task) every ~2 s for authoritative alive/dead. Inherited invariants
-- from osd.progress (each paid for with a live bug over there):
--   * capsules never linger: result file present, pueue says gone, or the
--     whole system reads dead -> capsule removed. Disappearing means
--     done-or-dead, never waiting.
--   * in-place element repaint; :show() only on hidden->visible.
--   * stall rendering must never do cold glyph I/O (resolver cache is
--     shared with osd, which pre-warms the hourglass).
--   * the cancel affordance never dims.
-- Interaction: ✕ cancels that job (via libexec/job -> pueue kill; the
-- task's own TERM trap decides what cancel means). Mouse-down anywhere
-- else on a capsule dismisses the whole stack without touching the tasks;
-- recall via jobs.toggle() (leader binding), `job::hud show`, or
-- automatically when a NEW job starts.

local osd = require("osd")

local M = {}

local STATE_ROOT = os.getenv("HOME") .. "/.local/state/jobs"
local JOB_BIN = os.getenv("HOME") .. "/.local/libexec/job"
local PUEUE_BIN = "/opt/homebrew/bin/pueue"
local TICK_SECS = 0.25
local PUEUE_EVERY = 8 -- ticks between pueue polls (~2 s)
local PUEUE_DEAD_AFTER = 3 -- consecutive failed polls -> treat system dead
local PUEUE_POLL_TIMEOUT = 10 -- seconds an outstanding poll may run before we count it as failed and retire it
local STALL_SECS = 3
local CAP_W, CAP_H, MARGIN, GAP = 300, 56, 12, 8
local PAD_H, ICON_SIZE, LABEL_SIZE = 14, 18, 11.5
local BAR_H, BAR_SEGS, BAR_GAP, PCT_W = 8, 32, 2, 38
local CANCEL_W, CANCEL_MARGIN, CANCEL_RESERVE = 24, 12, 30

local theme = osd.capsuleTheme
local watcher = nil
local timer = nil
local pollTask = nil
local pollTaskStarted = nil -- os.time() the outstanding poll was fired; nil when idle
local tickCount = 0
local pueueFails = 0
local pueueByLabel = nil -- label -> status kind ("running"|"queued"|"done")
local dismissed = false
local canvases = {} -- id -> hs.canvas
local hovered = {} -- id -> cancel-hover bool
local knownIds = {} -- id -> true, every job id ever seen this session
local knownIdsInitialized = false -- true once the first scan has populated knownIds

local function readFile(path)
	local f = io.open(path, "r")
	if not f then return nil end
	local s = f:read("*a")
	f:close()
	return s
end

-- Scan the state root: every dir with meta.json and no result file is an
-- active job. Cheap by design — one dir listing + one small read per job.
local function scanJobs()
	local jobs = {}
	local ok, iter, dirObj = pcall(hs.fs.dir, STATE_ROOT)
	if not ok or not iter then return jobs end
	for name in iter, dirObj do
		if name ~= "." and name ~= ".." then
			local dir = STATE_ROOT .. "/" .. name
			if hs.fs.attributes(dir, "mode") == "directory"
				and not hs.fs.attributes(dir .. "/result")
			then
				-- job::start mkdirs the job dir before writing meta.json; a
				-- tick can land in that window. Read raw first and only
				-- decode non-empty content so a still-being-written (or not
				-- yet written) meta.json is skipped silently instead of
				-- logging a JSON deserialisation error to the Console.
				local metaRaw = readFile(dir .. "/meta.json")
				if metaRaw and metaRaw ~= "" then
					local meta = hs.json.decode(metaRaw)
					if meta then
						local job = {
							id = name,
							title = meta.title or name,
							icon = meta.icon,
							reportsProgress = meta.progress == "expected",
							pct = -1,
							msg = "",
							epoch = nil,
						}
						local line = readFile(dir .. "/progress")
						if line then
							local e, p, m = line:match("^(%d+)%s+(-?%d+)%s*(.-)%s*$")
							if e then
								job.epoch = tonumber(e)
								job.pct = tonumber(p)
								job.msg = m
							end
						end
						jobs[#jobs + 1] = job
					end
				end
			end
		end
	end
	table.sort(jobs, function(a, b) return a.id < b.id end)
	return jobs
end

-- Async authoritative poll. label -> kind; nil until the first poll lands.
local function pollPueue()
	if pollTask then
		-- A wedged pueued must never freeze pueueByLabel at a stale
		-- snapshot forever (capsules must not linger). Retire an
		-- overdue poll as a failure and fall through to start a new one.
		if pollTaskStarted and (os.time() - pollTaskStarted) >= PUEUE_POLL_TIMEOUT then
			pollTask:terminate()
			pollTask = nil
			pollTaskStarted = nil
			pueueFails = pueueFails + 1
		else
			return
		end
	end
	pollTaskStarted = os.time()
	pollTask = hs.task.new(PUEUE_BIN, function(rc, stdout)
		pollTask = nil
		pollTaskStarted = nil
		if rc ~= 0 then
			pueueFails = pueueFails + 1
			return
		end
		pueueFails = 0
		local status = hs.json.decode(stdout or "")
		if not status or not status.tasks then return end
		local byLabel = {}
		for _, t in pairs(status.tasks) do
			local label = t.label
			local kind = "queued"
			local st = t.status
			if type(st) == "table" then
				if st.Running then kind = "running"
				elseif st.Done then kind = "done"
				elseif st.Paused then kind = "running"
				end
			elseif type(st) == "string" then
				kind = st == "Running" and "running"
					or st == "Done" and "done" or "queued"
			end
			if label then byLabel[label] = kind end
		end
		pueueByLabel = byLabel
	end, { "status", "--json" })
	if not pollTask:start() then
		pollTask = nil
		pollTaskStarted = nil
		pueueFails = pueueFails + 1
	end
end

local function cancelJob(id)
	-- Fire-and-forget; the kill lands on the task's process group and the
	-- callback path takes over (result file -> capsule removal + toast).
	hs.task.new("/bin/zsh", nil, { "-c", JOB_BIN .. " cancel " .. id }):start()
end

local function buildElements(job, stalled, preparing)
	local fillOn = stalled and { white = 1, alpha = theme.stallAlpha }
		or theme.barOn
	local resolved
	if stalled or preparing then
		resolved = osd.resolveNamedIcon(theme.stallIcon)
	elseif type(job.icon) == "string" and job.icon ~= "" then
		resolved = osd.resolveNamedIcon(job.icon)
	end
	local pct = math.max(0, math.min(100, job.pct or 0))
	local indeterminate = (job.pct or -1) < 0
	local elements = {}
	local bw2 = theme.borderW / 2
	elements[#elements + 1] = {
		type = "rectangle",
		id = "capsule-bg",
		action = "strokeAndFill",
		trackMouseDown = true,
		frame = { x = bw2, y = bw2, w = CAP_W - theme.borderW, h = CAP_H - theme.borderW },
		fillColor = theme.bg,
		strokeColor = theme.border,
		strokeWidth = theme.borderW,
		roundedRectRadii = { xRadius = CAP_H / 4, yRadius = CAP_H / 4 },
	}
	local iconFrame = { x = PAD_H, y = (CAP_H - ICON_SIZE) / 2, w = ICON_SIZE, h = ICON_SIZE }
	if type(resolved) == "table" and resolved.type == "glyphIcon" then
		elements[#elements + 1] = {
			type = "text",
			frame = iconFrame,
			text = hs.styledtext.new(resolved.char, {
				font = { name = osd.NERD_FONT_NAME, size = ICON_SIZE },
				color = fillOn,
				paragraphStyle = { alignment = "center" },
			}),
		}
	elseif type(resolved) == "table" and resolved.type == "swatchIcon" then
		elements[#elements + 1] = {
			type = "rectangle",
			action = "strokeAndFill",
			frame = iconFrame,
			fillColor = resolved.color,
			strokeColor = { white = 1, alpha = 0.65 },
			strokeWidth = 1,
			roundedRectRadii = { xRadius = 5, yRadius = 5 },
		}
	elseif resolved ~= nil and type(resolved) ~= "table" then
		elements[#elements + 1] = {
			type = "image",
			image = resolved,
			frame = iconFrame,
			imageScaling = "shrinkToFit",
			imageAlignment = "center",
		}
	end
	local contentX = PAD_H + ICON_SIZE + 10
	local label = job.title
	if job.msg and job.msg ~= "" then label = job.msg end
	elements[#elements + 1] = {
		type = "text",
		frame = { x = contentX, y = 9, w = CAP_W - contentX - PAD_H - CANCEL_RESERVE, h = 16 },
		text = hs.styledtext.new(label or "", {
			font = { name = ".AppleSystemUIFont", size = LABEL_SIZE },
			color = fillOn,
			paragraphStyle = { alignment = "left", lineBreak = "truncateMiddle" },
		}),
	}
	local barX = contentX
	local barW = CAP_W - barX - PCT_W - PAD_H - CANCEL_RESERVE
	local barY = 33
	local segW = (barW - (BAR_SEGS - 1) * BAR_GAP) / BAR_SEGS
	for i = 1, BAR_SEGS do
		local threshold = (i - 1) / BAR_SEGS * 100
		local on = (not indeterminate) and (pct > threshold)
		elements[#elements + 1] = {
			type = "rectangle",
			action = "fill",
			frame = { x = barX + (i - 1) * (segW + BAR_GAP), y = barY, w = segW, h = BAR_H },
			fillColor = on and fillOn or theme.barOff,
			roundedRectRadii = { xRadius = theme.barRadius, yRadius = theme.barRadius },
		}
	end
	elements[#elements + 1] = {
		type = "text",
		frame = { x = CAP_W - PCT_W - PAD_H - CANCEL_RESERVE + 4, y = barY - 4, w = PCT_W, h = 16 },
		text = hs.styledtext.new(indeterminate and "…" or string.format("%d%%", pct), {
			font = { name = ".AppleSystemUIFont", size = 12 },
			color = fillOn,
			paragraphStyle = { alignment = "right" },
		}),
	}
	elements[#elements + 1] = {
		type = "rectangle",
		id = "cancel-bg",
		action = "fill",
		frame = { x = CAP_W - CANCEL_W - CANCEL_MARGIN, y = (CAP_H - CANCEL_W) / 2, w = CANCEL_W, h = CANCEL_W },
		fillColor = hovered[job.id] and { white = 1, alpha = 0.16 } or { white = 1, alpha = 0 },
		roundedRectRadii = { xRadius = CANCEL_W / 2, yRadius = CANCEL_W / 2 },
	}
	elements[#elements + 1] = {
		type = "text",
		id = "cancel",
		trackMouseDown = true,
		trackMouseEnterExit = true,
		trackMouseByBounds = true,
		frame = { x = CAP_W - CANCEL_W - CANCEL_MARGIN, y = (CAP_H - 18) / 2, w = CANCEL_W, h = 18 },
		-- Escape hatch never dims: full-alpha barOn even while stalled.
		text = hs.styledtext.new("✕", {
			font = { name = ".AppleSystemUIFont", size = 13 },
			color = theme.barOn,
			paragraphStyle = { alignment = "center" },
		}),
	}
	return elements
end

local function capsuleFor(id, x, y)
	local c = canvases[id]
	if c then
		c:topLeft({ x = x, y = y })
		return c
	end
	c = hs.canvas.new({ x = x, y = y, w = CAP_W, h = CAP_H })
	if not c then return nil end
	c:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces
		+ hs.canvas.windowBehaviors.stationary)
	c:level(hs.canvas.windowLevels.overlay)
	c:canvasMouseEvents(true)
	c:mouseCallback(function(_, event, elemId)
		if elemId == "cancel" and (event == "mouseEnter" or event == "mouseExit") then
			hovered[id] = event == "mouseEnter"
			if canvases[id] and canvases[id]["cancel-bg"] then
				canvases[id]["cancel-bg"].fillColor = hovered[id]
					and { white = 1, alpha = 0.16 } or { white = 1, alpha = 0 }
			end
		elseif event == "mouseDown" and elemId == "cancel" then
			cancelJob(id)
		elseif event == "mouseDown" and elemId == "capsule-bg" then
			-- Defer: M.hide() deletes this very canvas, and deleting it
			-- from inside its own mouseCallback risks a use-after-free
			-- inside AppKit's event handler.
			hs.timer.doAfter(0, function() M.hide() end) -- dismiss the stack; the tasks keep running
		end
	end)
	canvases[id] = c
	return c
end

local function dropCanvas(id)
	local c = canvases[id]
	if c then
		c:delete()
		canvases[id] = nil
		hovered[id] = nil
	end
end

local function stopAll()
	if timer then
		timer:stop()
		timer = nil
	end
	for id in pairs(canvases) do dropCanvas(id) end
	pueueByLabel = nil
	pueueFails = 0
	tickCount = 0
end

local function repaint(job, index, now)
	local frame = hs.screen.mainScreen():frame()
	local x = frame.x + frame.w - CAP_W - MARGIN
	local y = frame.y + MARGIN + (index - 1) * (CAP_H + GAP)
	local kind = pueueByLabel and pueueByLabel["job:" .. job.id] or nil
	local preparing = (job.pct or -1) < 0 or kind == "queued"
	local stalled = false
	if job.reportsProgress and job.epoch and kind == "running" then
		stalled = (now - job.epoch) > STALL_SECS and not preparing
	end
	local c = capsuleFor(job.id, x, y)
	if not c then return end
	local elements = buildElements(job, stalled, preparing)
	-- In-place repaint, :show() only on hidden->visible (osd.progress's
	-- hard-won pattern; a remove-all/re-show cycle drops frames and asks
	-- AppKit to key a non-keyable canvas every tick).
	local oldCount = c:elementCount()
	local commonCount = math.min(oldCount, #elements)
	for i = 1, commonCount do c[i] = elements[i] end
	while oldCount > #elements do
		c:removeElement(oldCount)
		oldCount = oldCount - 1
	end
	for i = oldCount + 1, #elements do c:insertElement(elements[i]) end
	if not c:isShowing() then c:show() end
end

-- New-job detection lives here rather than in the pathwatcher: job::progress
-- does a tmp-write + `mv -f` per tick, which fires itemCreated/itemRenamed
-- on the state root just as often as a genuinely new job dir would -- a
-- watcher-driven clear defeated click-to-dismiss within one tick. Comparing
-- each scan against the running set of ids we've ever seen only clears
-- `dismissed` for an id that is truly new. The very first scan populates
-- the set without clearing anything, so pre-existing job dirs picked up at
-- setup() don't spuriously announce themselves.
local function noteNewJobs(jobs)
	if not knownIdsInitialized then
		for _, job in ipairs(jobs) do knownIds[job.id] = true end
		knownIdsInitialized = true
		return
	end
	for _, job in ipairs(jobs) do
		if not knownIds[job.id] then
			knownIds[job.id] = true
			dismissed = false
		end
	end
end

local function tick()
	tickCount = tickCount + 1
	if tickCount % PUEUE_EVERY == 1 then pollPueue() end

	local jobs = scanJobs()
	noteNewJobs(jobs)
	if #jobs == 0 or pueueFails >= PUEUE_DEAD_AFTER then
		-- Done-or-dead: nothing active, or the backbone is gone. Either way
		-- the capsules must not linger.
		stopAll()
		return
	end

	-- pueue says a labeled task is done/absent but no result file exists
	-- (callback missed): drop that capsule anyway.
	local alive = {}
	local aliveCount = 0
	local now = os.time()
	local shown = 0
	for _, job in ipairs(jobs) do
		local kind = pueueByLabel and pueueByLabel["job:" .. job.id] or nil
		local gone = pueueByLabel ~= nil and (kind == nil or kind == "done")
		if not gone then
			alive[job.id] = true
			aliveCount = aliveCount + 1
			if not dismissed then
				shown = shown + 1
				repaint(job, shown, now)
			end
		end
	end
	for id in pairs(canvases) do
		if not alive[id] or dismissed then dropCanvas(id) end
	end
	if aliveCount == 0 then
		-- Every scanned job dir reads gone per pueue (an orphaned dir with
		-- no result file, e.g. a crashed job): stand down instead of
		-- polling a corpse at 4 Hz forever with nothing left to show.
		stopAll()
	end
end

local function armTimer()
	if timer then return end
	timer = hs.timer.doEvery(TICK_SECS, tick)
	tick()
end

--- Start watching the job state dir. Any change under it (a new job dir,
--- or job::progress's per-tick tmp-write + `mv -f`) arms the timer; the
--- timer's own scan (see noteNewJobs) is what decides whether a change was
--- actually a new job worth clearing a dismissal for -- the watcher itself
--- cannot tell the two apart, so it stays dumb on purpose.
function M.setup()
	if watcher then return end
	hs.fs.mkdir(STATE_ROOT)
	watcher = hs.pathwatcher.new(STATE_ROOT, function()
		armTimer()
	end)
	watcher:start()
	armTimer() -- pick up jobs already running at HS (re)load
end

function M.show()
	dismissed = false
	armTimer()
end

function M.hide()
	dismissed = true
	for id in pairs(canvases) do dropCanvas(id) end
end

function M.toggle()
	if dismissed then M.show() else M.hide() end
end

function M.cleanup()
	if watcher then
		watcher:stop()
		watcher = nil
	end
	stopAll()
end

return M
