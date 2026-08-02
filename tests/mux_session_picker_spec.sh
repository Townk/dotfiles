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
    # The real pick-common sources theme-common (for theme::json_path); the stub
    # must too, so quick-launch-pick can resolve its palette via the shared order.
    print -r -- "source \"$PWD/home/dot_local/lib/theme-common.zsh\"" >>"$MSP_TMP/pick-common.zsh"
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

# Ctrl+D kills the session under the cursor and refreshes the list in place.
# fzf runs both halves as re-entries into the picker (`--kill <tail>`, then
# `--emit` for the reload), so they are driven here exactly the way fzf drives
# them. The REAL pick-common is used: --emit's whole job is to reproduce
# pick::feed's wrapping, which a stub would not have.
Describe 'mux workspace session picker — Ctrl+D kill'
  setup() {
    KSP_TMP=$(mktemp -d)
    KSP_PICKER="$PWD/home/dot_config/mux/scripts/executable_quick-launch-pick"
    mkdir -p "$KSP_TMP/.config/theme" "$KSP_TMP/cache"

    # `id` and `name` DIFFER, as they do in every real entry (`default` /
    # `Main`): the id is the dispatch key, the name is what the session is
    # called. A fixture where they matched let a kill aimed at the id pass here
    # while killing nothing on a real machine.
    cat >"$KSP_TMP/targets.json" <<'JSON'
{"workspaces":[{"id":"platypus-ws","name":"awesome-platypus"}]}
JSON
    cat >"$KSP_TMP/.config/theme/chezmoi-system.json" <<'JSON'
{"palette":{"white":"#ffffff","blue":"#89b4fa","mauve":"#cba6f7","overlay1":"#7f849c","subtext0":"#a6adc8"}}
JSON
    # One configured workspace that happens to be live, one purely ad-hoc
    # session — the two rows that must react differently to a kill.
    printf '%s\n' awesome-platypus stray-mongoose >"$KSP_TMP/sessions"

    # A STATEFUL stub: kill-session really removes the name, so the reload
    # sees the world the kill left behind rather than a canned reply.
    cat >"$KSP_TMP/tmux" <<EOF
#!/usr/bin/env zsh
case "\$1" in
  display)
    case "\$*" in
      *session_name*) print -r -- Main ;;
      *window_name*) print -r -- shell ;;
    esac
    ;;
  list-sessions)
    [[ "\$*" == *session_attached* ]] || cat "$KSP_TMP/sessions"
    ;;
  kill-session)
    grep -v -x -- "\${3#=}" "$KSP_TMP/sessions" >"$KSP_TMP/sessions.new" || true
    mv "$KSP_TMP/sessions.new" "$KSP_TMP/sessions"
    ;;
esac
EOF
    chmod +x "$KSP_TMP/tmux"
  }
  cleanup() { rm -rf "$KSP_TMP"; }
  BeforeEach setup
  AfterEach cleanup

  picker() {
    env HOME="$KSP_TMP" XDG_CONFIG_HOME="$KSP_TMP/.config" XDG_CACHE_HOME="$KSP_TMP/cache" \
      QUICK_LAUNCH_TARGETS="$KSP_TMP/targets.json" \
      PICK_LIB_DIR="$PWD/home/dot_local/lib" MUX_LIB="$PWD/home/dot_local/lib" \
      MUX_BACKEND=tmux MUX_TMUX_BIN="$KSP_TMP/tmux" TMUX=/tmp/tmux-test.sock,1,0 \
      zsh -f "$KSP_PICKER" workspace "$@"
  }
  rows() { picker --emit | perl -pe 's/\e\[[0-9;]*m//g; s/\x1f.*$//'; }
  row_for() { rows | grep -F -- "$1"; }
  # Field 3 of an emitted row is the hidden tail — the field the Ctrl+D bind
  # passes to --kill as fzf's {3}. Fields 1 and 2 are the selector and search
  # display columns pick::feed prepends in selector-shortcut mode.
  tail_subfield() { picker --emit | perl -pe 's/^[^\x1f]*\x1f[^\x1f]*\x1f//' | cut -d $'\036' -f "$1"; }
  # The exact string fzf hands to --kill: the whole tail of the row carrying
  # this label, taken from the picker's own output rather than hand-built.
  tail_for() {
    picker --emit |
      KSP_LABEL="$1" perl -ne 's/\e\[[0-9;]*m//g; my @f = split /\x1f/; print $f[2] if $f[1] =~ /\Q$ENV{KSP_LABEL}\E/'
  }

  It 'emits the dispatch id first — the field Enter accepts'
    When call tail_subfield 1
    The line 1 of output should equal "platypus-ws"
  End

  # The bug this fences: a configured workspace's session is named after its
  # `name`, so a kill aimed at the id half asked tmux to end "platypus-ws" and
  # the row kept its "(detached)" tag forever.
  It 'emits the session name as the field the kill bind reads'
    When call tail_subfield 3
    The line 1 of output should equal "awesome-platypus"
  End

  # Its row survives — it is still a workspace you can launch — but with no
  # parenthesized info suffix at all, since nothing about it is live any more.
  It 'keeps a configured workspace but drops its live tag once killed'
    picker --kill "$(tail_for 'Awesome Platypus')"
    When call row_for "Awesome Platypus"
    The lines of output should equal 1
    The output should not include "("
  End

  It 'drops an ad-hoc session row entirely once killed'
    picker --kill "$(tail_for 'Stray Mongoose')"
    When call rows
    The output should not include "Stray Mongoose"
    The output should include "Awesome Platypus"
  End

  # fzf hands over the whole tail, "<id>\x1e@window:<id>\x1e<session>".
  It 'kills the session the tail names, not the id it leads with'
    picker --kill "$(printf 'platypus-ws\036@window:platypus-ws\036awesome-platypus')"
    When call cat "$KSP_TMP/sessions"
    The output should not include "awesome-platypus"
    The output should include "stray-mongoose"
  End

  # Ctrl+D on a search that matches nothing: fzf fires the bind anyway, with
  # an empty {3}. Treating "no session" as "no kill mode" would fall through
  # and start a SECOND, interactive picker behind the first one.
  It 'no-ops on an empty tail instead of falling through to the picker'
    When call picker --kill ""
    The status should be success
    The output should equal ""
  End

  # The current session is never offered as a row, but neither half of this
  # may take the terminal down if it ever reaches one.
  It 'refuses to kill the session the picker is running in'
    picker --kill "$(printf 'main-ws\036@window:main-ws\036Main')"
    When call cat "$KSP_TMP/sessions"
    The lines of output should equal 2
  End
End
