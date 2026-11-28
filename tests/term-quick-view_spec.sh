# Tests for the size humaniser in the term-quick-view bin
# (home/dot_local/bin/executable_term-quick-view). The file is a zsh viewer;
# sourced with TERM_QUICK_VIEW_LIB set it exposes just its helpers and runs no
# UI, so the pure size-formatting logic can be exercised in isolation.
Describe 'term-quick-view size formatting'
  SCRIPT="$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_term-quick-view"

  humanize() {
    TERM_QUICK_VIEW_LIB=1
    source "$SCRIPT"
    _tqv_humanize_size "$1"
  }

  It 'renders an exact 1 MiB as 1.0MB (not .9MB)'
    When call humanize 1048576
    The output should equal "1.0MB"
  End

  It 'renders an exact 2 MiB as 2.0MB'
    When call humanize 2097152
    The output should equal "2.0MB"
  End

  It 'renders 2300000 bytes as 2.1MB'
    When call humanize 2300000
    The output should equal "2.1MB"
  End

  It 'rounds sub-MiB sizes up to whole KiB'
    When call humanize 2048
    The output should equal "2KB"
  End

  It 'emits nothing for a non-numeric size'
    When call humanize "not-a-number"
    The output should equal ""
  End
End

# Which chafa arguments the viewer draws with. The answer is the shared one
# (image-protocol-support.zsh); what stays the viewer's is that it only pins
# the protocol for the Kitty-graphics terminals and leaves the rest to
# chafa's auto-detection, and that a chafa too old for tmux passthrough gets
# character art instead of a blank pane.
Describe 'term-quick-view chafa arguments'
  SCRIPT="$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_term-quick-view"

  # args <TERM> <TERM_PROGRAM> [tmux: <client_termname> <session TERM_PROGRAM>]
  args() {
    unset TMUX ITERM_SESSION_ID LC_TERMINAL
    TERM_QUICK_VIEW_LIB=1
    source "$SCRIPT"
    source "$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib/image-protocol-support.zsh"
    local _client="${3:-}" _sess="${4:-}"
    tmux() {
      case "$*" in
        *client_termname*) print -r -- "$_client" ;;
        *show-environment*) [[ -n "$_sess" ]] && print -r -- "TERM_PROGRAM=$_sess" || print -r -- "-TERM_PROGRAM" ;;
      esac
    }
    chafa() { [[ -n "${STUB_OLD_CHAFA:-}" ]] || print -r -- "  --passthrough=MODE"; }
    (( $# > 2 )) && TMUX=/tmp/s,1,0
    TERM="$1" TERM_PROGRAM="$2" _tqv_chafa_args
    print -r -- "."
  }

  It 'asks for Kitty graphics in Ghostty and in Rex'
    both() { args xterm-ghostty ghostty; args xterm-256color rex; }
    When call both
    The output should equal "-f kitty
.
-f kitty
."
  End

  It 'knows Ghostty by its terminal name alone (over SSH the program name is not carried)'
    by_name() { args xterm-ghostty ''; args tmux-256color '' xterm-ghostty ''; }
    When call by_name
    The output should equal "-f kitty
.
-f kitty --passthrough tmux
."
  End

  It 'wraps Kitty graphics for tmux, and leaves probing as it was'
    wrapped() { args tmux-256color tmux xterm-ghostty ghostty; args tmux-256color tmux xterm-256color rex; }
    When call wrapped
    The output should equal "-f kitty --passthrough tmux
.
-f kitty --passthrough tmux
."
  End

  It 'falls back to character art when chafa is too old for tmux passthrough'
    STUB_OLD_CHAFA=1
    When call args tmux-256color tmux xterm-ghostty ghostty
    The output should equal "-f symbols
."
  End

  # The shared answer is explicit here (sixel, iterm, symbols); the viewer has
  # always let chafa detect these itself, and still does.
  It 'leaves every other terminal to chafa'"'"'s auto-detection'
    others() { args xterm-256color WezTerm; args tmux-256color tmux xterm-256color WezTerm; args xterm-256color Apple_Terminal; }
    When call others
    The output should equal ".
.
."
  End
End

# In a Rex pane the viewer opens as a floating layer over what you were
# looking at, not as a tab. Hermetic: `rex` is a stub that records the layer.
Describe 'term-quick-view in a Rex pane'
  SCRIPT="$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_term-quick-view"
  LIB="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib"

  setup() {
    QV_TMP=$(mktemp -d)
    : >"$QV_TMP/pic.png"
    cat >"$QV_TMP/rex" <<EOS
#!/bin/sh
printf '%s\n' "\$*" >>"$QV_TMP/rex.log"
case " \$* " in
  *" session.view "*) cat "$QV_TMP/view.json" ;;
  *" session.new_layer "*) cat >"$QV_TMP/req.json"; [ "\${STUB_LAYER:-ok}" = ok ] || exit 1; echo '{"block_ids":["block:layer"]}' ;;
esac
exit 0
EOS
    chmod +x "$QV_TMP/rex"
    print -r -- '{"session_id":"session:s","windows":[{"layers":[{"kind":"tiled","blocks":[{"block_id":"block:origin","label":"Quick View"}]}]}]}' >"$QV_TMP/view.json"
  }
  cleanup() { rm -rf "$QV_TMP"; unset STUB_LAYER; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  view() {
    env -u TMUX -u MUX_SESSION -u TERM_QUICK_VIEW_ARGS REX_SESSION=session:s REX_BLOCK=block:origin \
      MUX_REX_BIN="$QV_TMP/rex" MUX_LIB="$LIB" zsh "$SCRIPT" "$QV_TMP/pic.png" 2>/dev/null
    print -r -- "rc=$?"
  }
  req() { jq -r "$1" "$QV_TMP/req.json"; }

  It 'opens a floating layer that renders the file with Kitty graphics, and no tab'
    shape() {
      view
      req '.layout.block.options.command | join(" ")' | sed -e "s|/private$QV_TMP|TMP|g" -e "s|$QV_TMP|TMP|g" -e "s|^env \(.*\) [^ ]*term-quick-view --render|env \1 SELF --render|"
      req '.bounds | map(. * 100 | round) | join(",")'
      req '.layout.block.label'
      grep -c 'window new' "$QV_TMP/rex.log" || true
    }
    When call shape
    The output should equal "rc=0
env TERM_QUICK_VIEW_ARGS=-f kitty SELF --render TMP/pic.png
10,10,80,80
Quick View
0"
  End

  It 'replaces a quick view float that is already open, and only a float'
    # The tiled pane above carries the same label and must be left alone.
    print -r -- '{"session_id":"session:s","windows":[{"layers":[{"kind":"tiled","blocks":[{"block_id":"block:origin","label":"Quick View"}]},{"kind":"floating","blocks":[{"block_id":"block:old","label":"Quick View"},{"block_id":"block:other","label":"Notes"}]}]}]}' >"$QV_TMP/view.json"
    replaced() { view >/dev/null; grep 'block close' "$QV_TMP/rex.log" | sed 's/.*block close //'; }
    When call replaced
    The output should equal "-s block:old block:old"
  End

  It 'fails when no layer can be opened'
    export STUB_LAYER=fail
    When call view
    The output should equal "rc=1"
  End
End
