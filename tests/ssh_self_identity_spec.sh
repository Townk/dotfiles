# run_after_09-render-ssh-self-identity: renders the LOOSE sender fragment
# ~/.ssh/config.d/00-self-identity.conf from this machine's ~/.hostname-alias
# and clipboard key (peer-alias spec H2). The template has no data
# dependencies, so setup renders it once and each example runs it in an
# isolated $HOME with a sandboxed self-name file.
Describe 'ssh self-identity sender'
  SRC="$SHELLSPEC_PROJECT_ROOT/home/.chezmoiscripts/run_after_09-render-ssh-self-identity.sh.tmpl"

  setup() {
    TEST_TMP=$(mktemp -d "$SHELLSPEC_TMPBASE/self-id.XXXXXX")
    export HOME="$TEST_TMP/home"
    export XDG_STATE_HOME="$HOME/.local/state"
    mkdir -p "$HOME/.ssh/config.d" "$XDG_STATE_HOME/clipboard"
    printf 'peer-key-01\n' >"$XDG_STATE_HOME/clipboard/self-name"
    export SELF_IDENTITY_CORE_LIB="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib/clipboard-store-core.zsh"
    RENDERED="$TEST_TMP/self-identity.sh"
    chezmoi execute-template <"$SRC" >"$RENDERED"
    chmod +x "$RENDERED"
    FRAG="$HOME/.ssh/config.d/00-self-identity.conf"
  }
  cleanup() { rm -rf "$TEST_TMP"; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  It 'renders the SetEnv line from the alias file and the clipboard key'
    printf 'peer-laptop\n' >"$HOME/.hostname-alias"
    run() { "$RENDERED" 2>/dev/null; cat "$FRAG"; }
    When call run
    The line 1 of output should equal '# Written by chezmoi run_after_09 from ~/.hostname-alias — do not edit.'
    The line 2 of output should equal 'SetEnv LC_ORIGIN_HOST=peer-key-01 LC_ORIGIN_ALIAS=peer-laptop'
  End

  It 'writes the fragment with mode 600'
    printf 'peer-laptop\n' >"$HOME/.hostname-alias"
    "$RENDERED" 2>/dev/null
    When call sh -c 'ls -l "$1" | cut -c1-10' _ "$FRAG"
    The output should equal '-rw-------'
  End

  # Review Focus: a Windows-edited or padded alias file.
  It 'trims CRLF and trailing space from the alias file'
    printf 'peer-laptop  \r\n' >"$HOME/.hostname-alias"
    "$RENDERED" 2>/dev/null
    When call sed -n 2p "$FRAG"
    The output should equal 'SetEnv LC_ORIGIN_HOST=peer-key-01 LC_ORIGIN_ALIAS=peer-laptop'
  End

  It 'removes the fragment when there is no alias file'
    printf 'stale\n' >"$FRAG"
    "$RENDERED" 2>/dev/null
    When call test -e "$FRAG"
    The status should be failure
  End

  It 'removes the fragment when the alias is invalid'
    printf 'two words\n' >"$HOME/.hostname-alias"
    printf 'stale\n' >"$FRAG"
    "$RENDERED" 2>/dev/null
    When call test -e "$FRAG"
    The status should be failure
  End

  It 'does not rewrite an unchanged fragment'
    printf 'peer-laptop\n' >"$HOME/.hostname-alias"
    "$RENDERED" 2>/dev/null
    touch -t 200001010000 "$FRAG"; touch -t 200001010001 "$TEST_TMP/ref"
    "$RENDERED" 2>/dev/null
    When call find "$FRAG" -newer "$TEST_TMP/ref"
    The output should equal ''
  End

  # The whole point of rendering on the machine: no host value in the SOURCE.
  It 'keeps every host value out of the source template'
    When call grep -c -E 'peer-key-01|peer-laptop' "$SRC"
    The output should equal '0'
    The status should be failure
  End
End
