# The blink.cmp smart <Tab> handler in coding.lua must only complete when
# there is a word before the cursor. With nothing typed (line start, blank
# line, right after a space) it returns nil so the keymap chain falls through
# to snippet_forward/fallback and Tab indents instead of opening the menu.
# Probed with `nvim -l`: the plugin spec file is plain Lua, so we load it,
# build blink's opts, and drive the <Tab>/<S-Tab> handlers against a real
# buffer with a fake `cmp` that records which action it was asked for.
Describe 'nvim blink.cmp smart Tab'
  NVIM_LUA="$SHELLSPEC_PROJECT_ROOT/home/dot_config/nvim/lua"

  setup() {
    PROBE="$(mktemp "$SHELLSPEC_TMPBASE/nvim-probe.XXXXXX")"
    cat >"$PROBE" <<'LUA'
local file, key, line, nitems, snippet_active =
  arg[1], arg[2], arg[3], tonumber(arg[4]), arg[5] == "snippet"
-- See nvim-traits_spec.sh: coding.lua touches LazyVim.lsp.action eagerly.
_G.LazyVim = { lsp = { action = setmetatable({}, { __index = function() return function() end end }) } }
-- Item 2 is a snippet labelled "fo", so a typed "fo" is an exact snippet match.
local items = {}
for i = 1, nitems do
  items[i] = i == 2 and { label = "fo", kind = 15 } or { label = "item" .. i, kind = 1 }
end
package.preload["blink.cmp.completion.list"] = function() return { items = items } end
package.preload["blink.cmp.types"] = function() return { CompletionItemKind = { Snippet = 15 } } end

-- Cursor sits after the whole line, as in insert mode (onemore lets a
-- headless normal-mode cursor go one past the last byte).
vim.o.virtualedit = "onemore"
vim.api.nvim_buf_set_lines(0, 0, -1, false, { line })
vim.api.nvim_win_set_cursor(0, { 1, #line })

local blink
for _, s in ipairs(dofile(file)) do
  if type(s) == "table" and s[1] == "saghen/blink.cmp" then blink = s end
end
local handler = blink.opts(nil, {}).keymap[key][1]

local cmp = setmetatable({ snippet_active = function() return snippet_active end }, {
  __index = function(_, name)
    return function(o)
      return "called " .. name .. (o and o.index and (" index=" .. o.index) or "")
    end
  end,
})
print("result=" .. tostring((handler(cmp))))
LUA
    export PROBE
  }
  BeforeEach 'setup'

  # nvim -l prints to stderr in headless script mode; merge the streams.
  tab() { nvim -l "$PROBE" "$NVIM_LUA/plugins/coding.lua" "$@" 2>&1; }

  It 'falls through on an empty line (Tab indents, no menu)'
    Skip if "nvim not installed" ! command -v nvim >/dev/null 2>&1
    When call tab '<Tab>' '' 3
    The status should be success
    The output should include "result=nil"
  End

  It 'falls through on a whitespace-only line'
    Skip if "nvim not installed" ! command -v nvim >/dev/null 2>&1
    When call tab '<Tab>' '    ' 3
    The status should be success
    The output should include "result=nil"
  End

  It 'falls through right after a space, even with a single item listed'
    Skip if "nvim not installed" ! command -v nvim >/dev/null 2>&1
    When call tab '<Tab>' 'local x = ' 1
    The status should be success
    The output should include "result=nil"
  End

  It 'with a prefix and one item, auto-accepts it'
    Skip if "nvim not installed" ! command -v nvim >/dev/null 2>&1
    When call tab '<Tab>' 'foo' 1
    The status should be success
    The output should include "result=called accept index=1"
  End

  It 'with a prefix matching a snippet label, accepts that snippet'
    Skip if "nvim not installed" ! command -v nvim >/dev/null 2>&1
    When call tab '<Tab>' '  fo' 3
    The status should be success
    The output should include "result=called accept index=2"
  End

  It 'with a prefix and no exact match, starts cycling'
    Skip if "nvim not installed" ! command -v nvim >/dev/null 2>&1
    When call tab '<Tab>' 'ba' 3
    The status should be success
    The output should include "result=called insert_next"
  End

  It 'leaves snippet navigation to snippet_forward'
    Skip if "nvim not installed" ! command -v nvim >/dev/null 2>&1
    When call tab '<Tab>' 'ba' 3 snippet
    The status should be success
    The output should include "result=nil"
  End

  It '<S-Tab> still cycles backwards regardless of prefix'
    Skip if "nvim not installed" ! command -v nvim >/dev/null 2>&1
    When call tab '<S-Tab>' '' 3
    The status should be success
    The output should include "result=called insert_prev"
  End
End
