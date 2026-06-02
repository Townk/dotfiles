--- keybindings/system_shortcuts.lua
--- Declarative macOS symbolic hotkey management.
--- Reads the current system plist, diffs against desired state,
--- and writes only when changes are needed. Calls `activateSettings -u`
--- to apply changes without logout.

local M = {}

---------------------------------------------------------------------------
-- Lookup tables
---------------------------------------------------------------------------

--- macOS virtual key codes (physical key positions).
--- @type table<string, number>
local KEY_CODES = {
	-- Letters
	a = 0, s = 1, d = 2, f = 3, h = 4, g = 5, z = 6, x = 7, c = 8, v = 9,
	b = 11, q = 12, w = 13, e = 14, r = 15, y = 16, t = 17,
	o = 31, u = 32, i = 34, p = 35, l = 37, j = 38, k = 40,
	n = 45, m = 46,
	-- Numbers
	["1"] = 18, ["2"] = 19, ["3"] = 20, ["4"] = 21, ["5"] = 23, ["6"] = 22,
	["7"] = 26, ["8"] = 28, ["9"] = 25, ["0"] = 29,
	-- Symbols
	["="] = 24, ["-"] = 27, ["["] = 33, ["]"] = 30, ["\\"] = 42,
	[";"] = 41, ["'"] = 39, [","] = 43, ["."] = 47, ["/"] = 44, ["`"] = 50,
	-- Arrows
	left = 123, right = 124, down = 125, up = 126,
	-- Function keys
	f1 = 122, f2 = 120, f3 = 99, f4 = 118, f5 = 96, f6 = 97,
	f7 = 98, f8 = 100, f9 = 101, f10 = 109, f11 = 103, f12 = 111,
	f13 = 105, f14 = 107, f15 = 113, f16 = 106,
	-- Navigation
	home = 115, ["end"] = 119, pageup = 116, pagedown = 121,
	-- Special
	space = 49, tab = 48, ["return"] = 36, escape = 53,
	delete = 51, forwarddelete = 117,
}

--- ASCII codes for the first parameter of the symbolic hotkey tuple.
--- Keys without a printable ASCII equivalent use NO_ASCII (65535).
--- @type table<string, number>
local ASCII_CODES = {
	a = 97, b = 98, c = 99, d = 100, e = 101, f = 102, g = 103, h = 104,
	i = 105, j = 106, k = 107, l = 108, m = 109, n = 110, o = 111, p = 112,
	q = 113, r = 114, s = 115, t = 116, u = 117, v = 118, w = 119, x = 120,
	y = 121, z = 122,
	["0"] = 48, ["1"] = 49, ["2"] = 50, ["3"] = 51, ["4"] = 52,
	["5"] = 53, ["6"] = 54, ["7"] = 55, ["8"] = 56, ["9"] = 57,
	space = 32, tab = 9,
	["-"] = 45, ["="] = 61, ["["] = 91, ["]"] = 93, ["\\"] = 92,
	[";"] = 59, ["'"] = 39, [","] = 44, ["."] = 46, ["/"] = 47, ["`"] = 96,
}
local NO_ASCII = 65535

--- Modifier bitmask values (CGEventFlags).
--- @type table<string, number>
local MOD_BITS = {
	shift = 131072,    -- 0x00020000
	ctrl  = 262144,    -- 0x00040000
	alt   = 524288,    -- 0x00080000
	cmd   = 1048576,   -- 0x00100000
	fn    = 8388608,   -- 0x00800000
}

--- Keys that implicitly include the fn modifier in macOS bitmasks.
--- @type table<string, boolean>
local FN_KEYS = {}
for _, k in ipairs({
	"left", "right", "up", "down",
	"f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10", "f11", "f12",
	"f13", "f14", "f15", "f16",
	"home", "end", "pageup", "pagedown", "forwarddelete",
}) do
	FN_KEYS[k] = true
end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

--- Resolve a key name to its macOS virtual key code.
--- @param key string  Key name (e.g. "r", "up")
--- @return number|nil  Virtual key code, or nil if unknown
--- @private
local function resolveKeyCode(key)
	local code = KEY_CODES[string.lower(key)]
	if not code then
		hs.printf("[keybindings] WARNING: unknown key '%s'", key)
	end
	return code
end

--- Resolve a key name to its ASCII code for the symbolic hotkey tuple.
--- @param key string  Key name
--- @return number     ASCII code, or NO_ASCII (65535) for non-printable keys
--- @private
local function resolveAsciiCode(key)
	return ASCII_CODES[string.lower(key)] or NO_ASCII
end

--- Compute the CGEventFlags bitmask for a set of modifiers and key.
--- Automatically includes the fn modifier for arrow/function/navigation keys.
--- @param mods string[]|nil  Modifier names
--- @param key  string        Key name
--- @return number             Combined bitmask
--- @private
local function computeModifierBitmask(mods, key)
	local bits = 0
	for _, mod in ipairs(mods or {}) do
		local b = MOD_BITS[string.lower(mod)]
		if b then
			bits = bits + b
		else
			hs.printf("[keybindings] WARNING: unknown modifier '%s'", mod)
		end
	end
	if FN_KEYS[string.lower(key)] then
		bits = bits + MOD_BITS.fn
	end
	return bits
end

--- Build the plist dict structure for a symbolic hotkey entry.
--- @param spec SymbolicHotkeySpec
--- @return table|nil  Plist-compatible dict, or nil on invalid spec
--- @private
local function buildSymbolicEntry(spec)
	local enabled = spec.enabled
	if enabled == nil then enabled = true end

	-- Disable-only: no key specified
	if not enabled and not spec.key then
		return { enabled = false }
	end

	if not spec.key then
		hs.printf("[keybindings] WARNING: symbolic hotkey ID %d has no key", spec.id)
		return nil
	end

	local keyCode = resolveKeyCode(spec.key)
	if not keyCode then return nil end

	local ascii = resolveAsciiCode(spec.key)
	local bitmask = computeModifierBitmask(spec.mods, spec.key)

	return {
		enabled = enabled,
		value = {
			type = "standard",
			parameters = { ascii, keyCode, bitmask },
		},
	}
end

--- Deep-compare two symbolic hotkey entries for equality.
--- @param existing table|nil  Current plist entry
--- @param desired  table|nil  Desired plist entry
--- @return boolean
--- @private
local function entriesMatch(existing, desired)
	if not existing or not desired then return false end
	if existing.enabled ~= desired.enabled then return false end

	if desired.value then
		if not existing.value then return false end
		local ep = existing.value.parameters or {}
		local dp = desired.value.parameters or {}
		if #ep ~= #dp then return false end
		for i = 1, #dp do
			if ep[i] ~= dp[i] then return false end
		end
	end

	return true
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

local PLIST_PATH = os.getenv("HOME") .. "/Library/Preferences/com.apple.symbolichotkeys.plist"
local ACTIVATE_CMD = "/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u"

--- Read, diff, and write symbolic hotkey entries to the system plist.
--- Only writes if at least one entry differs from the current state.
--- Calls `activateSettings -u` to apply changes without logout.
--- @param specs SymbolicHotkeySpec[]  Hotkey specifications to apply
function M.apply(specs)
	if not specs or #specs == 0 then return end

	local plist = hs.plist.read(PLIST_PATH)
	if not plist then
		hs.printf("[keybindings] ERROR: could not read symbolic hotkeys plist")
		return
	end

	local hotkeys = plist.AppleSymbolicHotKeys
	if not hotkeys then
		hotkeys = {}
		plist.AppleSymbolicHotKeys = hotkeys
	end

	-- Normalize keys to strings (hs.plist may return them as numbers)
	local normalized = {}
	for k, v in pairs(hotkeys) do
		normalized[tostring(k)] = v
	end
	plist.AppleSymbolicHotKeys = normalized
	hotkeys = normalized

	local changed = false

	for _, spec in ipairs(specs) do
		local idStr = tostring(spec.id)
		local desired = buildSymbolicEntry(spec)
		if not desired then
			hs.printf("[keybindings] skipping symbolic hotkey ID %s (invalid spec)", idStr)
		elseif entriesMatch(hotkeys[idStr], desired) then
			hs.printf("[keybindings] symbolic hotkey %s: no change needed", idStr)
		else
			hs.printf("[keybindings] symbolic hotkey %s: updating", idStr)
			hotkeys[idStr] = desired
			changed = true
		end
	end

	if changed then
		local ok = hs.plist.write(PLIST_PATH, plist, true)
		if not ok then
			hs.printf("[keybindings] ERROR: failed to write symbolic hotkeys plist")
			return
		end
		hs.printf("[keybindings] activating symbolic hotkey changes…")
		local output, status = hs.execute(ACTIVATE_CMD)
		if status then
			hs.printf("[keybindings] symbolic hotkey changes activated")
		else
			hs.printf("[keybindings] WARNING: activateSettings may have failed: %s", tostring(output))
		end
	else
		hs.printf("[keybindings] all symbolic hotkeys already up to date")
	end
end

return M
