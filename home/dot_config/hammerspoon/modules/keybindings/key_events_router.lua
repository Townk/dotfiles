--- keybindings/key_events_router.lua
--- Generic key/modifier event routing with optional app scoping.

local M = {}

local eventTypes = hs.eventtap.event.types

local EVENT_NAMES = {
	[eventTypes.keyDown] = "keyDown",
	[eventTypes.flagsChanged] = "modifiersChanged",
}

local WATCHER_EVENT_NAMES = {
	[hs.application.watcher.activated] = "activated",
	[hs.application.watcher.deactivated] = "deactivated",
	[hs.application.watcher.launched] = "launched",
	[hs.application.watcher.terminated] = "terminated",
	[hs.application.watcher.hidden] = "hidden",
	[hs.application.watcher.unhidden] = "unhidden",
}

local state = {
	tap = nil,
	watcher = nil,
	routes = {},
}

local function shallowClone(tbl)
	local copy = {}
	for k, v in pairs(tbl or {}) do
		copy[k] = v
	end
	return copy
end

local function contains(list, value)
	for _, item in ipairs(list or {}) do
		if item == value then
			return true
		end
	end
	return false
end

local function frontmostAppName()
	local app = hs.application.frontmostApplication()
	return app and app:name()
end

local function appMatches(route, appName)
	if not route.app then
		return true
	end

	if type(route.app) == "string" then
		return route.app == appName
	end

	for _, name in ipairs(route.app) do
		if name == appName then
			return true
		end
	end

	return false
end

local function normalizeModifiers(flags)
	return {
		cmd = flags.cmd or false,
		shift = flags.shift or false,
		alt = flags.alt or false,
		ctrl = flags.ctrl or false,
	}
end

local function modifiersMatchExactly(active, required)
	local wanted = {}
	for _, mod in ipairs(required or {}) do
		wanted[string.lower(mod)] = true
	end

	for _, mod in ipairs({ "cmd", "shift", "alt", "ctrl" }) do
		if (active[mod] or false) ~= (wanted[mod] or false) then
			return false
		end
	end

	return true
end

local function restoreState(route)
	for key in pairs(route.state) do
		route.state[key] = nil
	end

	for key, value in pairs(route.initialState) do
		route.state[key] = value
	end
end

local function buildContext(route, event, eventName)
	local keyCode = event:getKeyCode()
	local modifiers = normalizeModifiers(event:getFlags())

	local ctx = {
		event = event,
		eventType = eventName,
		key = hs.keycodes.map[keyCode],
		modifiers = modifiers,
		state = route.state,
	}

	function ctx:appName()
		return frontmostAppName()
	end

	function ctx:keyStroke(stroke)
		hs.eventtap.keyStroke(stroke.modifiers or {}, stroke.key, 0)
	end

	function ctx:resetState()
		restoreState(route)
	end

	return ctx
end

local function predicateMatches(predicate, ctx)
	if not predicate then
		return true
	end

	if type(predicate) == "function" then
		local ok, result = pcall(predicate, ctx)
		if not ok then
			hs.printf("keyEvents: predicate failed: %s", tostring(result))
			return false
		end
		return result == true
	end

	if predicate.state then
		for key, value in pairs(predicate.state) do
			if ctx.state[key] ~= value then
				return false
			end
		end
	end

	if predicate.modifiers then
		for key, value in pairs(predicate.modifiers) do
			if (ctx.modifiers[key] or false) ~= value then
				return false
			end
		end
	end

	return true
end

local function ruleMatches(rule, ctx)
	local match = rule.match or {}

	if match.event and match.event ~= ctx.eventType then
		return false
	end

	if match.key and string.lower(match.key) ~= ctx.key then
		return false
	end

	if ctx.eventType == "keyDown" and not modifiersMatchExactly(ctx.modifiers, match.modifiers or {}) then
		return false
	end

	return predicateMatches(rule.when, ctx)
end

local function runAction(action, ctx)
	if not predicateMatches(action.when, ctx) then
		return nil
	end

	if action.setState then
		for key, value in pairs(action.setState) do
			ctx.state[key] = value
		end
	end

	if action.resetState then
		ctx:resetState()
	end

	if action.keyStroke then
		ctx:keyStroke(action.keyStroke)
	end

	if action.handler then
		local ok, result = pcall(action.handler, ctx)
		if not ok then
			hs.printf("keyEvents: action handler failed: %s", tostring(result))
			return nil
		end
		return result
	end

	return nil
end

local function runRule(rule, ctx)
	if rule.actions then
		for _, action in ipairs(rule.actions) do
			local result = runAction(action, ctx)
			if type(result) == "boolean" then
				return result
			end
		end
	else
		local result = runAction(rule, ctx)
		if type(result) == "boolean" then
			return result
		end
	end

	return rule.swallow == true
end

local function handleEvent(event)
	local eventName = EVENT_NAMES[event:getType()]
	if not eventName then
		return false
	end

	local appName = nil

	for _, route in ipairs(state.routes) do
		if route.app then
			appName = appName or frontmostAppName()
		end

		if appMatches(route, appName) then
			local ctx = buildContext(route, event, eventName)

			for _, rule in ipairs(route.rules) do
				if ruleMatches(rule, ctx) then
					return runRule(rule, ctx)
				end
			end
		end
	end

	return false
end

local function normalizeRoute(route)
	local initialState = shallowClone(route.state)

	return {
		app = route.app,
		name = route.name,
		resetOn = route.resetOn or {},
		rules = route.rules or {},
		initialState = initialState,
		state = shallowClone(initialState),
	}
end

function M.setup(routes)
	M.cleanup()

	for _, route in ipairs(routes or {}) do
		table.insert(state.routes, normalizeRoute(route))
	end

	if #state.routes == 0 then
		return
	end

	state.tap = hs.eventtap.new({
		eventTypes.keyDown,
		eventTypes.flagsChanged,
	}, handleEvent)
	state.tap:start()

	state.watcher = hs.application.watcher.new(function(appName, eventType)
		local eventName = WATCHER_EVENT_NAMES[eventType]
		if not eventName then
			return
		end

		for _, route in ipairs(state.routes) do
			if contains(route.resetOn, eventName) and appMatches(route, appName) then
				restoreState(route)
			end
		end
	end)
	state.watcher:start()
end

function M.cleanup()
	if state.watcher then
		state.watcher:stop()
		state.watcher = nil
	end

	if state.tap then
		state.tap:stop()
		state.tap = nil
	end

	state.routes = {}
end

return M
