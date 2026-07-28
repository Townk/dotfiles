# Workspace/session picker presentation: live tmux names are rebuilt on every
# launch, displayed like the status-bar pill, and retain their raw dispatch id.
Describe 'mux workspace session picker'
  setup() {
    MSP_TMP=$(mktemp -d)
    MSP_PICKER="$PWD/home/dot_config/mux/scripts/executable_quick-launch-pick"
    mkdir -p "$MSP_TMP/.config/theme" "$MSP_TMP/cache"

    cat >"$MSP_TMP/targets.json" <<'JSON'
{"workspaces":[{"id":"awesome-platypus","name":"awesome-platypus"}]}
JSON
    cat >"$MSP_TMP/.config/theme/chezmoi-system.json" <<'JSON'
{"palette":{"white":"#ffffff","blue":"#89b4fa","mauve":"#cba6f7","overlay1":"#7f849c","subtext0":"#a6adc8"}}
JSON
    cat >"$MSP_TMP/tmux" <<'ZSH'
#!/usr/bin/env zsh
case "$1" in
  display)
    case "$*" in
      *session_name*) print -r -- Main ;;
      *window_name*) print -r -- shell ;;
    esac
    ;;
  list-sessions)
    if [[ "$*" == *session_attached* ]]; then
      [[ -n "${STUB_SESSION:-}" && -n "${STUB_WINDOWED:-}" ]] && print -r -- "1 $STUB_SESSION"
    else
      [[ -n "${STUB_SESSION:-}" ]] && print -r -- "$STUB_SESSION"
    fi
    ;;
esac
ZSH
    chmod +x "$MSP_TMP/tmux"
    cat >"$MSP_TMP/pick-common.zsh" <<'ZSH'
die() { print -ru2 -- "$*"; return 1; }
require_cmd() { command -v "$1" >/dev/null; }
pick::cache_stale() { return 0; }
pick::hints() { print -r -- ""; }
pick::start() { command cat "${@[-1]}"; }
ZSH
    cat >"$MSP_TMP/mux-wrapper.zsh" <<ZSH
source "$PWD/home/dot_local/lib/mux.zsh"
source "$MSP_TMP/pick-common.zsh"
ZSH
  }
  cleanup() {
    rm -rf "$MSP_TMP"
    unset STUB_SESSION STUB_WINDOWED
  }
  BeforeEach setup
  AfterEach cleanup

  raw_lines() {
    env HOME="$MSP_TMP" XDG_CONFIG_HOME="$MSP_TMP/.config" XDG_CACHE_HOME="$MSP_TMP/cache" \
      QUICK_LAUNCH_TARGETS="$MSP_TMP/targets.json" \
      PICK_LIB_DIR="$PWD/home/dot_local/lib" PICK_COMMON_LIB="$MSP_TMP/pick-common.zsh" \
      MUX_LIB="$MSP_TMP/mux-wrapper.zsh" MUX_BACKEND=tmux \
      MUX_TMUX_BIN="$MSP_TMP/tmux" TMUX=/tmp/tmux-test.sock,1,0 \
      STUB_SESSION="${STUB_SESSION:-}" STUB_WINDOWED="${STUB_WINDOWED:-}" \
      zsh -f "$MSP_PICKER" workspace
  }
  visible_lines() {
    raw_lines | perl -pe 's/\e\[[0-9;]*m//g; s/\x1f.*$//'
  }
  dispatch_ids() {
    raw_lines | perl -pe 's/.*\x1f//; s/\x1e.*$//'
  }
  It 'shows a kebab-case session in Title Case'
    When call visible_lines
    The output should include "Awesome Platypus"
    The output should not include "awesome-platypus"
    The output should not include "ad-hoc"
  End

  It 'rebuilds from an updated session name on every launch'
    raw_lines >/dev/null
    printf '%s\n' '{"workspaces":[{"id":"wise-zebra","name":"wise-zebra"}]}' >"$MSP_TMP/targets.json"
    When call visible_lines
    The output should include "Wise Zebra"
    The output should not include "Awesome Platypus"
  End

  It 'keeps the raw session name as the dispatch id'
    printf '%s\n' '{"workspaces":[{"id":"wise-zebra","name":"wise-zebra"}]}' >"$MSP_TMP/targets.json"
    When call dispatch_ids
    The line 1 of output should equal "wise-zebra"
  End

  It 'labels a detached manual session with comma-separated ad-hoc info'
    printf '%s\n' '{"workspaces":[{"id":"awesome-platypus","name":"awesome-platypus","ad_hoc":true}]}' >"$MSP_TMP/targets.json"
    When call visible_lines
    The output should include "Awesome Platypus"
    The output should include "(ad-hoc, detached)"
  End

  It 'keeps ad-hoc presentation metadata out of the dispatch id'
    printf '%s\n' '{"workspaces":[{"id":"awesome-platypus","name":"awesome-platypus","ad_hoc":true}]}' >"$MSP_TMP/targets.json"
    When call dispatch_ids
    The line 1 of output should equal "awesome-platypus"
  End
End
