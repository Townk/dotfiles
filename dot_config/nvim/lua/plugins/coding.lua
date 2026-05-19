--------------------------------------------------------------------------------
-- Development Tools and Language Support
--------------------------------------------------------------------------------
-- This file configures plugins for coding productivity:
--   - lazydev.nvim: Lua development with NeoVim API documentation
--   - nvim-lspconfig: Language Server Protocol configurations
--   - nvim-dap: Debug Adapter Protocol (debugging support)
--   - nvim-dap-python: Python debugging integration
--   - nvim-treesitter: Syntax parsing and highlighting
--   - mason.nvim: LSP/tool installer
--   - conform.nvim: Code formatting
--   - blink.cmp: Completion engine with smart behavior
--   - nvim-autopairs: Auto-close brackets/quotes
--   - yanky.nvim: Clipboard/yank history management
--
-- The most complex configuration here is blink.cmp's smart actions which
-- provide intelligent tab behavior and session state tracking.
--------------------------------------------------------------------------------

return {
  {
    "folke/lazydev.nvim",
    ft = "lua",
    dependencies = {
      {
        "DrKJeff16/wezterm-types",
        lazy = true,
        version = false,
      },
    },
    opts = {
      library = {
        "vim",
        { path = "${3rd}/luv/library", words = { "vim%.uv" } },
        { path = "LazyVim", words = { "LazyVim" } },
        { path = "snacks.nvim", words = { "Snacks" } },
        { path = "lazy.nvim", words = { "LazyVim" } },
        { path = "wezterm-types", mods = { "wezterm" } },
        -- EmmyLua annotations for Hammerspoon - load always for proper type checking
        -- Using mods instead of words ensures globals are available immediately
        {
          path = vim.env.HOME .. "/.config/hammerspoon/Spoons/EmmyLua.spoon/annotations",
          mods = { "hs", "spoon" },
        },
      },
    },
  },

  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        tinymist = {
          settings = {
            formatterMode = "typstyle",
          },
        },
        basedpyright = {
          settings = {
            basedpyright = {
              disableOrganizeImports = true,
            },
          },
        },
        ruff = {
          keys = {
            { "<leader>ci", LazyVim.lsp.action["source.organizeImports"], desc = "Organize Imports" },
          },
        },
        lua_ls = {
          settings = {
            Lua = {
              diagnostics = {
                globals = { "vim", "hs", "spoon" },
              },
              workspace = {
                checkThirdParty = false,
                -- Ensure EmmyLua annotations are preloaded for Hammerspoon files
                library = {
                  vim.env.HOME .. "/.config/hammerspoon/Spoons/EmmyLua.spoon/annotations",
                },
                -- Increase preload limits for large annotation libraries
                preloadFileSize = 1000,
                maxPreload = 2000,
              },
            },
          },
        },
      },
    },
  },

  {
    "mfussenegger/nvim-dap",
    opts = function()
      local dap = require("dap")

      dap.listeners.after.event_initialized["dap_keymaps"] = function()
        vim.keymap.set("n", "<F5>", dap.continue, { desc = "Debug: Continue", buffer = true })
        vim.keymap.set("n", "<S-F5>", dap.run_to_cursor, { desc = "Debug: Run to cursor", buffer = true })
        vim.keymap.set("n", "<F6>", dap.step_out, { desc = "Debug: Step Out", buffer = true })
        vim.keymap.set("n", "<F7>", dap.step_into, { desc = "Debug: Step Into", buffer = true })
        vim.keymap.set("n", "<F8>", dap.step_over, { desc = "Debug: Step Over", buffer = true })
      end

      local function cleanup_keymaps()
        pcall(vim.keymap.del, "n", "<F5>", { buffer = true })
        pcall(vim.keymap.del, "n", "<S-F5>", { buffer = true })
        pcall(vim.keymap.del, "n", "<F6>", { buffer = true })
        pcall(vim.keymap.del, "n", "<F7>", { buffer = true })
        pcall(vim.keymap.del, "n", "<F8>", { buffer = true })
      end

      dap.listeners.before.event_terminated["dap_keymaps"] = cleanup_keymaps
      dap.listeners.before.event_exited["dap_keymaps"] = cleanup_keymaps
    end,
  },

  {
    "mfussenegger/nvim-dap-python",
    config = function()
      require("dap-python").setup("uv")
    end,
  },

  {
    "nvim-treesitter/nvim-treesitter",
    opts = {
      ensure_installed = {
        "bash",
        "gotmpl",
        "html",
        "javascript",
        "json",
        "lua",
        "markdown",
        "markdown_inline",
        "python",
        "query",
        "regex",
        "toml",
        "tsx",
        "typescript",
        "vim",
        "yaml",
      },
    },
  },

  {
    "WhoIsSethDaniel/mason-tool-installer.nvim",
    dependencies = { "mason-org/mason.nvim" },
    config = function()
      require("mason-tool-installer").setup({
        run_on_start = false,
        ensure_installed = {
          "basedpyright",
          "bash-language-server",
          "biome",
          "clangd",
          "cmakelang",
          "cmakelint",
          "codelldb",
          "debugpy",
          "delve",
          "flake8",
          "gofumpt",
          "goimports",
          "golangci-lint",
          "gopls",
          "java-debug-adapter",
          "java-test",
          "jdtls",
          "js-debug-adapter",
          "json-lsp",
          "just-lsp",
          "kotlin-debug-adapter",
          "kotlin-language-server",
          "kotlin-lsp",
          "ktfmt",
          "ktlint",
          "lua-language-server",
          "markdown-toc",
          "markdownlint-cli2",
          "marksman",
          "neocmakelsp",
          "prettierd",
          "ruff",
          "shellcheck",
          "shfmt",
          "stylua",
          "taplo",
          "tinymist",
          "vtsls",
          "yaml-language-server",
        },
      })
    end,
  },

  {
    "stevearc/conform.nvim",
    opts = {
      log_level = vim.log.levels.DEBUG,
      formatters_by_ft = {
        kotlin = { "ktfmt" },
        json = { "biome" },
        jsonc = { "biome" },
        -- Swap LazyVim's `prettier` for `prettierd` (daemon mode, ~10x faster
        -- startup). markdownlint-cli2 / markdown-toc still run after, gated by
        -- their own conditions.
        markdown = { "prettierd", "markdownlint-cli2", "markdown-toc" },
        ["markdown.mdx"] = { "prettierd", "markdownlint-cli2", "markdown-toc" },
      },
      formatters = {
        ktfmt = {
          prepend_args = { "--kotlinlang-style" },
        },
        -- prettierd's CLI parses argv as `<filename> [prettier-options...]`,
        -- so flags MUST come after $FILENAME. `prepend_args` would put them
        -- before and prettierd would treat the flag itself as the filename.
        -- Editorconfig's `max_line_length` already maps to `printWidth`; we
        -- only need to flip prose-wrap from its default `preserve` to
        -- `always` so paragraphs actually re-flow.
        prettierd = {
          args = { "$FILENAME", "--prose-wrap=always" },
        },
      },
    },
  },

  --------------------------------------------------------------------------------
  -- Blink.cmp: Intelligent Completion Engine
  --------------------------------------------------------------------------------
  -- WHY: blink.cmp is faster than nvim-cmp and has better snippet integration.
  -- The custom smart_actions provide enhanced UX:
  --
  -- Session Tracking:
  --   Tracks whether you're cycling through completions (last_direction).
  --   This allows Escape to cancel only after you've started navigating,
  --   otherwise it falls through to normal mode behavior.
  --
  -- Smart Tab Behavior:
  --   1. If only one completion -> auto-accept it
  --   2. If there's an exact snippet match -> accept that snippet
  --   3. Otherwise -> insert next completion (start cycling)
  --
  -- This makes Tab "do what you mean" instead of requiring multiple keys.
  --------------------------------------------------------------------------------
  {
    "saghen/blink.cmp",
    build = function()
      -- blink.cmp.build() shells out to bare `cargo build --release`, which
      -- otherwise resolves through mise shims to whatever rust toolchain the
      -- current project pins. Recreate `mise exec rust@nightly`: prepend the
      -- nightly install dir to bypass shims, then pin rustup to nightly.
      local nightly = vim.fn.trim(vim.fn.system({ "mise", "where", "rust@nightly" }))
      if vim.v.shell_error == 0 and nightly ~= "" then
        vim.env.PATH = nightly .. ":" .. vim.env.PATH
      end
      vim.env.RUSTUP_TOOLCHAIN = "nightly"
      require("blink.cmp").build():wait(60000)
    end,
    -- blink.cmp v2 (main branch, enabled via vim.g.lazyvim_blink_main) requires
    -- blink.lib as a separate plugin. LazyVim's extra doesn't declare it yet.
    dependencies = { "saghen/blink.lib" },
    opts = function(_, opts)
      -- Session state: tracks if user is actively navigating completions
      local session = { last_direction = nil }

      -- Reset session state when completion menu opens/closes
      vim.api.nvim_create_autocmd("User", {
        group = vim.api.nvim_create_augroup("BlinkCmpConfigInternal", { clear = true }),
        pattern = { "BlinkCmpMenuOpen", "BlinkCmpMenuClosed" },
        callback = function()
          session.last_direction = nil
        end,
      })

      local smart_actions = {}

      -- Smart Escape: only cancel if actively navigating, else fall through
      smart_actions.escape = function(cmp)
        if session.last_direction then
          return cmp.cancel()
        end
      end

      -- Smart Tab: auto-accept single items, prefer snippets, else cycle
      smart_actions.tab = function(cmp)
        if not cmp.snippet_active() then
          local col = vim.api.nvim_win_get_cursor(0)[2]
          local line = vim.api.nvim_get_current_line()
          local text_before = line:sub(1, col):match("(%S+)$") or ""
          local items = require("blink.cmp.completion.list").items or {}

          -- If only one completion available, auto-accept it
          if #items == 1 then
            return cmp.accept({ index = 1 })
          end

          -- Check if there's an exact snippet match for what was typed
          -- WHY: Prefer snippets over regular completions for better expansion
          local snippet_type = require("blink.cmp.types").CompletionItemKind.Snippet
          local snippet_idx = nil
          for idx, item in ipairs(items) do
            if item.label == text_before and item.kind == snippet_type then
              snippet_idx = idx
              break
            end
          end

          if snippet_idx ~= nil then
            return cmp.accept({ index = snippet_idx })
          end

          -- No exact match, start cycling through completions
          session.last_direction = "next"
          return cmp.insert_next()
        end
      end

      -- Smart Shift+Tab: cycle backwards through completions
      smart_actions.backtab = function(cmp)
        if not cmp.snippet_active() then
          session.last_direction = "prev"
          return cmp.insert_prev()
        end
      end

      return vim.tbl_deep_extend("force", opts, {
        completion = {
          list = {
            selection = {
              preselect = false,
              auto_insert = false,
            },
          },
          trigger = {
            show_in_snippet = false,
          },
        },
        keymap = {
          preset = "none",
          ["<C-space>"] = { "show", "show_documentation", "hide_documentation" },
          ["<CR>"] = { "accept", "fallback" },
          ["<C-y>"] = { "accept", "fallback" },
          ["<Esc>"] = { smart_actions.escape, "fallback" },
          ["<C-e>"] = { "cancel", "fallback" },
          ["<C-c>"] = { "cancel", "fallback" },
          ["<Up>"] = { "select_prev", "fallback" },
          ["<C-p>"] = { "select_prev", "fallback_to_mappings" },
          ["<Down>"] = { "select_next", "fallback" },
          ["<C-n>"] = { "select_next", "fallback_to_mappings" },
          ["<Tab>"] = { smart_actions.tab, "snippet_forward", "fallback" },
          ["<S-Tab>"] = { smart_actions.backtab, "snippet_backward", "fallback" },
          ["<C-b>"] = { "scroll_documentation_up", "fallback" },
          ["<C-f>"] = { "scroll_documentation_down", "fallback" },
          ["<C-k>"] = { "show_signature", "hide_signature", "fallback" },
        },
        cmdline = {
          enabled = true,
          keymap = {
            preset = "cmdline",
            ["<Down>"] = { "select_next", "fallback" },
            ["<Up>"] = {
              function(cmp)
                if require("blink.cmp.completion.list").selected_item_idx ~= nil then
                  return cmp.select_prev()
                end
              end,
              "fallback",
            },
          },
        },
      })
    end,
  },

  {
    "windwp/nvim-autopairs",
    event = "InsertEnter",
    opts = {},
  },

  {
    "gbprod/yanky.nvim",
    keys = {
      { "p", "<Plug>(YankyPutAfter)", mode = { "n" }, desc = "Put Text After Cursor" },
      { "P", "<Plug>(YankyPutAfter)", mode = { "x" }, desc = "Put Text After Cursor" },
      { "P", "<Plug>(YankyPutBefore)", mode = { "n" }, desc = "Put Text Before Cursor" },
      { "p", "<Plug>(YankyPutBefore)", mode = { "x" }, desc = "Put Text Before Cursor" },
      { "gp", "<Plug>(YankyGPutAfter)", mode = { "n" }, desc = "Put Text After Selection" },
      { "gP", "<Plug>(YankyGPutAfter)", mode = { "x" }, desc = "Put Text After Selection" },
      { "gP", "<Plug>(YankyGPutBefore)", mode = { "n" }, desc = "Put Text Before Selection" },
      { "gp", "<Plug>(YankyGPutBefore)", mode = { "x" }, desc = "Put Text Before Selection" },
    },
  },
}
