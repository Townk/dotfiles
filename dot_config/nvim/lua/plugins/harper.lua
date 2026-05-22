--------------------------------------------------------------------------------
-- Harper Grammar/Spell Checker
--------------------------------------------------------------------------------
-- Harper is a privacy-friendly, offline grammar + spell checker delivered as an
-- LSP server (`harper-ls`). On supported filetypes it lints prose in markdown
-- and text, plus comments and string literals in source code (via its own
-- tree-sitter parsers). Backtick-wrapped inline code and triple-backtick fenced
-- blocks inside comments/markdown are excluded by Harper's parsers, so code
-- snippets in comments don't trigger spurious diagnostics.
--
-- Docs:
--   https://writewithharper.com/docs/integrations/neovim
--   https://writewithharper.com/docs/integrations/language-server
--
-- Keybindings (added by this spec):
--   <leader>uH   Toggle Harper on/off (Snacks indicator, ON by default)
--   z=           Spelling/grammar fixes (Harper code actions, falls back to
--                native z= when no Harper diagnostic covers the cursor)
--   zg           Add word to Harper's user dictionary if cursor sits on a
--                Harper diagnostic, otherwise native zg (vim spell file)
--------------------------------------------------------------------------------

-- Shared user dictionary: vim's own personal spell file. Both vim's `zg`
-- and harper-ls read/write the same line-separated word list, so adding a
-- word once removes it from BOTH spell engines' flags.
--
-- The chezmoi source file is named `create_en.utf-8.add` (`create_` prefix),
-- meaning chezmoi will only seed this file on a fresh machine — it never
-- overwrites an existing destination. That stops `chezmoi apply --force`
-- (scheduled by the BufWritePost hook in lua/config/autocmds.lua) from
-- silently reverting personal `zg` additions every time you save another
-- config file.
local DICT_PATH = vim.fn.stdpath("config") .. "/spell/en.utf-8.add"

-- Return the Harper diagnostic that covers the cursor's column, or nil. Used
-- by the z= / zg overrides below to decide between LSP code actions and the
-- built-in spell commands. Both `lnum` and `col`/`end_col` from
-- vim.diagnostic.get are 0-based byte positions, hence the -1 adjustments.
local function harper_at_cursor()
  local row = vim.fn.line(".") - 1
  local col = vim.fn.col(".") - 1
  for _, d in ipairs(vim.diagnostic.get(0, { lnum = row })) do
    local src = (d.source or ""):lower()
    if src:find("harper", 1, true) and d.col <= col and col < (d.end_col or d.col + 1) then
      return d
    end
  end
end

return {
  --------------------------------------------------------------------------------
  -- harper-ls LSP configuration
  --------------------------------------------------------------------------------
  -- LazyVim auto-installs any server declared under nvim-lspconfig's
  -- `opts.servers` via mason-lspconfig, so no separate mason-tool-installer
  -- entry is needed.
  -- `filetypes` extends lspconfig's defaults with a few prose-heavy filetypes
  -- that aren't in the upstream list (text, yaml, zsh, plus the compound
  -- `markdown.gotmpl` used by chezmoi markdown templates).
  --
  -- `diagnosticSeverity = "hint"` keeps Harper hits visible but lower-priority
  -- than real LSP errors. Bump to "info" or "warning" for louder feedback.
  --
  -- `codeActions.ForceStable = true` makes Harper's "Replace with…" code
  -- actions deterministic across edits, so picking the same suggestion twice
  -- always yields the same replacement.
  --
  -- `linters` mirrors Harper's documented defaults; flipped `WrongApostrophe`
  -- on because typographic vs ASCII apostrophes are a common gotcha in prose.
  --------------------------------------------------------------------------------
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        harper_ls = {
          filetypes = {
            "asciidoc",
            "c",
            "clojure",
            "cmake",
            "cpp",
            "cs",
            "dart",
            "gitcommit",
            "go",
            "haskell",
            "html",
            "java",
            "javascript",
            "lua",
            "markdown",
            "markdown.gotmpl",
            "nix",
            "php",
            "python",
            "ruby",
            "rust",
            "sh",
            "swift",
            "tex",
            "text",
            "toml",
            "typescript",
            "typescriptreact",
            "typst",
            "yaml",
            "zsh",
          },
          settings = {
            ["harper-ls"] = {
              userDictPath = DICT_PATH,
              codeActions = { ForceStable = true },
              markdown = { IgnoreLinkTitle = true },
              dialect = "American",
              diagnosticSeverity = "hint",
              linters = {
                SpellCheck = true,
                SpelledNumbers = false,
                AnA = true,
                SentenceCapitalization = true,
                UnclosedQuotes = true,
                WrongApostrophe = true,
                LongSentences = true,
                RepeatedWords = true,
                Spaces = true,
                CorrectNumberSuffix = true,
              },
            },
          },
        },
      },
    },
    init = function()
      -- Pin vim's spellfile to DICT_PATH so `zg` writes to the same file
      -- harper-ls reads via userDictPath. Vim's default when `spellfile` is
      -- empty is `~/.local/share/nvim/site/spell/en.utf-8.add` (data dir),
      -- which Harper doesn't read — without this line, `zg` updates vim's
      -- dict but harper-ls keeps flagging the word.
      vim.opt.spellfile = DICT_PATH

      ------------------------------------------------------------------------
      -- Dict file watcher + base ↔ possessive auto-pair
      ------------------------------------------------------------------------
      -- One watcher, three jobs, on every external edit to DICT_PATH:
      --
      --   1. AUTO-PAIR: for any newly-added capitalized single-word token,
      --      write the partner form (base ↔ possessive). vim has no affix
      --      rules for personal .add entries and Harper doesn't split on
      --      the possessive apostrophe, so mirroring `Zellij` ↔ `Zellij's`
      --      makes both engines accept either form after one addition —
      --      regardless of whether it came from vim's `zg`, Harper's `z=`
      --      "Add to user dictionary" code action, or a manual file edit.
      --   2. REFRESH vim's compiled cache by running `:mkspell!` so the
      --      .add.spl binary matches the .add source.
      --   3. RELOAD vim's in-memory spell state by re-assigning `spelllang`
      --      on each spell-enabled window. (spell/spelllang are window-
      --      local, not buffer-local — iterating buffers fails.)
      --
      -- The watcher will re-fire for our own auto-pair write, but the
      -- `known` snapshot makes that pass a no-op (nothing new to add).
      local known = {}
      local function snapshot()
        known = {}
        local ok, iter = pcall(io.lines, DICT_PATH)
        if not ok then
          return
        end
        for line in iter do
          if line ~= "" then
            known[line] = true
          end
        end
      end
      snapshot()

      local watcher = vim.uv.new_fs_event()
      if watcher then
        watcher:start(
          DICT_PATH,
          {},
          vim.schedule_wrap(function(err)
            if err then
              return
            end

            -- Walk the dict once: snapshot the current contents AND collect
            -- entries that weren't in the previous snapshot.
            local current = {}
            local additions = {}
            local ok, iter = pcall(io.lines, DICT_PATH)
            if not ok then
              return
            end
            for line in iter do
              if line ~= "" then
                current[line] = true
                if not known[line] then
                  additions[#additions + 1] = line
                end
              end
            end
            known = current

            -- Compute partner forms for new capitalized tokens, then
            -- rewrite the file sorted (case-insensitive). One write
            -- covers extras + dedupe + sort, so the watcher only re-fires
            -- once for our own touch — the `known` snapshot then makes
            -- that pass a no-op.
            if #additions > 0 then
              for _, word in ipairs(additions) do
                local base = word:match("^([A-Z][%w]*)'s$")
                if base then
                  if not current[base] then
                    current[base] = true
                    known[base] = true
                  end
                elseif word:match("^[A-Z][%w]*$") then
                  local poss = word .. "'s"
                  if not current[poss] then
                    current[poss] = true
                    known[poss] = true
                  end
                end
              end

              local sorted = {}
              for word in pairs(current) do
                sorted[#sorted + 1] = word
              end
              table.sort(sorted, function(a, b)
                return a:lower() < b:lower()
              end)

              local f = io.open(DICT_PATH, "w")
              if f then
                for _, w in ipairs(sorted) do
                  f:write(w .. "\n")
                end
                f:close()
              end
            end

            -- Refresh vim's compiled cache and reload in-memory spell.
            pcall(vim.cmd, "silent! mkspell! " .. vim.fn.fnameescape(DICT_PATH))
            for _, win in ipairs(vim.api.nvim_list_wins()) do
              if vim.api.nvim_win_is_valid(win) and vim.wo[win].spell then
                pcall(vim.api.nvim_win_call, win, function()
                  vim.opt_local.spelllang = vim.opt_local.spelllang:get()
                end)
              end
            end

            -- Poke Harper for any additions — covers auto-paired partners
            -- Harper's own code action didn't add, plus manual file edits
            -- Harper has no other signal for. The duplicate ping when zg
            -- already notified is harmless.
            if #additions > 0 then
              for _, c in ipairs(vim.lsp.get_clients({ name = "harper_ls" })) do
                c.notify("workspace/didChangeConfiguration", {
                  settings = c.config.settings,
                })
              end
            end
          end)
        )
      end

      ------------------------------------------------------------------------
      -- z= : Spelling / grammar suggestions
      ------------------------------------------------------------------------
      -- When a Harper diagnostic covers the cursor, surface Harper's code
      -- actions (replacements, "ignore this rule here", "add to dict")
      -- through the standard LSP picker. Otherwise fall through to native
      -- z= so vim's spell suggestions still work for non-Harper buffers or
      -- words Harper considers fine.
      vim.keymap.set("n", "z=", function()
        if harper_at_cursor() then
          vim.lsp.buf.code_action({
            -- `kind` is omitted by some Harper builds; accept anything.
            filter = function(a)
              return a ~= nil
            end,
          })
        else
          vim.cmd("normal! z=")
        end
      end, { desc = "Spelling/grammar suggestions" })

      ------------------------------------------------------------------------
      -- zg : Add word to user dictionary
      ------------------------------------------------------------------------
      -- Native `zg` appends to DICT_PATH and recompiles the .spl, then we
      -- ping Harper to re-read its userDictPath. The base ↔ possessive
      -- auto-pair lives in the watcher above so it also fires when Harper's
      -- own "Add to user dictionary" code action (via `z=`) adds the word.
      vim.keymap.set("n", "zg", function()
        vim.cmd("normal! zg")
        for _, client in ipairs(vim.lsp.get_clients({ name = "harper_ls" })) do
          client.notify("workspace/didChangeConfiguration", {
            settings = client.config.settings,
          })
        end
      end, { desc = "Add word to dictionary (vim + Harper)" })

      ------------------------------------------------------------------------
      -- Toggle (<leader>uH)
      ------------------------------------------------------------------------
      -- Same VeryLazy/Snacks.toggle pattern used for the chezmoi-redirect
      -- toggle in lua/config/autocmds.lua. Default state is ON; flipping
      -- off stops every harper-ls client, flipping on re-fires the FileType
      -- autocmd so LazyVim's LSP attach hook restarts harper-ls on each
      -- loaded buffer.
      vim.api.nvim_create_autocmd("User", {
        pattern = "VeryLazy",
        once = true,
        callback = function()
          if type(_G.Snacks) ~= "table" or type(Snacks.toggle) ~= "table" then
            return
          end
          Snacks.toggle
            .new({
              name = "Harper Grammar",
              get = function()
                return vim.g.harper_enabled ~= false
              end,
              set = function(state)
                vim.g.harper_enabled = state
                if state then
                  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
                    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].filetype ~= "" then
                      pcall(vim.api.nvim_exec_autocmds, "FileType", {
                        buffer = buf,
                        modeline = false,
                      })
                    end
                  end
                else
                  for _, c in ipairs(vim.lsp.get_clients({ name = "harper_ls" })) do
                    vim.lsp.stop_client(c.id, true)
                  end
                end
              end,
            })
            :map("<leader>uH")
        end,
      })

      -- Gate auto-attach while the toggle is off. LazyVim's lspconfig setup
      -- registers a FileType autocmd that starts harper-ls on any matching
      -- buffer; without this guard, opening a new buffer would silently
      -- re-attach even after toggling Harper off.
      vim.api.nvim_create_autocmd("LspAttach", {
        callback = function(args)
          if vim.g.harper_enabled == false then
            local client = vim.lsp.get_client_by_id(args.data.client_id)
            if client and client.name == "harper_ls" then
              vim.lsp.stop_client(client.id, true)
            end
          end
        end,
        desc = "Block harper-ls auto-attach while toggle is off",
      })
    end,
  },
}
