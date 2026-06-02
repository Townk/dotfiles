--------------------------------------------------------------------------------
-- lazy.nvim Plugin Manager Bootstrap and Configuration
--------------------------------------------------------------------------------
-- This file sets up lazy.nvim (our plugin manager) and tells it where to find
-- all our plugins. It handles:
--   1. Installing lazy.nvim itself (if not present)
--   2. Loading LazyVim base configuration (provides sensible defaults)
--   3. Discovering and loading all custom plugins from lua/plugins/*.lua
--
-- Plugin Discovery:
--   - LazyVim plugins are auto-imported from lazyvim.plugins
--   - Custom plugins are auto-imported from lua/plugins/*.lua
--   - Each file in lua/plugins/ can return a single plugin spec or an array
--
-- Plugin Loading Strategy:
--   - lazy = false (default): Custom plugins load on startup for reliability
--   - LazyVim plugins use their own lazy-loading rules (events, keys, etc.)
--   - This ensures custom plugins work predictably without lazy-loading bugs
--
-- Performance Settings:
--   - checker.enabled = true: Auto-check for plugin updates in background
--   - checker.notify = false: Don't spam notifications about available updates
--   - Disabled unnecessary built-in plugins (tohtml, tutor) for faster startup
--
-- If plugins aren't loading, check :Lazy for errors or :Lazy sync to update.
--------------------------------------------------------------------------------

local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not (vim.uv or vim.loop).fs_stat(lazypath) then
  local lazyrepo = "https://github.com/folke/lazy.nvim.git"
  local out = vim.fn.system({ "git", "clone", "--filter=blob:none", "--branch=stable", lazyrepo, lazypath })
  if vim.v.shell_error ~= 0 then
    vim.api.nvim_echo({
      { "Failed to clone lazy.nvim:\n", "ErrorMsg" },
      { out, "WarningMsg" },
      { "\nPress any key to exit..." },
    }, true, {})
    vim.fn.getchar()
    os.exit(1)
  end
end
vim.opt.rtp:prepend(lazypath)

require("lazy").setup({
  spec = {
    -- add LazyVim and import its plugins
    { "LazyVim/LazyVim", import = "lazyvim.plugins" },
    -- import/override with your plugins
    { import = "plugins" },
  },
  defaults = {
    -- By default, only LazyVim plugins will be lazy-loaded. Your custom plugins will load during startup.
    -- If you know what you're doing, you can set this to `true` to have all your custom plugins lazy-loaded by default.
    lazy = false,
    -- It's recommended to leave version=false for now, since a lot the plugin that support versioning,
    -- have outdated releases, which may break your Neovim install.
    version = false, -- always use the latest git commit
    -- version = "*", -- try installing the latest stable version for plugins that support semver
  },
  install = { colorscheme = { "tokyonight", "habamax" } },
  checker = {
    enabled = true, -- check for plugin updates periodically
    notify = false, -- notify on update
  }, -- automatically check for plugin updates
  performance = {
    rtp = {
      -- disable some rtp plugins
      disabled_plugins = {
        -- "gzip",
        -- "matchit",
        -- "matchparen",
        -- "netrwPlugin",
        -- "tarPlugin",
        "tohtml",
        "tutor",
        -- "zipPlugin",
      },
    },
  },
})
