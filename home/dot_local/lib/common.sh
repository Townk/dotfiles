#!/usr/bin/env zsh
# common.sh — base primitives shared by every ~/.local/lib/*-common library and
# the zsh scripts in ~/.local/bin. SOURCED, never executed.
#
# Provides the cross-cutting primitives that used to be copy-pasted (with minor
# drift) into system-package-common.sh, system-secrets-common.sh, pick-common.zsh
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
# Written to work under BOTH zsh (the scripts) and bash (the bats suite sources
# system-package-common.sh, which sources this). Avoid zsh-only syntax here.

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
  C_BLU=""; C_BBL=""; C_GRN=""; C_YEL=""; C_RED=""; C_DIM=""; C_BWH=""; C_RES=""
fi

# --- logging ----------------------------------------------------------------
# One house style across every tool. info/ok go to stdout; warnings and errors
# to stderr. The message rides in a %s arg, so a literal % is safe and no
# backslash escapes are interpreted.
log_info()  { printf '%s→%s %s\n'      "$C_BLU" "$C_RES" "$*"; }
log_ok()    { printf '%s✓%s %s\n'      "$C_GRN" "$C_RES" "$*"; }
log_warn()  { printf '%s⚠%s  %s\n'     "$C_YEL" "$C_RES" "$*" >&2; }
log_error() { printf '%serror:%s %s\n' "$C_RED" "$C_RES" "$*" >&2; }
die()       { log_error "$*"; exit 1; }

# --- help-token dispatch ----------------------------------------------------
# is_help: the FIRST-arg help check, where a bare `help` subcommand counts.
is_help() {
  case "${1:-}" in
    -h|--help|help) return 0 ;;
    *)              return 1 ;;
  esac
}

# args_contain_help: scan a whole arg list for a help FLAG. A bare `help` token
# does NOT count here — it would collide with positional values (service names,
# subcommands, …).
args_contain_help() {
  local a
  for a in "$@"; do
    case "$a" in
      -h|--help) return 0 ;;
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
  (( ${#missing[@]} == 0 )) || die "missing required tool(s): ${missing[*]}"
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
# `for_each ... < <(producer)` rather than a pipe so the tally is reliable in
# both bash and zsh (a piped last stage is a subshell in bash).
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
