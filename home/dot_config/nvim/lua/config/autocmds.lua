--------------------------------------------------------------------------------
-- Automatic Commands (Autocommands)
--------------------------------------------------------------------------------
-- Autocmds run automatically when specific events occur (file open, mode change,
-- buffer write, etc.). These are loaded on VeryLazy event. LazyVim provides
-- many useful defaults (wrap spell, auto-create directories, etc.).
--
-- Default LazyVim autocmds:
--   https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/autocmds.lua
--
-- To remove a LazyVim autocommand group:
--   vim.api.nvim_del_augroup_by_name("lazyvim_wrap_spell")
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- Number Toggle: Relative in Normal Mode, Absolute in Insert Mode
--------------------------------------------------------------------------------
-- WHY: Relative line numbers are great for motions (5j, 12k) in normal mode,
-- but in insert mode you usually want to know the absolute line number for
-- reference, debugging, or error messages.
--
-- The buftype check ensures this only applies to actual file buffers, not
-- special buffers like terminals, help pages, or dashboard (which would look
-- weird with line numbers jumping around or cause errors).
--------------------------------------------------------------------------------
local number_toggle = vim.api.nvim_create_augroup("NumberToggle", { clear = true })

vim.api.nvim_create_autocmd("InsertEnter", {
  group = number_toggle,
  pattern = "*",
  callback = function()
    if vim.bo.buftype ~= "" then
      return -- Skip non-file buffers (Snacks, terminal, help, etc.)
    end
    vim.opt.relativenumber = false
  end,
  desc = "Use absolute line numbers in insert mode",
})

vim.api.nvim_create_autocmd("InsertLeave", {
  group = number_toggle,
  pattern = "*",
  callback = function()
    if vim.bo.buftype ~= "" then
      return -- Skip non-file buffers (Snacks, terminal, help, etc.)
    end
    vim.opt.relativenumber = true
  end,
  desc = "Use relative line numbers in normal mode",
})

--------------------------------------------------------------------------------
-- Yazi Lua Types: Configure lua_ls for Yazi plugin files
--------------------------------------------------------------------------------
-- WHY: Yazi plugin files need special type definitions that shouldn't pollute
-- other Lua projects. This autocmd adds the types.yazi library only when
-- editing files in ~/.config/yazi/ directory.
--
-- The types are loaded from the types.yazi plugin which provides EmmyLua
-- annotations for all Yazi globals (ya, cx, fs, ui, etc.)
--------------------------------------------------------------------------------
local yazi_types_group = vim.api.nvim_create_augroup("YaziTypes", { clear = true })

vim.api.nvim_create_autocmd({ "BufRead", "BufNewFile" }, {
  group = yazi_types_group,
  pattern = vim.env.HOME .. "/.config/yazi/**/*.lua",
  callback = function(args)
    local client = vim.lsp.get_clients({ bufnr = args.buf, name = "lua_ls" })[1]
    if not client then
      return
    end

    local yazi_types_path = vim.env.HOME .. "/.config/yazi/plugins/types.yazi"
    local current_libs = client.settings.Lua.workspace.library or {}

    -- Check if already added to avoid duplicates
    for _, lib in ipairs(current_libs) do
      if lib == yazi_types_path then
        return
      end
    end

    -- Add Yazi types to workspace library
    table.insert(current_libs, yazi_types_path)

    client.settings.Lua = vim.tbl_deep_extend("force", client.settings.Lua or {}, {
      workspace = {
        library = current_libs,
      },
    })

    -- Notify the LSP of settings change
    client.notify("workspace/didChangeConfiguration", {
      settings = client.settings,
    })
  end,
  desc = "Add Yazi types to lua_ls workspace",
})

--------------------------------------------------------------------------------
-- Chezmoi Redirect: Edit the source (template) instead of the destination
--------------------------------------------------------------------------------
-- WHY: Many config files in ~/.config and elsewhere are managed by chezmoi.
-- Editing the destination directly is a footgun: the next `chezmoi apply`
-- silently overwrites it. This autocmd transparently swaps any chezmoi-managed
-- buffer for its source file (the .tmpl, the symlink_*, etc.) right after read,
-- so saving updates the dotfiles repo. A companion BufWritePost schedules
-- `chezmoi apply` so the live file stays in sync without a manual step. The
-- apply is debounced (CHEZMOI_APPLY_DEBOUNCE_MS) so AutoSave-style rapid
-- saves coalesce into a single apply at the end of the burst; force an
-- immediate apply with :ChezmoiApplyNow.
--
-- The managed-files set is cached to avoid spawning chezmoi on every
-- BufReadPre. Cache freshness is preserved by two cheap, portable signals:
--   * FocusGained: invalidate when nvim regains focus (you typically run
--     `chezmoi add` in another terminal, then come back to nvim).
--   * TTL: invalidate after CHEZMOI_CACHE_TTL seconds as a safety net for
--     edits made while nvim is focused or via tools that don't surface focus.
-- Manual override: :ChezmoiRefresh.
--------------------------------------------------------------------------------
local chezmoi_group = vim.api.nvim_create_augroup("ChezmoiRedirect", { clear = true })
local CHEZMOI_CACHE_TTL = 60 -- seconds
local CHEZMOI_APPLY_DEBOUNCE_MS = 5000
local chezmoi_cache = nil
local chezmoi_apply_timer = nil
local chezmoi_redirect_enabled = true

-- Targets accumulated during a debounce burst. Scoping the apply to just the
-- saved files (rather than a blanket `chezmoi apply`) matters because a full
-- apply re-renders EVERY managed template — including the 1Password-backed
-- secrets fragment, whose `op read` pops a Touch ID prompt on each apply.
-- Editing an unrelated config file must never trigger that. Saves that don't
-- map to a known managed FILE target (a script, .chezmoidata, .chezmoiignore,
-- a symlink/dir) set the `full` flag, since those can affect many targets and
-- should still drive a complete apply.
local chezmoi_pending = {}
local chezmoi_pending_full = false

local function chezmoi_reset_pending()
  chezmoi_pending = {}
  chezmoi_pending_full = false
end

-- Debounce for `chezmoi apply` after saving a chezmoi-source buffer.
-- AutoSave plugins fire BufWritePost rapidly; running apply on each save
-- is wasteful. The trailing-edge debounce coalesces a burst of saves into
-- a single apply at the end of the burst. Use :ChezmoiApplyNow to force.
local function chezmoi_clear_apply_timer()
  if chezmoi_apply_timer then
    chezmoi_apply_timer:stop()
    if not chezmoi_apply_timer:is_closing() then
      chezmoi_apply_timer:close()
    end
    chezmoi_apply_timer = nil
  end
end

local function chezmoi_run_apply()
  -- --force: source edit wins over any destination drift accumulated since
  -- BufReadPre's chezmoi-reverse reconcile. Otherwise chezmoi would skip
  -- (or prompt for) targets it sees as modified, leaving the live file
  -- silently out of sync with the source we just saved.
  --
  -- Scope to the saved targets when we have them; otherwise (a `full` save, or
  -- nothing pending — e.g. a bare :ChezmoiApplyNow) apply everything.
  local cmd = { "chezmoi", "apply", "--force" }
  if not chezmoi_pending_full then
    vim.list_extend(cmd, vim.tbl_keys(chezmoi_pending))
  end
  chezmoi_reset_pending()
  vim.fn.jobstart(cmd, { detach = true })
end

local function chezmoi_schedule_apply()
  chezmoi_clear_apply_timer()
  chezmoi_apply_timer = vim.uv.new_timer()
  chezmoi_apply_timer:start(
    CHEZMOI_APPLY_DEBOUNCE_MS,
    0,
    vim.schedule_wrap(function()
      chezmoi_apply_timer = nil
      chezmoi_run_apply()
    end)
  )
end

local function chezmoi_state()
  if chezmoi_cache and (vim.uv.now() - chezmoi_cache.loaded_at) < CHEZMOI_CACHE_TTL * 1000 then
    return chezmoi_cache
  end
  local managed = vim.fn.systemlist({
    "chezmoi", "managed", "--include=files", "--path-style=absolute",
  })
  local source_dir = vim.trim(vim.fn.system({ "chezmoi", "source-path" }))
  if vim.v.shell_error ~= 0 then
    chezmoi_cache = { managed = {}, source_dir = "", loaded_at = vim.uv.now() }
    return chezmoi_cache
  end
  local set = {}
  for _, p in ipairs(managed) do
    set[p] = true
  end
  chezmoi_cache = { managed = set, source_dir = source_dir, loaded_at = vim.uv.now() }
  return chezmoi_cache
end

vim.api.nvim_create_user_command("ChezmoiRefresh", function()
  chezmoi_cache = nil
  chezmoi_state()
  vim.notify("chezmoi cache refreshed", vim.log.levels.INFO)
end, { desc = "Reload the chezmoi managed-files cache" })

vim.api.nvim_create_autocmd("FocusGained", {
  group = chezmoi_group,
  callback = function()
    chezmoi_cache = nil
  end,
  desc = "Invalidate the chezmoi cache when nvim regains focus",
})

vim.api.nvim_create_autocmd("BufReadPre", {
  group = chezmoi_group,
  callback = function(args)
    if not chezmoi_redirect_enabled then
      return
    end
    local target = vim.fn.fnamemodify(args.file, ":p")
    if target == "" or not vim.startswith(target, vim.uv.os_homedir()) then
      return
    end

    local s = chezmoi_state()

    -- Don't recurse when already inside the chezmoi source tree.
    if s.source_dir ~= "" and vim.startswith(target, s.source_dir) then
      return
    end
    if not s.managed[target] then
      return
    end

    local source = vim.trim(vim.fn.system({ "chezmoi", "source-path", "--", target }))
    if vim.v.shell_error ~= 0 or source == "" then
      return
    end

    -- Reconcile external drift before redirecting to the source. If a tool
    -- (e.g. `pi install`, `gh auth login`) mutated the target since the last
    -- `chezmoi apply`, propagate that change back into the source so we
    -- don't open a stale version.
    --
    -- chezmoi-reverse handles both templated and non-templated sources.
    -- --no-merge keeps us from blocking on a TTY merge tool inside an
    -- autocmd; if the drift touches a `{{ ... }}` directive, the source is
    -- left intact and we warn the user to run the merge by hand.
    local out = vim.fn.system({ "chezmoi-reverse", "--no-merge", target })
    local pretty = vim.fn.fnamemodify(target, ":~")
    if out:find("applied", 1, true) then
      vim.notify(
        ("chezmoi: reconciled external changes\n%s"):format(pretty),
        vim.log.levels.INFO
      )
    elseif out:find("needs-merge", 1, true) then
      vim.notify(
        ("chezmoi: drift in a templated region; run\n  chezmoi-reverse %s"):format(pretty),
        vim.log.levels.WARN
      )
    elseif out:find("failed", 1, true) then
      vim.notify(
        ("chezmoi-reverse failed\n%s\n%s"):format(pretty, vim.trim(out)),
        vim.log.levels.WARN
      )
    end

    local buf = args.buf
    vim.schedule(function()
      vim.cmd.edit(vim.fn.fnameescape(source))
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
      vim.notify(
        ("chezmoi: editing source\n%s"):format(vim.fn.fnamemodify(source, ":~")),
        vim.log.levels.INFO
      )
    end)
  end,
  desc = "Open the chezmoi source for managed destination files",
})

vim.api.nvim_create_autocmd("BufWritePost", {
  group = chezmoi_group,
  callback = function(args)
    if not chezmoi_redirect_enabled then
      return
    end
    local s = chezmoi_state()
    if s.source_dir == "" then
      return
    end
    local file = vim.fn.fnamemodify(args.file, ":p")
    if not vim.startswith(file, s.source_dir) then
      return
    end
    -- Map the saved SOURCE to its destination and scope the apply to it, but
    -- only when it's a known managed FILE target (so editing a plain config
    -- never re-renders the op-backed secrets fragment). Anything else forces a
    -- full apply, matching the prior behavior for scripts/data/symlinks.
    local target = vim.trim(vim.fn.system({ "chezmoi", "target-path", "--", file }))
    if vim.v.shell_error == 0 and target ~= "" and s.managed[target] then
      chezmoi_pending[target] = true
    else
      chezmoi_pending_full = true
    end
    chezmoi_schedule_apply()
  end,
  desc = "Schedule a debounced `chezmoi apply` after saving in the chezmoi source dir",
})

-- Flush any pending debounce before nvim exits so AutoSave bursts don't
-- leave the live file out of sync if you quit during a quiet window.
vim.api.nvim_create_autocmd("VimLeavePre", {
  group = chezmoi_group,
  callback = function()
    if chezmoi_apply_timer then
      chezmoi_clear_apply_timer()
      chezmoi_run_apply()
    end
  end,
  desc = "Flush any pending `chezmoi apply` debounce before quitting",
})

vim.api.nvim_create_user_command("ChezmoiApplyNow", function()
  chezmoi_clear_apply_timer()
  -- Explicit "apply everything now" escape hatch (also the way to run scripts /
  -- propagate data edits), so force a full apply regardless of what's pending.
  chezmoi_pending_full = true
  chezmoi_run_apply()
  vim.notify("chezmoi apply triggered", vim.log.levels.INFO)
end, { desc = "Run `chezmoi apply` immediately, bypassing the BufWritePost debounce" })

-- LazyVim/Snacks toggle, registered after Snacks loads (VeryLazy event).
-- Mapped to <leader>uM (chezMoi). Toggling off pauses both the redirect and
-- the auto-apply on save without removing the autocmds.
vim.api.nvim_create_autocmd("User", {
  pattern = "VeryLazy",
  once = true,
  callback = function()
    if type(_G.Snacks) ~= "table" or type(Snacks.toggle) ~= "table" then
      return
    end
    Snacks.toggle.new({
      name = "Chezmoi Redirect",
      get = function()
        return chezmoi_redirect_enabled
      end,
      set = function(state)
        chezmoi_redirect_enabled = state
      end,
    }):map("<leader>uM")
  end,
})

--------------------------------------------------------------------------------
-- Force classical conf syntax for `conf.gotmpl` buffers
--------------------------------------------------------------------------------
-- WHY: gotmpl directives in `conf.gotmpl` buffers are highlighted by the
-- gotmpl treesitter parser, but `conf` has no treesitter parser of its own.
-- nvim-treesitter's `additional_vim_regex_highlighting` is supposed to keep
-- vim's classical syntax engine alive alongside the treesitter parser, but
-- in practice (here at least) treesitter still clears `bo.syntax` for the
-- compound filetype, so the inner content renders unstyled.
--
-- This autocmd explicitly sets the buffer-local `syntax` to `conf` AFTER
-- treesitter has finished setting up (via `vim.schedule`), which sources
-- `syntax/conf.vim` and gives us the `#` comments, key/value, and bare-word
-- highlighting we want underneath the gotmpl directives.
vim.api.nvim_create_autocmd("FileType", {
  group = vim.api.nvim_create_augroup("ConfGotmplSyntax", { clear = true }),
  pattern = "conf.gotmpl",
  callback = function(args)
    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(args.buf) then
        vim.bo[args.buf].syntax = "conf"
      end
    end)
  end,
})

--------------------------------------------------------------------------------
-- Unicode Code-Point Hints: show the glyph inline next to detected escapes
--------------------------------------------------------------------------------
-- WHY: Mirrors LSP inlay hints, but for textual code-point escapes. When a
-- line contains `\u{1F600}`, `U+1F600`, or `\u00E9`, the resolved glyph is
-- shown right after the token as dimmed virtual text (e.g. `\u{1F600} 😀`).
-- Pairs with the `<leader>cu` keymaps that rewrite the escape into the glyph;
-- both recognize the same formats via `utils.unicode`.
--
-- IMPLEMENTATION: persistent extmarks refreshed on buffer/edit events, not a
-- decoration provider. Decoration providers only support *ephemeral* marks,
-- and ephemeral `virt_text_pos = "inline"` does not render (only "eol"/"overlay"
-- do) -- verified empirically. Persistent inline marks render correctly, at the
-- cost of an explicit refresh and a buffer rescan on change.
--------------------------------------------------------------------------------
local unicode = require("utils.unicode")
local unicode_hints_ns = vim.api.nvim_create_namespace("UnicodeCodepointHints")
local unicode_hints_enabled = true

-- Dim style matching the theme's inlay hints; `default` lets a colorscheme or
-- the user override it without this clobbering their choice.
vim.api.nvim_set_hl(0, "UnicodeCodepointHint", { link = "LspInlayHint", default = true })

-- Re-place all hints for `bufnr` (0/nil = current). Clears first so stale marks
-- never accumulate; skips disabled state and special buffers.
local function unicode_hints_refresh(bufnr)
  if bufnr == nil or bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, unicode_hints_ns, 0, -1)
  if not unicode_hints_enabled or vim.bo[bufnr].buftype ~= "" then
    return
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for i, line in ipairs(lines) do
    unicode.each_match(line, function(_, stop, hex)
      -- `stop` is the 0-indexed byte just past the token; inline virtual text
      -- there renders immediately after the escape.
      vim.api.nvim_buf_set_extmark(bufnr, unicode_hints_ns, i - 1, stop, {
        virt_text = { { " " .. unicode.glyph(hex) .. " ", "UnicodeCodepointHint" } },
        virt_text_pos = "inline",
      })
    end)
  end
end

-- Update on display and on edits. TextChangedI is intentionally omitted so the
-- hints don't shuffle while you type mid-line; they settle on InsertLeave.
vim.api.nvim_create_autocmd({ "BufWinEnter", "TextChanged", "InsertLeave" }, {
  group = vim.api.nvim_create_augroup("UnicodeCodepointHints", { clear = true }),
  callback = function(args)
    unicode_hints_refresh(args.buf)
  end,
  desc = "Refresh inline Unicode code-point hints",
})

-- This file loads on VeryLazy, after the first buffer is already shown, so do
-- an initial pass over loaded buffers (their BufWinEnter has already fired).
for _, b in ipairs(vim.api.nvim_list_bufs()) do
  if vim.api.nvim_buf_is_loaded(b) then
    unicode_hints_refresh(b)
  end
end

-- Snacks toggle (registered after Snacks loads), mapped to <leader>uU.
vim.api.nvim_create_autocmd("User", {
  pattern = "VeryLazy",
  once = true,
  callback = function()
    if type(_G.Snacks) ~= "table" or type(Snacks.toggle) ~= "table" then
      return
    end
    Snacks.toggle.new({
      name = "Unicode Code-Point Hints",
      get = function()
        return unicode_hints_enabled
      end,
      set = function(state)
        unicode_hints_enabled = state
        for _, b in ipairs(vim.api.nvim_list_bufs()) do
          if vim.api.nvim_buf_is_loaded(b) then
            unicode_hints_refresh(b)
          end
        end
      end,
    }):map("<leader>uU")
  end,
})
