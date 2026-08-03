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

# --- Catppuccin palette (single source) -------------------------------------
# C_HEX_* (bare hex, UNGATED — passed as --theme-* args to ai-playbook input,
# which owns its own tty, so they must exist even when our stdout is captured)
# and their gated truecolor SGR twins C_* are generated from
# .chezmoidata/theme.yaml into ~/.config/theme/chezmoi-system.zsh by chezmoi — the
# single styling source of truth. THEME_* tokens (theme-common.zsh) compose from
# these. THEME_PALETTE_FILE overrides the path; the ShellSpec suite renders the
# palette to a temp and points it there, so tests don't require `chezmoi apply`.
# The palette is a GENERATED artifact: on a fresh machine .setup.sh runs
# system-onboard (which sources this lib under set -eu) before the full apply
# renders it, so tolerate the pre-generation window — consumers degrade to
# empty C_HEX_* until the theme exists.
_common_palette="${THEME_PALETTE_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/theme/chezmoi-system.zsh}"
if [[ -r "$_common_palette" ]]; then
  source "$_common_palette"
fi
unset _common_palette

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
have_tty() { [ -t 0 ] || { : </dev/tty; } 2>/dev/null; }

# --- spinner ----------------------------------------------------------------
# One spinner for the whole tree. Everything animates on STDERR, so a caller's
# stdout stays pipeable and the frames never contaminate captured data.
#
# spin::active
# True when a human is watching. SPIN_PROGRESS forces it on (1) or off (0) —
# the seam for tests, schedulers, and callers with their own progress policy.
spin::active() {
  case "${SPIN_PROGRESS:-}" in
    1) return 0 ;;
    0) return 1 ;;
  esac
  [ -t 2 ]
}

# spin::nap [centiseconds]
# One animation tick (default 0.1s) without forking: `sleep` is external in
# zsh, so a spinner would otherwise fork+exec 10×/second for its whole life —
# the only fork in the common silent case. zselect times out with rc 1 and no
# ready fds, so module presence is probed once (same guarded pattern as
# pick-clipboard's CLIP_PROGRESS_ZSELECT); a zsh built without the module
# falls back to `sleep`.
zmodload zsh/zselect 2>/dev/null && typeset -g _common_have_zselect=1 \
  || typeset -g _common_have_zselect=0
spin::nap() {
  local cs="${1:-10}"
  if (( _common_have_zselect )); then
    zselect -t "$cs" 2>/dev/null
    return 0
  fi
  sleep "$(( cs / 100.0 ))"
}

# spin::wait <pid> [title]
# Animate a braille spinner with elapsed seconds while <pid> runs, so a silent
# long job never looks frozen. Returns as soon as the process is gone; the
# CALLER still has to `wait` for its exit status. No-op when nobody's watching.
spin::wait() {
  local pid="$1" title="${2:-}"
  spin::active || return 0
  local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  local start=$SECONDS s=1 elapsed
  while kill -0 "$pid" 2>/dev/null; do
    elapsed=$((SECONDS - start))
    print -nu2 -- "\r  ${C_BLU}${frames[s]}${C_RES} ${title:+$title }${elapsed}s  "
    spin::nap
    s=$((s % 10 + 1))
  done
  print -nu2 -- "\r\e[K"
}

# spin::stream <pid> <file> [title]
# Animate the spinner while <file> stays empty, then — the moment <pid> writes
# its first byte — clear the spinner and mirror <file> to stdout as it grows.
# A silent command shows life; a talking one streams live instead of being
# buffered to the end. Returns once <pid> is gone (after flushing the tail);
# the CALLER still has to `wait` for its exit status.
#
# Mirroring happens even when nobody is watching (no TTY): the animation is
# optional, delivering the command's output never is.
spin::stream() {
  local pid="$1" file="$2" title="${3:-}"
  local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  local start=$SECONDS s=1 elapsed off=1 size spinning=1 active=1 stall=0
  spin::active || { spinning=0; active=0 }
  # `[[ -s ]]` costs no fork, so the common silent case never pays for the
  # size arithmetic below — that starts only once there IS output to mirror.
  while kill -0 "$pid" 2>/dev/null; do
    if [[ -s "$file" ]]; then
      size=$(wc -c <"$file" 2>/dev/null) || size=0
      if ((size >= off)); then
        if ((spinning)); then
          print -nu2 -- "\r\e[K"
          spinning=0
        fi
        tail -c "+$off" "$file"
        off=$((size + 1))
        stall=0
      elif ((active && ++stall >= 5)); then
        # Quiet for ~0.5s mid-stream, so bring the spinner BACK rather than
        # retiring it at the first byte: `brew bundle` announces "Upgrading
        # google-chrome" and then downloads it in silence for minutes, which
        # is exactly the dead air the spinner exists to cover.
        spinning=1
      fi
    fi
    if ((spinning)); then
      elapsed=$((SECONDS - start))
      print -nu2 -- "\r  ${C_BLU}${frames[s]}${C_RES} ${title:+$title }${elapsed}s  "
      s=$((s % 10 + 1))
    fi
    spin::nap
  done
  ((spinning)) && print -nu2 -- "\r\e[K"
  # Whatever landed between the last poll and exit. Without this the final
  # lines of a fast-finishing command would be dropped.
  size=$(wc -c <"$file" 2>/dev/null) || size=0
  ((size >= off)) && tail -c "+$off" "$file"
  return 0
}

# spin::run [--merge-stderr] [--stream] <title> <outfile> <-- cmd...>
# Run <cmd> with its stdout captured to <outfile> while the spinner animates,
# and return <cmd>'s exit status. Only stdout is redirected by default, so
# <outfile> stays clean when it is DATA the caller parses; --merge-stderr folds
# stderr in too, for callers silencing a command purely to cut noise.
#
# Without --stream a captured command that fails dies SILENTLY — the caller
# owns surfacing <outfile> on a non-zero return, or the error is simply lost.
# With --stream the output is mirrored live (see spin::stream) and <outfile> is
# just the conduit, so there is nothing left for the caller to surface.
spin::run() {
  local merge=0 stream=0
  while true; do
    case "${1:-}" in
      --merge-stderr)
        merge=1
        shift
        ;;
      --stream)
        stream=1
        shift
        ;;
      *) break ;;
    esac
  done
  local title="$1" outfile="$2"
  shift 2
  [[ "${1:-}" == -- ]] && shift
  local rc=0 pid
  if ((merge)); then
    "$@" >"$outfile" 2>&1 &
  else
    "$@" >"$outfile" &
  fi
  pid=$!
  if ((stream)); then
    spin::stream "$pid" "$outfile" "$title"
  else
    spin::wait "$pid" "$title"
  fi
  wait "$pid" || rc=$?
  return $rc
}

# spin::quiet <title> <cmd...>
# Run a command behind a spinner with its output captured, surfacing that
# output ONLY if it fails. For tools whose SUCCESS output is pure noise — npm
# announcing "changed 1 package" when the version is identical, uv listing every
# resolved transitive dependency — where the caller reports the real outcome by
# other means. A failure must never be silenced along with the noise, hence the
# dump. Returns the command's exit status.
spin::quiet() {
  local title="$1"
  shift
  local out rc=0
  out=$(mktemp)
  spin::run --merge-stderr "$title" "$out" -- "$@" || rc=$?
  ((rc == 0)) || cat "$out" >&2
  rm -f "$out"
  return $rc
}

# spin::streamed <title> <cmd...>
# Run a command that is SILENT when there is nothing to do but narrates real
# work (brew bundle, cargo, go install, ya pkg upgrade). Spins through the dead
# air, then streams the output live the instant it speaks, so a long build
# reports progress as it happens instead of arriving in one lump at the end.
# Returns the command's exit status.
#
# Prefer this over spin::quiet whenever the output is signal rather than noise:
# nothing is withheld, so there is nothing for the caller to surface on failure.
spin::streamed() {
  local title="$1"
  shift
  local out rc=0
  out=$(mktemp)
  spin::run --merge-stderr --stream "$title" "$out" -- "$@" || rc=$?
  rm -f "$out"
  return $rc
}

# --- change reporting -------------------------------------------------------
# report::changes <before_file> <after_file> [singular_noun]
# The post-update status report. Both files are "name<TAB>version" TSV
# snapshots taken either side of the work — versions, git hashes, lockfile
# commits, whatever identifies a thing's state. This is what lets a caller
# silence a chatty tool: the report states the outcome from observed fact
# rather than from parsing the tool's prose.
#
# Prints a line per entry that actually moved, then a single tally for the
# rest. Unchanged entries deliberately get NO line of their own: on a
# Homebrew-sized ecosystem they bury the handful of lines that matter.
#
# Transitions are reported without claiming a direction — a version that moves
# backwards (a pin, a downgrade) is as real a change as an upgrade, and
# comparing arbitrary version strings to tell them apart isn't worth it.
report::changes() {
  local before="$1" after="$2" noun="${3:-package}"
  local unchanged=0 name verb detail
  # awk classifies and pre-formats, emitting "name<TAB>verb<TAB>detail". No
  # INTERIOR field may be empty: tab counts as IFS whitespace, so `read` folds
  # a run of tabs into one delimiter and an empty middle column would silently
  # shift every field after it left.
  #
  # FILENAME (not NR==FNR) for the same reason as pkg::changed_versions: with
  # an EMPTY before file the classic idiom reads the after file's first rows as
  # "before" and swallows them.
  while IFS=$'\t' read -r name verb detail; do
    case "$verb" in
      +) log_ok "$name installed: $detail" ;;
      -) log_ok "$name removed: $detail" ;;
      '~') log_ok "$name $detail" ;;
      =) unchanged=$((unchanged + 1)) ;;
    esac
  done < <(awk -F'\t' -v before="$before" '
      FILENAME == before { old[$1] = $2; next }
      {
        seen[$1] = 1
        if (!($1 in old))        printf "%s\t+\t%s\n", $1, $2
        else if (old[$1] != $2)  printf "%s\t~\t%s → %s\n", $1, old[$1], $2
        else                     printf "%s\t=\t%s\n", $1, $2
      }
      END { for (n in old) if (!(n in seen)) printf "%s\t-\t%s\n", n, old[n] }
    ' "$before" "$after" | sort)
  if ((unchanged > 0)); then
    # <noun> arrives singular; the -y/-ies rule covers every caller's word
    # (crate, tool, package, formula, binary, snap, plugin, extension).
    if ((unchanged != 1)); then
      if [[ "$noun" == *y ]]; then
        noun="${noun%y}ies"
      else
        noun="${noun}s"
      fi
    fi
    log_info "$unchanged $noun already up to date"
  fi
  return 0
}

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

# --- bounded polling --------------------------------------------------------
# poll::until <timeout_s> <interval_s> <cmd...>
# Run <cmd> repeatedly until it succeeds (rc 0) or <timeout_s> wall-clock
# seconds elapse. The IN-PROCESS twin of the `wait-until` bin: <cmd> runs in
# THIS shell, so it can be a shell function closing over the caller's locals
# (dynamic scope) — where `wait-until` execs an external program and is the
# right tool for an external-command condition. Same contract otherwise:
#
#   * <cmd> is checked ONCE before the first sleep, so an already-true
#     condition returns immediately (rc 0);
#   * the budget is a WALL CLOCK — the elapsed check happens BEFORE each nap,
#     so a slow condition cannot overrun the timeout by more than one probe;
#   * a non-positive interval is not a cadence: check exactly once.
#
# Returns 0 the instant <cmd> succeeds, 1 on timeout. Both args accept floats.
poll::until() {
  local timeout="$1" interval="$2"
  shift 2
  zmodload zsh/datetime 2>/dev/null
  if (( interval <= 0 )); then
    "$@" && return 0
    return 1
  fi
  # Fork-free nap via spin::nap (centiseconds, min 1 so a tiny float interval
  # can't degenerate into a busy loop).
  local -i interval_cs=$(( interval * 100 ))
  (( interval_cs < 1 )) && interval_cs=1
  local -F start=$EPOCHREALTIME
  while true; do
    "$@" && return 0
    (( (EPOCHREALTIME - start) >= timeout )) && return 1
    spin::nap "$interval_cs"
  done
}

# --- run locks --------------------------------------------------------------
# lock::hold <lockfile> [timeout_s]
# Acquire a run-lock via `zsystem flock`, held until the process exits (flock
# keeps the fd open). timeout defaults to 0 = NON-BLOCKING: rc 1 when the lock
# is already held (callers coalesce/skip rather than queue). A positive timeout
# waits up to that many seconds for the current holder to finish. Returns the
# `zsystem flock` status (0 on acquire, non-zero on busy/timeout).
#
# The lockfile touch is CONDITIONAL (only when the file is absent) — NOT an
# unconditional `: >> file`. This is load-bearing under fcntl: `zsystem flock`
# is backed by POSIX fcntl record locks, which are owned by the PROCESS, so
# opening-then-closing ANY fd on the file (which `: >> file` does) drops EVERY
# lock that process already holds on it. A caller re-locking a file it already
# holds on another fd — e.g. clipboard-mount's `ensure` (holding the lock)
# calling `teardown` (which re-locks) in the same process — would have its
# outer lock silently dropped by an unconditional touch, opening a window a
# concurrent process can steal. Skipping the touch when the file exists never
# opens that fd, so the existing hold survives; when the file is absent the
# process holds no lock on it yet, so creating it is safe. (See the
# clipboard-mount cm::teardown comment, which this shared default preserves.)
lock::hold() {
  local lockfile="$1" timeout="${2:-0}"
  zmodload zsh/system 2>/dev/null
  [[ -e "$lockfile" ]] || : >> "$lockfile" 2>/dev/null
  zsystem flock -t "$timeout" "$lockfile" 2>/dev/null
}

# --- notifications ----------------------------------------------------------
# notify::available [--path]
# True when the running Hammerspoon's `hs` CLI is reachable, i.e. an OSD
# notification can actually be shown. Honors $HS as an explicit override, then
# falls back to PATH. With --path it also prints the resolved hs path on stdout
# (nothing + rc 1 when unavailable). This is the probe `notify` uses to bail
# quietly with no `hs`, shared so OSD callers (e.g. copy-pwd deciding whether
# an OSD will be SEEN) resolve it exactly the same way.
notify::available() {
  local hs="${HS:-/opt/homebrew/bin/hs}"
  [ -x "$hs" ] || hs="$(command -v hs 2>/dev/null || true)"
  [ -n "$hs" ] && [ -x "$hs" ] || return 1
  [ "${1:-}" = --path ] && printf '%s' "$hs"
  return 0
}

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

  local hs
  hs="$(notify::available --path)" || return 1

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
