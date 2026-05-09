--------------------------------------------------------------------------------
-- NeoVim Configuration Entry Point
--------------------------------------------------------------------------------
-- This file is the first thing NeoVim loads when it starts. Its sole purpose
-- is to bootstrap the lazy.nvim plugin manager, which then loads everything
-- else (LazyVim base + our custom plugins and configuration).
--
-- The actual configuration is in:
--   - lua/config/lazy.lua     - Plugin manager setup and plugin discovery
--   - lua/config/options.lua  - Vim options and global settings
--   - lua/config/keymaps.lua  - Custom keybindings
--   - lua/config/autocmds.lua - Autocommands
--   - lua/plugins/*.lua       - Plugin specifications
--
-- If you're debugging startup issues, check :Lazy or :messages for errors.
--------------------------------------------------------------------------------

-- Bootstrap lazy.nvim, LazyVim base configuration, and all custom plugins
require("config.lazy")
