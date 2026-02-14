---@meta
--- audio/types.d.lua
--- Shared type definitions for the audio module.
--- This file is declaration-only and is not required at runtime.

---------------------------------------------------------------------------
-- Device adapter config
---------------------------------------------------------------------------

--- Adapter table that maps polymorphic hs.audiodevice method names
--- (e.g. inputVolume vs outputVolume) to a uniform interface.
--- One instance exists per device direction (input / output).
--- @class DeviceConfig
--- @field deviceType    "INPUT"|"OUTPUT"
--- @field supportsMute  fun(dev: hs.audiodevice): boolean
--- @field getVolume     fun(dev: hs.audiodevice): number|nil
--- @field isMuted       fun(dev: hs.audiodevice): boolean|nil
--- @field setVolume     fun(dev: hs.audiodevice, level: number)
--- @field setMuted      fun(dev: hs.audiodevice, flag: boolean)
--- @field setAsDefault  fun(dev: hs.audiodevice)

---------------------------------------------------------------------------
-- Device
---------------------------------------------------------------------------

--- Wrapper around a single hs.audiodevice with safe accessors
--- and software-mute fallback for devices without hardware mute.
--- @class Device
--- @field _device         hs.audiodevice   Raw Hammerspoon device object
--- @field _uid            string           Cached device UID
--- @field _transportType  string           Cached transport type
--- @field _name           string           Cached device name
--- @field _supportsHwMute boolean          Whether the device supports hardware mute
--- @field _cachedVolume   number           Last-known non-zero volume (for software mute restore)
--- @field _config         DeviceConfig     Adapter config for input/output polymorphism

--- Input device specialization (microphones).
--- Inherits all Device methods; uses inputConfig adapter.
--- @class InputDevice : Device

--- Output device specialization (speakers, headphones).
--- Inherits all Device methods; uses outputConfig adapter.
--- @class OutputDevice : Device

---------------------------------------------------------------------------
-- System device collection config
---------------------------------------------------------------------------

--- Adapter table for SystemDevices that maps to the correct
--- hs.audiodevice static methods per device direction.
--- @class SystemDevicesConfig
--- @field getDefaultDevice fun(): hs.audiodevice|nil
--- @field getAllDevices    fun(): hs.audiodevice[]|nil
--- @field deviceSupports  fun(rawDev: hs.audiodevice): boolean
--- @field createDevice    fun(rawDev: hs.audiodevice): Device

---------------------------------------------------------------------------
-- System device collections
---------------------------------------------------------------------------

--- Collection of all devices of one direction (input or output)
--- with default-device tracking, sync mode, and device cycling.
--- @class SystemDevices
--- @field _devices       Device[]                  Ordered list of wrapped devices
--- @field _devicesByUid  table<string, Device>     UID-indexed lookup for deduplication
--- @field _defaultDevice Device|nil                Currently active default device
--- @field _sync          boolean                   Whether volume/mute changes broadcast to all devices
--- @field _config        SystemDevicesConfig        Adapter config for input/output polymorphism

--- @class SystemDevicesOpts
--- @field sync boolean|nil  Sync volume/mute across all devices (default: true)

--- System input device collection (microphones).
--- Inherits all SystemDevices methods; uses inputConfig adapter.
--- @class SystemInputs : SystemDevices

--- System output device collection (speakers, headphones).
--- Inherits all SystemDevices methods; uses outputConfig adapter.
--- @class SystemOutputs : SystemDevices

---------------------------------------------------------------------------
-- Module state
---------------------------------------------------------------------------

--- Internal watcher lifecycle state.
--- @class AudioWatcherState
--- @field running      boolean        Whether the hs.audiodevice.watcher is active
--- @field userCallback fun(event: string)|nil  Optional user-supplied callback
