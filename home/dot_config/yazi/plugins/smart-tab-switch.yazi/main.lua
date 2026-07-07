--- @sync entry
-- Create a new tab and enter the hovered directory.
-- Falls back to the current working directory when the hovered entry is not a
-- directory (or nothing is hovered), matching Yazi's native `tab_create`.
local function entry()
	local cur = cx.active.current
	local h = cur.hovered
	if h and h.cha.is_dir then
		ya.emit("tab_create", { h.url })
	else
		ya.emit("tab_create", { cur.cwd })
	end
end

return { entry = entry }
