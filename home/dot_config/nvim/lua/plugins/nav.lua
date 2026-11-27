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

-- Rex: a smart-splits backend.
--
-- smart-splits v3 ships no multiplexer backends; each is a table it calls
-- when a motion or a resize runs out of nvim windows. Rex is terminal and
-- multiplexer in one and nobody publishes a backend for it, so this file
-- carries one. With it:
--   - a move past nvim's last split goes on into the next Rex pane;
--   - a resize, when the nvim window fills the whole axis (nothing of nvim's
--     own to resize), moves the Rex pane's border instead.
--
-- A Rex pane is one with $REX_BLOCK and no $TMUX — the same
-- precedence the shell side uses, so a tmux started inside a Rex pane is not
-- mistaken for Rex. The CLI lives in $REX_BIN_DIR (Rex exports it into every
-- pane; the Mac app keeps the binary inside its bundle, off the login PATH).
--
-- The Rex half is in ~/.config/rex/init.lua: its Ctrl(+Shift)+h/j/k/l and
-- arrow binds pass the key to nvim when nvim is in the pane and act
-- themselves otherwise, and its `pane_resize_by` action is what `resize`
-- below calls — one resize behaviour for a shell pane and an nvim pane.
local M = {}

-- Cells per resize step. Rex's own resize keys use the same number
-- (RESIZE_STEP in init.lua), so a step is a step whichever side handles it.
M.RESIZE_STEP = 2

function M.in_rex()
  return (vim.env.REX_BLOCK or "") ~= ""
    and (vim.env.TMUX or "") == ""
end

function M.rex_bin()
  local dir = vim.env.REX_BIN_DIR
  if dir and dir ~= "" and vim.fn.executable(dir .. "/rex") == 1 then
    return dir .. "/rex"
  end
  return "rex"
end

-- Fire and forget: a blocked keypress is worse than a missed motion, and a
-- missing neighbour or border is not an error worth a message.
local function rex(...)
  local cmd = { M.rex_bin(), "--autostart=false", ... }
  if (vim.env.REX_SESSION or "") ~= "" then
    vim.list_extend(cmd, { "-s", vim.env.REX_SESSION })
  end
  pcall(vim.system, cmd, { detach = true })
  return true
end

M.rex_backend = {
  name = "rex",
  protocol_version = "^3.0.0",
  detect = M.in_rex,
  move = function(direction)
    return rex("focus", direction)
  end,
  resize = function(direction, opts)
    local cells = opts and opts.amount or M.RESIZE_STEP
    return rex("do", "pane_resize_by", "-b", vim.env.REX_BLOCK, "direction=" .. direction, "cells=" .. cells)
  end,
}

return {
  {
    "mrjones2014/smart-splits.nvim",
    opts = {
      resize = { amount = M.RESIZE_STEP },
      -- Outside Rex no backend detects, which is the normal case there, not
      -- something to warn about on every start.
      mux = { backend = M.rex_backend, warn_if_unusable = false },
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
