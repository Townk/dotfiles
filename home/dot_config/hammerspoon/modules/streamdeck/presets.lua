--- streamdeck/presets.lua
--- Pre-built state providers, actions, and control bundles for Stream Deck
--- configuration. These eliminate the need for inline function() end wrappers
--- in the config for common operations.

local audio = require("audio")
local controls = require("system.controls")
local actions = require("system.actions")
local helpers = require("streamdeck.helpers")
local sdColors = require("streamdeck.renderer").colors
local sdLayers = require("streamdeck.layers")
local apps = require("apps")
local sd = require("streamdeck")

local M = {}

-- ============================================================
-- BUTTONS
-- Pre-defined buttons ready to be passed to the Button
-- class constructor.
-- ============================================================
M.buttons = {
	toggleFocus = {
		state = function()
			return controls.focusMode().active
		end,
		callback = controls.toggleDoNotDisturb,
		layers = {
			sdLayers.image({ on = "bg-frame-red", off = "bg-frame-orange" }),
			sdLayers.svgIcon({ on = "bell-filled-off", off = "bell-filled-on" }, {
				gradient = {
					on = { colors = { { hex = "#c0392b" }, { hex = "#7b0000" }, { hex = "#c0392b" } }, angle = 45 },
					off = {
						colors = { { hex = "#f5c518" }, { hex = "#e67e00" }, { hex = "#e67e00" }, { hex = "#f5c518" } },
						angle = 45,
					},
				},
				offsetY = -10,
			}),
			sdLayers.label({ on = "Focus On", off = "Set focus" }),
		},
	},
	screenshot = {
		callback = function()
			apps.shottrCaptureArea()
		end,
		layers = {
			sdLayers.image("bg-frame-green"),
			sdLayers.svgIcon("screenshot", {
				gradient = { colors = { { hex = "#00AB00" }, { hex = "#006400" }, { hex = "#00AB00" } }, angle = 45 },
				offsetY = -10,
			}),
			sdLayers.label("Screenshot"),
		},
	},
	cycleDefaultAudioInput = {
		state = function()
			local dev = audio.inputs:defaultDevice()
			local deviceName = dev and dev:name() or nil
			if deviceName then
				local name = deviceName:lower()
				if name:find("camera") or name:find("webcam") then
					return { icon = "webcam", name = deviceName }
				end
			end
			return { icon = "mic", name = deviceName or "Unknown input" }
		end,
		callback = actions.cycleInputDevice,
		layers = {
			sdLayers.image("bg-frame-yellow-green"),
			sdLayers.svgIcon(function(dev)
				return dev.icon
			end, {
				gradient = { colors = { { hex = "#FFFE6B" }, { hex = "#54FFB9" } }, angle = 45 },
				offsetY = -10,
			}),
			sdLayers.svgIcon("badge-cycle", { tint = { hex = "#FF5555" }, size = 0.15, offsetY = -25, offsetX = 27 }),
			sdLayers.label(function(dev)
				if #dev.name > 13 then
					return string.sub(dev.name, 1, 12) .. "…"
				end
				return dev.name
			end, { size = 12 }),
		},
	},
	cycleDefaultAudioOutput = {
		state = function()
			local dev = audio.outputs:defaultDevice()
			if not dev then
				return { icon = "audio-out-devices", name = "Unknown out" }
			end
			local audioType = dev:transportType():lower()
			local deviceName = dev:name()
			if audioType == "built-in" then
				return { icon = "audio-out-built-in", name = deviceName or "Built-in" }
			elseif audioType == "displayport" then
				return { icon = "audio-out-tv", name = deviceName or "TV audio" }
			end

			if deviceName then
				local name = deviceName:lower()
				if name:find("headphone") or name:find("airpod") or name:find("beats") then
					return { icon = "audio-out-headphone", name = deviceName }
				elseif name:find("edifier") then
					return { icon = "audio-out-speaker", name = deviceName }
				end
				return { icon = "audio-out-devices", name = deviceName }
			end
			return { icon = "audio-out-devices", name = "Generic out" }
		end,
		callback = actions.cycleOutputDevice,
		layers = {
			sdLayers.image("bg-frame-yellow-green"),
			sdLayers.svgIcon(function(dev)
				return dev.icon
			end, {
				gradient = { colors = { { hex = "#FFFE6B" }, { hex = "#54FFB9" } }, angle = 45 },
				offsetY = -10,
			}),
			sdLayers.svgIcon("badge-cycle", { tint = { hex = "#FF5555" }, size = 0.15, offsetY = -25, offsetX = 27 }),
			sdLayers.label(function(dev)
				if #dev.name > 13 then
					return string.sub(dev.name, 1, 12) .. "…"
				end
				return dev.name
			end, { size = 12 }),
		},
	},
	mediaPreviousTrack = {
		callback = function()
			helpers.sendSystemKey("PREVIOUS")
		end,
		layers = {
			sdLayers.image("bg-frame-lilac"),
			sdLayers.svgIcon("skip-prev", {
				gradient = { colors = { { hex = "#7790ED" }, { hex = "#5D4991" }, { hex = "#7790ED" } }, angle = 45 },
				offsetY = -10,
			}),
			sdLayers.label("Prev"),
		},
	},
	mediaNextTrack = {
		callback = function()
			helpers.sendSystemKey("NEXT")
		end,
		layers = {
			sdLayers.image("bg-frame-lilac"),
			sdLayers.svgIcon("skip-next", {
				gradient = { colors = { { hex = "#7790ED" }, { hex = "#5D4991" }, { hex = "#7790ED" } }, angle = 45 },
				offsetY = -10,
			}),
			sdLayers.label("Next"),
		},
	},
	mediaPlayPause = {
		state = helpers.isMediaPlaying,
		callback = function()
			helpers.sendSystemKey("PLAY")
		end,
		layers = {
			sdLayers.image("bg-frame-lilac"),
			sdLayers.svgIcon({ on = "pause", off = "play" }, {
				gradient = { colors = { { hex = "#7790ED" }, { hex = "#5D4991" }, { hex = "#7790ED" } }, angle = 45 },
				offsetY = -10,
			}),
			sdLayers.label({ on = "Pause", off = "Play" }),
		},
	},
	lockScreen = {
		callback = function()
			hs.caffeinate.lockScreen()
		end,
		layers = {
			sdLayers.image("bg-frame-cyan"),
			sdLayers.svgIcon("lock-person", {
				size = 0.5,
				gradient = { colors = { { hex = "#00BED7" }, { hex = "#015570" }, { hex = "#00BED7" } }, angle = 45 },
				offsetY = -10,
			}),
			sdLayers.label("Lock Screen"),
		},
	},
}

-- ============================================================
-- ENCODERS
-- Pre-defined encoders ready to be passed to one of the
-- Encoder class factory functions.
-- ============================================================
M.encoders = {
	audioOutputVolume = {
		state = function()
			return audio.outputs:defaultDevice()
		end,
		value = controls.outputVolume,
		title = function(dev)
			return dev:name()
		end,
		icon = function(dev)
			return dev:isMuted() and "volume-off" or "volume-up"
		end,
		iconOpts = { tint = sdColors.white },
		status = { min = 0, max = 100 },
		displayValue = function(dev)
			return dev:isMuted() and "Muted" or nil
		end,
		barValue = function(dev)
			return dev:isMuted() and 0 or nil
		end,
		---@diagnostic disable-next-line: unused-local
		callbackInc = function(s, v, sec)
			controls.outputVolumeUp(sec and 2.5 or 10)
		end,
		---@diagnostic disable-next-line: unused-local
		callbackDec = function(s, v, sec)
			controls.outputVolumeDown(sec and 2.5 or 10)
		end,
		callbackPress = controls.toggleOutputMute,
	},
	audioInputVolume = {
		state = function()
			return audio.inputs:defaultDevice()
		end,
		value = controls.inputVolume,
		title = function(dev)
			return dev:name()
		end,
		icon = function(dev)
			return dev:isMuted() and "mic-off" or "mic"
		end,
		iconOpts = { tint = sdColors.white },
		status = { min = 0, max = 100 },
		displayValue = function(dev)
			return dev:isMuted() and "Muted" or nil
		end,
		barValue = function(dev)
			return dev:isMuted() and 0 or nil
		end,
		---@diagnostic disable-next-line: unused-local
		callbackInc = function(s, v, sec)
			controls.inputVolumeUp(sec and 2.5 or 10)
		end,
		---@diagnostic disable-next-line: unused-local
		callbackDec = function(s, v, sec)
			controls.inputVolumeDown(sec and 2.5 or 10)
		end,
		callbackPress = controls.toggleInputMute,
	},
	screenBrightness = {
		value = controls.brightness,
		title = "Screen brightness",
		icon = "light-mode",
		iconOpts = { tint = sdColors.white },
		status = { min = 0, max = 100 },
		---@diagnostic disable-next-line: unused-local
		callbackInc = function(s, v, sec)
			controls.brightnessUp(sec and 2.5 or 10)
		end,
		---@diagnostic disable-next-line: unused-local
		callbackDec = function(s, v, sec)
			controls.brightnessDown(sec and 2.5 or 10)
		end,
		callbackPress = controls.toggleDarkMode,
	},
	streamDeckBrightness = {
		value = sd.deckBrightnessGet,
		title = "Stream Deck",
		icon = "light-mode",
		iconOpts = { tint = sdColors.white },
		status = { min = 0, max = 100 },
		---@diagnostic disable-next-line: unused-local
		callbackInc = function(s, v, sec)
			sd.deckBrightnessInc(sec and 2.5 or 10)
		end,
		---@diagnostic disable-next-line: unused-local
		callbackDec = function(s, v, sec)
			sd.deckBrightnessDec(sec and 2.5 or 10)
		end,
	},
}

return M
