# Tests for home/dot_local/lib/fzf-tab-rich.zsh — the type classifier and the
# glyph/color maps used to enrich fzf-tab candidates.
Describe 'fzf-tab-rich.zsh'
  Include home/dot_local/lib/fzf-tab-rich.zsh

  setup()   { TEST_TMP=$(mktemp -d); }
  cleanup() { rm -rf "$TEST_TMP"; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  Describe 'ftb_rich::_esc'
    It 'converts a hex color to a truecolor escape'
      esc() { ftb_rich::_esc '#f9e2af'; }
      When call esc
      The output should equal "$(printf '\033[38;2;249;226;175m')"
    End
    It 'emits nothing for an invalid hex'
      esc() { ftb_rich::_esc 'nope'; }
      When call esc
      The output should equal ''
    End
  End

  Describe 'ftb_rich::classify (filesystem)'
    cls() { ftb_rich::classify "$1" "$2" && print -r -- "$REPLY"; }

    It 'classifies a directory'
      mkdir "$TEST_TMP/d"
      When call cls '' "$TEST_TMP/d"
      The output should equal 'directory'
    End
    It 'classifies a symlink'
      : > "$TEST_TMP/real"; ln -s "$TEST_TMP/real" "$TEST_TMP/lnk"
      When call cls '' "$TEST_TMP/lnk"
      The output should equal 'symlink'
    End
    It 'classifies an executable'
      : > "$TEST_TMP/x"; chmod +x "$TEST_TMP/x"
      When call cls '' "$TEST_TMP/x"
      The output should equal 'executable'
    End
    It 'classifies a regular file'
      : > "$TEST_TMP/f"
      When call cls '' "$TEST_TMP/f"
      The output should equal 'file'
    End
  End

  Describe 'ftb_rich::classify (group description)'
    cls() { ftb_rich::classify "$1" "$2" && print -r -- "$REPLY"; }

    Parameters
      'shell function'        function
      'shell builtin command' builtin
      'alias'                 alias
      'external command'      command
      'parameter'             variable
      'option'                option
      'command flag'          option
      'argument'              argument
      'value'                 value
      'branch'                git-ref
      'process ID'            process
      'wat'                   fallback
    End
    It "maps '$1' -> $2"
      When call cls "$1" ''
      The output should equal "$2"
    End
  End

  Describe 'glyph map'
    It 'has a glyph for every classifier output type'
      types=(directory file executable symlink command builtin function alias variable option argument value git-ref process fallback)
      missing=''
      for t in $types; do [[ -n ${_ftb_rich_glyph[$t]} ]] || missing+="$t "; done
      When call print -r -- "$missing"
      The output should equal ''
    End
  End

  Describe 'ftb_rich::render'
    # Build one _ftb_complist entry: field1 \0 field2(key) \0 field3(suffix).
    nul=$'\0'; bs=$'\2'
    entry() { print -rn -- "$1$nul$2$nul$3"; }
    # Extract field 2 the way fzf-tab does on accept.
    key_of() { local e=$1; print -rn -- "${${e#*$nul}%$nul*}"; }

    It 'prepends a glyph and preserves the accept key (field 2) byte-for-byte'
      _ftb_groups=('external command')
      _ftb_compcap=("git${bs}word${nul}git${nul}group${nul}1")
      _ftb_complist=("$(entry $'\e[33m' git '')")
      ftb_rich::render
      When call key_of "$_ftb_complist[1]"
      The output should equal 'git'
    End

    It 'adds the command glyph for an external-command group'
      _ftb_groups=('external command')
      _ftb_compcap=("git${bs}word${nul}git${nul}group${nul}1")
      _ftb_complist=("$(entry $'\e[33m' git '')")
      ftb_rich::render
      When call print -rn -- "$_ftb_complist[1]"
      The output should include "${_ftb_rich_glyph[command]}"
    End

    It 'uses the directory glyph derived from a / suffix in degrade mode'
      FZF_TAB_RICH_MAX=0            # force the degrade path
      _ftb_groups=(); _ftb_compcap=()
      _ftb_complist=("$(entry '' somedir /)")
      ftb_rich::render
      When call print -rn -- "$_ftb_complist[1]"
      The output should include "${_ftb_rich_glyph[directory]}"
    End

    It 'is a no-op body-wise when FZF_TAB_RICH_MAX degrade still keeps field 2'
      FZF_TAB_RICH_MAX=0
      _ftb_complist=("$(entry '' foo.txt '')")
      ftb_rich::render
      When call key_of "$_ftb_complist[1]"
      The output should equal 'foo.txt'
    End

    # Regression: a candidate whose display key exists in more than one group
    # (e.g. `system-update` is both an external command AND a shell function).
    # The compcap lookup must not blindly take the first match — it should pick
    # the type that actually runs (zsh shadowing: function shadows the command).
    It 'picks the shadowing type (function over command) for a key in two groups'
      _ftb_groups=('external command' 'shell function')
      _ftb_compcap=(
        "system-update${bs}word${nul}system-update${nul}group${nul}1"
        "system-update${bs}word${nul}system-update${nul}group${nul}2"
      )
      _ftb_complist=("$(entry $'\e[33m' system-update '')")
      ftb_rich::render
      When call print -rn -- "$_ftb_complist[1]"
      The output should include "${_ftb_rich_glyph[function]}"
    End
  End
End
