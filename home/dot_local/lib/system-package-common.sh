# system-package-common.sh — shared helpers for system-package-* scripts.
# This file is intended to be sourced; it does not run on its own.

# Color/format helpers; respect non-tty stdout.
if [[ -t 1 ]]; then
  PKG_C_BLU=$'\e[34m'
  PKG_C_BBL=$'\e[94m'
  PKG_C_RED=$'\e[31m'
  PKG_C_YEL=$'\e[33m'
  PKG_C_BWH=$'\e[1;37m'
  PKG_C_RES=$'\e[0m'
else
  PKG_C_BLU=""; PKG_C_BBL=""; PKG_C_RED=""; PKG_C_YEL=""; PKG_C_BWH=""; PKG_C_RES=""
fi

PKG_DIR="${PKG_DIR:-$HOME/.config/packages}"
PKG_STATE_DIR="$PKG_DIR/.state"

pkg_info()  { printf '%s=>%s %s\n' "$PKG_C_BLU" "$PKG_C_RES" "$*"; }
pkg_warn()  { printf '%s=>%s %s\n' "$PKG_C_YEL" "$PKG_C_RES" "$*" >&2; }
pkg_error() { printf '%serror:%s %s\n' "$PKG_C_RED" "$PKG_C_RES" "$*" >&2; }
pkg_die()   { pkg_error "$*"; exit 1; }

# pkg_is_help <arg>
# Return 0 iff <arg> is one of -h, --help, help. Used by every dispatch
# layer to short-circuit help requests BEFORE any side-effecting work
# (a stray --help must never trigger a real sync or service restart).
pkg_is_help() {
  case "${1:-}" in
    -h|--help|help) return 0 ;;
    *)              return 1 ;;
  esac
}

# pkg_args_contain_help <arg>...
# Return 0 iff any of the supplied args looks like a help request. Used at
# positional-argument dispatch points (e.g. `system-service info --help`)
# where the help token isn't necessarily the first remaining arg.
pkg_args_contain_help() {
  local a=""
  for a in "$@"; do
    case "$a" in
      -h|--help) return 0 ;;
    esac
  done
  return 1
}

# pkg_manifest_read <file>
# Print one tool per line: strips #-comments (full-line and inline trailing),
# trims leading/trailing whitespace, skips blank lines.
pkg_manifest_read() {
  local file="$1"
  [[ -f "$file" ]] || { pkg_error "manifest not found: $file"; return 1; }
  awk '
    { sub(/#.*$/, "") }
    { gsub(/^[[:space:]]+|[[:space:]]+$/, "") }
    NF { print }
  ' "$file"
}

# pkg_diff_only_in <file_a> <file_b>
# Print sorted lines that appear in file_a but not in file_b.
pkg_diff_only_in() {
  comm -23 <(sort -u "$1") <(sort -u "$2")
}

# pkg_changed_versions <before_file> <after_file>
# Both files are "name\tversion" TSV (one row per package). Print one
# package name per line where the version differs between before/after,
# including packages that are new in <after_file>. Packages removed from
# <after_file> are intentionally NOT emitted — uninstalled binaries don't
# need a service restart (the orphan service is handled at sync time).
pkg_changed_versions() {
  local before="$1" after="$2"
  awk -F'\t' '
    NR==FNR { v[$1] = $2; next }
    { if (!($1 in v) || v[$1] != $2) print $1 }
  ' "$before" "$after"
}

# pkg_restart_services_for <pkg>...
# Hook called by each system-package-<eco> worker after a sync to restart
# any system service (launchd or brew) whose backing package was just
# upgraded. Delegates the matching/status logic to `system-service
# restart-for`, which knows how to map a package name to its service(s)
# and only restarts ones that are currently running.
#
# Soft-fails: if `system-service` isn't on PATH (e.g. partial install on
# a fresh machine) we silently skip — package sync should still succeed.
pkg_restart_services_for() {
  (( $# > 0 )) || return 0
  command -v system-service >/dev/null 2>&1 || return 0
  system-service restart-for "$@" || true
}

# pkg_table_print <header> [group_col]
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
pkg_table_print() {
  local header="$1"
  local group_col="${2:-0}"
  awk -F'\t' \
      -v header="$header" \
      -v group_col="$group_col" \
      -v bbl="$PKG_C_BBL" \
      -v reset="$PKG_C_RES" '
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
