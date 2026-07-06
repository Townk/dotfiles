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
    # fzf runs with --ansi and STRIPS SGR escapes from the line it returns, so
    # the string fzf-tab looks up in _ftb_compcap is the *visible* text. Mirror
    # that here — matching against the raw colored field 2 would mask the exact
    # accept-time mismatch this recolor path has to avoid.
    strip_sgr() { emulate -L zsh -o extendedglob; local s=$1; print -rn -- "${s//$'\e'\[[0-9;]#m/}"; }

    It 'keeps the inserted word resolvable after styling field 2'
      _ftb_groups=('external command')
      _ftb_compcap=("git${bs}word${nul}git${nul}group${nul}1")
      _ftb_complist=("$(entry '' git '')")
      ftb_rich::render
      resolve() {
        local choice=$(strip_sgr "$(key_of "$_ftb_complist[1]")")
        local match=${_ftb_compcap[(r)${(b)choice}${bs}*]}
        local -A vv=("${(@0)${match#*$bs}}")
        print -rn -- "$vv[word]"
      }
      When call resolve
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

    # Regression: with MULTIPLE rows each hitting the ambiguous (>1 match) branch
    # — which happens whenever _match/_approximate add duplicate compcap entries —
    # a bare `local m` re-declared per outer iteration made zsh PRINT `m=<value>`
    # (the stale compcap entry) to stdout, dumping a wall of internals. render
    # must emit nothing to stdout.
    It 'does not leak loop internals to stdout across multiple ambiguous rows'
      _ftb_groups=('external command' 'shell function')
      _ftb_compcap=(
        "a${bs}word${nul}a${nul}group${nul}1"
        "a${bs}word${nul}a${nul}group${nul}2"
        "b${bs}word${nul}b${nul}group${nul}1"
        "b${bs}word${nul}b${nul}group${nul}2"
      )
      _ftb_complist=("$(entry '' a '')" "$(entry '' b '')")
      When call ftb_rich::render
      The output should equal ''
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

    # Descriptions: zsh renders "value  -- description"; we drop the "-- " marker
    # and dim the description. The accept key (field 2) and the compcap key are
    # rewritten together, so completion still inserts the bare word.
    It 'colors the value blue, dims the description, drops the "-- " marker'
      _ftb_groups=('alias')
      _ftb_compcap=("git  -- noglob git${bs}word${nul}git")
      _ftb_complist=("$(entry '' 'git  -- noglob git' '')")
      ftb_rich::render
      When call key_of "$_ftb_complist[1]"
      The output should not include ' -- '
      The output should include 'noglob git'
      The output should include "${_ftb_rich_value}"
      The output should include "${_ftb_rich_dim}"
    End

    It 'colors a plain (undescribed) value blue'
      _ftb_groups=('external command')
      _ftb_compcap=("ls${bs}word${nul}ls${nul}group${nul}1")
      _ftb_complist=("$(entry '' ls '')")
      ftb_rich::render
      When call key_of "$_ftb_complist[1]"
      The output should include "${_ftb_rich_value}"
    End

    It 'still resolves accept after the description recolor'
      _ftb_groups=('alias')
      _ftb_compcap=("git  -- noglob git${bs}word${nul}git")
      _ftb_complist=("$(entry '' 'git  -- noglob git' '')")
      ftb_rich::render
      accept() {
        local choice=$(strip_sgr "$(key_of "$_ftb_complist[1]")")
        local match=${_ftb_compcap[(r)${(b)choice}${bs}*]}
        local -A vv=("${(@0)${match#*$bs}}")
        print -rn -- "$vv[word]"
      }
      When call accept
      The output should equal 'git'
    End
  End
End
