# host.zsh — naming another machine the way a human knows it (peer-alias spec H6).
# The map is sandboxed via HOST_ALIASES_FILE / HOST_SELF_ALIAS_FILE; nothing
# here reads the real ~/.hostname-alias or ~/.local/state.

Describe 'host.zsh'
  Include home/dot_local/lib/host.zsh

  setup() {
    SB="$SHELLSPEC_TMPBASE/host"; rm -rf "$SB"; mkdir -p "$SB"
    HOST_ALIASES_FILE="$SB/aliases"
    HOST_SELF_ALIAS_FILE="$SB/self-alias"
    printf 'peer-key-01 peer-laptop\nbuild-7.lan build-box\n' >"$HOST_ALIASES_FILE"
    printf 'desk-box\n' >"$HOST_SELF_ALIAS_FILE"
  }
  BeforeEach 'setup'

  It 'names a mapped machine by its alias'
    When call host::display peer-key-01
    The output should equal 'peer-laptop'
  End

  It 'matches a key containing dots literally'
    When call host::display build-7.lan
    The output should equal 'build-box'
  End

  It 'names this machine by its own alias'
    When call host::display self-key self-key
    The output should equal 'desk-box'
  End

  # The sender strips CR and outer whitespace; the reader must agree.
  It 'trims CRLF and outer whitespace from the own-alias file'
    printf '  desk-box \t\r\n' >"$HOST_SELF_ALIAS_FILE"
    When call host::display self-key self-key
    The output should equal 'desk-box'
  End

  It 'keeps the key for an own alias with inner whitespace'
    printf 'desk box\n' >"$HOST_SELF_ALIAS_FILE"
    When call host::display self-key self-key
    The output should equal 'self-key'
  End

  It 'keeps an unknown key as it is'
    When call host::display stranger-9
    The output should equal 'stranger-9'
  End

  It 'keeps the key when the map is missing'
    HOST_ALIASES_FILE="$SB/nope"
    When call host::display peer-key-01
    The output should equal 'peer-key-01'
  End

  It 'keeps its own key when the own-alias file is missing'
    HOST_SELF_ALIAS_FILE="$SB/nope"
    When call host::display self-key self-key
    The output should equal 'self-key'
  End

  # Review Focus: a corrupted line is never shown.
  It 'rejects a CRLF-terminated alias'
    printf 'peer-key-02 bad-alias\r\n' >>"$HOST_ALIASES_FILE"
    When call host::display peer-key-02
    The output should equal 'peer-key-02'
  End

  It 'rejects an alias with shell or SQL metacharacters'
    printf "peer-key-03 x';DROP\n" >>"$HOST_ALIASES_FILE"
    When call host::display peer-key-03
    The output should equal 'peer-key-03'
  End

  It 'builds a CASE expression from the valid lines'
    When call host::sql_case source_host
    The output should equal "(CASE source_host WHEN 'peer-key-01' THEN 'peer-laptop' WHEN 'build-7.lan' THEN 'build-box' ELSE source_host END)"
  End

  It 'returns the bare column when the map is empty'
    : >"$HOST_ALIASES_FILE"
    When call host::sql_case source_host
    The output should equal 'source_host'
  End

  # Review Focus: tampered lines are never inlined into SQL.
  It 'never inlines an invalid line into SQL'
    printf "evil' OR 1=1 -- x\npeer-key-04 ok'alias\n" >>"$HOST_ALIASES_FILE"
    When call host::sql_case source_host
    The output should not include "evil"
    The output should not include "ok'alias"
  End

  It 'produces SQL that sqlite evaluates to the alias'
    check() {
      local expr; expr="$(host::sql_case h)"
      sqlite3 :memory: "CREATE TABLE t(h TEXT); INSERT INTO t VALUES('peer-key-01'),('stranger-9'); SELECT $expr FROM t ORDER BY rowid;"
    }
    When call check
    The line 1 of output should equal 'peer-laptop'
    The line 2 of output should equal 'stranger-9'
  End
End
