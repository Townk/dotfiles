-- chezmoi-system — nvim colorscheme driven by ~/.config/theme/chezmoi-system.lua (the
-- palette + roles generated from .chezmoidata/theme.yaml). Theme-agnostic: ANY
-- palette that fills the vocabulary drives nvim, with NO catppuccin RUNTIME
-- dependency.
--
-- The highlight-group DEFINITIONS are vendored from catppuccin/nvim (MIT — see
-- lua/chezmoi_theme/ctp/LICENSE) under lua/chezmoi_theme/ctp/. We feed them OUR
-- palette via the injected globals C/O/U, exactly how catppuccin's own compiler
-- invokes its group modules — so we inherit catppuccin's full editor + treesitter
-- + LSP + plugin coverage while staying single-sourced and switchable. Two
-- vendored files were minimally patched to drop `require("catppuccin"...)` (see
-- the inline notes in ctp/groups/integrations/{mini,render_markdown}.lua).
--
-- Reads the palette on every load, so a theme.yaml switch + `chezmoi apply` shows
-- up on the next nvim start (or `:colorscheme chezmoi-system`). Bails if the
-- bridge is missing rather than erroring.

local ok, theme = pcall(dofile, vim.env.HOME .. "/.config/theme/chezmoi-system.lua")
if not ok or type(theme) ~= "table" or not theme.palette then
  return
end

local p = theme.palette
local appearance = (theme.meta and theme.meta.appearance) or "dark"

-- C: catppuccin's color table = our palette slots + the extras it derives.
local C = vim.tbl_extend("force", {}, p)
C.none = "NONE"
C.terminal_black = p.surface1
C.dim = p.mantle

-- U: the subset of catppuccin's color utils the vendored groups use.
local U = { bg = p.base, fg = p.text }
local function hex2rgb(hex)
  hex = hex:gsub("#", "")
  return { tonumber(hex:sub(1, 2), 16), tonumber(hex:sub(3, 4), 16), tonumber(hex:sub(5, 6), 16) }
end
function U.blend(fg, bg, alpha)
  local f, b = hex2rgb(fg), hex2rgb(bg)
  local ch = function(i)
    return math.floor(math.min(math.max(0, alpha * f[i] + (1 - alpha) * b[i]), 255) + 0.5)
  end
  return string.format("#%02X%02X%02X", ch(1), ch(2), ch(3))
end
function U.darken(hex, amount, bg) return U.blend(hex, bg or U.bg, math.abs(amount)) end
function U.lighten(hex, amount, fg) return U.blend(hex, fg or U.fg, math.abs(amount)) end
-- catppuccin uses vary_color to pick a per-flavour variant; we only have an
-- appearance, so honor the `latte` variant on a light theme, else the default.
function U.vary_color(palettes, default)
  if appearance == "light" and palettes.latte ~= nil then
    return palettes.latte
  end
  return default
end

-- O: catppuccin's options — only the fields the vendored groups read, with
-- catppuccin's stock defaults (no transparency; comments/conditionals italic).
local O = {
  transparent_background = false,
  dim_inactive = { enabled = false },
  float = { solid = false, transparent = false },
  styles = {
    comments = { "italic" },
    conditionals = { "italic" },
    loops = {},
    functions = {},
    keywords = {},
    strings = {},
    variables = {},
    numbers = {},
    booleans = {},
    properties = {},
    types = {},
    operators = {},
    miscs = {},
  },
  lsp_styles = {
    virtual_text = {
      errors = { "italic" },
      hints = { "italic" },
      warnings = { "italic" },
      information = { "italic" },
      ok = { "italic" },
    },
    underlines = {
      errors = { "underline" },
      hints = { "underline" },
      warnings = { "underline" },
      information = { "underline" },
      ok = { "underline" },
    },
    inlay_hints = { background = true },
  },
  integrations = {
    blink_cmp = { style = "bordered" },
    gitsigns = { enabled = true, transparent = false },
    illuminate = { enabled = true, lsp = false },
    mini = { enabled = true, indentscope_color = "" },
    navic = { enabled = true, custom_bg = "NONE" },
    snacks = { enabled = true, indent_scope_color = "" },
  },
}

-- Inject as globals, exactly how catppuccin's compiler calls the group modules.
-- Saved/restored around the apply loop below so we don't leak C/O/U into the
-- session's global namespace.
local prevC, prevO, prevU = _G.C, _G.O, _G.U
_G.C, _G.O, _G.U = C, O, U

vim.opt.termguicolors = true
vim.o.background = appearance
vim.cmd("highlight clear")
if vim.fn.exists("syntax_on") == 1 then
  vim.cmd("syntax reset")
end
vim.g.colors_name = "chezmoi-system"

-- catppuccin spec -> nvim_set_hl spec.
local function to_hl(spec)
  if spec.link then
    return { link = spec.link }
  end
  local out = { fg = spec.fg, bg = spec.bg, sp = spec.sp, blend = spec.blend }
  if spec.style then
    for _, s in ipairs(spec.style) do
      out[s] = true
    end
  end
  if out.fg == "NONE" then out.fg = nil end
  if out.bg == "NONE" then out.bg = nil end
  return out
end

local modules = {
  "chezmoi_theme.ctp.groups.editor",
  "chezmoi_theme.ctp.groups.syntax",
  "chezmoi_theme.ctp.groups.treesitter",
  "chezmoi_theme.ctp.groups.lsp",
  "chezmoi_theme.ctp.groups.semantic_tokens",
  "chezmoi_theme.ctp.groups.integrations.blink_cmp",
  "chezmoi_theme.ctp.groups.integrations.snacks",
  "chezmoi_theme.ctp.groups.integrations.which_key",
  "chezmoi_theme.ctp.groups.integrations.gitsigns",
  "chezmoi_theme.ctp.groups.integrations.lsp_trouble",
  "chezmoi_theme.ctp.groups.integrations.noice",
  "chezmoi_theme.ctp.groups.integrations.mini",
  "chezmoi_theme.ctp.groups.integrations.navic",
  "chezmoi_theme.ctp.groups.integrations.render_markdown",
  "chezmoi_theme.ctp.groups.integrations.dap",
  "chezmoi_theme.ctp.groups.integrations.dap_ui",
  "chezmoi_theme.ctp.groups.integrations.mason",
  "chezmoi_theme.ctp.groups.integrations.flash",
  "chezmoi_theme.ctp.groups.integrations.illuminate",
  "chezmoi_theme.ctp.groups.integrations.treesitter_context",
}

local set = vim.api.nvim_set_hl
for _, mod in ipairs(modules) do
  local mok, m = pcall(require, mod)
  if mok and type(m) == "table" and type(m.get) == "function" then
    local gok, groups = pcall(m.get)
    if gok and type(groups) == "table" then
      for name, spec in pairs(groups) do
        pcall(set, 0, name, to_hl(spec))
      end
    end
  end
end

-- Restore any prior globals (don't pollute the session namespace).
_G.C, _G.O, _G.U = prevC, prevO, prevU

-- :terminal colors from roles.ansi.
local an = (theme.roles and theme.roles.ansi) or {}
local ansi = {
  an.black, an.red, an.green, an.yellow, an.blue, an.magenta, an.cyan, an.white,
  an.bright_black, an.bright_red, an.bright_green, an.bright_yellow,
  an.bright_blue, an.bright_magenta, an.bright_cyan, an.bright_white,
}
for i = 0, 15 do
  if ansi[i + 1] then
    vim.g["terminal_color_" .. i] = ansi[i + 1]
  end
end
