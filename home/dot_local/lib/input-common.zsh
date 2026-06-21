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
  local danger=0 warning=0 title="" padding="" inset="" measure=0 width=""
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
      --measure)     measure=1; shift ;;
      --width)       width="${2-}"; shift 2 ;;
      --icon|--margin|--header) shift 2 ;;
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

  if ((measure)); then
    flags+=(--measure)
    [[ -n "$width" ]] && flags+=(--width "$width")
    "$bin" "${flags[@]}"
    return
  fi

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
  local prompt="" placeholder="" value="" width="" title="" padding="" inset="" measure=0
  while (($#)); do
    case "$1" in
      --placeholder) placeholder="${2-}"; shift 2 ;;
      --value)       value="${2-}"; shift 2 ;;
      --width)       width="${2-}"; shift 2 ;;
      --title)       title="${2-}"; shift 2 ;;
      --padding)     padding="${2-}"; shift 2 ;;
      --inset)       inset="${2-}"; shift 2 ;;
      --header)      prompt="${2-}"; shift 2 ;;
      --measure)     measure=1; shift ;;
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

  if ((measure)); then
    flags+=(--measure)
    [[ -n "$width" ]] && flags+=(--width "$width")
    "$bin" "${flags[@]}"
    return
  fi

  local answer rc=0
  answer="$("$bin" "${flags[@]}")" || rc=$?
  ((rc != 0)) && return 130
  [[ -n "$answer" ]] || return 130
  print -rn -- "$answer"
}

# input::text "Q" [--value V] [--height N] — multi-line via ai-assist-input,
# which self-renders matching chrome (title + rule + box).
input::text() {
  local prompt="" value="" height="" title="" width="" measure=0
  while (($#)); do
    case "$1" in
      --value)   value="${2-}"; shift 2 ;;
      --height)  height="${2-}"; shift 2 ;;
      --title)   title="${2-}"; shift 2 ;;
      --header)  prompt="${2-}"; shift 2 ;;
      --width)   width="${2-}"; shift 2 ;;
      --measure) measure=1; shift ;;
      --icon|--margin|--padding) shift 2 ;;
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
  theme::args; args+=("${AI_THEME_ARGS[@]}")

  if ((measure)); then
    args+=(--measure)
    [[ -n "$width" ]] && args+=(--width "$width")
    "$bin" "${args[@]}"
    return
  fi

  local answer rc=0
  answer="$("$bin" "${args[@]}")" || rc=$?
  ((rc != 0)) && return 130
  [[ -n "$answer" ]] || return 130
  print -rn -- "$answer"
}

# input::choose "Q" [--multi] [--other LABEL] [--title T] [CHOICE...] — shim
# over `ai-assist-input --type choose`. Choices via argv (after first positional
# or after --). --multi: selections joined by newline. 130 on cancel/empty.
input::choose() {
  local question="" multi=0 other="" title="" measure=0 width=""
  local -a choices
  local _got_prompt=0
  while (($#)); do
    case "$1" in
      --multi)        multi=1; shift ;;
      --multi=*)      multi=1; shift ;;
      --other)        other="${2-}"; shift 2 ;;
      --title)        title="${2-}"; shift 2 ;;
      --header)       [[ -z "$question" ]] && question="${2-}"; shift 2 ;;
      --measure)      measure=1; shift ;;
      --width)        width="${2-}"; shift 2 ;;
      --icon|--margin|--padding) shift 2 ;;
      --) shift; choices+=("$@"); break ;;
      -*) shift ;;
      *)  if (( ! _got_prompt )); then question="$1"; _got_prompt=1; else choices+=("$1"); fi; shift ;;
    esac
  done

  local bin; bin="$(_input::bin)"

  local -a flags=(--type choose)
  [[ -n "$title" ]]    && flags+=(--title "$title")
  [[ -n "$question" ]] && flags+=(--prompt "$question")
  ((multi))            && flags+=(--multi)
  [[ -n "$other" ]]    && flags+=(--other "$other")
  theme::args; flags+=("${AI_THEME_ARGS[@]}")

  if ((measure)); then
    flags+=(--measure)
    [[ -n "$width" ]] && flags+=(--width "$width")
    flags+=(-- "${choices[@]}")
    "$bin" "${flags[@]}"
    return
  fi

  flags+=(-- "${choices[@]}")

  local answer rc=0
  answer="$("$bin" "${flags[@]}")" || rc=$?
  ((rc != 0)) && return 130
  [[ -n "$answer" ]] || return 130
  print -rn -- "$answer"
}

# input::form [--title T] [--spec FILE] — shim over `ai-assist-input --type form`.
# Spec read from FILE (--spec) or stdin (written to a temp file); the binary owns
# the tab flow + field rendering. Answers printed as name<US>value joined by RS;
# exit 0 on submit, 130 on cancel.
input::form() {
  local title="" spec_file="" _tmp_spec="" measure=0 width=""
  while (($#)); do
    case "$1" in
      --title)   title="${2-}"; shift 2 ;;
      --spec)    spec_file="${2-}"; shift 2 ;;
      --measure) measure=1; shift ;;
      --width)   width="${2-}"; shift 2 ;;
      --) shift; break ;;
      -*) shift ;;
      *) shift ;;
    esac
  done

  # If no --spec, read stdin into a temp file (the binary requires a seekable
  # file; it also cannot read from the pane's stdin reliably).
  if [[ -z "$spec_file" ]]; then
    _tmp_spec="$(mktemp "${TMPDIR:-/tmp}/iform.XXXXXX")" || return 1
    cat > "$_tmp_spec"
    spec_file="$_tmp_spec"
  fi

  local bin; bin="$(_input::bin)"

  local -a flags=(--type form --spec "$spec_file")
  [[ -n "$title" ]] && flags+=(--title "$title")
  theme::args; flags+=("${AI_THEME_ARGS[@]}")

  if ((measure)); then
    flags+=(--measure)
    [[ -n "$width" ]] && flags+=(--width "$width")
    "$bin" "${flags[@]}"
    local _rc=$?
    [[ -n "$_tmp_spec" ]] && rm -f -- "$_tmp_spec"
    return $_rc
  fi

  local answer rc=0
  answer="$("$bin" "${flags[@]}")" || rc=$?

  [[ -n "$_tmp_spec" ]] && rm -f -- "$_tmp_spec"

  ((rc != 0)) && return 130
  print -rn -- "$answer"
}
