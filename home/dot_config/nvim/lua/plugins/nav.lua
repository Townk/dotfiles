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

-- Rex: the multiplexer smart-splits has no backend for.
--
-- Under tmux, smart-splits' tmux backend carries a motion past nvim's last
-- split into the next tmux pane. Rex is terminal and multiplexer in one and
-- smart-splits does not know it, so in a Rex pane it sees "no multiplexer"
-- and falls back to `move.at_edge` — by default, wrapping around inside
-- nvim. This is that hook: in a Rex pane, hand the motion to Rex.
--
-- A Rex pane is one with $REX_BLOCK and neither $TMUX nor $ZELLIJ — the same
-- precedence the shell side uses, so a tmux started inside a Rex pane keeps
-- its own backend. The CLI lives in $REX_BIN_DIR (Rex exports it into every
-- pane; the Mac app keeps the binary inside its bundle, off the login PATH).
--
-- The Rex half is in ~/.config/rex/init.lua: its Ctrl+h/j/k/l and
-- Ctrl+arrow binds pass the key to nvim when nvim is in the pane, and move
-- the pane focus themselves otherwise.
local M = {}

function M.in_rex()
  return (vim.env.REX_BLOCK or "") ~= ""
    and (vim.env.TMUX or "") == ""
    and (vim.env.ZELLIJ or "") == ""
end

function M.rex_bin()
  local dir = vim.env.REX_BIN_DIR
  if dir and dir ~= "" and vim.fn.executable(dir .. "/rex") == 1 then
    return dir .. "/rex"
  end
  return "rex"
end

-- smart-splits' `move.at_edge`: called when there is no nvim window further
-- in ctx.direction. Outside Rex this is the default it replaces (wrap).
function M.at_edge(ctx)
  if not M.in_rex() then
    ctx.wrap()
    return
  end
  local cmd = { M.rex_bin(), "--autostart=false", "focus", ctx.direction }
  if (vim.env.REX_SESSION or "") ~= "" then
    vim.list_extend(cmd, { "-s", vim.env.REX_SESSION })
  end
  -- Fire and forget: a missing neighbour is not an error worth a message.
  pcall(vim.system, cmd, { detach = true })
end

return {
  {
    "mrjones2014/smart-splits.nvim",
    opts = {
      move = { at_edge = M.at_edge },
    },
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
