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
  vim.fn.jobstart({ "chezmoi", "apply" }, { detach = true })
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

    -- Reconcile external drift for non-templated sources. If a tool (e.g.
    -- `pi install`) mutated the target since the last `chezmoi apply`, pull
    -- those changes into the source so we don't open a stale version.
    if not vim.endswith(source, ".tmpl") then
      local status = vim.fn.system({ "chezmoi", "status", "--", target })
      if vim.v.shell_error == 0 and status ~= "" then
        vim.fn.system({ "chezmoi", "re-add", "--force", "--", target })
        vim.notify(
          ("chezmoi: reconciled external changes\n%s"):format(vim.fn.fnamemodify(target, ":~")),
          vim.log.levels.INFO
        )
      end
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
