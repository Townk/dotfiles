# fzf-tab-rich.zsh — type-glyph enrichment for the fzf-tab completion menu.
#
# Sourced from ~/.config/zsh/completion.sh AFTER the theme palette and the
# fzf-tab plugin. The enrichment runs ONLY from fzf-tab's render path (a wrapper
# around -ftb-generate-complist installed in completion.sh), so the native zsh
# menu and every non-fzf-tab surface fall back to unmodified behavior.
#
# It prepends a colored, per-type Nerd Font glyph to each candidate and never
# touches fzf-tab's field 2 (the accept key) — descriptions zsh bakes into the
# candidate are shown by fzf-tab as-is.

# ── color helper ─────────────────────────────────────────────────────────────
# ftb_rich::_esc <#rrggbb> -> truecolor SGR escape (nothing if hex is invalid).
ftb_rich::_esc() {
  emulate -L zsh -o extended_glob
  local h=${1#\#}
  [[ $h == [[:xdigit:]](#c6) ]] || return 0
  print -rn -- $'\e['"38;2;$((16#${h[1,2]}));$((16#${h[3,4]}));$((16#${h[5,6]}))m"
}

typeset -g FTB_RICH_RESET=$'\e[0m'

# ── type -> glyph (Nerd Font code points, \U 8-hex form) ─────────────────────
typeset -gA _ftb_rich_glyph=(
  directory  $'\U000F024B'  file      $'\U000F0214'  executable $'\U000F0493'
  symlink    $'\U000F0339'  command   $'\U0000F120'  builtin    $'\U000F01A7'
  function   $'\U000F0295'  alias     $'\U000F0054'  variable   $'\U000F0AE7'
  option     $'\U000F023B'  argument  $'\U000F0169'  value      $'\U000F0173'
  git-ref    $'\U000F062C'  process   $'\U000F035B'  fallback   $'\U000F01D8'
)

# ── type -> palette role (resolved to an escape once, at source time) ────────
typeset -gA _ftb_rich_role=(
  directory  C_ROLE_UI_ACCENT        file      C_ROLE_UI_FG_DIM
  executable C_ROLE_STATE_SUCCESS    symlink   C_ROLE_STATE_INFO
  command    C_ROLE_UI_FG            builtin   C_ROLE_UI_FG
  function   C_ROLE_ACTION_PRIMARY   alias     C_ROLE_STATE_HINT
  variable   C_ROLE_STATE_WARNING    option    C_ROLE_STATE_HINT
  argument   C_ROLE_UI_MUTED         value     C_ROLE_UI_MUTED
  git-ref    C_ROLE_ACTION_ATTENTION process   C_ROLE_STATE_INFO
  fallback   C_ROLE_UI_MUTED
)

typeset -gA _ftb_rich_color=()
() {
  local t
  for t in ${(k)_ftb_rich_glyph}; do
    _ftb_rich_color[$t]="$(ftb_rich::_esc "${(P)_ftb_rich_role[$t]}")"
  done
}

# ── classifier ───────────────────────────────────────────────────────────────
# ftb_rich::classify <group_desc> <filepath> -> sets REPLY to one type token.
# filepath is realdir+word for path candidates (may be empty).
typeset -g REPLY
ftb_rich::classify() {
  emulate -L zsh
  local gd=${1:l} fp=$2
  if [[ -n $fp ]]; then
    [[ -d $fp ]] && { REPLY=directory;  return }
    [[ -L $fp ]] && { REPLY=symlink;    return }
    [[ -x $fp ]] && { REPLY=executable; return }
    [[ -e $fp ]] && { REPLY=file;       return }
  fi
  # NOTE: order matters — some group descriptions contain more than one
  # keyword (e.g. "command flag" contains both "command" and "flag"), so
  # more specific patterns must be checked before the broader "command"
  # catch-all. builtin is also kept ahead of command so descriptions like
  # "shell builtin command" classify as builtin, not command.
  case $gd in
    (*function*)             REPLY=function ;;
    (*builtin*)              REPLY=builtin ;;
    (*alias*)                REPLY=alias ;;
    (*parameter*|*variable*) REPLY=variable ;;
    (*option*|*flag*)        REPLY=option ;;
    (*argument*)             REPLY=argument ;;
    (*value*)                REPLY=value ;;
    (*branch*|*commit*|*tag*|*head*) REPLY=git-ref ;;
    (*process*|*job*|*pid*)  REPLY=process ;;
    (*command*)              REPLY=command ;;
    (*)                      REPLY=fallback ;;
  esac
  return 0
}

# ── shadowing precedence ─────────────────────────────────────────────────────
# A display key can resolve to more than one group — e.g. `system-update` is
# both an external command and a shell function. fzf-tab keys candidates by the
# display string, so we can't tell which row is which from _ftb_complist alone.
# Pick the type zsh would actually run: alias > function > builtin > command.
# Anything outside that ladder (or a tie) keeps the first type. Sets REPLY.
typeset -gA _ftb_rich_shadow_rank=( alias 1 function 2 builtin 3 command 4 )
ftb_rich::_shadow_pick() {
  emulate -L zsh
  local t best=$1 r; local -i bestrank=99
  for t in "$@"; do
    r=${_ftb_rich_shadow_rank[$t]:-50}
    (( r < bestrank )) && { bestrank=$r; best=$t }
  done
  REPLY=$best
}

# ── render ───────────────────────────────────────────────────────────────────
# Rewrite _ftb_complist in place: prepend a colored type glyph to field 1 of
# each entry. Field 2 (accept key) and field 3 (suffix) are preserved verbatim;
# no NULs are added. Above FZF_TAB_RICH_MAX candidates, take a cheap path that
# derives the glyph from field 3's suffix (no _ftb_compcap lookup).
ftb_rich::render() {
  emulate -L zsh
  (( $#_ftb_complist )) || return 0
  local nul=$'\0' bs=$'\2'
  local -i degrade=0
  (( $#_ftb_complist > ${FZF_TAB_RICH_MAX:-400} )) && degrade=1

  local entry f2 f3 filepath word g c
  local -A v
  local -a out=()

  for entry in $_ftb_complist; do
    f2=${${entry#*$nul}%$nul*}          # accept key (between first & last NUL)
    f3=${entry##*$nul}                  # suffix (after last NUL)

    if (( degrade )); then
      case $f3 in
        (*/) REPLY=directory ;;
        (*@) REPLY=symlink ;;
        (*)  REPLY=file ;;
      esac
    else
      # Gather ALL compcap entries for this display key, not just the first:
      # a key can appear in multiple groups (a name that is both a function and
      # an external command). Reverse-subscript `(r)` would take only the first.
      local -a matches=(${(M)_ftb_compcap:#${(b)f2}${bs}*})
      if (( $#matches == 0 )); then
        REPLY=fallback
      elif (( $#matches == 1 )); then
        v=("${(@0)${matches[1]#*$bs}}")
        word=${(Q)v[word]}
        filepath=''
        (( $+v[realdir] )) && filepath=${v[realdir]}$word
        ftb_rich::classify "${_ftb_groups[${v[group]:-0}]:-}" "$filepath"
      else
        # Ambiguous key: classify each group's entry, then pick by shadowing.
        local -a types=(); local m
        for m in $matches; do
          v=("${(@0)${m#*$bs}}")
          word=${(Q)v[word]}
          filepath=''
          (( $+v[realdir] )) && filepath=${v[realdir]}$word
          ftb_rich::classify "${_ftb_groups[${v[group]:-0}]:-}" "$filepath"
          types+=$REPLY
        done
        ftb_rich::_shadow_pick $types
      fi
    fi

    g=${_ftb_rich_glyph[$REPLY]:-$_ftb_rich_glyph[fallback]}
    c=${_ftb_rich_color[$REPLY]:-}
    out+="${c}${g}${FTB_RICH_RESET}  ${entry}"
  done

  _ftb_complist=("${(@)out}")
  return 0
}
