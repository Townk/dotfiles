--------------------------------------------------------------------------------
-- Editor Enhancement Plugins
--------------------------------------------------------------------------------
-- This file configures plugins that enhance the core editing experience:
--   - auto-save: Automatically save files on text change (never lose work)
--   - mini.align: Text alignment helper (gl/gL commands)
--   - mini.move: Move lines/selections with Alt+Arrow keys
--   - treesj: Split/join code blocks intelligently (respects syntax)
--   - coerce: Case conversion (snake_case, camelCase, etc.)
--   - smart-comment-wrap: Auto-wrap comments at custom width
--   - nvim-tcss: Sort Tailwind CSS classes automatically
--
-- These plugins make common editing operations faster and more ergonomic.
--------------------------------------------------------------------------------

return {
  --------------------------------------------------------------------------------
  -- Auto-Save: Never Lose Work
  --------------------------------------------------------------------------------
  -- WHY: Auto-saves on InsertLeave and TextChanged events, ensuring edits are
  -- persisted even if NeoVim crashes or you forget to save. lockmarks = true
  -- preserves mark positions after auto-save (so `'` marks don't jump around).
  --------------------------------------------------------------------------------
  {
    "okuuva/auto-save.nvim",
    version = false,
    cmd = "ASToggle",
    event = { "InsertLeave", "TextChanged" },
    opts = {
      lockmarks = true,  -- Preserve mark positions after auto-save
    },
  },

  --------------------------------------------------------------------------------
  -- Text Alignment: mini.align
  --------------------------------------------------------------------------------
  -- WHY: Quickly align text around delimiters (=, :, |, etc.). The `gl` prefix
  -- keeps it under the `g` (go/goto) namespace which is conventionally used for
  -- navigation and transformation operations.
  -- USAGE: `glip=` aligns paragraph around `=`, `gLip=` shows live preview
  --------------------------------------------------------------------------------
  {
    "nvim-mini/mini.align",
    version = false,
    opts = {
      mappings = {
        start = "gl",  -- Align command
        start_with_preview = "gL",  -- Align with live preview
      },
    },
  },

  {
    "nvim-mini/mini.move",
    event = "VeryLazy",
    keys = {
      { "<A-Left>", [[<Cmd>lua MiniMove.move_selection('left')<CR>]], mode = { "x" }, desc = "Move left" },
      { "<A-Right>", [[<Cmd>lua MiniMove.move_selection('right')<CR>]], mode = { "x" }, desc = "Move right" },
      { "<A-Down>", [[<Cmd>lua MiniMove.move_selection('down')<CR>]], mode = { "x" }, desc = "Move down" },
      { "<A-Up>", [[<Cmd>lua MiniMove.move_selection('up')<CR>]], mode = { "x" }, desc = "Move up" },
      { "<A-Left>", [[<Cmd>lua MiniMove.move_line('left')<CR>]], mode = { "n" }, desc = "Move line left" },
      { "<A-Right>", [[<Cmd>lua MiniMove.move_line('right')<CR>]], mode = { "n" }, desc = "Move line right" },
      { "<A-Down>", [[<Cmd>lua MiniMove.move_line('down')<CR>]], mode = { "n" }, desc = "Move line down" },
      { "<A-Up>", [[<Cmd>lua MiniMove.move_line('up')<CR>]], mode = { "n" }, desc = "Move line up" },
    },
  },

  --------------------------------------------------------------------------------
  -- TreeSJ: Split/Join Code Blocks
  --------------------------------------------------------------------------------
  -- WHY: Intelligently splits single-line code into multi-line format (or vice versa)
  -- while respecting syntax. Much smarter than simple text manipulation.
  -- USAGE: <leader>jm toggles, <leader>jj joins, <leader>js splits
  -- EXAMPLE: `{ foo: 1, bar: 2 }` ↔ `{\n  foo: 1,\n  bar: 2\n}`
  --------------------------------------------------------------------------------
  {
    "Wansmer/treesj",
    dependencies = { "nvim-treesitter/nvim-treesitter" },
    config = function()
      require("treesj").setup({
        use_default_keymaps = false,  -- We define custom keymaps below
      })
      vim.keymap.set("n", "<leader>jm", require("treesj").toggle, { desc = "treesj: Toggle (M)erge/Split" })
      vim.keymap.set("n", "<leader>jj", require("treesj").join, { desc = "treesj: (J)oin" })
      vim.keymap.set("n", "<leader>js", require("treesj").split, { desc = "treesj: (S)plit" })
    end,
  },

  {
    "gregorias/coerce.nvim",
    dependencies = { { "gregorias/coop.nvim" } },
    version = false,
    config = true,
    opts = {
      default_mode_keymap_prefixes = {
        normal_mode = "<leader>co",
        motion_mode = "<leader>cO",
        visual_mode = "<leader>co",
      },
    },
  },

  --------------------------------------------------------------------------------
  -- Smart Comment Wrapping (Local Plugin)
  --------------------------------------------------------------------------------
  -- WHY: Auto-wraps standalone comments at configurable width using treesitter
  -- to detect comment context. Keeps comments readable without manual formatting.
  -- See local-plugins/smart-comment-wrap/lua/smart-comment-wrap/init.lua for details.
  --------------------------------------------------------------------------------
  {
    "smart-comment-wrap",
    dir = vim.fn.stdpath("config") .. "/local-plugins/smart-comment-wrap",
    opts = {},
  },

  --------------------------------------------------------------------------------
  -- Tailwind CSS Class Sorter
  --------------------------------------------------------------------------------
  -- WHY: Automatically sorts Tailwind CSS classes in a consistent order, making
  -- them easier to read and reducing git diffs when classes are reordered.
  --------------------------------------------------------------------------------
  {
    "cachebag/nvim-tcss",
    config = true,
  },

  --------------------------------------------------------------------------------
  -- Render Markdown: Heading & Code-Block Background Width
  --------------------------------------------------------------------------------
  -- WHY: With `width = "block"`, the heading/code background only spans the
  -- rendered text. Short headings (e.g. `# A`) end up with a tiny coloured
  -- stub. `min_width` forces the background to extend to at least the buffer's
  -- &textwidth (set by .editorconfig's `max_line_length` or ftplugin), falling
  -- back to vim.g.comments_width when textwidth is unset.
  --
  -- The plugin's `min_width` is a static integer (no function values), so we
  -- mutate the cached per-buffer config inside `on.attach` — that hook fires
  -- during the FileType event, after editorconfig has applied textwidth.
  --
  -- Quotes and callouts only render a left-bar glyph (▋); the plugin doesn't
  -- support extending their highlight as a block, so they're not configurable
  -- here.
  --------------------------------------------------------------------------------
  {
    "MeanderingProgrammer/render-markdown.nvim",
    opts = {
      heading = {
        width = "block",
      },
      on = {
        attach = function(ctx)
          -- editorconfig's BufRead handler may fire after FileType (after
          -- attach), so reading textwidth synchronously here can be too early.
          -- Schedule lets the current event chain finish first; we also wire
          -- OptionSet so later changes (editorconfig, manual `:set tw=`)
          -- propagate.
          local function sync()
            if not vim.api.nvim_buf_is_valid(ctx.buf) then return end
            local cfg = require("render-markdown.state").cache[ctx.buf]
            if not cfg then return end
            local tw = vim.bo[ctx.buf].textwidth
            local mw = tw > 0 and tw or (vim.g.comments_width or 80)
            cfg.heading.min_width = mw
            cfg.code.min_width = mw
          end
          vim.schedule(sync)
          vim.api.nvim_create_autocmd("OptionSet", {
            pattern = "textwidth",
            callback = function()
              if vim.api.nvim_get_current_buf() == ctx.buf then
                sync()
              end
            end,
          })
        end,
      },
    },
  },
}
