--- audio/system_devices.lua
--- Collections of audio devices grouped by direction (input/output).
--- Manages a device list with UID-indexed deduplication, default-device
--- tracking, optional sync mode, and round-robin device cycling.
---
--- SystemInputs and SystemOutputs are thin subclasses that inject the
--- correct hs.audiodevice static methods via config adapter tables.

local audioDevices = require("audio.devices")
local InputDevice = audioDevices.InputDevice
local OutputDevice = audioDevices.OutputDevice

local M = {}

---------------------------------------------------------------------------
-- SystemDevices (base class)
---------------------------------------------------------------------------

--- @class SystemDevices
local SystemDevices = {}
SystemDevices.__index = SystemDevices

--- Create a new device collection by querying hs.audiodevice.
--- Enumerates all devices of the configured direction, wraps each one,
--- identifies the current default, and optionally syncs volume/mute state.
--- @param opts?   SystemDevicesOpts   Options (sync defaults to true)
--- @param config  SystemDevicesConfig  Adapter table for input/output polymorphism
--- @return SystemDevices
function SystemDevices:new(opts, config)
	opts = opts or {}
	config = config or {}
	local sync = opts.sync ~= false

	local devices = {}
	local devicesByUid = {}
	local defaultDevice = nil

	local rawDefault = config.getDefaultDevice()
	local rawDevices = config.getAllDevices() or {}

	for _, rawDev in ipairs(rawDevices) do
		if config.deviceSupports(rawDev) then
			local rawUid = rawDev:uid()
			if rawUid and rawDev:name() then
				local newDevice = config.createDevice(rawDev)
				table.insert(devices, newDevice)
				devicesByUid[rawUid] = newDevice
				if rawDefault and rawUid == rawDefault:uid() then
					defaultDevice = newDevice
				end
			end
		end
	end

	-- Fallback: default device wasn't in the enumerated list
	if not defaultDevice and rawDefault then
		local uid = rawDefault:uid()
		if uid and devicesByUid[uid] then
			defaultDevice = devicesByUid[uid]
		elseif uid then
			defaultDevice = config.createDevice(rawDefault)
			table.insert(devices, defaultDevice)
			devicesByUid[uid] = defaultDevice
		end
	end

	local obj = {
		_devices = devices,
		_devicesByUid = devicesByUid,
		_defaultDevice = defaultDevice,
		_sync = sync,
		_config = config,
	}
	setmetatable(obj, self)

	-- Initial sync: propagate default device state to all others
	if sync and defaultDevice then
		local defaultVolume = defaultDevice:volume()
		local defaultMuted = defaultDevice:isMuted()
		for _, dev in ipairs(devices) do
			if dev ~= defaultDevice then
				dev:setVolume(defaultVolume)
				dev:setMuted(defaultMuted)
			end
		end
	end

	return obj
end

---------------------------------------------------------------------------
-- Internal helpers
---------------------------------------------------------------------------

--- Remove devices whose underlying hs.audiodevice is no longer valid.
--- Cleans up both the ordered list and the UID index.
--- @private
function SystemDevices:_pruneInvalidDevices()
	local validDevices = {}
	local pruned = false
	for _, dev in ipairs(self._devices) do
		if dev:isValid() then
			table.insert(validDevices, dev)
		else
			local uid = dev:uid()
			if uid then
				self._devicesByUid[uid] = nil
			end
			pruned = true
			print(string.format("[Audio] Pruned invalid device: %s", dev:name()))
		end
	end
	if pruned then
		self._devices = validDevices
	end
end

---------------------------------------------------------------------------
-- Default device management
---------------------------------------------------------------------------

--- Re-query the system default device and update the internal reference.
--- Prunes invalid devices first, then looks up the new default by UID.
--- If the default is a genuinely new device, it is added to the collection
--- and synced when sync mode is active.
function SystemDevices:refreshDefault()
	self:_pruneInvalidDevices()

	local rawDefault = self._config.getDefaultDevice()
	if not rawDefault then
		self._defaultDevice = nil
		return
	end

	local defaultUid = rawDefault:uid()
	if not defaultUid then
		self._defaultDevice = nil
		return
	end

	-- O(1) lookup in UID index
	local existing = self._devicesByUid[defaultUid]
	if existing then
		self._defaultDevice = existing
		return
	end

	-- Genuinely new device
	local newDevice = self._config.createDevice(rawDefault)
	table.insert(self._devices, newDevice)
	self._devicesByUid[defaultUid] = newDevice
	self._defaultDevice = newDevice
	print(string.format("[Audio] New default device discovered: %s", newDevice:name()))

	-- Sync new device state to all others when sync mode is active
	if self._sync then
		local vol = newDevice:volume()
		local muted = newDevice:isMuted()
		for _, dev in ipairs(self._devices) do
			if dev ~= newDevice then
				dev:setVolume(vol)
				dev:setMuted(muted)
			end
		end
	end
end

--- Get the current default device.
--- @return Device|nil
function SystemDevices:defaultDevice()
	return self._defaultDevice
end

--- Get all tracked devices in enumeration order.
--- @return Device[]
function SystemDevices:allDevices()
	return self._devices
end

---------------------------------------------------------------------------
-- Volume / mute (delegated to default device, or broadcast when synced)
---------------------------------------------------------------------------

--- Get the default device's volume. Returns 0 if no device is available.
--- @return number
function SystemDevices:volume()
	if not self._defaultDevice then
		self:refreshDefault()
	end
	if not self._defaultDevice then
		return 0
	end
	return self._defaultDevice:volume()
end

--- Check if the default device is muted. Returns true if no device is available.
--- @return boolean
function SystemDevices:isMuted()
	if not self._defaultDevice then
		self:refreshDefault()
	end
	if not self._defaultDevice then
		return true
	end
	return self._defaultDevice:isMuted()
end

--- Set volume. Broadcasts to all devices when sync is active.
--- @param level number  Volume level (0-100)
function SystemDevices:setVolume(level)
	if self._sync then
		for _, dev in ipairs(self._devices) do
			dev:setVolume(level)
		end
	elseif self._defaultDevice then
		self._defaultDevice:setVolume(level)
	end
end

--- Set mute state. Broadcasts to all devices when sync is active.
--- @param flag boolean  true to mute, false to unmute
function SystemDevices:setMuted(flag)
	if self._sync then
		for _, dev in ipairs(self._devices) do
			dev:setMuted(flag)
		end
	elseif self._defaultDevice then
		self._defaultDevice:setMuted(flag)
	end
end

--- Toggle the mute state of the default device.
function SystemDevices:toggleMute()
	local newState = not self:isMuted()
	self:setMuted(newState)
end

--- Increase volume. Broadcasts to all devices when sync is active.
--- @param amount? number  Volume delta in percentage points
function SystemDevices:increaseVolume(amount)
	if self._sync then
		for _, dev in ipairs(self._devices) do
			dev:increaseVolume(amount)
		end
	elseif self._defaultDevice then
		self._defaultDevice:increaseVolume(amount)
	end
end

--- Decrease volume. Broadcasts to all devices when sync is active.
--- @param amount? number  Volume delta in percentage points
function SystemDevices:decreaseVolume(amount)
	if self._sync then
		for _, dev in ipairs(self._devices) do
			dev:decreaseVolume(amount)
		end
	elseif self._defaultDevice then
		self._defaultDevice:decreaseVolume(amount)
	end
end

---------------------------------------------------------------------------
-- Device cycling
---------------------------------------------------------------------------

--- Cycle to the next valid device in round-robin order and make it the
--- system default. Skips invalid (disconnected) devices.
--- When sync is active, propagates the new default's state to all others.
--- @return Device|nil  The new default device, or nil if fewer than 2 devices
function SystemDevices:cycleDevice()
	if #self._devices < 2 then
		return nil
	end

	local currentUid = self._defaultDevice and self._defaultDevice:uid()
	local currentIdx = nil

	if currentUid then
		for i, dev in ipairs(self._devices) do
			if dev:uid() == currentUid then
				currentIdx = i
				break
			end
		end
	end

	if not currentIdx then
		print("[Audio] cycleDevice: current default not in device list")
	end

	-- Try each device in order, starting after the current one
	local startIdx = currentIdx or 0
	for offset = 1, #self._devices do
		local idx = ((startIdx - 1 + offset) % #self._devices) + 1
		local candidate = self._devices[idx]
		if candidate:isValid() then
			candidate:setAsDefault()
			self._defaultDevice = candidate

			if self._sync then
				local vol = candidate:volume()
				local muted = candidate:isMuted()
				for _, dev in ipairs(self._devices) do
					if dev ~= candidate then
						dev:setVolume(vol)
						dev:setMuted(muted)
					end
				end
			end

			return candidate
		end
	end

	print("[Audio] cycleDevice: no valid device found")
	return nil
end

---------------------------------------------------------------------------
-- SystemInputs
---------------------------------------------------------------------------

--- @class SystemInputs : SystemDevices
local SystemInputs = setmetatable({}, { __index = SystemDevices })
SystemInputs.__index = SystemInputs

--- Adapter config mapping SystemDevices to hs.audiodevice input API.
--- @type SystemDevicesConfig
local inputConfig = {
	getDefaultDevice = function()
		return hs.audiodevice.defaultInputDevice()
	end,
	getAllDevices = function()
		return hs.audiodevice.allInputDevices()
	end,
	deviceSupports = function(rawDev)
		return rawDev:inputMuted() ~= nil or rawDev:inputVolume() ~= nil
	end,
	createDevice = function(rawDev)
		return InputDevice:new(rawDev)
	end,
}

--- Create a new system input device collection.
--- @param opts? SystemDevicesOpts
--- @return SystemInputs
function SystemInputs:new(opts)
	local obj = SystemDevices:new(opts, inputConfig)
	setmetatable(obj, self)
	return obj --[[@as SystemInputs]]
end

---------------------------------------------------------------------------
-- SystemOutputs
---------------------------------------------------------------------------

--- @class SystemOutputs : SystemDevices
local SystemOutputs = setmetatable({}, { __index = SystemDevices })
SystemOutputs.__index = SystemOutputs

--- Adapter config mapping SystemDevices to hs.audiodevice output API.
--- @type SystemDevicesConfig
local outputConfig = {
	getDefaultDevice = function()
		return hs.audiodevice.defaultOutputDevice()
	end,
	getAllDevices = function()
		return hs.audiodevice.allOutputDevices()
	end,
	deviceSupports = function(rawDev)
		return rawDev:outputMuted() ~= nil or rawDev:outputVolume() ~= nil
	end,
	createDevice = function(rawDev)
		return OutputDevice:new(rawDev)
	end,
}

--- Create a new system output device collection.
--- @param opts? SystemDevicesOpts
--- @return SystemOutputs
function SystemOutputs:new(opts)
	local obj = SystemDevices:new(opts, outputConfig)
	setmetatable(obj, self)
	return obj --[[@as SystemOutputs]]
end

---------------------------------------------------------------------------
-- Exports
---------------------------------------------------------------------------

M.SystemDevices = SystemDevices
M.SystemInputs = SystemInputs
M.SystemOutputs = SystemOutputs

return M
