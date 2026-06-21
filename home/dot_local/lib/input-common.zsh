#!/usr/bin/env zsh
# input-common.zsh — input::* themed INLINE widgets (confirm/line/text/choose/
# form). SOURCED, never executed. The portable widget layer any script can use;
# zj::* (zellij.zsh) floats these in a pane. Theme + boilerplate live here once.

_input_self="${(%):-%x}"
source "$(dirname "$_input_self")/theme-common.zsh"
source "$(dirname "$_input_self")/pick-common.zsh"
unset _input_self

# _input::bin — resolve the ai-assist-input binary. A zellij-spawned pane's PATH
# does NOT include ~/.local/share/go/bin (only the interactive profile adds it),
# so a bare `command -v` fails there → fall back to the known install paths.
# AI_ASSIST_INPUT_BIN overrides everything (used by tests).
_input::bin() {
  local p
  [[ -n "${AI_ASSIST_INPUT_BIN:-}" ]] && { print -r -- "$AI_ASSIST_INPUT_BIN"; return 0; }
  p="$(command -v ai-assist-input 2>/dev/null)"
  [[ -n "$p" ]] && { print -r -- "$p"; return 0; }
  for p in "$HOME/.local/share/go/bin/ai-assist-input" "$HOME/go/bin/ai-assist-input"; do
    [[ -x "$p" ]] && { print -r -- "$p"; return 0; }
  done
  print -r -- "ai-assist-input"
}

# input::confirm "Q" [--default yes|no] [--affirmative T] [--negative T]
#                    [--danger|--warning] [--title T] [--padding R] [--inset R]
# Shim over `ai-assist-input --type confirm`. Prints "yes"/"no"; exit 0/1/130.
# --danger/--warning recolor border+title+button (the binary forces default=no
# on danger). The themed chrome, keys, and hint all live in the binary now.
input::confirm() {
  local prompt="" default="yes" affirmative="Yes" negative="No"
  local danger=0 warning=0 title="" padding="" inset=""
  while (($#)); do
    case "$1" in
      --default)     default="${2:-yes}"; shift 2 ;;
      --affirmative) affirmative="${2:-Yes}"; shift 2 ;;
      --negative)    negative="${2:-No}"; shift 2 ;;
      --danger)      danger=1; shift ;;
      --warning)     warning=1; shift ;;
      --title)       title="${2-}"; shift 2 ;;
      --padding)     padding="${2-}"; shift 2 ;;
      --inset)       inset="${2-}"; shift 2 ;;
      --icon|--margin|--width|--header) shift 2 ;;
      --) shift; break ;;
      -*) shift ;;
      *)  [[ -z "$prompt" ]] && prompt="$1"; shift ;;
    esac
  done

  local bin; bin="$(_input::bin)"

  local -a flags=(--type confirm --affirmative "$affirmative" --negative "$negative")
  [[ -n "$title" ]]   && flags+=(--title "$title")
  [[ -n "$prompt" ]]  && flags+=(--prompt "$prompt")
  ((danger))          && flags+=(--danger)
  ((warning))         && flags+=(--warning)
  [[ "$default" == no ]] && flags+=(--default negative)
  [[ -n "$padding" ]] && flags+=(--padding "$padding")
  [[ -n "$inset" ]]   && flags+=(--inset "$inset")
  theme::args; flags+=("${AI_THEME_ARGS[@]}")

  # The binary exits 0 (confirmed) / 1 (declined) / 130 (cancel); map to yes/no.
  local rc=0
  "$bin" "${flags[@]}" >/dev/null || rc=$?
  case "$rc" in
    0) print -rn -- "yes"; return 0 ;;
    1) print -rn -- "no";  return 1 ;;
    *) return 130 ;;
  esac
}

# input::line "Q" [--placeholder P] [--value V] [--width N] [--title T]
# Shim over `ai-assist-input --type line`. Prints the typed line; 130 on
# empty/cancel.
input::line() {
  local prompt="" placeholder="" value="" width="" title="" padding="" inset=""
  while (($#)); do
    case "$1" in
      --placeholder) placeholder="${2-}"; shift 2 ;;
      --value)       value="${2-}"; shift 2 ;;
      --width)       width="${2-}"; shift 2 ;;
      --title)       title="${2-}"; shift 2 ;;
      --padding)     padding="${2-}"; shift 2 ;;
      --inset)       inset="${2-}"; shift 2 ;;
      --header)      prompt="${2-}"; shift 2 ;;
      --icon|--margin) shift 2 ;;
      --) shift; break ;;
      -*) shift ;;
      *)  [[ -z "$prompt" ]] && prompt="$1"; shift ;;
    esac
  done

  local bin; bin="$(_input::bin)"

  local -a flags=(--type line)
  [[ -n "$title" ]]       && flags+=(--title "$title")
  [[ -n "$prompt" ]]      && flags+=(--prompt "$prompt")
  [[ -n "$value" ]]       && flags+=(--value "$value")
  [[ -n "$placeholder" ]] && flags+=(--placeholder "$placeholder")
  [[ -n "$padding" ]]     && flags+=(--padding "$padding")
  [[ -n "$inset" ]]       && flags+=(--inset "$inset")
  theme::args; flags+=("${AI_THEME_ARGS[@]}")

  local answer rc=0
  answer="$("$bin" "${flags[@]}")" || rc=$?
  ((rc != 0)) && return 130
  [[ -n "$answer" ]] || return 130
  print -rn -- "$answer"
}

# input::text "Q" [--value V] [--height N] — multi-line via ai-assist-input,
# which self-renders matching chrome (title + rule + box).
input::text() {
  local prompt="" value="" height="" title=""
  while (($#)); do
    case "$1" in
      --value)  value="${2-}"; shift 2 ;;
      --height) height="${2-}"; shift 2 ;;
      --title)  title="${2-}"; shift 2 ;;
      --header) prompt="${2-}"; shift 2 ;;
      --icon|--margin|--padding|--width) shift 2 ;;
      --) shift; break ;;
      -*) shift ;;
      *)  [[ -z "$prompt" ]] && prompt="$1"; shift ;;
    esac
  done

  local bin; bin="$(_input::bin)"

  local -a args=()
  [[ -n "$title" ]]  && args+=(--title "$title")
  [[ -n "$prompt" ]] && args+=(--prompt "$prompt")
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
      *)  if [[ -z "$question" ]]; then question="$1"; else choices+=("$1"); fi; shift ;;
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

# input::form [--title T] [--spec FILE] — present 2-5 fields as a tabbed flow in
# one pane, advancing as the user answers. Spec read from FILE or stdin; answers
# printed as name<US>value records joined by RS. Any field cancel aborts → 130.
# The tab/title chrome is drawn to STDERR (the pane tty) so STDOUT carries only
# the framed answers for the caller/FIFO.
input::form() {
  local title="Questions" spec_file=""
  while (($#)); do
    case "$1" in
      --title) title="${2:-Questions}"; shift 2 ;;
      --spec)  spec_file="${2-}"; shift 2 ;;
      --) shift; break ;;
      -*) shift ;;
      *) shift ;;
    esac
  done

  local US=$'\x1f' RS=$'\x1e' GS=$'\x1d'
  local raw
  if [[ -n "$spec_file" ]]; then raw="$(<"$spec_file")"; else raw="$(cat)"; fi

  local -a f_name f_type f_label f_param parts
  local rec
  for rec in "${(@ps:$RS:)raw}"; do
    [[ -n "$rec" ]] || continue
    parts=("${(@ps:$US:)rec}")
    f_name+=("${parts[1]:-}")
    f_type+=("${parts[2]:-line}")
    f_label+=("${parts[3]:-}")
    f_param+=("${parts[4]:-}")
  done

  local n=${#f_name}
  if ((n < 2 || n > 5)); then
    print -ru2 -- "input::form: need 2-5 fields, got $n"
    return 2
  fi

  local -a answers
  local i j q t p ans d pp mflag
  local -a ch
  local rc
  for ((i = 1; i <= n; i++)); do
    # --- tab/title chrome → stderr (the pane tty); stdout stays answers-only ---
    {
      printf '\033[2J\033[H'
      printf '\n  %s▓▓▓ %s%s\n' "$THEME_H1" "$title" "$THEME_RESET"
      printf '  %s%s%s\n\n  ' "$THEME_SEPARATOR" "$(theme::rule)" "$THEME_RESET"
      for ((j = 1; j <= n; j++)); do
        ((j > 1)) && printf '%s %s %s' "$THEME_COMMENT" "$THEME_ICON_TAB_SEP" "$THEME_RESET"
        if ((j < i)); then
          printf '%s%s %s%s' "$THEME_COMMENT" "$THEME_ICON_CHECK" "${f_label[$j]}" "$THEME_RESET"
        elif ((j == i)); then
          printf '%s%s %s%s' "$THEME_H2" "$THEME_ICON_ACTIVE" "${f_label[$j]}" "$THEME_RESET"
        else
          printf '%s%s%s' "$THEME_COMMENT" "${f_label[$j]}" "$THEME_RESET"
        fi
      done
      printf '\n\n'
    } >&2

    q="${f_label[$i]}" t="${f_type[$i]}" p="${f_param[$i]}"
    ans="" rc=0
    case "$t" in
      line) ans="$(input::line "$q" --placeholder "$p")" || rc=$? ;;
      text) ans="$(input::text "$q")" || rc=$? ;;
      confirm)
        d="yes"; [[ "$p" == no ]] && d="no"
        ans="$(input::confirm "$q" --default "$d")" || rc=$?
        ((rc == 130)) && return 130
        rc=0
        ;;
      choose)
        pp="$p" mflag=0
        [[ "$pp" == multi:* ]] && { mflag=1; pp="${pp#multi:}"; }
        ch=("${(@ps:$GS:)pp}")
        if ((mflag)); then
          ans="$(input::choose "$q" --multi -- "${ch[@]}")" || rc=$?
          ans="${ans//$'\n'/$GS}"
        else
          ans="$(input::choose "$q" -- "${ch[@]}")" || rc=$?
        fi
        ;;
      *) print -ru2 -- "input::form: unknown field type '$t'"; return 2 ;;
    esac
    ((rc != 0)) && return 130
    answers+=("${f_name[$i]}${US}${ans}")
  done

  print -rn -- "${(pj:$RS:)answers}"
}
