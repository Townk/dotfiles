#!/usr/bin/env zsh
# common.zsh — base primitives shared by every ~/.local/lib/*-common library and
# the zsh scripts in ~/.local/bin. SOURCED, never executed.
#
# Provides the cross-cutting primitives that used to be copy-pasted (with minor
# drift) into system-package-common.zsh, system-secrets-common.zsh, pick-common.zsh
# and the commit-* / system-update scripts:
#   * the ANSI palette (C_*), gated on an interactive stdout
#   * logging: log_info / log_ok / log_warn / log_error / die
#   * help-token dispatch: is_help / args_contain_help
#   * command presence: require_cmd
#
# Domain libraries keep their OWN namespaced helpers (pkg::manifest_read,
# sec::rebuild_slot, pick::start, svc::*); only these neutral primitives live
# here, under one canonical name each. Convention: library functions are
# namespaced with `::`; this shared base stays bare (it is the stdlib, not a
# module); module constants stay UPPER_SNAKE (PKG_DIR, LAUNCH_AGENTS, …) since
# `::` is not valid in shell variable names.
#
# Sourced under zsh by the ~/.local/bin scripts, the *-common libraries, and the
# ShellSpec suite (which runs under zsh).

# Idempotent: a script may pull this in more than once (e.g. transitively via a
# *-common library and again directly) without redefining everything.
[ -n "${__COMMON_SH_LOADED:-}" ] && return 0
__COMMON_SH_LOADED=1

# --- palette (full superset; only emitted when stdout is a terminal) --------
if [ -t 1 ]; then
  C_BLU=$'\e[34m'
  C_BBL=$'\e[94m'
  C_GRN=$'\e[32m'
  C_YEL=$'\e[33m'
  C_RED=$'\e[31m'
  C_DIM=$'\e[2m'
  C_BWH=$'\e[1;37m'
  C_RES=$'\e[0m'
else
  C_BLU=""
  C_BBL=""
  C_GRN=""
  C_YEL=""
  C_RED=""
  C_DIM=""
  C_BWH=""
  C_RES=""
fi

# --- extended truecolor palette (Catppuccin Mocha) for dialog chrome ---------
# C_HEX_* are bare hex values (UNGATED): passed as explicit color args to gum,
# which owns its own tty, so they must exist even when our stdout is captured.
# The SGR C_* twins below are gated like the base palette so non-terminal
# output stays escape-free. THEME_* tokens (theme-common.zsh) compose from these.
C_HEX_MAUVE="#cba6f7"
C_HEX_TEXT="#cdd6f4"
C_HEX_SUBTEXT="#a6adc8"
C_HEX_SURFACE0="#313244"
C_HEX_SURFACE2="#585b70"
C_HEX_OVERLAY0="#6c7086"
C_HEX_BASE="#1e1e2e"
C_HEX_DANGER="#f38ba8"
if [ -t 1 ]; then
  C_MAUVE=$'\e[38;2;203;166;247m'
  C_TEXT=$'\e[38;2;205;214;244m'
  C_SUBTEXT=$'\e[38;2;166;173;200m'
  C_SURFACE0=$'\e[38;2;49;50;68m'
  C_SURFACE2=$'\e[38;2;88;91;112m'
  C_OVERLAY0=$'\e[38;2;108;112;134m'
  C_BASE=$'\e[38;2;30;30;46m'
  C_DANGER=$'\e[38;2;243;139;168m'
  C_BOLD=$'\e[1m'
else
  C_MAUVE="" C_TEXT="" C_SUBTEXT="" C_SURFACE0="" C_SURFACE2="" \
    C_OVERLAY0="" C_BASE="" C_DANGER="" C_BOLD=""
fi

# --- logging ----------------------------------------------------------------
# One house style across every tool. info/ok go to stdout; warnings and errors
# to stderr. The message rides in a %s arg, so a literal % is safe and no
# backslash escapes are interpreted.
log_info() { printf '%s→%s %s\n' "$C_BLU" "$C_RES" "$*"; }
log_ok() { printf '%s✓%s %s\n' "$C_GRN" "$C_RES" "$*"; }
log_warn() { printf '%s⚠%s  %s\n' "$C_YEL" "$C_RES" "$*" >&2; }
log_error() { printf '%serror:%s %s\n' "$C_RED" "$C_RES" "$*" >&2; }
die() {
  log_error "$*"
  exit 1
}

# --- help-token dispatch ----------------------------------------------------
# is_help: the FIRST-arg help check, where a bare `help` subcommand counts.
is_help() {
  case "${1:-}" in
    -h | --help | help) return 0 ;;
    *) return 1 ;;
  esac
}

# args_contain_help: scan a whole arg list for a help FLAG. A bare `help` token
# does NOT count here — it would collide with positional values (service names,
# subcommands, …).
args_contain_help() {
  local a
  for a in "$@"; do
    case "$a" in
      -h | --help) return 0 ;;
    esac
  done
  return 1
}

# --- command presence -------------------------------------------------------
# Die listing EVERY missing command, so the user fixes one round of installs
# instead of rerunning to discover the next gap.
require_cmd() {
  local c
  local -a missing
  missing=()
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  ((${#missing[@]} == 0)) || die "missing required tool(s): ${missing[*]}"
}

# --- terminal --------------------------------------------------------------
# have_tty: true when we can reach a controlling terminal for interaction —
# stdin is a tty, or /dev/tty is openable even when stdin is a pipe. Used by
# the prompt helpers and any tool deciding whether to show interactive UI.
have_tty() { [ -t 0 ] || [ -e /dev/tty ]; }

# --- iteration with a failure tally -----------------------------------------
# for_each <label> <fn>   (items on stdin, one per line)
# Run <fn> "<item>" for each non-empty line, counting the ones that return
# non-zero. <fn> is responsible for any per-item message; for_each emits a
# "<label>: N of M failed" summary when any failed and returns the failure
# count (0 = all succeeded). The loop runs in the caller's shell — feed it with
# `for_each ... < <(producer)` rather than a pipe so the tally is reliable
# (a piped last stage runs in a subshell, which would lose the count).
for_each() {
  local label="$1" fn="$2" item total=0 failures=0
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    total=$((total + 1))
    "$fn" "$item" || failures=$((failures + 1))
  done
  [ "$failures" -gt 0 ] && log_warn "$label: $failures of $total failed"
  return "$failures"
}

# --- notifications ----------------------------------------------------------
# notify [--icon SPEC] [--sound NAME] [--ansi] MESSAGE...
#
# Show a transient on-screen notification through the already-running
# Hammerspoon's custom OSD (the same widget used for volume/brightness), via
# the global `notify`/`notifyAnsi` Lua helpers it exposes. This is our
# replacement for terminal-notifier: ephemeral, consistent, with a chosen icon
# and system sound — and it actually honours both on current macOS.
#
#   --icon  SPEC   OSD icon: an SVG name, `glyph:<nerd-font-name>`, or
#                  `swatch:#RRGGBB`. Omitted → no icon.
#   --sound NAME   System sound (System Settings → Sound), e.g. Frog/Glass.
#                  Omitted/empty → silent.
#   --ansi         MESSAGE may carry ANSI SGR colour escapes (routes to the
#                  `notifyAnsi` helper instead of `notify`).
#
# Best-effort by design: it drives the running Hammerspoon through its `hs`
# CLI (path overridable via $HS). Returns 1 (quietly) when `hs` is unavailable
# and 2 when there is nothing to show, so callers on hot paths can ignore the
# result. Synchronous — background it (`notify ... &`) where a stray OSD hiccup
# must never delay the caller.
notify() {
  local icon="" sound="" fn="notify"
  while [ $# -gt 0 ]; do
    case "$1" in
      -i | --icon)
        if [ $# -ge 2 ]; then
          icon="$2"
          shift 2
        else shift; fi
        ;;
      --icon=*)
        icon="${1#--icon=}"
        shift
        ;;
      -s | --sound)
        if [ $# -ge 2 ]; then
          sound="$2"
          shift 2
        else shift; fi
        ;;
      --sound=*)
        sound="${1#--sound=}"
        shift
        ;;
      --ansi)
        fn="notifyAnsi"
        shift
        ;;
      --)
        shift
        break
        ;;
      *) break ;;
    esac
  done

  local text="$*"
  [ -n "$text" ] || [ -n "$icon" ] || return 2

  local hs="${HS:-/opt/homebrew/bin/hs}"
  [ -x "$hs" ] || hs="$(command -v hs 2>/dev/null || true)"
  [ -n "$hs" ] && [ -x "$hs" ] || return 1

  # `hs -c` runs inside the already-running Hammerspoon process, so client
  # environment variables are invisible there; pass every argument as a Lua
  # string literal (or bare `nil` when empty).
  local cmd
  cmd="$fn($(_notify_lua_arg "$icon"), $(_notify_lua_arg "$text"), $(_notify_lua_arg "$sound"))"

  # The `hs` CLI blocks on its Mach-port lookup when it can't reach the running
  # Hammerspoon (it's not running, or we're in a different launch context), and
  # its own `-t` timeout does not bound that wait. Cap it with timeout(1) so a
  # stuck lookup can never wedge the caller; on its own this stays synchronous.
  if command -v gtimeout >/dev/null 2>&1; then
    gtimeout 5 "$hs" -t 4 -c "$cmd"
  elif command -v timeout >/dev/null 2>&1; then
    timeout 5 "$hs" -t 4 -c "$cmd"
  else
    "$hs" -t 4 -c "$cmd"
  fi
}

# _notify_lua_arg VALUE — emit a Lua literal on stdout: a double-quoted,
# escaped string, or bare `nil` when VALUE is empty. Private to notify().
_notify_lua_arg() {
  [ -n "$1" ] || {
    printf 'nil'
    return 0
  }
  local v="$1"
  v="${v//\\/\\\\}"
  v="${v//\"/\\\"}"
  v="${v//$'\033'/\\27}"
  v="${v//$'\n'/\\n}"
  v="${v//$'\r'/\\r}"
  v="${v//$'\t'/\\t}"
  printf '"%s"' "$v"
}
