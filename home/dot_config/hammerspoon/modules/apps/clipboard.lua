--- apps/clipboard.lua
--- NeoVim-aware clipboard operations and dictionary lookup.
--- Copies the current selection (adapting to NeoVim when focused) and
--- feeds it to a macOS Shortcut for word definition.
---
--- Usage:
---   local clipboard = require("apps.clipboard")
---   clipboard.defineSelection()

local M = {}
local osd = require("osd")

--- Check whether the focused window belongs to a NeoVim instance.
--- @return boolean
--- @private
local function isNeovimFocused()
  local win = hs.window.focusedWindow()
  if not win then return false end
  local title = win:title() or ""
  return title:find("vim") ~= nil
end

--- Copy the current selection to the system clipboard.
--- In NeoVim, sends `"+y` keystrokes to yank to the `+` register;
--- otherwise sends ⌘C.
--- @private
function M.copySelection()
  if isNeovimFocused() then
    -- In NeoVim, send `"+y` to yank the visual selection to the system clipboard.
    hs.eventtap.keyStroke({ "shift" }, "'")  -- "
    hs.eventtap.keyStroke({ "shift" }, "=")  -- +
    hs.eventtap.keyStroke({}, "y")
  else
    hs.eventtap.keyStroke({ "cmd" }, "c")
  end
end

--- Copy the current selection and look it up via the "Word LookUp" macOS Shortcut.
--- Preserves the previous clipboard contents and restores them after copying.
function M.defineSelection()
  local oldClipboard = hs.pasteboard.getContents()
  M.copySelection()

  hs.timer.doAfter(0.2, function()
    local selectedText = hs.pasteboard.getContents()
    -- Restore only when there was something to restore: getContents() returns
    -- nil for non-text clipboards (an image, a file clip), and setContents(nil)
    -- CLEARS the pasteboard — the lookup would wipe the user's last copy.
    if oldClipboard ~= nil then
      hs.pasteboard.setContents(oldClipboard)
    end
    if selectedText and selectedText ~= "" then
      hs.execute("echo '" .. selectedText .. "' | /usr/bin/shortcuts run 'Word LookUp'")
    else
      hs.printf("No text was selected")
    end
  end)
end

--- Copy Google Chrome's active tab URL to the system clipboard.
function M.copyChromeCurrentTabUrl()
  local ok, url = hs.osascript.applescript([[
    tell application "Google Chrome"
      if not (exists front window) then return ""
      return URL of active tab of front window
    end tell
  ]])

  if ok and url and url ~= "" then
    hs.pasteboard.setContents(url)
    osd.notify("glyph:nf-fa-chrome", "URL copied to clipboard", "Frog")
  else
    hs.printf("Chrome active tab URL was not available")
  end
end

return M
