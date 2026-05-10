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
# Read tab-separated rows from stdin, prepend the (also tab-separated) header,
# align via `column -t`, then post-process the output:
#   - colorize the header line (bold white) and add an underline of ─ chars
#     beneath it that mirrors the column layout
#   - leave row content untouched (workers wrap "update available" themselves)
# Header is one string with tabs between column labels, e.g. $'Package\tVersion'.
pkg_table_print() {
  local header="$1"
  local first=1 line sep
  { printf '%s\n' "$header"; cat; } | column -t -s $'\t' | while IFS= read -r line; do
    if (( first )); then
      first=0
      printf '%s%s%s\n' "$PKG_C_BWH" "$line" "$PKG_C_RES"
      sep=$(printf '%s' "$line" | sed 's/[^[:space:]]/─/g')
      printf '%s%s%s\n' "$PKG_C_BWH" "$sep" "$PKG_C_RES"
    else
      printf '%s\n' "$line"
    fi
  done
}
