--- streamdeck/init.lua
--- Module coordinator: discovers the Stream Deck+ device, queries its
--- hardware dimensions, and delegates to the engine for all button/encoder
--- behaviour driven by the composable config passed from root init.lua.
---
--- Usage from root init.lua:
---   local sd = require("streamdeck")
---   sd.setup({ profiles = { ... }, defaultProfile = "main", ... })

local renderer = require("streamdeck.renderer")
local engine = require("streamdeck.engine")

local M = {}

-- Active device reference
local deck = nil
--- @type StreamDeckConfig|nil
local sdConfig = nil

-- ============================================================
-- DECK BRIGHTNESS
-- ============================================================

--- @type number
local deckBrightness = 70

function M.deckBrightnessGet()
	return deckBrightness
end

function M.deckBrightnessSet(value)
	deckBrightness = math.max(0, math.min(100, value))
	if deck then
		deck:setBrightness(deckBrightness)
	end
end

function M.deckBrightnessInc(step)
	M.deckBrightnessSet(deckBrightness + (step or 10))
end

function M.deckBrightnessDec(step)
	M.deckBrightnessSet(deckBrightness - (step or 10))
end

-- ============================================================
-- NOTIFICATIONS
-- ============================================================

local sdNotification = nil
local function sdNotify(message)
	if sdNotification then
		sdNotification:withdraw()
	end
	sdNotification = hs.notify.new(nil, {
		title = "Stream Deck",
		informativeText = message,
	})
	if sdNotification then
		sdNotification:send()
	end
end

-- ============================================================
-- DEVICE SETUP
-- ============================================================

local function setupDevice(device)
	deck = device

	-- Query real image size from hardware and propagate to renderer
	local imgSize = deck:imageSize()
	if imgSize then
		renderer.setSizes(imgSize, { w = 200, h = 100 })
	end

	-- Register callbacks (all dispatch through the engine)
	deck:buttonCallback(engine.buttonCallback)
	deck:encoderCallback(engine.encoderCallback)
	deck:screenCallback(engine.screenCallback)

	if sdConfig and sdConfig.brightness then
    if type(sdConfig.brightness) == "function" then
      deckBrightness = sdConfig.brightness()
    else
      deckBrightness = sdConfig.brightness --[[@as number]]
    end
		deck:setBrightness(deckBrightness)
	end

	-- Initialise the engine with device handle and config
	engine.setup(device, sdConfig)

	local cols, rows = deck:buttonLayout()
	print(string.format("[Stream Deck] Device ready — %dx%d buttons, image %dx%d", cols, rows, imgSize.w, imgSize.h))
end

-- ============================================================
-- DISCOVERY
-- ============================================================

local function onDeviceDiscovery(connected, device)
	if connected then
		print("[Stream Deck] Device connected")
		setupDevice(device)
	else
		print("[Stream Deck] Device disconnected")
		engine.cleanup()
		deck = nil
		sdNotify("Stream Deck disconnected")
	end
end

-- ============================================================
-- PUBLIC API
-- ============================================================

--- Re-initialise the Stream Deck (useful after wake / reconnect).
function M.reconnect()
	if deck then
		deck:reset()
	end

	if hs.streamdeck.numDevices() > 0 then
		local device = hs.streamdeck.getDevice(1)
		if device then
			setupDevice(device)
		end
	else
		sdNotify("No Stream Deck found")
	end
end

--- Call once from the root init.lua with a StreamDeckConfig table.
--- @param config StreamDeckConfig
function M.setup(config)
	assert(config, "[Stream Deck] setup() requires a config table")
	assert(config.profiles and #config.profiles > 0, "[Stream Deck] config must have at least one profile")
	sdConfig = config

	hs.streamdeck.init(onDeviceDiscovery)

	-- A device may already be connected when Hammerspoon starts
	if hs.streamdeck.numDevices() > 0 then
		local device = hs.streamdeck.getDevice(1)
		if device then
			setupDevice(device)
		end
	else
		print("[Stream Deck] No device found at startup — waiting for connection…")
	end
end

--- Tear down timers and canvases (called before hs.reload).
function M.cleanup()
	engine.cleanup()
	renderer.cleanup()
end

return M
