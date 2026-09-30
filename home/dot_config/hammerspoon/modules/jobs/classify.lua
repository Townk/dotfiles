-- jobs/classify.lua — the jobs HUD's state decision, with no hs.* dependency so
-- it is testable headless (tests/hammerspoon_jobs_classify_spec.sh).
-- Spec: docs/superpowers/specs/2026-09-29-job-waiting-phase-design.md (W4, W6).
local M = {}

-- x265 legitimately gaps a few seconds between progress updates on hard
-- scenes; 3s flickered the hourglass on healthy encodes (live 2026-08-21).
-- 6s still surfaces a genuinely wedged job fast.
M.STALL_SECS = 6

-- The `phase` sidecar's content → "waiting", or nil. Only the exact word
-- counts, optionally followed by newlines (what the tmux reader's `$(<file)`
-- tolerates); any other content is "no phase" (forward compatibility).
function M.readPhase(raw)
	if raw and raw:match("^waiting\n*$") then return "waiting" end
	return nil
end

-- job: { phase, pct, epoch, reportsProgress }; kind: pueue status or nil.
-- A waiting job (phase set, no real percent yet: job::progress writes the
-- percent before removing `phase`, so a real percent always wins) is never
-- preparing or stalled: it legitimately waits (a live share, up to a day)
-- and must not look like dying.
function M.classify(job, kind, now, stallSecs)
	if job.phase == "waiting" and (job.pct or -1) < 0 then return "waiting" end
	if (job.pct or -1) < 0 or kind == "queued" then return "preparing" end
	if job.reportsProgress and job.epoch and kind == "running"
		and (now - job.epoch) > (stallSecs or M.STALL_SECS)
	then
		return "stalled"
	end
	return "running"
end

-- Time since `created` (epoch seconds) as the HUD shows it where the percent
-- would go: "12m", "3h", "2d". Minutes never read 0.
function M.elapsed(created, now)
	if not created then return "" end
	local s = math.max(0, now - created)
	if s < 3600 then return string.format("%dm", math.max(1, math.floor(s / 60))) end
	if s < 48 * 3600 then return string.format("%dh", math.floor(s / 3600)) end
	return string.format("%dd", math.floor(s / 86400))
end

return M
