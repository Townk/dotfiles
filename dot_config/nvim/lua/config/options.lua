--------------------------------------------------------------------------------
-- Global Options and Feature Toggles
--------------------------------------------------------------------------------
-- These options are loaded before lazy.nvim startup, so they affect plugin
-- initialization. LazyVim provides sensible defaults (see link below), and
-- we override specific options here.
--
-- Default LazyVim options:
--   https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/options.lua
--
-- WHY each option is set:
--------------------------------------------------------------------------------

-- Disable auto-formatting on save (prefer manual formatting with <leader>cf)
-- WHY: Gives explicit control over when code is reformatted, avoiding unwanted
-- changes during rapid editing or when working with poorly-formatted codebases
vim.g.autoformat = false

-- Disable Snacks.nvim animations (dashboard, notifications, etc.)
-- WHY: Animations add visual delay and can cause flicker on some terminals.
-- Disabling improves perceived responsiveness and reduces visual noise.
vim.g.snacks_animate = false

-- Use blink.cmp as the main completion engine instead of nvim-cmp
-- WHY: blink.cmp is faster and has better snippet integration. This tells
-- LazyVim to configure blink.cmp properly instead of nvim-cmp.
vim.g.lazyvim_blink_main = true

-- Disable mini.pairs auto-pairing plugin (use nvim-autopairs instead)
-- WHY: nvim-autopairs has more robust behavior with certain edge cases and
-- better integration with blink.cmp's completion flow.
vim.g.minipairs_disable = true

-- Default comment-wrap width for the smart-comment-wrap local plugin
-- WHY: Without this, the plugin only activates when `comments_width` is set
-- via .editorconfig. Setting a global default makes auto-wrap work for any
-- file; per-project .editorconfig values still override it.
vim.g.comments_width = 80

-- Set Python LSP to basedpyright (instead of pyright)
-- WHY: basedpyright is a faster, more actively maintained fork of pyright
-- with better type inference and fewer false positives.
vim.g.lazyvim_python_lsp = "basedpyright"

-- Set Python linter/formatter to ruff (instead of pylint/black)
-- WHY: ruff is 10-100x faster than traditional Python tools and combines
-- linting + formatting in one tool, simplifying the toolchain.
vim.g.lazyvim_python_ruff = "ruff"

-- Define the paths to add. Adjust the Homebrew path if necessary (e.g., to /usr/local/bin for Intel Macs).
local homebrew_bin = "/opt/homebrew/bin"
-- The default mise shims directory.
local mise_shims = vim.env.HOME .. "/.local/share/mise/shims"

-- Function to add a path to the environment PATH variable if it's not already present
local function add_to_path(path_to_add)
    -- Get the current PATH value
    local current_path = vim.env.PATH or ""

    -- Check if the path is already in the PATH string (handles both Windows and Unix path separators)
    if not string.find(current_path, path_to_add, 1, true) then
        -- Prepend the new path to prioritize Homebrew/mise binaries
        vim.env.PATH = path_to_add .. ":" .. current_path
    end
end

-- Add the specific paths
add_to_path(homebrew_bin)
add_to_path(mise_shims)

