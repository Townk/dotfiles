# Decision tests for share.yazi. Neovim supplies the Lua runtime; yazi globals
# and Command are stubbed, so nothing is transferred and no clipboard is touched.
# Spec: docs/superpowers/specs/2026-08-18-share-phase3-faces-design.md (F1/F2)

Describe 'share.yazi'
  PLUGIN="$SHELLSPEC_PROJECT_ROOT/home/dot_config/yazi/plugins/share.yazi/main.lua"

  setup() {
    HARNESS="$SHELLSPEC_TMPBASE/share-yazi-test.lua"
    cat > "$HARNESS" <<'LUA'
-- Yazi runs `entry` in an async VM where ya.sync blocks reach cx; for a
-- decision test the identity function is enough.
ya = {
  sync = function(fn) return fn end,
  notify = function(t) print("NOTIFY:" .. (t.level or "info") .. ":" .. (t.title or "") .. ":" .. (t.content or "")) end,
}

local sel  = os.getenv("SHARE_TEST_SELECTED") or ""
local hov  = os.getenv("SHARE_TEST_HOVERED")  or ""
local selected = {}
for p in sel:gmatch("[^|]+") do selected[#selected + 1] = p end

cx = {
  active = {
    selected = selected,
    current  = { hovered = (hov ~= "" and { url = hov } or nil) },
  },
}

-- A callable TABLE, not a function: yazi's Command carries fields (PIPED), and
-- a Lua function cannot be indexed. Stubbing it as a plain function fails with
-- "attempt to index global 'Command' (a function value)".
Command = setmetatable({ PIPED = "piped" }, { __call = function(_, name)
  local cmd = { name = name, _args = {} }
  function cmd:arg(a) self._args = a; return self end
  function cmd:stdin(_) return self end
  function cmd:spawn()
    print("SPAWN:" .. self.name)
    return {
      write_all = function(_, s) print("CLIP:" .. s) end,
      flush = function() end,
      wait = function() end,
    }
  end
  function cmd:output()
    print("RUN:" .. self.name .. " " .. table.concat(self._args, " "))
    if os.getenv("SHARE_TEST_FAIL") == "1" then
      return { status = { success = false }, stdout = "", stderr = "boom" }
    end
    return {
      status = { success = true },
      stdout = os.getenv("SHARE_TEST_STDOUT") or "",
      stderr = os.getenv("SHARE_TEST_STDERR") or "",
    }
  end
  return cmd
end })

local plugin = dofile(os.getenv("SHARE_YAZI_PLUGIN"))
local mode = os.getenv("SHARE_TEST_MODE")
plugin.entry(nil, { args = (mode ~= "" and mode) and { mode } or {} })
LUA
  }
  BeforeEach 'setup'

  run_share() {  # run_share <mode> [selected] [hovered]
    SHARE_TEST_MODE="$1" SHARE_TEST_SELECTED="${2-}" SHARE_TEST_HOVERED="${3-}" \
    SHARE_TEST_STDOUT="${STDOUT_LINE-}" SHARE_TEST_STDERR="${STDERR_LINE-}" \
    SHARE_TEST_FAIL="${FAILMODE-}" SHARE_YAZI_PLUGIN="$PLUGIN" \
      nvim --headless -u NONE -l "$HARNESS" 2>&1
  }

  # F1: the UNMARKED key does the default thing. Shift must not silently change
  # which of two transfer models you get.
  It 'shares live by default, asking for the line on stdout'
    STDOUT_LINE='R.pdf (1 B) — receive with:  croc aaaa-bbbb'
    When call run_share live /tmp/a.pdf
    The output should include 'RUN:share send --background --for-face -- /tmp/a.pdf'
  End

  # Stored has no line to hand back — the URL does not exist until the upload
  # finishes — so it must NOT ask for one.
  It 'shares stored without --for-face, since there is no line yet'
    When call run_share store /tmp/a.pdf
    The output should include 'RUN:share send --background --store -- /tmp/a.pdf'
    The output should not include '--for-face'
  End

  It 'shares the selection when there is one'
    STDOUT_LINE='2 files (2 B) — receive with:  croc aaaa-bbbb'
    When call run_share live '/tmp/a.pdf|/tmp/b.pdf'
    The output should include '-- /tmp/a.pdf /tmp/b.pdf'
  End

  It 'falls back to the hovered file when nothing is selected'
    STDOUT_LINE='h.pdf (1 B) — receive with:  croc aaaa-bbbb'
    When call run_share live '' /tmp/hovered.pdf
    The output should include '-- /tmp/hovered.pdf'
  End

  # A selection can contain anything, and a filename beginning with `-` must
  # never be read as an option.
  It 'terminates options before the paths'
    STDOUT_LINE='x (1 B) — receive with:  croc aaaa-bbbb'
    When call run_share live -- '/tmp/-weird.pdf'
    The output should include ' -- '
  End

  It 'refuses when nothing is selected or hovered'
    When call run_share live
    The output should include 'NOTIFY:error'
    The output should not include 'RUN:share'
  End

  # The clipboard is THIS face's delivery mechanism: the next thing the human
  # does is paste into a chat. share itself is told not to write it
  # (--for-face), so the plugin does it deliberately.
  It 'puts the live line on the clipboard'
    STDOUT_LINE='R.pdf (1 B) — receive with:  croc aaaa-bbbb'
    When call run_share live /tmp/a.pdf
    The output should include 'SPAWN:pbcopy'
    The output should include 'CLIP:R.pdf (1 B) — receive with:  croc aaaa-bbbb'
  End

  # Nothing to copy yet, so copying would be a lie.
  It 'does not touch the clipboard for a stored share'
    When call run_share store /tmp/a.pdf
    The output should not include 'SPAWN:pbcopy'
  End

  # A live send to an endpoint that cannot carry one falls back to stored and
  # says so on stderr, producing no line. Reporting "copied" would be false.
  It 'reports the fallback instead of claiming it copied something'
    STDOUT_LINE=''
    STDERR_LINE='share: drop cannot carry a live transfer — sending stored instead'
    When call run_share live /tmp/a.pdf
    The output should not include 'SPAWN:pbcopy'
    The output should include 'cannot carry a live transfer'
  End

  It 'surfaces a failure rather than reporting success'
    FAILMODE=1
    When call run_share live /tmp/a.pdf
    The output should include 'NOTIFY:error'
    The output should include 'boom'
  End
End
