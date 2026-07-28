# quick-launch: the merged-targets cache must track the SOURCE SET, not just
# mtimes.
#
# The cache was validated by "is any source newer than the cache?". `mv`
# preserves mtime, so when the quick-launch data moved to ~/.config/mux/ the
# loose launch.d fragments landed in the new directory OLDER than the
# merged.json written just after the move — when launch.d was still empty.
# Every later open reused that one-workspace merge, and no amount of waiting
# or reopening could ever refresh it (measured on the work laptop: rows=1
# with home.yaml and work.yaml sitting right there, intact).
#
# A file removed from launch.d has the mirror-image problem: its entries
# outlive it in the cache.
Describe 'quick-launch merged-targets cache'
  LIB="$SHELLSPEC_PROJECT_ROOT/home/dot_config/mux/scripts/lib"

  setup() {
    FIX=$(mktemp -d)
    export QUICK_LAUNCH_DIR="$FIX/cfg"
    export XDG_CACHE_HOME="$FIX/cache"
    mkdir -p "$QUICK_LAUNCH_DIR/launch.d" "$XDG_CACHE_HOME/quick-launch"
    cat > "$QUICK_LAUNCH_DIR/default.yaml" <<'YAML'
workspaces:
  - id: default
    name: Main
YAML
  }
  cleanup() { rm -rf "$FIX"; unset QUICK_LAUNCH_DIR XDG_CACHE_HOME; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  # Prime the cache from default.yaml alone, then drop in a fragment whose
  # mtime is OLDER than the cache — the moved-file case.
  ids_after_adding_old_fragment() {
    . "$LIB/config.zsh"
    ql_load || return 1
    printf '%s\n' "$QL_JSON" > "$XDG_CACHE_HOME/quick-launch/merged.json"

    cat > "$QUICK_LAUNCH_DIR/launch.d/work.yaml" <<'YAML'
workspaces:
  - id: work-box
    name: Work Box
YAML
    touch -t 202606071824 "$QUICK_LAUNCH_DIR/launch.d/work.yaml"

    unset QL_JSON
    ql_load || return 1
    printf '%s\n' "$QL_JSON" | jq -r '[.workspaces[].id] | join(",")'
  }

  It 'picks up a fragment that arrives older than the cache'
    When call ids_after_adding_old_fragment
    The output should equal "default,work-box"
    The status should be success
  End

  ids_after_removing_fragment() {
    . "$LIB/config.zsh"
    cat > "$QUICK_LAUNCH_DIR/launch.d/work.yaml" <<'YAML'
workspaces:
  - id: work-box
    name: Work Box
YAML
    ql_load || return 1
    printf '%s\n' "$QL_JSON" > "$XDG_CACHE_HOME/quick-launch/merged.json"

    rm -f "$QUICK_LAUNCH_DIR/launch.d/work.yaml"
    unset QL_JSON
    ql_load || return 1
    printf '%s\n' "$QL_JSON" | jq -r '[.workspaces[].id] | join(",")'
  }

  It 'forgets a fragment that was removed'
    When call ids_after_removing_fragment
    The output should equal "default"
    The status should be success
  End

  # The fast path must still be a fast path: an untouched source set reuses
  # the cache rather than re-running yq/jq per file.
  It 'still serves an unchanged source set from the cache'
    reuse() {
      . "$LIB/config.zsh"
      ql_load || return 1
      # Prime the cache the way the writer does: content AND source set.
      printf '%s\n' "$QL_JSON" > "$(ql_cache_path)"
      ql_source_files > "$(ql_cache_sources_path)"
      # Poison the cache: if it is consulted, this is what comes back.
      printf '%s\n' '{"tools":{},"workspaces":[{"id":"from-cache"}],"tabs":[],"panes":[]}' \
        > "$(ql_cache_path)"
      unset QL_JSON
      ql_load || return 1
      printf '%s\n' "$QL_JSON" | jq -r '[.workspaces[].id] | join(",")'
    }
    When call reuse
    The output should equal "from-cache"
    The status should be success
  End
End
