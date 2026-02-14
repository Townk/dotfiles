--- streamdeck/button.lua
--- Button and ButtonToggler classes for Stream Deck composable architecture.
--- Buttons are built from ordered lists of composable layer functions.

local layers = require("streamdeck.layers")
local resolve = layers.resolve

local M = {}

-- ============================================================
-- BUTTON (base class)
-- ============================================================

--- @class Button
local Button = {}
Button.__index = Button
M.Button = Button

--- Create a new Button.
--- @param def table  Button definition
--- @return Button
function Button.new(def)
	local self = setmetatable({}, Button)
	self._layers = def.layers or { layers.standard(def) }
	self._state = def.state ~= nil and def.state or true
	self._callback = def.callback
	self._callbackLong = def.callbackLong
	self.poll = def.poll
	return self
end

--- Resolve the current state.
--- @return any
function Button:state()
	return resolve(self._state)
end

--- Produce canvas elements by piping state through all layers.
--- @param state any   Resolved state value
--- @param ctx table   { w: number, h: number }
--- @return table[]    Array of hs.canvas element tables
function Button:render(state, ctx)
	local elements = {}
	for _, layer in ipairs(self._layers) do
		elements = layer(elements, state, ctx)
	end
	return elements
end

--- Handle a button press.
--- @param state any  Current state at press time
function Button:onPress(state)
	if self._callback then
		self._callback(state)
	end
end

--- Handle a long press.
--- @param state any  Current state at press time
function Button:onLongPress(state)
	if self._callbackLong then
		self._callbackLong(state)
	end
end

return M
