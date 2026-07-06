# fzf-tab-rich.zsh — type-glyph enrichment for the fzf-tab completion menu.
#
# Sourced from ~/.config/zsh/completion.sh AFTER the theme palette and the
# fzf-tab plugin. The enrichment runs ONLY from fzf-tab's render path (a wrapper
# around -ftb-generate-complist installed in completion.sh), so the native zsh
# menu and every non-fzf-tab surface fall back to unmodified behavior.
#
# It prepends a colored, per-type Nerd Font glyph to each candidate and recolors
# field 2 for DISPLAY (blue value, dimmed description). fzf runs with --ansi and
# strips SGR escapes from the line it hands back on accept, so the accept/preview
# lookups key on the *visible* text — not the escaped one. The matching
# _ftb_compcap key is therefore rewritten to that plain visible text so the
# lookups still resolve.

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

# Value (candidate) color = blue; description half = muted grey.
typeset -g _ftb_rich_value="$(ftb_rich::_esc "${C_HEX_BLUE:-}")"
typeset -g _ftb_rich_dim="$(ftb_rich::_esc "${C_ROLE_UI_MUTED:-}")"

# ── display styling ───────────────────────────────────────────────────────────
# zsh renders a described match as "value<pad>-- description" (-- is the default
# list-separator). Restyle into "<blue>value<reset>   <dim>description<reset>":
# color the candidate blue, drop the "-- " marker, and dim the description so it
# reads as secondary. Sets REPLY. Used for _ftb_complist field 2 (the DISPLAY
# string). The compcap key gets ftb_rich::_plain instead — the same text
# transform WITHOUT the SGR escapes — because fzf strips ANSI from the line it
# returns, so the accept/preview lookups match on the visible text.
ftb_rich::_style() {
  emulate -L zsh
  local s=$1
  if [[ $s == *' -- '* ]]; then
    REPLY="${_ftb_rich_value}${s%% -- *}${FTB_RICH_RESET}   ${_ftb_rich_dim}${s#* -- }${FTB_RICH_RESET}"
  else
    REPLY="${_ftb_rich_value}${s}${FTB_RICH_RESET}"
  fi
}

# ftb_rich::_plain — the visible text ftb_rich::_style produces, sans color: same
# "-- " → three-space transform, no SGR. This is exactly what fzf hands back on
# accept (it strips ANSI under --ansi), so it's what the compcap key must equal.
# Sets REPLY.
ftb_rich::_plain() {
  emulate -L zsh
  local s=$1
  if [[ $s == *' -- '* ]]; then
    REPLY="${s%% -- *}   ${s#* -- }"
  else
    REPLY="$s"
  fi
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

  # Declare every loop-scoped local ONCE, here — never with a bare `local` inside
  # the loop. In zsh a bare `local m` (no assignment), re-run on a later iteration
  # when `m` already exists, PRINTS `m=<value>` to stdout (typeset's "show the
  # parameter" behavior) — which would dump compcap entries onto the terminal.
  local entry f2 f3 f1 new_f2 filepath word g c m cc
  local -A v
  local -a out=() matches types newcc

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
      matches=(${(M)_ftb_compcap:#${(b)f2}${bs}*})
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
        types=()
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
    # Style field 2 (blue value, dimmed description). REPLY is reused by _style,
    # so read the glyph/color from it (above) BEFORE this call. Rebuild the entry
    # with the restyled field 2; field 1 and field 3 are preserved. In degrade
    # mode we leave field 2 raw — the compcap keys aren't rewritten there (below),
    # so styling field 2 would desync it from the accept key.
    if (( degrade )); then
      new_f2=$f2
    else
      ftb_rich::_style "$f2"; new_f2=$REPLY
    fi
    f1=${entry%%$nul*}
    out+="${c}${g}${FTB_RICH_RESET}  ${f1}${nul}${new_f2}${nul}${f3}"
  done
  _ftb_complist=("${(@)out}")

  # Rewrite each compcap key to the PLAIN visible form of the restyled field 2 —
  # fzf strips ANSI from the line it returns on accept, so the accept/preview
  # lookups key on the visible text, not the escaped one. (Rewriting to the
  # escaped form silently breaks accept: the stripped choice never matches.)
  # Skipped in degrade mode, which never rewrote field 2 above.
  (( degrade )) && return 0
  newcc=()
  for cc in $_ftb_compcap; do
    ftb_rich::_plain "${cc%%$bs*}"
    newcc+="${REPLY}${bs}${cc#*$bs}"
  done
  _ftb_compcap=("${(@)newcc}")
  return 0
}
