#!/usr/bin/env zsh
# pick-symbols-common.zsh — shared scaffolding for the symbols.db-backed
# pickers (pick-glyph, pick-gitmoji). They differ only in the SQL projection
# and their key map; everything else — option parsing, the DB-not-found guard,
# and the recency recorder — lived identically in both and now lives here.
#
# SOURCED, never executed. Pulls in pick-common.zsh (and transitively the base
# common.sh) for require_cmd / die / pick::start, so a picker only needs to
#   source "$PICK_LIB_DIR/pick-symbols-common.zsh"
# instead of pick-common.zsh directly.

# Source pick-common relative to THIS file. BASH_SOURCE under bash; %x under zsh.
if [ -n "${BASH_SOURCE:-}" ]; then
  _pick_symbols_self="${BASH_SOURCE[0]}"
else
  _pick_symbols_self="${(%):-%x}"
fi
source "${PICK_COMMON_LIB:-$(dirname "$_pick_symbols_self")/pick-common.zsh}"
unset _pick_symbols_self

# pick_symbols::parse_args <arg>...
# Parse the shared picker flags into the script-scope vars multi/copy/query/
# resume/no_border (initialized here), and override DB_FILE on --db. On
# -h/--help it calls the caller's usage() and exits 0; unknown args die.
# DB_FILE must already hold the picker's default before this is called.
pick_symbols::parse_args() {
  multi=0; copy=0; query=""; resume=0; no_border=0
  while (( $# > 0 )); do
    case "$1" in
      -m|--multi)   multi=1; shift ;;
      -c|--copy)    copy=1; shift ;;
      -q|--query)   [[ $# -ge 2 ]] || die "missing arg for $1"; query="$2"; shift 2 ;;
      --db)         [[ $# -ge 2 ]] || die "missing arg for $1"; DB_FILE="$2"; shift 2 ;;
      --resume)     resume=1; shift ;;
      --no-border)  no_border=1; shift ;;
      -h|--help)    usage; exit 0 ;;
      --)           shift; break ;;
      *) die "unknown arg: $1 (try --help)" ;;
    esac
  done
}

# pick_symbols::require_db — ensure sqlite3 is present and DB_FILE exists, with
# the consistent "build it with chezmoi apply" hint.
pick_symbols::require_db() {
  require_cmd sqlite3
  [[ -f "$DB_FILE" ]] || die "symbols DB not found: $DB_FILE
Build it with: chezmoi apply (runs the symbols-db hook)"
}

# pick_symbols::record_recency <symbol>...
# --on-items-picked hook: stamp last_used=now on every picked symbol so the
# next launch floats it to the top (the streamed query orders by last_used).
# The symbol is the symbols-table primary key.
pick_symbols::record_recency() {
  (( $# )) || return 0
  local now sym vals=""
  now=$(date +%s)
  for sym in "$@"; do
    [[ -z "$sym" ]] && continue
    sym=${sym//\'/\'\'}   # SQL-escape single quotes
    vals+="'${sym}',"
  done
  [[ -z "$vals" ]] && return 0
  sqlite3 "$DB_FILE" "UPDATE symbols SET last_used=$now WHERE symbol IN (${vals%,});"
}
