--- streamdeck/encoder.lua
--- Typed encoder constructors for Stream Deck LCD strip sections.
---
--- Three pre-defined layouts:
---
---   ValueBar : title | icon (col 1) | progress value + bar (cols 2-3)
---   Icon     : title | icon centered in full bottom area
---   Text     : title | icon (col 1) | description text (cols 2-3)
---
--- All layout is derived from a single computeEncoderLayout() call at
--- construction time, so every element's position is relative to the
--- configured availableArea rather than hard-coded pixel values.
---
--- EncoderStack wraps N encoders, cycles on press-while-turn,
--- and injects the stack-badge into each sub-encoder automatically.

local layers = require("streamdeck.layers")
local resolve = layers.resolve

--- Strip canvas dimensions used to pre-compute layout at construction time.
--- These match renderer.stripSize defaults and are updated by the engine
--- before any encoder is constructed in practice.
local STRIP_CTX = { w = 200, h = 100 }

local M = {}

-- ============================================================
-- BASE ENCODER
-- ============================================================

--- @class Encoder
local Encoder = {}
Encoder.__index = Encoder
M.Encoder = Encoder

--- @param def table
--- @return Encoder
function Encoder.new(def)
	local self = setmetatable({}, Encoder)
	self._layers            = def.layers or nil
	self._title             = def.title
	self._state             = def.state
	self._value             = def.value
	self._callbackInc       = def.callbackInc
	self._callbackDec       = def.callbackDec
	self._callbackPress     = def.callbackPress
	self._callbackTouch     = def.callbackTouch
	self._callbackTouchLong = def.callbackTouchLong
	self.poll               = def.poll
	return self
end

--- @return any
function Encoder:state()
	return resolve(self._state)
end

--- @return any
function Encoder:value()
	return resolve(self._value)
end

--- @param state any
--- @param value any
--- @param ctx LayerContext
--- @param elements? table[]
--- @return table[]
function Encoder:render(state, value, ctx, elements)
	elements = elements or {}
	for _, layer in ipairs(self._layers or {}) do
		elements = layer(elements, state, ctx, value)
	end
	return elements
end

--- @param state any
--- @param value any
--- @param secondary boolean
--- @return any
function Encoder:onInc(state, value, secondary)
	if self._callbackInc then
		return self._callbackInc(state, value, secondary)
	end
	return value
end

--- @param state any
--- @param value any
--- @param secondary boolean
--- @return any
function Encoder:onDec(state, value, secondary)
	if self._callbackDec then
		return self._callbackDec(state, value, secondary)
	end
	return value
end

--- @param state any
--- @param value any
function Encoder:onPress(state, value)
	if self._callbackPress then
		self._callbackPress(state, value)
	end
end

--- @param state any
--- @param value any
function Encoder:onTouch(state, value)
	local cb = self._callbackTouch or self._callbackPress
	if cb then cb(state, value) end
end

--- @param state any
--- @param value any
function Encoder:onTouchLong(state, value)
	if self._callbackTouchLong then
		self._callbackTouchLong(state, value)
	end
end

-- ============================================================
-- TYPED CONSTRUCTORS
-- ============================================================

--- @param def ValueBarDef
--- @return Encoder
function Encoder.ValueBar(def)
	local layout = layers.computeEncoderLayout(STRIP_CTX, def.layoutOpts)

	local titleLayer = layers.encoderTitle(def.title, layout)
	local iconLayer  = layers.encoderIcon(def.icon, layout, def.iconOpts)

	local function defaultPct(state, value)
		local status = resolve(def.status, state, value)
		if type(status) == "table" and status.min and status.max then
			local range = status.max - status.min
			if range > 0 then
				return ((value or 0) - status.min) / range * 100
			end
			return 0
		end
		return value or 0
	end

	local valueLayer = layers.encoderProgressValue(
		function(state, value)
			if def.displayValue then
				local override = def.displayValue(state, value)
				if override ~= nil then return override end
			end
			return math.floor(defaultPct(state, value))
		end,
		layout,
		def.barColor
	)
	local barLayer = layers.encoderProgressBar(
		function(state, value)
			if def.barValue then
				local override = def.barValue(state, value)
				if override ~= nil then return override end
			end
			return defaultPct(state, value)
		end,
		layout,
		def.barColor
	)

	return Encoder.new({
		title             = def.title,
		state             = def.state,
		value             = def.value,
		poll              = def.poll,
		callbackInc       = def.callbackInc,
		callbackDec       = def.callbackDec,
		callbackPress     = def.callbackPress,
		callbackTouch     = def.callbackTouch,
		callbackTouchLong = def.callbackTouchLong,
		layers            = { titleLayer, iconLayer, valueLayer, barLayer },
	})
end

--- @param def IconDef
--- @return Encoder
function Encoder.Icon(def)
	local layout = layers.computeEncoderLayout(STRIP_CTX, def.layoutOpts)

	local titleLayer = layers.encoderTitle(def.title, layout)
	local iconLayer  = layers.encoderIconFull(def.icon, layout, def.iconOpts)

	return Encoder.new({
		title             = def.title,
		state             = def.state,
		value             = def.value,
		poll              = def.poll,
		callbackInc       = def.callbackInc,
		callbackDec       = def.callbackDec,
		callbackPress     = def.callbackPress,
		callbackTouch     = def.callbackTouch,
		callbackTouchLong = def.callbackTouchLong,
		layers            = { titleLayer, iconLayer },
	})
end

--- @param def TextDef
--- @return Encoder
function Encoder.Text(def)
	local layout = layers.computeEncoderLayout(STRIP_CTX, def.layoutOpts)

	local titleLayer = layers.encoderTitle(def.title, layout)
	local iconLayer  = layers.encoderIcon(def.icon, layout, def.iconOpts)
	local descLayer  = layers.encoderDescription(def.description, layout, def.descColor)

	return Encoder.new({
		title             = def.title,
		state             = def.state,
		value             = def.value,
		poll              = def.poll,
		callbackInc       = def.callbackInc,
		callbackDec       = def.callbackDec,
		callbackPress     = def.callbackPress,
		callbackTouch     = def.callbackTouch,
		callbackTouchLong = def.callbackTouchLong,
		layers            = { titleLayer, iconLayer, descLayer },
	})
end

-- ============================================================
-- ENCODER STACK
-- ============================================================

--- @class EncoderStack
local EncoderStack = {}
EncoderStack.__index = EncoderStack
M.EncoderStack = EncoderStack

local STACK_BADGE_SVG = "stacks"

--- @param def EncoderStackDef
--- @return EncoderStack
function EncoderStack.new(def)
	assert(def.encoders and #def.encoders >= 2, "EncoderStack requires at least 2 encoders")

	local self       = setmetatable({}, EncoderStack)
	self._encoders   = def.encoders
	self._active     = 1
	self._selecting  = false
	self.poll        = def.poll

	local badgeLayout = layers.computeEncoderLayout(STRIP_CTX, def.layoutOpts)
	local badgeLayer  = layers.encoderBadge(STACK_BADGE_SVG, badgeLayout, def.badgeOpts)
	for _, enc in ipairs(self._encoders) do
		enc._layers = enc._layers or {}
		table.insert(enc._layers, badgeLayer)
	end

	self._pickerLayer = layers.encoderStackPicker(
		STACK_BADGE_SVG,
		function()
			local enc = self:_current()
			return resolve(enc._title, enc:state(), enc:value())
		end,
		badgeLayout
	)

	return self
end

function EncoderStack:_current()
	return self._encoders[self._active]
end

function EncoderStack:beginSelecting()
	self._selecting = true
end

function EncoderStack:endSelecting()
	self._selecting = false
end

function EncoderStack:state()
	return self:_current():state()
end

function EncoderStack:value()
	return self:_current():value()
end

function EncoderStack:render(state, value, ctx)
	local elements = {}
	for _, layer in ipairs(self._layers or {}) do
		elements = layer(elements, state, ctx, value)
	end
	if self._selecting then
		return self._pickerLayer(elements, state, ctx, value)
	end
	return self:_current():render(state, value, ctx, elements)
end

function EncoderStack:onInc(state, value, secondary)
	if secondary then
		self._active = (self._active % #self._encoders) + 1
		return self:_current():value()
	end
	return self:_current():onInc(state, value, false)
end

function EncoderStack:onDec(state, value, secondary)
	if secondary then
		self._active = ((self._active - 2) % #self._encoders) + 1
		return self:_current():value()
	end
	return self:_current():onDec(state, value, false)
end

function EncoderStack:onPress(state, value)
	self:_current():onPress(state, value)
end

function EncoderStack:onTouch(state, value)
	self:_current():onTouch(state, value)
end

function EncoderStack:onTouchLong(state, value)
	self:_current():onTouchLong(state, value)
end

return M
