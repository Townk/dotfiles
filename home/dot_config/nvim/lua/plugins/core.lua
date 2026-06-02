--------------------------------------------------------------------------------
-- Core UI/UX Plugin Configurations
--------------------------------------------------------------------------------
-- This file configures the essential visual and interactive components:
--   - Colorscheme (Catppuccin Mocha)
--   - Statusline (Lualine with custom doom-modeline theme)
--   - File explorer (Snacks with W3C ARIA-compliant navigation)
--   - Dashboard (Snacks dashboard with custom layout)
--   - Command line UI (Noice with custom formats)
--   - Diagnostics display (Trouble)
--
-- These plugins form the visual foundation of the editor experience.
--------------------------------------------------------------------------------

return {
  --------------------------------------------------------------------------------
  -- Colorscheme: Catppuccin Mocha
  --------------------------------------------------------------------------------
  -- WHY: Warm, soothing palette that reduces eye strain during long sessions.
  -- Mocha variant provides the darkest background for high contrast.
  --------------------------------------------------------------------------------
  {
    "LazyVim/LazyVim",
    dependencies = {
      { "catppuccin/nvim", name = "catppuccin", priority = 1000 },
    },
    opts = {
      colorscheme = "catppuccin-mocha",
    },
  },

  --------------------------------------------------------------------------------
  -- Statusline: Lualine with Custom Doom-Modeline Theme
  --------------------------------------------------------------------------------
  -- WHY: Custom theme in lua/lualine/themes/doom-modeline.lua provides a more
  -- information-dense statusline with dynamic color extraction from the current
  -- colorscheme, custom components for file paths, LSP status, etc.
  --------------------------------------------------------------------------------
  {
    "nvim-lualine/lualine.nvim",
    event = "VeryLazy",
    opts = function(_, opts)
      return vim.tbl_deep_extend("force", opts, require("lualine.themes.doom-modeline"))
    end,
  },

  --------------------------------------------------------------------------------
  -- Diagnostics: Trouble
  --------------------------------------------------------------------------------
  -- WHY: use_diagnostic_signs = true makes Trouble use the same icons as the
  -- sign column, maintaining visual consistency across the interface.
  --------------------------------------------------------------------------------
  {
    "folke/trouble.nvim",
    opts = { use_diagnostic_signs = true },
  },

  {
    "folke/snacks.nvim",
    ---@type snacks.Config
    opts = {
      dashboard = {
        -- your dashboard configuration comes here
        -- or leave it empty to use the default settings
        -- refer to the configuration section below
        width = 60,
        preset = {
          ---@type snacks.dashboard.Item[]
          keys = {
            { icon = " ", key = "f", desc = "Find File", action = ":lua Snacks.dashboard.pick('files')" },
            { icon = "󱏒 ", key = "e", desc = "File Explorer", action = ":lua Snacks.explorer.open()" },
            { icon = " ", key = "r", desc = "Recent Files", action = ":lua Snacks.dashboard.pick('oldfiles')" },
            { icon = " ", key = "s", desc = "Restore Session", section = "session" },
            { icon = "󰒲 ", key = "l", desc = "Lazy", action = ":Lazy" },
            { icon = " ", key = "m", desc = "Mason", action = ":Mason" },
            { icon = " ", key = "x", desc = "Lazy Extras", action = ":LazyExtras" },
            { icon = " ", key = "q", desc = "Quit", action = ":qa" },
          },
          header = [[
███╗   ██╗███████╗ ██████╗ ██╗   ██╗██╗███╗   ███╗
████╗  ██║██╔════╝██╔═══██╗██║   ██║██║████╗ ████║
██╔██╗ ██║█████╗  ██║   ██║██║   ██║██║██╔████╔██║
██║╚██╗██║██╔══╝  ██║   ██║╚██╗ ██╔╝██║██║╚██╔╝██║
██║ ╚████║███████╗╚██████╔╝ ╚████╔╝ ██║██║ ╚═╝ ██║
╚═╝  ╚═══╝╚══════╝ ╚═════╝   ╚═══╝  ╚═╝╚═╝     ╚═╝]],
        },
        sections = {
          { section = "header" },
          {
            pane = 2,
            section = "terminal",
            cmd = "colorscript -e square",
            height = 5,
            padding = 1,
          },
          { section = "keys", gap = 1, padding = 1 },
          { pane = 2, icon = " ", title = "Recent Files", section = "recent_files", indent = 2, padding = 1 },
          { pane = 2, icon = " ", title = "Projects", section = "projects", indent = 2, padding = 1 },
          { section = "startup" },
        },
      },
      picker = {
        win = {
          input = {
            keys = {
              -- Map <Esc> to the "close" action in both normal and insert modes
              ["<Esc>"] = { "close", mode = { "n", "i" } },
              -- Other default keymaps
              ["<C-c>"] = { "cancel", mode = "i" },
            },
          },
        },
        sources = {
          explorer = {
            -- The file tree explorer should automatically close after I select a file to open
            auto_close = true,
            trash = true,
            layout = {
              -- I don't like the search box always visible, so I hide it until I need it
              auto_hide = { "input" },
            },
            actions = {
              --------------------------------------------------------------------------------
              -- ARIA-Compliant Tree Navigation
              --------------------------------------------------------------------------------
              -- WHY: The W3C Web Accessibility Initiative - Accessible Rich Internet
              -- Applications (WAI-ARIA) specification defines standard keyboard navigation
              -- for tree view components. Following this standard makes the file explorer
              -- behave consistently with other accessible tree interfaces users may know.
              --
              -- W3C ARIA Tree View Pattern:
              --   https://www.w3.org/WAI/ARIA/apg/patterns/treeview/
              --   Shortened link used in old comment: https://bit.ly/ARIA-NAV
              --
              -- Standard behavior:
              --   Right Arrow: Expand collapsed node, OR move to first child if expanded
              --   Left Arrow: Collapse expanded node, OR move to parent if collapsed
              --
              -- WHY THIS MATTERS: Users familiar with screen readers or accessible
              -- interfaces will find this navigation pattern intuitive. It also provides
              -- better UX than having right/left only expand/collapse without movement.
              --------------------------------------------------------------------------------

              --- ARIA Right Arrow: Expand node or navigate to first child
              -- If directory is collapsed -> expand it
              -- If directory is already expanded -> move cursor to first child
              aria_right = function(picker, item)
                local Tree = require("snacks.explorer.tree")
                local actions = require("snacks.explorer.actions")
                if not item then
                  return
                end
                local dir = picker:dir()
                if item.dir then
                  if not item.open then
                    Tree:open(dir)
                    actions.update(picker, { target = dir, refresh = true })
                  else
                    vim.cmd("normal! j")
                  end
                end
              end,
              --- ARIA Left Arrow: Collapse node or navigate to parent
              -- If directory is expanded -> collapse it
              -- If directory is collapsed -> move cursor to parent directory
              aria_left = function(picker, item)
                local Tree = require("snacks.explorer.tree")
                local actions = require("snacks.explorer.actions")
                if not item then
                  return
                end
                local dir = picker:dir()
                if item.dir then
                  if not item.open then
                    dir = vim.fs.dirname(dir)
                  else
                    Tree:close(dir)
                  end
                end
                actions.update(picker, { target = dir, refresh = true })
              end,

              --- Close Search: Return focus to file list from search input
              -- WHY: In the explorer, <Esc> should exit search mode but stay in
              -- the explorer (unlike the picker where <Esc> closes everything).
              -- This allows quick search -> escape -> continue navigating workflow.
              close_search = function(picker)
                vim.cmd("stopinsert")
                picker:action("focus_list")
              end,

              --- Toggle Open/Close: Tab key to toggle directory expansion
              -- WHY: Provides a single-key toggle for directories (Tab or Shift+Tab)
              -- which is faster than using right arrow to open, left arrow to close.
              toggle_open_close = function(picker, item)
                local Tree = require("snacks.explorer.tree")
                local actions = require("snacks.explorer.actions")
                if not item then
                  return
                end
                local dir = picker:dir()
                if item.dir then
                  if not item.open then
                    Tree:open(dir)
                  else
                    Tree:close(dir)
                  end
                  actions.update(picker, { target = dir, refresh = true })
                end
              end,

              --- Yank Path: Show selector dialog to choose what path format to copy
              -- WHY: Different workflows need different path formats. This provides
              -- a quick way to copy absolute paths, relative paths, or just filenames.
              yank_path = function(picker, item)
                if not item or not item.file then
                  return
                end

                local PathUtils = require("utils.path")

                local file_path = item.file
                local is_dir = item.dir or false
                local relative_path = vim.fn.fnamemodify(file_path, ":.")
                local absolute_dir = vim.fn.fnamemodify(file_path, ":h")
                local relative_dir = vim.fn.fnamemodify(relative_path, ":h")

                local home = vim.env.HOME or ""
                local home_relative_path = file_path
                local home_relative_dir = absolute_dir
                if file_path:sub(1, #home) == home then
                  home_relative_path = "~" .. file_path:sub(#home + 1)
                  home_relative_dir = "~" .. absolute_dir:sub(#home + 1)
                end

                local options = {
                  { text = "Absolute path", value = file_path },
                  { text = "Relative path", value = relative_path },
                  { text = "Home-relative path", value = home_relative_path },
                  { text = "Absolute dirname", value = absolute_dir },
                  { text = "Relative dirname", value = relative_dir },
                  { text = "Home-relative dirname", value = home_relative_dir },
                }

                if not is_dir then
                  local file_name = vim.fn.fnamemodify(file_path, ":t")
                  local file_name_no_ext = vim.fn.fnamemodify(file_path, ":t:r")
                  table.insert(options, { text = "File name", value = file_name })
                  table.insert(options, { text = "Base name", value = file_name_no_ext })
                else
                  local dir_name = vim.fn.fnamemodify(file_path, ":t")
                  table.insert(options, { text = "Base name", value = dir_name })
                end

                Snacks.picker.pick({
                  source = "yank_selector",
                  items = options,
                  title = " Yank to Clipboard ",
                  layout = "select",
                  format = function(opt)
                    local is_absolute_opt = opt.text:match("^Absolute")
                    local display_value = PathUtils.truncate_path(opt.value, 40, not is_absolute_opt)
                    local display = opt.text .. " (" .. display_value .. ")"
                    return { { display, "SnacksPickerLabel" } }
                  end,
                  confirm = function(selector_picker, selected)
                    selector_picker:close()
                    if selected and selected.value then
                      vim.fn.setreg("+", selected.value)
                      vim.fn.setreg("0", selected.value)
                      vim.fn.setreg('"', selected.value)
                      vim.notify("Yanked: " .. selected.value, vim.log.levels.INFO)
                    end
                  end,
                })
              end,
            },
            win = {
              input = {
                keys = {
                  ["<Esc>"] = { "close_search", mode = "i" },
                },
              },
              list = {
                keys = {
                  -- ARIA-style arrow key navigation:
                  ["<Right>"] = { "aria_right", desc = "Expand or enter directory" },
                  ["l"] = { "aria_right", desc = "Expand or enter directory" },
                  ["<Left>"] = { "aria_left", desc = "Collapse or go to parent" },
                  ["h"] = { "aria_left", desc = "Collapse or go to parent" },
                  ["<S-Space>"] = { "select_and_prev", desc = "Select file and go to previous" },
                  ["<Space>"] = { "select_and_next", desc = "Select file and go to next" },
                  ["<Tab>"] = { "toggle_open_close", desc = "Toggle a directory open or close" },
                  ["<S-Tab>"] = { "toggle_open_close", desc = "Toggle a directory open or close" },
                  ["Y"] = { "yank_path", desc = "Yank path to clipboard" },
                },
              },
            },
          },
        },
      },
    },
  },

  --------------------------------------------------------------------------------
  -- Enhanced Command Line UI: Noice
  --------------------------------------------------------------------------------
  -- WHY: Noice provides a floating command line and message area, making
  -- commands more visible and reducing clutter in the main editor area.
  --
  -- Custom cmdline formats provide visual cues for different command types:
  --   : = Command Palette (Vim commands)
  --   :lua = Lua code execution
  --   := = Lua expression evaluation
  --   :e = File opening
  --
  -- Each format gets a distinct icon and title so you can tell at a glance
  -- what type of command you're entering.
  --------------------------------------------------------------------------------
  {
    "folke/noice.nvim",
    opts = {
      presets = {
        bottom_search = false, -- Don't move search to bottom (keep in cmdline)
        lsp_doc_border = true, -- Add borders to LSP documentation popups
      },
      cmdline = {
        enabled = true,
        format = {
          -- Standard Vim command mode (:w, :Lazy, etc.)
          cmdline = { pattern = "^:", icon = "", title = " Command Palette ", lang = "vim" },
          -- Lua code execution (:lua vim.notify("hello"))
          lua = { pattern = { "^:%s*lua%s+" }, icon = "", lang = "lua" },
          -- Lua expression evaluation (:= vim.bo.filetype)
          lua_eval = { pattern = { "^:%s*lua%s*=%s*", "^:%s*=%s*" }, icon = "", title = " Lua Eval ", lang = "lua" },
          -- File opening (:e ~/.config/nvim/init.lua)
          edit = { pattern = { "^:%s*e%s+" }, icon = "", title = " Open File ", lang = "lua" },
        },
      },
    },
  },

  --------------------------------------------------------------------------------
  -- Disable mini.pairs Auto-Pairing Plugin
  --------------------------------------------------------------------------------
  -- WHY: Using nvim-autopairs instead (configured in coding.lua) which has
  -- better integration with blink.cmp completion and more robust edge case handling.
  --------------------------------------------------------------------------------
  {
    "nvim-mini/mini.pairs",
    enabled = false,
  },

  --------------------------------------------------------------------------------
  -- Enhanced Help Pages
  --------------------------------------------------------------------------------
  -- WHY: Making the docs look good makes my ADHD brain keep focus on the page.
  --------------------------------------------------------------------------------
  {
    "OXY2DEV/helpview.nvim",
    lazy = false,
  },
}
