# system-package-common.zsh — shared helpers for system-package-* scripts.
# This file is intended to be sourced; it does not run on its own.

# Logging, the ANSI palette (C_*), help-token dispatch (is_help /
# args_contain_help), and require_cmd come from the shared base. Source it
# relative to THIS file so it resolves both at ~/.local/lib (production) and at
# the repo path (the ShellSpec suite sources us directly).
_pkg_common_self="${(%):-%x}"
source "$(dirname "$_pkg_common_self")/common.zsh"
unset _pkg_common_self

PKG_DIR="${PKG_DIR:-$HOME/.config/packages}"
PKG_STATE_DIR="$PKG_DIR/.state"

# --- sync verbosity ---------------------------------------------------------
# Some sync warnings are real but routinely uninteresting: the expected,
# nothing-to-do outcomes almost every run hits (an undeclared formula another
# package still needs, a tap still in use). They stay WARNINGS rather than
# becoming info — nothing about them is merely informational, they just aren't
# worth interrupting a clean run for. `sync --verbose` is how you ask to see
# them. Genuine failures are never gated.
PKG_VERBOSE="${PKG_VERBOSE:-0}"

# pkg::sync_parse_args [args...]
# Shared `sync` flag parsing. Every worker runs this, so `system-package sync
# --verbose` fans out uniformly and an unknown flag errors instead of being
# silently dropped (the dispatcher forwards sync args to each worker verbatim).
pkg::sync_parse_args() {
  PKG_VERBOSE=0
  while (($# > 0)); do
    case "$1" in
      -v | --verbose)
        PKG_VERBOSE=1
        shift
        ;;
      *) die "unknown flag for sync: $1" ;;
    esac
  done
}

# pkg::warn_verbose <message>
# Emit a warning only when the sync was asked for verbose output.
pkg::warn_verbose() {
  ((PKG_VERBOSE)) || return 0
  log_warn "$@"
}

# pkg::run_tool <title> <cmd...>
# Run a package manager whose success output is noise, routing by verbosity:
# discarded behind a spinner by default (report::changes states the real
# outcome), streamed live under --verbose. Callers must ALSO drop the tool's own
# quiet flag when verbose — suppression happens at the source (`uv -q`, `npm
# --silent`), so routing alone would stream a stream with nothing in it.
pkg::run_tool() {
  if ((PKG_VERBOSE)); then
    spin::streamed "$@"
  else
    spin::quiet "$@"
  fi
}

# --- manifest stamps --------------------------------------------------------
# A worker re-applies a package's install FLAGS by reinstalling it, which is
# expensive (uv tears down and rebuilds the whole environment; cargo rebuilds
# from source). Doing that every sync to catch the rare flag edit wastes minutes
# and floods the output. Instead each worker records the manifest it last synced
# successfully, and reinstalls only the entries whose line actually moved.

# pkg::manifest_line_changed <stamp_file> <name> <line>
# True when <name>'s manifest line differs from the one recorded at the last
# successful sync. False when no stamp exists yet or the name is absent from it:
# a first sync has nothing to RE-apply, and treating "unknown" as "changed"
# would force a full rebuild on every fresh machine.
pkg::manifest_line_changed() {
  local stamp="$1" name="$2" line="$3"
  [[ -f "$stamp" ]] || return 1
  local previous=""
  previous=$(awk -v c="$name" '$1 == c {print; exit}' "$stamp")
  [[ -n "$previous" && "$previous" != "$line" ]]
}

# pkg::write_manifest_stamp <stamp_file> <manifest>
# Record <manifest> as the baseline for the next sync's line-changed check.
# Call this ONLY after a fully successful sync: stamping a partial run adopts
# lines that never got applied, so the pending work is silently forgotten.
pkg::write_manifest_stamp() {
  local stamp="$1" manifest="$2"
  mkdir -p "${stamp:h}"
  cp "$manifest" "$stamp"
}

# pkg::manifest_read <file>
# Print one tool per line: strips #-comments (full-line and inline trailing),
# trims leading/trailing whitespace, skips blank lines.
pkg::manifest_read() {
  local file="$1"
  [[ -f "$file" ]] || {
    log_error "manifest not found: $file"
    return 1
  }
  awk '
    { sub(/#.*$/, "") }
    { gsub(/^[[:space:]]+|[[:space:]]+$/, "") }
    NF { print }
  ' "$file"
}

# pkg::line_canonical <manifest-line>
# The canonical package name: the first shell-token of the line. zsh's ${(z)}
# tokenizer (quote-aware) is the shared dialect — workers used to diverge here
# (npm split on $IFS, others shell-tokenized; equivalent for unquoted names,
# but ${(z)} is the correct one).
pkg::line_canonical() {
  local -a words=(${(z)1})
  print -r -- "${words[1]:-}"
}

# pkg::line_has_spec <manifest-line>
# True when the line uses the `<name> -- <install-spec>` form — a non-registry
# install (git / local path / editable) where the spec after `--` is the
# package argument rather than the bare name.
pkg::line_has_spec() {
  local -a words=(${(z)1})
  [[ "${words[2]:-}" == "--" ]]
}

# pkg::diff_only_in <file_a> <file_b>
# Print sorted lines that appear in file_a but not in file_b.
pkg::diff_only_in() {
  comm -23 <(sort -u "$1") <(sort -u "$2")
}

# pkg::changed_versions <before_file> <after_file>
# Both files are "name\tversion" TSV (one row per package). Print one
# package name per line where the version differs between before/after,
# including packages that are new in <after_file>. Packages removed from
# <after_file> are intentionally NOT emitted — uninstalled binaries don't
# need a service restart (the orphan service is handled at sync time).
pkg::changed_versions() {
  local before="$1" after="$2"
  # FILENAME (not NR==FNR) distinguishes the two inputs: with an EMPTY before
  # file the classic NR==FNR idiom misclassifies the after file's first rows
  # as "before" and swallows them — fresh installs never registered as
  # changes (so first-install service restarts/hooks silently skipped).
  awk -F'\t' -v before="$before" '
    FILENAME == before { v[$1] = $2; next }
    { if (!($1 in v) || v[$1] != $2) print $1 }
  ' "$before" "$after"
}

# pkg::restart_services_for <pkg>...
# Hook called by each system-package-<eco> worker after a sync to restart
# any system service (launchd or brew) whose backing package was just
# upgraded. Delegates the matching/status logic to `system-service
# restart-for`, which knows how to map a package name to its service(s)
# and only restarts ones that are currently running.
#
# Soft-fails: if `system-service` isn't on PATH (e.g. partial install on
# a fresh machine) we silently skip — package sync should still succeed.
pkg::restart_services_for() {
  (($# > 0)) || return 0
  command -v system-service >/dev/null 2>&1 || return 0
  system-service restart-for "$@" || true
}

# pkg::restart_changed <before_file> <after_file>
# The standard post-sync tail every worker runs: diff two "name\tversion"
# snapshots and restart any service tied to a package whose version changed.
# Uses a read loop (not zsh's ${(f)}) so it stays valid wherever this base is
# sourced.
pkg::restart_changed() {
  local -a changed=()
  local pkg
  while IFS= read -r pkg; do
    [ -n "$pkg" ] && changed+=("$pkg")
  done < <(pkg::changed_versions "$1" "$2")
  ((${#changed[@]} > 0)) && pkg::restart_services_for "${changed[@]}"
  return 0
}

# ── Package hooks (hooks.toml) ─────────────────────────────────────────────
# ~/.config/packages/hooks.toml maps a BINARY name to commands the sync runs
# around lifecycle events, generalizing the services.toml restart pattern:
#
#   [ai-playbook]
#   on-change = ["ai-playbook man install --force"]
#   on-remove = ["ai-playbook man uninstall"]
#
# Keys: `on-change` fires post-sync for a binary that was installed, upgraded,
# or downgraded (same version-diff pkg::restart_changed uses); `on-remove`
# fires BEFORE the worker deletes a binary, so a hook may invoke the binary
# itself (e.g. a self-uninstalling docs command). Parsing is a deliberate TOML
# subset: single-line double-quoted string arrays only; commands must not
# contain double quotes. Hooks soft-fail (logged, never fail the sync).

# pkg::hooks_for <binary> <on-change|on-remove>
# Print one configured hook command per line (nothing when the file or the
# binary's section is absent).
pkg::hooks_for() {
  local hooks_file="$PKG_DIR/hooks.toml"
  [[ -f "$hooks_file" ]] || return 0
  awk -v want="$1" -v key="$2" '
    /^[ \t]*\[/ {
      sec = $0
      gsub(/[\[\]]/, "", sec)
      gsub(/^[ \t]+|[ \t]+$/, "", sec)
      next
    }
    sec == want && $0 ~ "^[ \t]*" key "[ \t]*=" {
      line = $0
      sub(/\].*$/, "]", line)   # drop trailing comments after the array
      while (match(line, /"[^"]*"/)) {
        print substr(line, RSTART + 1, RLENGTH - 2)
        line = substr(line, RSTART + RLENGTH)
      }
    }
  ' "$hooks_file"
}

# pkg::run_hooks <binary> <on-change|on-remove>
# Run each configured hook command for the binary via `zsh -c`. Soft-fails:
# a failing hook is logged and the sync continues; always returns 0.
pkg::run_hooks() {
  local bin="$1" key="$2" cmd
  while IFS= read -r cmd; do
    [[ -z "$cmd" ]] && continue
    log_info "hook [$bin] $key: $cmd"
    zsh -c "$cmd" || log_warn "hook failed [$bin] $key: $cmd"
  done < <(pkg::hooks_for "$bin" "$key")
  return 0
}

# pkg::hooks_changed <before_file> <after_file>
# The post-sync hooks tail (run it next to pkg::restart_changed): fire every
# binary's on-change hooks when its version changed across the sync
# (installed, upgraded, or downgraded — the same diff restart_changed uses).
pkg::hooks_changed() {
  local pkg
  while IFS= read -r pkg; do
    [[ -n "$pkg" ]] && pkg::run_hooks "$pkg" "on-change"
  done < <(pkg::changed_versions "$1" "$2")
  return 0
}

# pkg::outdated_rows <fetcher_sh> [jobs]
# stdin: "name<TAB>version" rows. <fetcher_sh> is a /bin/sh snippet that, given
# a package name in $1, prints its latest version on stdout (empty = unknown).
# Emits "name<TAB>version[ (update available: X)|(update check failed)]" rows,
# running up to <jobs> fetches concurrently (default 8) — a big speedup over a
# serial per-package HTTP loop for `list --update`. Output order is NOT
# preserved; pipe to `sort`.
#
# An unknown latest version gets its OWN annotation rather than falling through
# to a bare row: rendering "we could not check" identically to "up to date" is
# how a broken fetcher (a registry rejecting the request, no network) passes for
# a clean bill of health indefinitely.
#
# The $1 guard makes empty input a clean no-op on both GNU xargs (which would
# otherwise run once with no args) and BSD xargs.
pkg::outdated_rows() {
  local jobs="${2:-8}"
  PKG_FETCHER="$1" C_YEL="$C_YEL" C_DIM="$C_DIM" C_RES="$C_RES" \
    xargs -P "$jobs" -L 1 sh -c '
    [ -n "$1" ] || exit 0
    latest=$(sh -c "$PKG_FETCHER" _ "$1" 2>/dev/null || true)
    if [ -z "$latest" ]; then
      printf "%s\t%s %s(update check failed)%s\n" "$1" "$2" "$C_DIM" "$C_RES"
    elif [ "$latest" != "$2" ]; then
      printf "%s\t%s %s(update available: %s)%s\n" "$1" "$2" "$C_YEL" "$latest" "$C_RES"
    else
      printf "%s\t%s\n" "$1" "$2"
    fi
  ' _
}

# pkg::warn_update_check_failed <source>
# The bulk-query counterpart to the "(update check failed)" row annotation.
# npm/brew/snap answer `list --update` with ONE query covering every package,
# so a failure has no single row to attach to — and silently yields an empty
# "nothing is outdated" map. Warn instead, so a broken check can never read as
# a clean bill of health.
pkg::warn_update_check_failed() {
  log_warn "update check failed ($1); the versions below may be out of date"
}

# pkg::table_print <header> [group_col]
# Read tab-separated rows from stdin and emit a formatted table:
#   - header (bright blue), padded to each column's full width
#   - underline (bright blue ─), spanning each column's full width
#   - rows, with cells padded to the column width
# A row whose only cell is the literal string "__SEP__" is treated as a
# request to emit an inline separator at that position. If group_col (1-based
# column index) is set and > 0, the function auto-emits a separator whenever
# that column's value changes between consecutive rows. Consecutive separators
# (e.g. an explicit __SEP__ followed by an auto-separator) are deduped.
# Column width is the max visible width across the header label and all
# non-sentinel row cells; ANSI escape sequences in cells (e.g. the yellow
# "update available" annotation) are stripped for width calculation but
# preserved on output.
# Header is one string with tabs between column labels, e.g. $'Package\tVersion'.
pkg::table_print() {
  local header="$1"
  local group_col="${2:-0}"
  awk -F'\t' \
    -v header="$header" \
    -v group_col="$group_col" \
    -v bbl="$C_BBL" \
    -v reset="$C_RES" '
    function visual_width(s,   t) {
      t = s; gsub(/\033\[[0-9;]*m/, "", t); return length(t)
    }
    BEGIN {
      n = split(header, hdrs, "\t")
      for (i = 1; i <= n; i++) widths[i] = visual_width(hdrs[i])
      prev_data = 0
    }
    {
      rn++
      if (NF == 1 && $1 == "__SEP__") {
        is_sep[rn] = 1; cols[rn] = 0
      } else {
        is_sep[rn] = 0
        for (i = 1; i <= NF; i++) {
          cells[rn, i] = $i
          w = visual_width($i)
          if (w > widths[i]) widths[i] = w
        }
        cols[rn] = NF
        if (group_col > 0 && prev_data > 0 \
            && cells[prev_data, group_col] != $group_col) {
          auto_sep[rn] = 1
        }
        prev_data = rn
      }
    }
    END {
      gap = "  "
      # Pre-compute per-column ─ runs (used by header underline and __SEP__ rows)
      for (i = 1; i <= n; i++) {
        sep_cell[i] = ""
        for (j = 1; j <= widths[i]; j++) sep_cell[i] = sep_cell[i] "─"
      }
      # Header row
      printf "%s", bbl
      for (i = 1; i <= n; i++) {
        printf "%s%*s", hdrs[i], widths[i] - visual_width(hdrs[i]), ""
        if (i < n) printf "%s", gap
      }
      printf "%s\n", reset
      # Underline row
      printf "%s", bbl
      for (i = 1; i <= n; i++) {
        printf "%s", sep_cell[i]
        if (i < n) printf "%s", gap
      }
      printf "%s\n", reset
      # Data rows, with explicit __SEP__ and auto-group separators interleaved.
      # last_sep dedupes consecutive separator emissions.
      last_sep = 0
      for (r = 1; r <= rn; r++) {
        if ((is_sep[r] || auto_sep[r]) && !last_sep) {
          printf "%s", bbl
          for (i = 1; i <= n; i++) {
            printf "%s", sep_cell[i]
            if (i < n) printf "%s", gap
          }
          printf "%s\n", reset
          last_sep = 1
        }
        if (!is_sep[r]) {
          nc = cols[r]
          for (i = 1; i <= nc; i++) {
            printf "%s%*s", cells[r, i], widths[i] - visual_width(cells[r, i]), ""
            if (i < nc) printf "%s", gap
          }
          printf "\n"
          last_sep = 0
        }
      }
    }
  '
}
