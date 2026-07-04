# tm — Terminal Time Machine, anchored where you stand (spec 2026-07-04).
#
#   tm [dir]          EXPLORE the snapshots of this directory (yazi, jailed)
#   tm --diff [dir]   DIFF this directory: snapshot vs live (hunk tree-view)
#   tm <file>         diff session scoped to one file
#   tm --deleted [p]  recover deletions here (diff session; apply restores)
#
# Thin front-end over `system-backup browse`; scrub sessions (timeline +
# lens panes) live there.
tm() {
  case "${1:-}" in
    --diff)    system-backup browse --diff "${2:-$PWD}" ;;
    --deleted) system-backup browse --deleted "${2:-$PWD}" ;;
    "")        system-backup browse "$PWD" ;;
    *)         system-backup browse "$@" ;;
  esac
}
