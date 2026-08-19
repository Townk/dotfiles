# The share-receive branch of smart-paste.yazi (F4). Yazi globals and Command
# stubbed; nothing is received and no clipboard is read.
#
# The invariant under test is a SAFETY one: a paste must never pull a file onto
# disk without asking. Every other route to a receive is explicitly invoked;
# a paste is a file-management gesture, and the clipboard's content arrived in
# somebody else's chat message.

Describe 'smart-paste.yazi — share receive'
  PLUGIN="$SHELLSPEC_PROJECT_ROOT/home/dot_config/yazi/plugins/smart-paste.yazi/main.lua"

  setup() {
    HARNESS="$SHELLSPEC_TMPBASE/sp-share-test.lua"
    cat > "$HARNESS" <<'LUA'
ya = {
  sync = function(fn) return fn end,
  notify = function(t) print("NOTIFY:" .. (t.level or "info") .. ":" .. (t.content or "")) end,
  which = function(t)
    print("ASKED:" .. (t.cands[1].desc or ""))
    return tonumber(os.getenv("SP_CHOICE") or "0")
  end,
}
cx = { active = { current = { cwd = "/here" }, selected = {} }, yanked = { is_cut = false } }

Command = setmetatable({ PIPED = "piped" }, { __call = function(_, name)
  local cmd = { name = name, _args = {} }
  function cmd:arg(a) self._args = a; return self end
  function cmd:cwd(_) return self end
  function cmd:stdin(_) return self end
  function cmd:stdout(_) return self end
  function cmd:stderr(_) return self end
  function cmd:output()
    local verb = self._args[1] or ""
    print("RUN:" .. self.name .. " " .. table.concat(self._args, " "))
    if self.name == "share" and verb == "peek" then
      local out = os.getenv("SP_PEEK") or ""
      return { status = { success = out ~= "" }, stdout = out, stderr = "" }
    end
    if self.name == "share" and verb == "get" then
      if os.getenv("SP_RX_FAIL") == "1" then
        return { status = { success = false }, stdout = "", stderr = "relay unreachable" }
      end
      return { status = { success = true }, stdout = "", stderr = "" }
    end
    return { status = { success = true }, stdout = "", stderr = "" }
  end
  return cmd
end })

local plugin = dofile(os.getenv("SP_PLUGIN"))
print("RESULT:" .. tostring(plugin._test.try_share_receive("/here")))
LUA
  }
  BeforeEach 'setup'

  run_sp() {
    SP_PEEK="${PEEK-}" SP_CHOICE="${CHOICE:-0}" SP_RX_FAIL="${RXFAIL-}" SP_PLUGIN="$PLUGIN" \
      nvim --headless -u NONE -l "$HARNESS" 2>&1
  }

  # THE safety property. A `y` was never pressed, so nothing may be received.
  It 'never receives without asking'
    PEEK=$'live\tReport.pdf (4.2 MB)'
    CHOICE=0
    When call run_sp
    The output should include 'ASKED:Receive Report.pdf (4.2 MB) into this folder'
    The output should not include 'RUN:share get'
    The output should include 'RESULT:false'
  End

  It 'names the file and its size in the prompt'
    PEEK=$'live\tDeck.key (18.0 MB)'
    CHOICE=1
    When call run_sp
    The output should include 'ASKED:Receive Deck.key (18.0 MB) into this folder'
  End

  It 'receives into the current directory once confirmed'
    PEEK=$'live\tReport.pdf (4.2 MB)'
    CHOICE=1
    When call run_sp
    The output should include 'RUN:share get --out /here'
    The output should include 'RESULT:true'
  End

  # Declining must fall THROUGH to yazi's ordinary paste, not swallow the key.
  It 'falls through to a normal paste when declined'
    PEEK=$'live\tReport.pdf (4.2 MB)'
    CHOICE=2
    When call run_sp
    The output should include 'RESULT:false'
    The output should not include 'RUN:share get'
  End

  # Nothing share-shaped on the clipboard: no prompt at all. A confirmation
  # dialog on every ordinary paste would be intolerable.
  It 'does not prompt when the clipboard holds no share'
    PEEK=''
    When call run_sp
    The output should not include 'ASKED:'
    The output should include 'RESULT:false'
  End

  It 'handles a stored share as well as a live one'
    PEEK=$'stored\ta stored share'
    CHOICE=1
    When call run_sp
    The output should include 'ASKED:Receive a stored share into this folder'
    The output should include 'RUN:share get --out /here'
  End

  It 'reports a failed receive instead of claiming success'
    PEEK=$'live\tReport.pdf (4.2 MB)'
    CHOICE=1
    RXFAIL=1
    When call run_sp
    The output should include 'NOTIFY:error'
    The output should include 'relay unreachable'
    The output should include 'RESULT:true'
  End
End
