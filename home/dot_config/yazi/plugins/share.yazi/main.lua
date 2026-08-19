-- share.yazi -- hand the selection (or the hovered file) to another person.
-- Spec: docs/superpowers/specs/2026-08-18-share-phase3-faces-design.md (F1/F2)
--
--   plugin share            live  -- the default: a code phrase, held open
--   plugin share -- store   stored -- uploaded and parked, for a recipient
--                                     who will not be around today
--
-- ALWAYS job-backed. yazi must never block on a transfer, so both modes hand
-- off to `share --background` and return immediately; the tmux statusbar and
-- the jobs HUD carry it from there.
--
-- THE TWO MODES REPORT DIFFERENTLY, and the reason is worth stating because it
-- looks like an inconsistency otherwise:
--
--   live   the code phrase exists BEFORE the transfer starts, so the pasteable
--          line comes back immediately. It goes on the clipboard and into a
--          notification, and the transfer waits in the background for whoever
--          you send it to.
--   store  the URL does not exist until the upload finishes, so there is
--          nothing to hand over yet. The job's own acknowledgable completion
--          toast carries the link when it is ready (share::announce --ack), and
--          the red bell keeps it until it has been read.
--
-- The clipboard write is done HERE rather than by `share --for-face`, which
-- suppresses it. That is deliberate: the library composes the line, the face
-- decides where it belongs. yazi's answer is "the clipboard" (you are about to
-- paste it into a chat); pick-clipboard's answer is "inject it into the pane,
-- and do not touch the clipboard, because the entry the human picked IS a file
-- clip and must stay one".

local function fail(content)
	ya.notify({ title = "Share", content = content, level = "error", timeout = 5 })
end

-- Selected files if there are any, else the hovered one. Mirrors yazi's own
-- convention for every bulk operation, so `b s` on a selection shares the
-- selection and `b s` on nothing shares what you are looking at.
local selected_or_hovered = ya.sync(function()
	local paths = {}
	for _, u in pairs(cx.active.selected) do
		paths[#paths + 1] = tostring(u)
	end
	if #paths == 0 then
		local h = cx.active.current.hovered
		if h then
			paths[1] = tostring(h.url)
		end
	end
	return paths
end)

return {
	entry = function(_, job)
		local mode = job.args and job.args[1] or "live"
		if mode ~= "live" and mode ~= "store" then
			return fail("unknown mode: " .. tostring(mode))
		end

		local paths = selected_or_hovered()
		if #paths == 0 then
			return fail("nothing selected or hovered")
		end

		-- `--` before the paths: a filename beginning with `-` must never be
		-- read as an option, and a selection can contain anything.
		local args = { "send", "--background" }
		if mode == "store" then
			args[#args + 1] = "--store"
		else
			-- Only live has a line to hand back; --for-face is what puts it on
			-- stdout (and keeps `share` itself off the clipboard, which this
			-- plugin then writes deliberately).
			args[#args + 1] = "--for-face"
		end
		args[#args + 1] = "--"
		for _, p in ipairs(paths) do
			args[#args + 1] = p
		end

		local out = Command("share"):arg(args):output()
		if not out then
			return fail("could not run `share`")
		end
		if not out.status.success then
			local err = (out.stderr or ""):gsub("%s+$", "")
			return fail(err ~= "" and err or "share failed")
		end

		if mode == "store" then
			return ya.notify({
				title = "Share",
				content = string.format("Uploading %d item(s) — you'll get the link when it's ready", #paths),
				timeout = 4,
			})
		end

		local line = (out.stdout or ""):gsub("%s+$", "")
		if line == "" then
			-- A live send that produced no line means the endpoint could not
			-- carry one and `share` fell back to stored (it says so on stderr).
			-- Reporting "copied" here would be a lie.
			local err = (out.stderr or ""):gsub("%s+$", "")
			return ya.notify({
				title = "Share",
				content = err ~= "" and err or "shared — see the jobs HUD",
				timeout = 5,
			})
		end

		-- The clipboard is the delivery mechanism for this face: the next thing
		-- the human does is paste into a chat.
		local clip = Command("pbcopy"):stdin(Command.PIPED):spawn()
		if clip then
			clip:write_all(line)
			clip:flush()
			clip:wait()
		end

		ya.notify({ title = "Share — copied, paste it", content = line, timeout = 8 })
	end,
}
