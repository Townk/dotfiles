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

-- Convert textual Unicode code-point escapes into the glyphs they represent
-- WHY: Source/data files sometimes encode characters as escapes like
-- `\u{1F600}`. This rewrites them in place to the actual glyph (😀) without
-- leaving normal/visual mode and without touching the search register.
-- WHEN:
--   - Normal mode: place the cursor anywhere on an escape token and press
--     `<leader>cu` to convert just that token.
--   - Visual mode: select one or more tokens (charwise, linewise, or blockwise
--     `Ctrl+V`) and press `<leader>cu` to convert every fully-selected match.
-- FORMATS: `\u{HEX}` and `U+HEX` are variable length; `\uHEX` is the JS/Java
-- style and is bound to exactly 4 hex digits (so `\u1F600` is not ambiguous).
-- The recognized formats live in `utils.unicode`, shared with the inline hint
-- feature in autocmds.lua so both stay in sync.
do
  local unicode = require("utils.unicode")

  local function convert_under_cursor()
    local row, col = unpack(vim.api.nvim_win_get_cursor(0)) -- col is 0-indexed byte
    local line = vim.api.nvim_get_current_line()
    unicode.each_match(line, function(start, stop, hex)
      -- `start`/`stop` are 0-indexed byte offsets (stop is exclusive); the
      -- token under the cursor occupies columns [start, stop - 1]
      if col >= start and col <= stop - 1 then
        vim.api.nvim_buf_set_text(0, row - 1, start, row - 1, stop, { unicode.glyph(hex) })
        return
      end
    end)
  end

  local function convert_selection()
    local mode = vim.fn.mode()
    local from, to = vim.fn.getpos("v"), vim.fn.getpos(".")
    local texts = vim.fn.getregion(from, to, { type = mode })
    local regions = vim.fn.getregionpos(from, to, { type = mode })
    if #regions == 0 then
      return
    end
    -- Decode each selected segment, then write all affected lines back in a
    -- single `nvim_buf_set_lines` so the whole conversion is one undo step.
    -- (getregion yields one segment per line for charwise, linewise, and
    -- blockwise selections, so each segment maps to a distinct row.)
    local first_row = regions[1][1][2] - 1
    local last_row = regions[#regions][2][2] - 1
    local lines = vim.api.nvim_buf_get_lines(0, first_row, last_row + 1, false)
    for i, region in ipairs(regions) do
      local sp, ep = region[1], region[2] -- { bufnum, lnum, col, off }, 1-indexed cols
      local idx = sp[2] - first_row -- 1-indexed position within `lines`
      local line = lines[idx]
      lines[idx] = line:sub(1, sp[3] - 1) .. unicode.decode(texts[i]) .. line:sub(ep[3] + 1)
    end
    vim.api.nvim_buf_set_lines(0, first_row, last_row + 1, false, lines)
  end

  vim.keymap.set("n", "<leader>cu", convert_under_cursor, { silent = true, desc = "Convert Unicode escape under cursor to glyph" })
  vim.keymap.set("x", "<leader>cu", convert_selection, { silent = true, desc = "Convert Unicode escapes in selection to glyph" })
end
