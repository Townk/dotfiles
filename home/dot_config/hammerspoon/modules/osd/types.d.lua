---@meta
--- osd/types.d.lua
--- Type definitions for the OSD module.

--- Direction hint for structured icon tables.
--- @alias OsdDirection "up"|"down"

--- Structured icon table with directional variants.
--- Provides different icons based on whether the value is increasing,
--- decreasing, or at zero. Use `static` for a single icon at all levels
--- above zero (mutually exclusive with `up`/`down`).
--- @class OsdStructuredIcons
--- @field up     hs.image|string|nil  Shown when direction is "up" (or as fallback)
--- @field down   hs.image|string|nil  Shown when direction is "down"
--- @field off    hs.image|string|nil  Shown when percent <= 0
--- @field static hs.image|string|nil  Shown for all percent > 0 (overrides up/down)

--- All accepted icon formats for `osd.show()`.
---
---  - `hs.image`           — single icon used at all levels
---  - `hs.image[]`         — plain list; picks icon by percentage (evenly divided)
---  - `OsdStructuredIcons`  — directional variants (up/down/off/static)
---  - `nil`                — no icon (text-only mode)
--- @alias OsdIconSpec hs.image|string|hs.image[]|string[]|OsdStructuredIcons
