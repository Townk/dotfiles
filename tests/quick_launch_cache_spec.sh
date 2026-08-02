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

# quick-launch pane picker: the per-launch PANE cache is keyed by the ACTIVE
# scope (workspace + tab), because the pane list itself is scoped — switching
# workspaces must not serve the previous workspace's panes.
#
# D1 bug: the cache FILENAME was derived from a LOSSY sanitization of the raw
# scope — `${scope//[^A-Za-z0-9._-]/_}` — while the cache CONTENTS use the RAW
# scope. Two distinct scopes that sanitize to the same token (workspace `a/b`
# vs `a b`) collapsed onto ONE cache file, and pick::cache_stale only compares
# mtimes, never the scope — so the second scope was served the first's panes.
# The fix folds the RAW scope into the cache IDENTITY so a differing scope
# forces its own cache.
Describe 'quick-launch pane-scope cache identity'
  PICKER="$SHELLSPEC_PROJECT_ROOT/home/dot_config/mux/scripts/executable_quick-launch-pick"
  LIBDIR="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib"

  setup() {
    FIX=$(mktemp -d)
    mkdir -p "$FIX/.config/theme" "$FIX/cache" "$FIX/bin"

    # Two workspaces whose names sanitize to the SAME token (`a/b` -> `a_b`,
    # `a b` -> `a_b`) but are RAW-distinct, each carrying its OWN pane. The
    # active-scope collect() surfaces the active workspace's panes, so which
    # pane appears is a direct read of which scope built the cache.
    cat > "$FIX/targets.json" <<'JSON'
{"panes":[],"tabs":[],
 "workspaces":[
   {"id":"wsA","name":"a/b","panes":[{"id":"paneA","name":"PaneA","action":{"type":"Shell"}}]},
   {"id":"wsB","name":"a b","panes":[{"id":"paneB","name":"PaneB","action":{"type":"Shell"}}]}
 ]}
JSON

    # Palette the jq assembler paints from (theme::json_path resolves it).
    cat > "$FIX/.config/theme/chezmoi-system.json" <<'JSON'
{"palette":{"white":"#ffffff","blue":"#89b4fa","mauve":"#cba6f7","overlay1":"#7f849c","subtext0":"#a6adc8"}}
JSON

    # Real pick-common (so the REAL pick::cache_stale + cache identity run),
    # with only pick::start replaced by a dump of the assembled cache file —
    # no fzf, no tty. What it prints IS the cache the scope resolved to.
    {
      print -r -- "source \"$LIBDIR/pick-common.zsh\""
      print -r -- 'pick::start() { command cat -- "${@[-1]}"; }'
    } > "$FIX/pick-common-stub.zsh"

    # Active scope is read from mux::current_session / mux::current_tab_name;
    # stub them from the env so each run declares its own scope.
    {
      print -r -- 'mux::current_session()  { print -r -- "${STUB_WS:-}"; }'
      print -r -- 'mux::current_tab_name() { print -r -- "${STUB_TAB:-}"; }'
    } > "$FIX/mux.zsh"

    # require_cmd fzf must pass though fzf is never run (pick::start is stubbed).
    print -r -- '#!/usr/bin/env zsh' > "$FIX/bin/fzf"
    chmod +x "$FIX/bin/fzf"
  }
  cleanup() { rm -rf "$FIX"; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  # Run the pane picker for scope ($1 = workspace, $2 = tab); prints the
  # assembled cache the scope resolved to.
  run_pane() {
    env HOME="$FIX" XDG_CONFIG_HOME="$FIX/.config" XDG_CACHE_HOME="$FIX/cache" \
      QUICK_LAUNCH_TARGETS="$FIX/targets.json" \
      THEME_PALETTE_JSON="$FIX/.config/theme/chezmoi-system.json" \
      PICK_LIB_DIR="$LIBDIR" PICK_COMMON_LIB="$FIX/pick-common-stub.zsh" \
      MUX_LIB="$FIX" PATH="$FIX/bin:$PATH" \
      STUB_WS="$1" STUB_TAB="$2" \
      zsh -f "$PICKER" pane
  }

  # Append a sentinel to every pane cache file: it survives a cache HIT (the
  # file is reused as-is) and vanishes on a rebuild (the file is rewritten).
  poison_pane_caches() {
    local f
    for f in "$FIX"/cache/quick-launch/lines-pane-*.txt(N); do
      print -r -- $'ZZZ\x1fCACHE_SENTINEL' >> "$f"
    done
  }

  It 'does not serve a scope-collision peer the first scope panes'
    # Prime scope `a/b` (sanitizes to a_b), then open the colliding scope
    # `a b` (also a_b): it must show ITS pane, never the primed one.
    run_pane "a/b" "" >/dev/null 2>&1
    When call run_pane "a b" ""
    The output should include "paneB"
    The output should not include "paneA"
    The status should be success
  End

  It 'reuses the same-scope cache without a needless rebuild'
    run_pane "a/b" "" >/dev/null 2>&1
    poison_pane_caches
    When call run_pane "a/b" ""
    The output should include "CACHE_SENTINEL"
    The output should include "paneA"
    The status should be success
  End
End
