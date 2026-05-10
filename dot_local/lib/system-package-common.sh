# system-package-common.sh — shared helpers for system-package-* scripts.
# This file is intended to be sourced; it does not run on its own.

# Color/format helpers; respect non-tty stdout.
if [[ -t 1 ]]; then
  PKG_C_BLU=$'\e[34m'
  PKG_C_RED=$'\e[31m'
  PKG_C_YEL=$'\e[33m'
  PKG_C_BWH=$'\e[1;37m'
  PKG_C_RES=$'\e[0m'
else
  PKG_C_BLU=""; PKG_C_RED=""; PKG_C_YEL=""; PKG_C_BWH=""; PKG_C_RES=""
fi

PKG_DIR="${PKG_DIR:-$HOME/.config/packages}"
PKG_STATE_DIR="$PKG_DIR/.state"

pkg_info()  { printf '%s=>%s %s\n' "$PKG_C_BLU" "$PKG_C_RES" "$*"; }
pkg_warn()  { printf '%s=>%s %s\n' "$PKG_C_YEL" "$PKG_C_RES" "$*" >&2; }
pkg_error() { printf '%serror:%s %s\n' "$PKG_C_RED" "$PKG_C_RES" "$*" >&2; }
pkg_die()   { pkg_error "$*"; exit 1; }

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

# pkg_table_print <header>
# Read tab-separated rows from stdin and emit a formatted table:
#   - header (bold white), padded to each column's full width
#   - underline (bold white ─), spanning each column's full width
#   - rows, with cells padded to the column width
# Column width is the max visible width across the header label and all row
# cells; ANSI escape sequences in cells (e.g. the yellow "update available"
# annotation) are stripped for width calculation but preserved on output.
# Header is one string with tabs between column labels, e.g. $'Package\tVersion'.
pkg_table_print() {
  local header="$1"
  awk -F'\t' \
      -v header="$header" \
      -v bwh="$PKG_C_BWH" \
      -v reset="$PKG_C_RES" '
    function visual_width(s,   t) {
      t = s; gsub(/\033\[[0-9;]*m/, "", t); return length(t)
    }
    BEGIN {
      n = split(header, hdrs, "\t")
      for (i = 1; i <= n; i++) widths[i] = visual_width(hdrs[i])
    }
    {
      rn++
      for (i = 1; i <= NF; i++) {
        cells[rn, i] = $i
        w = visual_width($i)
        if (w > widths[i]) widths[i] = w
      }
      cols[rn] = NF
    }
    END {
      gap = "  "
      # Header row
      printf "%s", bwh
      for (i = 1; i <= n; i++) {
        printf "%s%*s", hdrs[i], widths[i] - visual_width(hdrs[i]), ""
        if (i < n) printf "%s", gap
      }
      printf "%s\n", reset
      # Underline row
      printf "%s", bwh
      for (i = 1; i <= n; i++) {
        sep = ""; for (j = 1; j <= widths[i]; j++) sep = sep "─"
        printf "%s", sep
        if (i < n) printf "%s", gap
      }
      printf "%s\n", reset
      # Data rows
      for (r = 1; r <= rn; r++) {
        nc = cols[r]
        for (i = 1; i <= nc; i++) {
          printf "%s%*s", cells[r, i], widths[i] - visual_width(cells[r, i]), ""
          if (i < nc) printf "%s", gap
        }
        printf "\n"
      }
    }
  '
}
