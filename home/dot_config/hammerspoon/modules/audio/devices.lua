--- audio/devices.lua
--- Individual audio device wrappers with safe accessors.
--- Provides a base Device class and InputDevice/OutputDevice specializations
--- that adapt hs.audiodevice's split method names (inputVolume vs outputVolume)
--- into a uniform interface via config adapter tables.
---
--- Devices without hardware mute support get a software-mute fallback
--- that caches the last non-zero volume before zeroing it out.

local M = {}

---------------------------------------------------------------------------
-- Device (base class)
---------------------------------------------------------------------------

--- @class Device
local Device = {}
Device.__index = Device

--- Wrap a config adapter call in pcall. Returns nil on error.
--- @param fn   function        Config adapter function to call
--- @param ...  any             Arguments forwarded to fn
--- @return     any|nil         Result of fn, or nil on error
--- @private
function Device:_safeCall(fn, ...)
	local ok, result = pcall(fn, ...)
	if not ok then
		print(string.format("[Audio] Device '%s' call failed: %s",
			self._name or "?", tostring(result)))
		return nil
	end
	return result
end

--- Check if the underlying hs.audiodevice object is still usable.
--- Devices become invalid when hardware is disconnected.
--- @return boolean
function Device:isValid()
	local ok = pcall(self._device.uid, self._device)
	return ok
end

--- Create a new Device wrapper around a raw hs.audiodevice.
--- @param audiodevice hs.audiodevice  Raw Hammerspoon device object
--- @param config      DeviceConfig    Adapter table for input/output polymorphism
--- @return Device
function Device:new(audiodevice, config)
	local ok, rawVol = pcall(config.getVolume, audiodevice)
	local currentVol = (ok and rawVol) or nil

	local obj = {
		_device = audiodevice,
		_uid = audiodevice:uid(),
		_name = audiodevice:name(),
    _transportType = audiodevice:transportType(),
		_supportsHwMute = config.supportsMute(audiodevice),
		_cachedVolume = (currentVol and currentVol > 0) and currentVol or 50,
		_config = config,
	}
	setmetatable(obj, self)
	return obj
end

--- Human-readable representation for debugging.
--- Shows "(INVALID, name=...)" when the device is disconnected.
--- @return string
function Device:repr()
	if not self:isValid() then
		return self._config.deviceType
			.. string.format("(INVALID, name=%s)", self._name or "?")
	end
	return string.format(
		self._config.deviceType .. "(name=%s, volume=%s, muted=%s)",
		self:name(),
		tostring(self:volume()),
		tostring(self:isMuted())
	)
end

--- Get the cached device name.
--- @return string
function Device:name()
	return self._name or "Unknown"
end

--- Get the cached device UID.
--- @return string
function Device:uid()
	return self._uid
end

--- Get the device transport type.
--- @return string
function Device:transportType()
	return self._transportType
end

--- Get the current volume level (0-100). Returns 0 on error.
--- @return number
function Device:volume()
	return self:_safeCall(self._config.getVolume, self._device) or 0
end

--- Set the volume level.
--- @param level number  Volume level (0-100)
function Device:setVolume(level)
	self:_safeCall(self._config.setVolume, self._device, level)
end

--- Increase volume by the given amount, unmuting first if muted.
--- @param amount? number  Volume delta in percentage points (default: 2.5, minimum: 2.5)
function Device:increaseVolume(amount)
	local overrideAmount = math.max(2.5, amount or 2.5)
	if self:isMuted() then
		self:setMuted(false)
	end
	local newVol = math.min(100, self:volume() + overrideAmount)
	self:setVolume(newVol)
end

--- Decrease volume by the given amount, unmuting first if muted.
--- @param amount? number  Volume delta in percentage points (default: 2.5, minimum: 2.5)
function Device:decreaseVolume(amount)
	local overrideAmount = math.max(2.5, amount or 2.5)
	if self:isMuted() then
		self:setMuted(false)
	end
	local newVol = math.max(0, self:volume() - overrideAmount)
	self:setVolume(newVol)
end

--- Check whether the device is muted.
--- Uses hardware mute when available, otherwise checks if volume == 0.
--- Returns true as fail-safe when the device is invalid.
--- @return boolean
function Device:isMuted()
	if self._supportsHwMute then
		local result = self:_safeCall(self._config.isMuted, self._device)
		if result == nil then return true end
		return result
	end
	return self:volume() == 0
end

--- Set the mute state.
--- Devices with hardware mute use the native API directly.
--- Devices without hardware mute use a software fallback: muting caches
--- the current volume then zeroes it; unmuting restores the cached volume.
--- @param flag boolean  true to mute, false to unmute
function Device:setMuted(flag)
	if self._supportsHwMute then
		self:_safeCall(self._config.setMuted, self._device, flag)
		return
	end

	-- Software mute fallback
	if flag then
		local currentVol = self:volume()
		if currentVol > 0 then
			self._cachedVolume = currentVol
		end
		self:setVolume(0)
	else
		self:setVolume(self._cachedVolume)
	end
end

--- Toggle the mute state.
function Device:toggleMute()
	self:setMuted(not self:isMuted())
end

--- Make this device the system default for its direction.
function Device:setAsDefault()
	self:_safeCall(self._config.setAsDefault, self._device)
end

---------------------------------------------------------------------------
-- InputDevice
---------------------------------------------------------------------------

--- @class InputDevice : Device
local InputDevice = setmetatable({}, { __index = Device })
InputDevice.__index = InputDevice

--- Adapter config mapping Device methods to hs.audiodevice input API.
--- @type DeviceConfig
local inputConfig = {
	deviceType = "INPUT",
	supportsMute = function(dev)
		return dev:inputMuted() ~= nil
	end,
	getVolume = function(dev)
		return dev:inputVolume()
	end,
	isMuted = function(dev)
		return dev:inputMuted()
	end,
	setVolume = function(dev, level)
		dev:setInputVolume(level)
	end,
	setMuted = function(dev, flag)
		dev:setInputMuted(flag)
	end,
	setAsDefault = function(dev)
		dev:setDefaultInputDevice()
	end,
}

--- Create a new InputDevice wrapper.
--- @param audiodevice hs.audiodevice  Raw input device
--- @return InputDevice
function InputDevice:new(audiodevice)
	local obj = Device:new(audiodevice, inputConfig)
	setmetatable(obj, self)
	return obj --[[@as InputDevice]]
end

---------------------------------------------------------------------------
-- OutputDevice
---------------------------------------------------------------------------

--- @class OutputDevice : Device
local OutputDevice = setmetatable({}, { __index = Device })
OutputDevice.__index = OutputDevice

--- Adapter config mapping Device methods to hs.audiodevice output API.
--- @type DeviceConfig
local outputConfig = {
	deviceType = "OUTPUT",
	supportsMute = function(dev)
		return dev:outputMuted() ~= nil
	end,
	getVolume = function(dev)
		return dev:outputVolume()
	end,
	isMuted = function(dev)
		return dev:outputMuted()
	end,
	setVolume = function(dev, level)
		dev:setOutputVolume(level)
	end,
	setMuted = function(dev, flag)
		dev:setOutputMuted(flag)
	end,
	setAsDefault = function(dev)
		dev:setDefaultOutputDevice()
	end,
}

--- Create a new OutputDevice wrapper.
--- @param audiodevice hs.audiodevice  Raw output device
--- @return OutputDevice
function OutputDevice:new(audiodevice)
	local obj = Device:new(audiodevice, outputConfig)
	setmetatable(obj, self)
	return obj --[[@as OutputDevice]]
end

---------------------------------------------------------------------------
-- Exports
---------------------------------------------------------------------------

M.Device = Device
M.InputDevice = InputDevice
M.OutputDevice = OutputDevice

return M
