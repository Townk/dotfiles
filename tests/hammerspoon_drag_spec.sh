# Unit-level eventtap probe for the Cmd+drag window mover.
Describe 'Hammerspoon Cmd+drag passthrough'
  probe() {
    HAMMERSPOON_SPEC_ROOT="$PWD" lua <<'LUA'
local root = assert(os.getenv("HAMMERSPOON_SPEC_ROOT"))
package.path = root .. "/home/dot_config/hammerspoon/modules/?.lua;"
  .. root .. "/home/dot_config/hammerspoon/modules/?/init.lua;"
  .. package.path

local frontApp
local callback
local eventTypes = {
  leftMouseDown = 1,
  leftMouseDragged = 2,
  leftMouseUp = 3,
  mouseMoved = 4,
}

hs = {
  application = {
    frontmostApplication = function() return frontApp end,
  },
  eventtap = {
    event = {
      types = eventTypes,
      properties = { eventSourceUserData = 99 },
    },
    new = function(_, cb)
      callback = cb
      return {
        start = function() end,
        stop = function() end,
        isEnabled = function() return true end,
      }
    end,
  },
  printf = function() end,
  window = {
    orderedWindows = function() return {} end,
  },
}

local function app(bundleID, name)
  return {
    bundleID = function() return bundleID end,
    name = function() return name end,
  }
end

local function mouseDown()
  return {
    getProperty = function() return 0 end,
    getType = function() return eventTypes.leftMouseDown end,
    getFlags = function() return { cmd = true } end,
    location = function() return { x = 100, y = 100 } end,
  }
end

local drag = require("windows.drag")
drag.setup({ mods = { "cmd" } })

frontApp = app("com.apple.ScreenSharing", "Screen Sharing")
assert(callback(mouseDown()) == false, "Screen Sharing must receive Cmd+mouseDown")

frontApp = app("com.example.Local", "Local App")
assert(callback(mouseDown()) == true, "local Cmd+mouseDown must remain buffered")

drag.cleanup()
print("ok")
LUA
  }

  It 'yields the complete gesture to Screen Sharing'
    When call probe
    The output should equal "ok"
    The status should be success
  End
End
