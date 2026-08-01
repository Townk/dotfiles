# Pure decision/portability tests for smart-paste.yazi. Neovim supplies the
# Lua runtime; Yazi globals and Command are stubbed before loading the plugin.
Describe 'smart-paste.yazi'
  PLUGIN="$SHELLSPEC_PROJECT_ROOT/home/dot_config/yazi/plugins/smart-paste.yazi/main.lua"

  setup() {
    HARNESS="$SHELLSPEC_TMPBASE/smart-paste-test.lua"
    cat > "$HARNESS" <<'LUA'
ya = { sync = function(fn) return fn end }
cx = {
  active = { current = { cwd = "/active/yazi/dir" } },
  yanked = { is_cut = false },
}

local calls = {}
Command = function(name)
  local cmd = { name = name }
  function cmd:cwd(dir)
    self.cwd_value = dir
    return self
  end
  function cmd:arg(args)
    self.args = args
    calls[#calls + 1] = args[1] .. ":" .. args[2]
    return self
  end
  function cmd:output()
    local mode = os.getenv("SMART_STAT_MODE")
    if self.name == "stat" and mode == "bsd" and self.args[1] == "-f" then
      return { status = { success = true }, stdout = "123\n" }
    elseif self.name == "stat" and mode == "gnu-nonnumeric" and self.args[1] == "-f" then
      return { status = { success = true }, stdout = "filesystem report\n" }
    elseif self.name == "stat" and (mode == "gnu" or mode == "gnu-nonnumeric") and self.args[1] == "-c" then
      return { status = { success = true }, stdout = "456\n" }
    end
    return { status = { success = false }, stdout = "" }
  end
  return cmd
end

local plugin = assert(dofile(assert(os.getenv("SMART_PASTE_PLUGIN"))))
local test = assert(plugin._test)

local op = os.getenv("SMART_TEST_OP")
if op == "mtime" then
  print(test.mtime("/marker"))
  print(table.concat(calls, ","))
elseif op == "cwd" then
  assert(test.get_cwd() == "/active/yazi/dir")
  local cmd = test.pbpaste_command(test.get_cwd(), { "--files", "--porcelain" })
  assert(cmd.cwd_value == "/active/yazi/dir")
  assert(cmd.args[1] == "--files" and cmd.args[2] == "--porcelain")
  print(cmd.cwd_value)
else
  local choose = test.choose_source
  local function manifest(ts, ...)
    return { ts = ts, paths = { ... } }
  end
  assert(choose({}, nil, 0, 0) == "native")
  assert(choose({ "/b", "/a" }, manifest(20, "/a", "/b"), 0, 0) == "native")
  assert(choose({}, manifest(20, "/remote"), 10, 0) == "system")
  assert(choose({}, manifest(10, "/remote"), 20, 0) == "native")
  assert(choose({ "/local" }, manifest(20, "/remote"), 0, 10) == "system")
  assert(choose({ "/local" }, manifest(10, "/remote"), 0, 20) == "native")
  print("decision-ok")
end
LUA
  }
  BeforeEach 'setup'

  run_mtime() {
    SMART_STAT_MODE=$1 SMART_TEST_OP=mtime SMART_PASTE_PLUGIN="$PLUGIN" \
      nvim --headless -u NONE -l "$HARNESS" 2>&1
  }

  run_decision() {
    SMART_TEST_OP=decision SMART_PASTE_PLUGIN="$PLUGIN" \
      nvim --headless -u NONE -l "$HARNESS" 2>&1
  }

  run_cwd() {
    SMART_TEST_OP=cwd SMART_PASTE_PLUGIN="$PLUGIN" \
      nvim --headless -u NONE -l "$HARNESS" 2>&1
  }

  It 'uses BSD stat on macOS'
    When call run_mtime bsd
    The line 1 of output should equal "123"
    The line 2 of output should equal "-f:%m"
    The status should be success
  End

  It 'falls back to GNU stat on Linux'
    When call run_mtime gnu
    The line 1 of output should equal "456"
    The line 2 of output should equal "-f:%m,-c:%Y"
    The status should be success
  End

  It 'falls back when GNU stat -f succeeds with nonnumeric output'
    When call run_mtime gnu-nonnumeric
    The line 1 of output should equal "456"
    The line 2 of output should equal "-f:%m,-c:%Y"
    The status should be success
  End

  It 'treats a missing marker as epoch zero'
    When call run_mtime missing
    The line 1 of output should equal "0"
    The line 2 of output should equal "-f:%m,-c:%Y"
    The status should be success
  End

  It 'pins all five source-resolution rules'
    When call run_decision
    The output should equal "decision-ok"
    The status should be success
  End

  It 'pins pbpaste to the active Yazi tab directory'
    When call run_cwd
    The output should equal "/active/yazi/dir"
    The status should be success
  End
End
