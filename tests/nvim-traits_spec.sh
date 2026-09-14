# nvim consults the chezmoi facts file's `traits` table: the IDE layer
# (Mason, LSP, DAP, lint, format) is enabled only with dev_tooling, the AI
# plugin only with ai_tooling. Probed with `nvim -l`: the plugin spec files
# are plain Lua that return tables, so they load without nvim's config and we
# read the `enabled` field of every named spec. No facts file at all (a Mac
# before its next apply) must mean "everything on".
Describe 'nvim plugin specs honour the chezmoi traits'
  NVIM_LUA="$SHELLSPEC_PROJECT_ROOT/home/dot_config/nvim/lua"

  setup() {
    PROBE="$(mktemp "$SHELLSPEC_TMPBASE/nvim-probe.XXXXXX")"
    cat >"$PROBE" <<'LUA'
local file, dev, ai, facts = arg[1], arg[2] == "true", arg[3] == "true", arg[4] ~= "nofacts"
if facts then
  package.preload["config.chezmoi"] = function()
    return { os = "linux", profile = "appliance",
      traits = { headless = true, ephemeral = false, dev_tooling = dev, ai_tooling = ai } }
  end
end
-- Real nvim has this global set (by LazyVim's own bootstrap) long before any
-- plugin spec file is loaded; this bare probe never runs that bootstrap, and
-- coding.lua's ruff server config references LazyVim.lsp.action in a plain
-- table literal, which Lua evaluates eagerly regardless of `enabled`. Stub it
-- so the file can load at all.
_G.LazyVim = { lsp = { action = setmetatable({}, { __index = function() return function() end end }) } }
for _, s in ipairs(dofile(file)) do
  if type(s) == "table" and s[1] then print(s[1] .. " enabled=" .. tostring(s.enabled)) end
end
LUA
    export PROBE
  }
  BeforeEach 'setup'

  # nvim -l routes Lua's print() through its message subsystem, which lands
  # on stderr rather than stdout in headless script mode; merge the streams
  # so shellspec's stdout-only "The output" matcher sees it.
  specs() { nvim -l "$PROBE" "$NVIM_LUA/plugins/$1" "$2" "$3" "${4:-}" 2>&1; }

  It 'appliance (no dev, no ai): the IDE layer and the AI plugin are disabled'
    Skip if "nvim not installed" ! command -v nvim >/dev/null 2>&1
    When call specs coding.lua false false
    The status should be success
    The output should include "mason-org/mason.nvim enabled=false"
    The output should include "mason-org/mason-lspconfig.nvim enabled=false"
    The output should include "WhoIsSethDaniel/mason-tool-installer.nvim enabled=false"
    The output should include "neovim/nvim-lspconfig enabled=false"
    The output should include "mfussenegger/nvim-dap enabled=false"
    The output should include "mfussenegger/nvim-dap-python enabled=false"
    The output should include "mfussenegger/nvim-lint enabled=false"
    The output should include "stevearc/conform.nvim enabled=false"
    The output should include "mfussenegger/nvim-jdtls enabled=false"
    The output should include "mrcjkb/rustaceanvim enabled=false"
    The output should include "nvim-treesitter/nvim-treesitter enabled=nil"
  End

  It 'appliance: the AI plugin is disabled'
    Skip if "nvim not installed" ! command -v nvim >/dev/null 2>&1
    When call specs ai.lua false false
    The status should be success
    The output should include "NickvanDyke/opencode.nvim enabled=false"
  End

  It 'server (dev + ai): everything is enabled'
    Skip if "nvim not installed" ! command -v nvim >/dev/null 2>&1
    When call specs coding.lua true true
    The status should be success
    The output should include "mason-org/mason.nvim enabled=true"
    The output should include "neovim/nvim-lspconfig enabled=true"
    The output should include "mfussenegger/nvim-dap enabled=true"
    The output should not include "enabled=false"
  End

  It 'no facts file: everything is enabled (a machine before its next apply)'
    Skip if "nvim not installed" ! command -v nvim >/dev/null 2>&1
    When call specs coding.lua false false nofacts
    The status should be success
    The output should include "mason-org/mason.nvim enabled=true"
    The output should not include "enabled=false"
  End

  It 'the plugin files consult chezmoi.traits and compare no profile name'
    When call grep -l 'chezmoi.profile ==' "$NVIM_LUA/plugins/coding.lua" "$NVIM_LUA/plugins/ai.lua"
    The status should be failure
  End
End
