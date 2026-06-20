#!/usr/bin/env zsh
# input-common.zsh — input::* themed INLINE widgets (confirm/line/text/choose/
# form). SOURCED, never executed. The portable widget layer any script can use;
# zj::* (zellij.zsh) floats these in a pane. Theme + boilerplate live here once.

_input_self="${(%):-%x}"
source "$(dirname "$_input_self")/theme-common.zsh"
source "$(dirname "$_input_self")/pick-common.zsh"
unset _input_self

# input::confirm "Q" [--default yes|no] [--affirmative T] [--negative T]
#                    [--danger] [--icon G] [--padding SPEC]
# Prints "yes"/"no"; exit 0 (yes) / 1 (no) / 130 (cancel). --danger swaps the
# selection to red AND forces default=no (never default to a destructive act).
input::confirm() {
  local question="" default="yes" affirmative="Yes" negative="No"
  local danger=0 icon="$THEME_ICON_PROMPT" padding=""
  while (($#)); do
    case "$1" in
      --default)     default="${2:-yes}"; shift 2 ;;
      --affirmative) affirmative="${2:-Yes}"; shift 2 ;;
      --negative)    negative="${2:-No}"; shift 2 ;;
      --danger)      danger=1; shift ;;
      --icon)        icon="${2-}"; shift 2 ;;
      --padding)     padding="${2-}"; shift 2 ;;
      --margin|--width|--header|--title) shift 2 ;;
      --) shift; break ;;
      -*) shift ;;
      *)  question="$1"; shift ;;
    esac
  done
  [[ -n "$question" ]] || question="${1:-}"

  local gum; gum="${GUM_BIN:-gum}"
  command -v -- "$gum" >/dev/null 2>&1 && gum="$(command -v -- "$gum")"

  local -a flags=("${theme_gum_confirm[@]}" --affirmative "$affirmative" --negative "$negative")
  if ((danger)); then
    flags+=(--selected.background "$C_HEX_DANGER" --default=false)
  elif [[ "$default" == no ]]; then
    flags+=(--default=false)
  else
    flags+=(--default)
  fi
  [[ -n "$padding" ]] && flags+=(--padding "$padding")

  local rc=0
  "$gum" confirm "${flags[@]}" "${icon:+$icon }$question" || rc=$?
  case "$rc" in
    0) print -rn -- "yes"; return 0 ;;
    1) print -rn -- "no";  return 1 ;;
    *) return 130 ;;
  esac
}

# input::line "Q" [--placeholder P] [--value V] [--icon G] [--width N]
input::line() {
  local question="" placeholder="" value="" icon="$THEME_ICON_PROMPT" width=""
  while (($#)); do
    case "$1" in
      --placeholder) placeholder="${2-}"; shift 2 ;;
      --value)       value="${2-}"; shift 2 ;;
      --icon)        icon="${2-}"; shift 2 ;;
      --width)       width="${2-}"; shift 2 ;;
      --header|--title) question="${2-}"; shift 2 ;;
      --margin|--padding) shift 2 ;;
      --) shift; break ;;
      -*) shift ;;
      *)  question="$1"; shift ;;
    esac
  done
  [[ -n "$question" ]] || question="${1:-}"

  local gum; gum="${GUM_BIN:-gum}"
  command -v -- "$gum" >/dev/null 2>&1 && gum="$(command -v -- "$gum")"

  local -a flags=("${theme_gum_input[@]}" --prompt "${icon:+$icon }")
  [[ -n "$question" ]]    && flags+=(--header "$question")
  [[ -n "$placeholder" ]] && flags+=(--placeholder "$placeholder")
  [[ -n "$value" ]]       && flags+=(--value "$value")
  [[ -n "$width" ]]       && flags+=(--width "$width")

  local answer rc=0
  answer="$("$gum" input "${flags[@]}")" || rc=$?
  ((rc != 0)) && return 130
  [[ -n "$answer" ]] || return 130
  print -rn -- "$answer"
}

# input::text "Q" [--value V] [--height N] — multi-line via ai-assist-input,
# which self-renders matching chrome (title + rule + box).
input::text() {
  local question="" value="" height=""
  while (($#)); do
    case "$1" in
      --value)  value="${2-}"; shift 2 ;;
      --height) height="${2-}"; shift 2 ;;
      --header|--title) question="${2-}"; shift 2 ;;
      --icon|--margin|--padding|--width) shift 2 ;;
      --) shift; break ;;
      -*) shift ;;
      *)  question="$1"; shift ;;
    esac
  done
  [[ -n "$question" ]] || question="${1:-}"

  local bin; bin="${AI_ASSIST_INPUT_BIN:-ai-assist-input}"
  command -v -- "$bin" >/dev/null 2>&1 && bin="$(command -v -- "$bin")"

  local -a args=(--title "$question")
  [[ -n "$value" ]]  && args+=(--value "$value")
  [[ -n "$height" ]] && args+=(--height "$height")

  local answer rc=0
  answer="$("$bin" "${args[@]}")" || rc=$?
  ((rc != 0)) && return 130
  [[ -n "$answer" ]] || return 130
  print -rn -- "$answer"
}

# input::choose "Q" [--multi[=SEP]] [CHOICE...] — thin pick::start wrapper in
# selector mode with 1-9 shortcuts. Choices via argv or our stdin. --multi
# joins selections with SEP (default newline).
input::choose() {
  local question="" multi=0 sep=$'\n'
  local -a choices
  while (($#)); do
    case "$1" in
      --multi)   multi=1; shift ;;
      --multi=*) multi=1; sep="${1#--multi=}"; shift ;;
      --header|--title) question="${2-}"; shift 2 ;;
      --icon|--margin|--padding|--width) shift 2 ;;
      --) shift; choices+=("$@"); break ;;
      -*) shift ;;
      *)  choices+=("$1"); shift ;;
    esac
  done

  local -a pick_args=(--selector --selector-shortcuts --header "$question")
  if ((multi)); then
    [[ "$sep" == $'\n' ]] && pick_args+=(--multi) || pick_args+=(--multi="$sep")
  fi

  local answer rc=0
  if ((${#choices})); then
    answer="$(print -rl -- "${choices[@]}" | pick::start "${pick_args[@]}")" || rc=$?
  else
    answer="$(pick::start "${pick_args[@]}")" || rc=$?
  fi
  ((rc != 0)) && return 130
  [[ -n "$answer" ]] || return 130
  print -rn -- "$answer"
}
