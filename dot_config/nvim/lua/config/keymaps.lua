--------------------------------------------------------------------------------
-- Custom Keybindings
--------------------------------------------------------------------------------
-- These keymaps are loaded on VeryLazy event (after UI is ready). LazyVim
-- provides extensive default keybindings (link below), and these are our
-- custom additions/overrides that improve specific workflows.
--
-- Default LazyVim keymaps:
--   https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/keymaps.lua
--
-- Design philosophy:
--   - Swap frequently-used keys to reduce keystrokes (`;` for command mode)
--   - Extend `g` prefix for navigation/selection operations
--   - Add Ctrl+; shortcuts for quick Lua command entry
--------------------------------------------------------------------------------

-- Swap `;` and `:` for faster command palette access
-- WHY: `;` is easier to type than Shift+: for entering Ex commands, which
-- happens dozens of times per session. The original `;` (repeat f/t/F/T)
-- is reassigned to `:` since it's used less frequently.
-- WHEN: Use `;w` instead of `:w`, `;Lazy` instead of `:Lazy`, etc.
vim.keymap.set({'n', 'v', 'o'}, ';', ':', { desc = 'Command palette' })
vim.keymap.set({'n', 'v', 'o'}, ':', ';', { desc = 'Next ftFT' })

-- Quick Lua command entry (Ctrl+; opens :lua prompt)
-- WHY: For quick one-off Lua commands without typing `:lua ` each time
-- WHEN: Use `Ctrl+;` then type Lua code like `vim.inspect(some_var)`
vim.api.nvim_set_keymap('n', '<C-;>', ':lua<Space>', { noremap = true })

-- Quick Lua eval mode (Ctrl+Alt+; opens := prompt)
-- WHY: The `:=` command evaluates and prints Lua expressions, useful for
-- debugging or inspecting values. This shortcut saves typing `:=`.
-- WHEN: Use `Ctrl+Alt+;` then type expression like `vim.bo.filetype`
vim.api.nvim_set_keymap('n', '<C-A-;>', ':=', { noremap = true })

-- Reselect last paste or change region (like `gv` but for paste/change)
-- WHY: Standard NeoVim has `gv` to reselect the last visual selection, but
-- there's no built-in way to reselect what you just pasted or changed. This
-- keymap fills that gap using the `[` and `]` marks (which track the last
-- change/paste boundaries).
-- WHEN: After pasting text, use `gV` to visually select what was just pasted
-- for further editing (indent, surround, delete, etc.)
-- HOW IT WORKS: Uses marks `[` (start) and `]` (end) + register type to
-- reconstruct the appropriate visual mode (char/line/block)
vim.keymap.set("n", "gV", function()
  vim.api.nvim_feedkeys("`[" .. vim.fn.strpart(vim.fn.getregtype(), 0, 1) .. "`]", "n", false)
end, { desc = "Select last paste/change" })

-- Jump to the start of the current treesitter context (sticky scroll region)
-- WHY: treesitter-context shows the containing function/class at the top of
-- the screen when you're deep in a nested structure. This keymap jumps the
-- cursor to the actual start of that context (the function definition line).
-- WHEN: When you see a function name in the sticky header and want to jump
-- to its definition line to see parameters or add documentation.
-- EXAMPLE: If editing line 150 inside a function and the sticky header shows
-- "function process_data()", press `gX` to jump to the actual function line.
vim.keymap.set("n", "gX", function()
  require("treesitter-context").go_to_context(vim.v.count1)
end, { silent = true, desc = "Go to start of context" })
