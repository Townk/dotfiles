local M = {}

-- ============================================================
-- ICON LOADING (Material SVGs with canvas-drawn fallbacks)
-- ============================================================

local ICON_DIR = hs.configdir .. "/Assets/icons/svg"

local iconCache = {}

--- @param name string The icon name to return
--- @return hs.image|nil
function M.getIcon(name)
  local icon = iconCache[name]
  if icon == nil then
    icon = hs.image.imageFromPath(ICON_DIR .. "/" .. name .. ".svg")
    if icon ~= nil then
      iconCache[name] = icon
    end
  end
  return icon
end

--- Remove all images previously loaded from cache.
--- Note that this won't free images that are being held by other piece of
--- code.
function M.clearCache()
  iconCache = {}
end

return M
