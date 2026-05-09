--------------------------------------------------------------------------------
-- Window/Pane Navigation
--------------------------------------------------------------------------------
-- This file configures smart-splits for seamless navigation between:
--   - NeoVim windows/splits
--   - Tmux panes (when running inside tmux)
--
-- WHY: Provides unified navigation with Ctrl+hjkl (or Ctrl+Arrows) that works
-- across both NeoVim splits and tmux panes, eliminating the mental context
-- switch between different navigation systems.
--
-- The keymaps work in both normal and terminal mode, so you can navigate even
-- from within a :terminal buffer.
--------------------------------------------------------------------------------

return {
  {
    "mrjones2014/smart-splits.nvim",
    keys = {
      {
        "<C-h>",
        function()
          require("smart-splits").move_cursor_left()
        end,
        mode = { "n", "t" },
        desc = "Move cursor to the panel on the left",
      },
      {
        "<C-j>",
        function()
          require("smart-splits").move_cursor_down()
        end,
        mode = { "n", "t" },
        desc = "Move cursor to the panel below",
      },
      {
        "<C-k>",
        function()
          require("smart-splits").move_cursor_up()
        end,
        mode = { "n", "t" },
        desc = "Move cursor to the panel above",
      },
      {
        "<C-l>",
        function()
          require("smart-splits").move_cursor_right()
        end,
        mode = { "n", "t" },
        desc = "Move cursor to the panel on the right",
      },
      {
        "<C-Left>",
        function()
          require("smart-splits").move_cursor_left()
        end,
        mode = { "n", "t" },
        desc = "Move cursor to the panel on the left",
      },
      {
        "<C-Down>",
        function()
          require("smart-splits").move_cursor_down()
        end,
        mode = { "n", "t" },
        desc = "Move cursor to the panel below",
      },
      {
        "<C-Up>",
        function()
          require("smart-splits").move_cursor_up()
        end,
        mode = { "n", "t" },
        desc = "Move cursor to the panel above",
      },
      {
        "<C-Right>",
        function()
          require("smart-splits").move_cursor_right()
        end,
        mode = { "n", "t" },
        desc = "Move cursor to the panel on the right",
      },
      {
        "<C-S-h>",
        function()
          require("smart-splits").resize_left()
        end,
        mode = { "n", "t" },
        desc = "Resize panels to the left",
      },
      {
        "<C-S-j>",
        function()
          require("smart-splits").resize_down()
        end,
        mode = { "n", "t" },
        desc = "Resize panels doward",
      },
      {
        "<C-S-k>",
        function()
          require("smart-splits").resize_up()
        end,
        mode = { "n", "t" },
        desc = "Resize panels upward",
      },
      {
        "<C-S-l>",
        function()
          require("smart-splits").resize_right()
        end,
        mode = { "n", "t" },
        desc = "Resize panels to the right",
      },
      {
        "<C-S-Left>",
        function()
          require("smart-splits").resize_left()
        end,
        mode = { "n", "t" },
        desc = "Resize panels to the left",
      },
      {
        "<C-S-Down>",
        function()
          require("smart-splits").resize_down()
        end,
        mode = { "n", "t" },
        desc = "Resize panels doward",
      },
      {
        "<C-S-Up>",
        function()
          require("smart-splits").resize_up()
        end,
        mode = { "n", "t" },
        desc = "Resize panels upward",
      },
      {
        "<C-S-Right>",
        function()
          require("smart-splits").resize_right()
        end,
        mode = { "n", "t" },
        desc = "Resize panels to the right",
      },
    },
  },
}
