--- @sync step
-- Thin shim so the {/} keybindings drive the same per-tab pointer bookkeeping
-- as the header back/forward buttons (BackNav, defined in init.lua). The bridge
-- runs in the sync VM, where the `BackNav` global lives: it pre-moves the
-- pointer and reports whether a target exists, so the real command is emitted
-- only when it will actually move (and its echoed cd is absorbed as a no-op).
local step = ya.sync(function(_, dir) return BackNav.step(dir) end)

return {
	entry = function(_, job)
		local dir = job.args and job.args[1]
		if dir ~= "back" and dir ~= "forward" then
			return
		end
		if step(dir) then
			ya.emit(dir, {})
		end
	end,
}
