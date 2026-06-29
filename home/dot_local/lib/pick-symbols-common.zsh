#!/usr/bin/env zsh
# pick-symbols-common.zsh — shared scaffolding for the symbols.db-backed
# pickers (pick-glyph, pick-gitmoji). They differ only in the SQL projection
# and their key map; everything else — option parsing, the DB-not-found guard,
# and the recency recorder — lived identically in both and now lives here.
#
# SOURCED, never executed. Pulls in pick-common.zsh (and transitively the base
# common.zsh) for require_cmd / die / pick::start, so a picker only needs to
#   source "$PICK_LIB_DIR/pick-symbols-common.zsh"
# instead of pick-common.zsh directly.

# Source pick-common relative to THIS file.
_pick_symbols_self="${(%):-%x}"
source "${PICK_COMMON_LIB:-$(dirname "$_pick_symbols_self")/pick-common.zsh}"
unset _pick_symbols_self

# pick_symbols::parse_args <arg>...
# Parse the shared picker flags into the script-scope vars multi/copy/query/
# resume/no_border (initialized here), and override DB_FILE on --db. On
# -h/--help it calls the caller's usage() and exits 0; unknown args die.
# DB_FILE must already hold the picker's default before this is called.
pick_symbols::parse_args() {
  multi=0
  copy=0
  query=""
  resume=0
  no_border=0
  while (($# > 0)); do
    case "$1" in
      -m | --multi)
        multi=1
        shift
        ;;
      -c | --copy)
        copy=1
        shift
        ;;
      -q | --query)
        [[ $# -ge 2 ]] || die "missing arg for $1"
        query="$2"
        shift 2
        ;;
      --db)
        [[ $# -ge 2 ]] || die "missing arg for $1"
        DB_FILE="$2"
        shift 2
        ;;
      --resume)
        resume=1
        shift
        ;;
      --no-border)
        no_border=1
        shift
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      --)
        shift
        break
        ;;
      *) die "unknown arg: $1 (try --help)" ;;
    esac
  done
}

# pick_symbols::require_db — ensure sqlite3 is present and DB_FILE exists, with
# the consistent "build it with chezmoi apply" hint.
pick_symbols::require_db() {
  require_cmd sqlite3
  # `-escape off` (sqlite ≥ 3.46) disables the CLI's newer control-character
  # output escaping so the raw ANSI colour + US/RS field bytes the projections
  # emit pass through untouched. Older builds (e.g. Ubuntu's 3.37) emit raw
  # bytes already and reject the unknown flag, so only pass it when supported.
  typeset -ga PICK_SQLITE_RAW
  PICK_SQLITE_RAW=()
  if sqlite3 -escape off ':memory:' 'SELECT 1;' >/dev/null 2>&1; then
    PICK_SQLITE_RAW=(-escape off)
  fi
  [[ -f "$DB_FILE" ]] || die "symbols DB not found: $DB_FILE
Build it with: chezmoi apply (runs the symbols-db hook)"
}

# pick_symbols::record_recency <symbol>...
# --on-items-picked hook: stamp last_used=now on every picked symbol so the
# next launch floats it to the top (the streamed query orders by last_used).
# The symbol is the symbols-table primary key.
pick_symbols::record_recency() {
  (($#)) || return 0
  local now sym vals=""
  now=$(date +%s)
  for sym in "$@"; do
    [[ -z "$sym" ]] && continue
    sym=${sym//\'/\'\'} # SQL-escape single quotes
    vals+="'${sym}',"
  done
  [[ -z "$vals" ]] && return 0
  sqlite3 "$DB_FILE" "UPDATE symbols SET last_used=$now WHERE symbol IN (${vals%,});"
}
