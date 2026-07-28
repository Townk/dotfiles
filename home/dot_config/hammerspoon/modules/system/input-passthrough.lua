--- system/input-passthrough.lua
--- Shared predicate for input-forwarding applications. Local event taps must
--- yield while one of these apps is frontmost so the remote machine receives
--- the original keyboard or mouse event unchanged.

local M = {}

local DEFAULT_APPS = {
	["com.apple.ScreenSharing"] = true,
	["com.apple.RemoteDesktop"] = true,
	["com.realvnc.vncviewer"] = true,
	["com.teamviewer.TeamViewer"] = true,
}

--- True when the frontmost app forwards input to another machine.
--- Extra entries may be keyed by bundle ID or application name.
--- @param extra table<string, boolean>|nil
--- @return boolean
function M.isFrontmost(extra)
	local app = hs.application.frontmostApplication()
	if not app then
		return false
	end

	local id = app:bundleID()
	if id and (DEFAULT_APPS[id] or (extra or {})[id]) then
		return true
	end

	local name = app:name()
	return name ~= nil and (extra or {})[name] == true
end

return M
