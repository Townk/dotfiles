---@meta
--- system/types.d.lua
--- Shared type definitions for the system module.
--- This file is declaration-only and is not required at runtime.

---------------------------------------------------------------------------
-- Controls
---------------------------------------------------------------------------

--- Callback invoked when a control value changes.
--- @alias ControlsOnChange fun(setting: "volume"|"inputVolume"|"brightness"|"focus")

---------------------------------------------------------------------------
-- OptimisticState
---------------------------------------------------------------------------

--- Reader function. Calls callback(value) when the read completes.
--- Returns an hs.task handle for cleanup, or nil for synchronous reads.
--- @alias OptimisticReadFn fun(callback: fun(value: any)): hs.task|nil

--- Writer function. Calls callback(ok) when the write completes.
--- Returns an hs.task handle for cleanup, or nil for synchronous writes.
--- @alias OptimisticWriteFn fun(targetValue: any, callback: fun(ok: boolean)): hs.task|nil

--- Configuration for creating an OptimisticState instance.
--- @class OptimisticStateConfig
--- @field initial    any                     Starting optimistic value
--- @field min        number|nil              Lower clamp bound (numeric states only)
--- @field max        number|nil              Upper clamp bound (numeric states only)
--- @field read       OptimisticReadFn                        Reader function
--- @field write      OptimisticWriteFn                       Writer function
--- @field equals     (fun(a: any, b: any): boolean)|nil      Equality check (default: ==)
--- @field debounce   number|nil                              Debounce window in seconds (default 0.08)

--- Reusable optimistic state manager with async reads/writes,
--- observer notification, and first-fires-immediately debounced mutations.
--- Supports any value type; min/max clamping applies only when both are set.
--- @class OptimisticState
--- @field private _value      any
--- @field private _min        number|nil
--- @field private _max        number|nil
--- @field private _observers  fun(value: any)[]
--- @field private _equals     fun(a: any, b: any): boolean
--- @field private _debounce   number
--- @field private _read       OptimisticReadFn
--- @field private _write      OptimisticWriteFn
--- @field private _writeTimer hs.timer|nil
--- @field private _dirty      boolean
--- @field private _writing    boolean
--- @field private _reading    boolean
--- @field private _readTask   hs.task|nil
--- @field private _writeTask  hs.task|nil
--- @field private _notifying  boolean
--- @field private _generation number

---------------------------------------------------------------------------
-- Focus mode
---------------------------------------------------------------------------

--- Snapshot of the current macOS Focus mode state.
--- @class FocusMode
--- @field active  boolean  Whether a Focus mode is currently active
--- @field name    string   Name of the active mode (e.g. "Do Not Disturb"), or ""

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

--- Options for lifecycle.setup().
--- @class LifecycleOpts
--- @field cleanup fun()|nil  Cleanup callback invoked before every hs.reload()

---------------------------------------------------------------------------
-- Keyboard shortcuts
---------------------------------------------------------------------------

--- Specification for a single symbolic hotkey entry.
--- @class SymbolicHotkeySpec
--- @field id      number         Symbolic hotkey ID (see ID reference in keybindings/system_shortcuts.lua)
--- @field enabled boolean|nil    Whether the shortcut is enabled (default: true)
--- @field mods    string[]|nil   Modifier keys (e.g. {"ctrl","cmd"})
--- @field key     string|nil     Key name (e.g. "up", "space"); nil for disable-only entries
