# tm — Terminal Time Machine, anchored where you stand (spec §7).
#
#   tm                browse THIS directory's history
#   tm <path>         scrub one file/dir's versions
#   tm --deleted      recover files deleted under here
#
# Thin front-end over `system-backup browse`; the heavy lifting (httm over a
# transient restic mount, or the fzf picker) lives there.
tm() {
  case "${1:-}" in
    --deleted) system-backup browse --deleted "${2:-$PWD}" ;;
    "")        system-backup browse "$PWD" ;;
    *)         system-backup browse "$@" ;;
  esac
}
