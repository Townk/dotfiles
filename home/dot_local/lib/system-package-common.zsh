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

# pkg::manifest_read <file>
# Print one tool per line: strips #-comments (full-line and inline trailing),
# trims leading/trailing whitespace, skips blank lines.
pkg::manifest_read() {
  local file="$1"
  [[ -f "$file" ]] || { log_error "manifest not found: $file"; return 1; }
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
  local -a words=( ${(z)1} )
  print -r -- "${words[1]:-}"
}

# pkg::line_has_spec <manifest-line>
# True when the line uses the `<name> -- <install-spec>` form — a non-registry
# install (git / local path / editable) where the spec after `--` is the
# package argument rather than the bare name.
pkg::line_has_spec() {
  local -a words=( ${(z)1} )
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
  awk -F'\t' '
    NR==FNR { v[$1] = $2; next }
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
  (( $# > 0 )) || return 0
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
  (( ${#changed[@]} > 0 )) && pkg::restart_services_for "${changed[@]}"
  return 0
}

# pkg::outdated_rows <fetcher_sh> [jobs]
# stdin: "name<TAB>version" rows. <fetcher_sh> is a /bin/sh snippet that, given
# a package name in $1, prints its latest version on stdout (empty = unknown).
# Emits "name<TAB>version[ (update available: X)]" rows, running up to <jobs>
# fetches concurrently (default 8) — a big speedup over a serial per-package
# HTTP loop for `list --update`. Output order is NOT preserved; pipe to `sort`.
# The $1 guard makes empty input a clean no-op on both GNU xargs (which would
# otherwise run once with no args) and BSD xargs.
pkg::outdated_rows() {
  local jobs="${2:-8}"
  PKG_FETCHER="$1" C_YEL="$C_YEL" C_RES="$C_RES" \
  xargs -P "$jobs" -L 1 sh -c '
    [ -n "$1" ] || exit 0
    latest=$(sh -c "$PKG_FETCHER" _ "$1" 2>/dev/null || true)
    if [ -n "$latest" ] && [ "$latest" != "$2" ]; then
      printf "%s\t%s %s(update available: %s)%s\n" "$1" "$2" "$C_YEL" "$latest" "$C_RES"
    else
      printf "%s\t%s\n" "$1" "$2"
    fi
  ' _
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
