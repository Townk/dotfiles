# Tests for rex-picker — the script behind the key-bound pickers on Rex. It
# opens a floating layer over $REX_BLOCK running rex-modal around a pick-*
# command; the table of sizes, titles, environment and commands is copied from
# the tmux bindings. Hermetic: `rex` is a stub that records the layer request.
Describe 'rex-picker'
  PICKER="$SHELLSPEC_PROJECT_ROOT/home/dot_config/mux/scripts/executable_rex-picker"
  LIB="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib"

  setup() {
    RP_TMP=$(mktemp -d)
    cat >"$RP_TMP/rex" <<EOS
#!/bin/sh
printf '%s\n' "\$*" >>"$RP_TMP/rex.log"
case " \$* " in
  *" session.view "*) cat "$RP_TMP/view.json" 2>/dev/null; exit 0 ;;
  *" block call "*" process"*) echo '{"foreground":{"cwd":"$RP_TMP","name":"zsh"}}'; exit 0 ;;
  *" session.new_layer "*)
    cat >"$RP_TMP/req.json"
    [ "\${STUB_LAYER:-ok}" = ok ] || exit 1
    echo '{"block_ids":["block:layer"]}' ;;
esac
exit 0
EOS
    chmod +x "$RP_TMP/rex"
  }
  cleanup() { rm -rf "$RP_TMP"; unset STUB_LAYER; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  picker() {
    env -u TMUX -u ZELLIJ HOME=/home/u REX_SESSION=session:s REX_BLOCK="${RP_BLOCK-block:origin}" \
      MUX_REX_BIN="$RP_TMP/rex" MUX_LIB="$LIB" zsh "$PICKER" "$@" 2>"$RP_TMP/err"
    print -r -- "rc=$?"
  }
  cmdline() { jq -r '.layout.block.options.command | join(" ")' "$RP_TMP/req.json"; }
  bounds() { jq -c '.bounds | map(. * 100 | round)' "$RP_TMP/req.json"; }

  It 'opens the glyph picker over the calling block, injecting'
    run() { picker glyph; cmdline; bounds; }
    When call run
    The output should equal "rc=0
env COLORTERM=truecolor PICK_GLYPH_PADDING=0,2,0,2 /home/u/.config/mux/scripts/rex-modal --origin block:origin --title Glyph Picker --inject --no-chrome -- /home/u/.local/libexec/pick-glyph
[15,20,70,60]"
  End

  It 'resumes the glyph picker'
    run() { picker glyph --resume >/dev/null; cmdline; }
    When call run
    The output should equal "env COLORTERM=truecolor PICK_GLYPH_PADDING=0,2,0,2 /home/u/.config/mux/scripts/rex-modal --origin block:origin --title Glyph Picker (resumed) --inject --no-chrome -- /home/u/.local/libexec/pick-glyph --resume"
  End

  It 'opens the gitmoji picker'
    run() { picker gitmoji >/dev/null; cmdline; }
    When call run
    The output should equal "env COLORTERM=truecolor PICK_GITMOJI_PADDING=0,2,0,2 /home/u/.config/mux/scripts/rex-modal --origin block:origin --title Gitmoji Picker --inject --no-chrome -- /home/u/.local/libexec/pick-gitmoji"
  End

  It 'opens the clipboard history taller'
    run() { picker clipboard >/dev/null; cmdline; bounds; }
    When call run
    The output should equal "env COLORTERM=truecolor /home/u/.config/mux/scripts/rex-modal --origin block:origin --title Clipboard history --inject --no-chrome -- /home/u/.local/libexec/pick-clipboard
[15,13,70,75]"
  End

  It 'opens the notification history WITHOUT injecting'
    run() { picker notifications >/dev/null; cmdline; }
    When call run
    The output should equal "env COLORTERM=truecolor /home/u/.config/mux/scripts/rex-modal --origin block:origin --title Notifications --no-chrome -- /home/u/.local/libexec/pick-notifications"
  End

  It 'never calls rex without --autostart=false'
    run() { picker glyph >/dev/null; grep -c -v -- '--autostart=false' "$RP_TMP/rex.log" || true; }
    When call run
    The output should equal "0"
  End

  It 'fails when the layer cannot be opened'
    run() { STUB_LAYER=fail picker glyph; cat "$RP_TMP/err"; }
    When call run
    The output should include "rc=1"
    The output should include "could not open a floating layer"
  End

  It 'fails outside a Rex pane'
    run() { RP_BLOCK="" picker glyph; ls "$RP_TMP" | grep -c req.json || true; }
    When call run
    The output should equal "rc=1
0"
  End

  It 'rejects an unknown picker'
    When call picker bogus
    The output should equal "rc=2"
  End

  It 'rejects --resume for a picker that has none'
    When call picker clipboard --resume
    The output should equal "rc=2"
  End

  It 'opens the picker in the directory of the pane it was called for'
    run() { picker gitmoji >/dev/null; jq -r '.layout.block.options.cwd' "$RP_TMP/req.json"; }
    When call run
    The output should equal "$RP_TMP"
  End

  It 'does nothing when the key is pressed inside a float'
    # The second press of a picker key lands in the first picker's float; a
    # float opened for it would type its result into that picker.
    print -r -- '{"windows":[{"layers":[{"kind":"tiled","blocks":[{"block_id":"block:shell"}]},{"kind":"floating","blocks":[{"block_id":"block:origin"}]}]}]}' >"$RP_TMP/view.json"
    run() { picker gitmoji; [[ -e "$RP_TMP/req.json" ]] && print opened || print "not opened"; }
    When call run
    The output should equal "rc=0
not opened"
  End

  It 'still opens over a tiled pane when another float exists'
    print -r -- '{"windows":[{"layers":[{"kind":"tiled","blocks":[{"block_id":"block:origin"}]},{"kind":"floating","blocks":[{"block_id":"block:other"}]}]}]}' >"$RP_TMP/view.json"
    run() { picker gitmoji; [[ -e "$RP_TMP/req.json" ]] && print opened || print "not opened"; }
    When call run
    The output should equal "rc=0
opened"
  End
End
