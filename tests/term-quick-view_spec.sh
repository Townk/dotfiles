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
