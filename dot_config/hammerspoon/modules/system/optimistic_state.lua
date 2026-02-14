--- system/optimistic_state.lua
--- Reusable optimistic state manager with async reads/writes,
--- observer notification, and first-fires-immediately debounced mutations.
--- Supports any value type. For numeric values, optional min/max config fields
--- enable automatic clamping; inc() and dec() are also available in that case.
---
--- Usage:
---   local OptimisticState = require("system.optimistic_state")
---
---   -- Numeric with clamping:
---   local state = OptimisticState.new({
---       initial = 50, min = 0, max = 100,
---       read = function(cb) ... return task end,
---       write = function(target, cb) ... return task end,
---   })
---   state:inc(10)
---
---   -- Boolean (no clamping):
---   local state = OptimisticState.new({
---       initial = false,
---       read = function(cb) ... return task end,
---       write = function(target, cb) ... return task end,
---   })
---   state:set(true)

local M = {}

--- @class OptimisticState
local OptimisticState = {}
OptimisticState.__index = OptimisticState

-- ============================================================
-- HELPERS
-- ============================================================

local function clamp(val, lo, hi)
	return math.max(lo, math.min(hi, val))
end

-- ============================================================
-- CONSTRUCTOR
-- ============================================================

--- Create a new OptimisticState.
--- @param config OptimisticStateConfig
--- @return OptimisticState
function OptimisticState.new(config)
	assert(config, "[OptimisticState] new() requires a config table")
	assert(config.read, "[OptimisticState] config.read is required")
	assert(config.write, "[OptimisticState] config.write is required")

	local self = setmetatable({}, OptimisticState)
	self._value = config.initial
	self._min = config.min
	self._max = config.max
	self._read = config.read
	self._write = config.write
	self._equals = config.equals or function(a, b) return a == b end
	self._debounce = config.debounce or 0.08
	self._observers = {}
	self._writeTimer = nil
	self._dirty = false
	self._writing = false
	self._reading = false
	self._readTask = nil
	self._writeTask = nil
	self._notifying = false
	self._generation = 0

	-- Kick off initial async read to sync with hardware
	self:_asyncRead()

	return self
end

-- ============================================================
-- PUBLIC API
-- ============================================================

--- Get the current optimistic value. Never blocks, never triggers a read.
function OptimisticState:get()
	return self._value
end

--- Set a new value. Clamps if min/max are configured. Notifies observers and
--- schedules a debounced write if the value changed.
function OptimisticState:set(newValue)
	local next = (self._min ~= nil and self._max ~= nil)
		and clamp(newValue, self._min, self._max)
		or newValue
	if self._equals(next, self._value) then return end
	self._value = next
	self._generation = self._generation + 1
	self:_notify()
	self:_scheduleWrite()
end

--- Increment the numeric value by delta. Only meaningful for numeric states.
--- @param delta number
function OptimisticState:inc(delta)
	self:set(self._value + delta)
end

--- Decrement the numeric value by delta. Only meaningful for numeric states.
--- @param delta number
function OptimisticState:dec(delta)
	self:set(self._value - delta)
end

--- Register an observer callback. Returns an unsubscribe function.
--- @param fn fun(value: number)
--- @return fun()  Unsubscribe function
function OptimisticState:observe(fn)
	table.insert(self._observers, fn)
	return function()
		for i, obs in ipairs(self._observers) do
			if obs == fn then
				table.remove(self._observers, i)
				return
			end
		end
	end
end

--- Force an async read from hardware. Only if not already reading.
--- Result updates _value and notifies if changed (and no writes pending).
function OptimisticState:refresh()
	self:_asyncRead()
end

--- Stop timers, terminate running tasks, clear observers.
--- Call before hs.reload() to prevent leaks.
function OptimisticState:cleanup()
	if self._writeTimer then
		self._writeTimer:stop()
		self._writeTimer = nil
	end
	self:_terminateTask("_readTask")
	self:_terminateTask("_writeTask")
	self._observers = {}
end

-- ============================================================
-- OBSERVER NOTIFICATION
-- ============================================================

--- Dispatch the current value to all observers.
--- Re-entrancy safe: if an observer calls set()/inc()/dec(), the value
--- updates but nested _notify() is suppressed (no infinite loop).
--- @private
function OptimisticState:_notify()
	if self._notifying then return end
	self._notifying = true
	local val = self._value
	for _, fn in ipairs(self._observers) do
		fn(val)
	end
	self._notifying = false
end

-- ============================================================
-- FIRST-FIRES-IMMEDIATELY DEBOUNCED WRITE
-- ============================================================

--- Schedule a write using first-fires-immediately debouncing.
---
--- First mutation when idle: fires the write immediately + starts cooldown.
--- Subsequent mutations during cooldown: mark dirty, timer keeps running.
--- When cooldown fires: if dirty, fire another write + new cooldown.
--- @private
function OptimisticState:_scheduleWrite()
	self._dirty = true

	if self._writeTimer == nil then
		-- First mutation in this window: fire immediately
		self:_fireWrite()
		-- Start cooldown gate
		self._writeTimer = hs.timer.doAfter(self._debounce, function()
			self._writeTimer = nil
			if self._dirty then
				-- More mutations arrived during cooldown: fire coalesced write
				self:_scheduleWrite()
			end
		end)
	end
	-- If timer is already running: _dirty is set, timer will pick it up.
end

--- Execute the actual async write with the current optimistic value.
--- @private
function OptimisticState:_fireWrite()
	self._dirty = false
	self._writing = true
	local target = self._value
	local gen = self._generation

	self._writeTask = self._write(target, function(ok)
		self._writing = false
		self._writeTask = nil

		if not ok then
			print("[OptimisticState] Write failed for target=" .. tostring(target))
			return
		end

		-- Confirmation read: only if no mutations since write started
		if self._generation == gen and not self._dirty then
			self:_asyncRead()
		end
	end)
end

-- ============================================================
-- ASYNC READ
-- ============================================================

--- Start an async hardware read. Guards against concurrent reads.
--- The result is only adopted if no write activity occurred since
--- the read started (generation counter check).
--- @private
function OptimisticState:_asyncRead()
	if self._reading then return end
	self._reading = true
	local gen = self._generation

	self._readTask = self._read(function(value)
		self._reading = false
		self._readTask = nil

		if value == nil then return end

		-- Only adopt hardware value if state is quiescent:
		-- no mutations since read started, no writes pending or in-flight.
		if self._generation == gen
			and not self._dirty
			and not self._writing
			and self._writeTimer == nil
		then
			local next = (self._min ~= nil and self._max ~= nil)
				and clamp(value, self._min, self._max)
				or value
			if not self._equals(next, self._value) then
				self._value = next
				self._generation = self._generation + 1
				self:_notify()
			end
		end
	end)
end

-- ============================================================
-- TASK MANAGEMENT
-- ============================================================

--- Safely terminate a running hs.task stored in the given field.
--- @param field string  Field name (e.g. "_readTask", "_writeTask")
--- @private
function OptimisticState:_terminateTask(field)
	local task = self[field]
	if task then
		if type(task.isRunning) == "function" and task:isRunning() then
			task:terminate()
		end
		self[field] = nil
	end
end

return OptimisticState
