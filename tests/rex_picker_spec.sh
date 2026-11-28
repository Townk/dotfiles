# Tests for rex-picker — the script behind the key-bound pickers on Rex. It
# opens a floating layer over $REX_BLOCK running rex-modal around a pick-*
# command; the table of sizes, titles, environment and commands is copied from
# the tmux bindings. Hermetic: `rex` is a stub that records the layer request.
Describe 'rex-picker'
  PICKER="$SHELLSPEC_PROJECT_ROOT/home/dot_config/mux/scripts/executable_rex-picker"
  LIB="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib"

  # One warm slot for the fake rex every example writes: see
  # tests/exec_warm_helper.sh.
  Include tests/exec_warm_helper.sh
  BeforeAll 'spec_exec_pool_warm 1'
  setup() {
    spec_sandbox; RP_TMP=$SANDBOX
    # All canned: `session.view` from view.json when an example writes one,
    # the pane's process (cwd: the sandbox), and `session.new_layer`, which
    # records the request in req.json (STUB_LAYER=fail makes it fail).
    spec_fake_rex "$RP_TMP"
  }
  BeforeEach 'setup'

  # A HOME that does not exist, and NOT under /home: that is an automount
  # point on macOS, where every lookup of a dotfile below it (jq's ~/.jq,
  # zsh's ~/.zshenv) waits ~100 ms for autofs to say no.
  picker() {
    env -u TMUX HOME=/nohome/u REX_SESSION=session:s REX_BLOCK="${RP_BLOCK-block:origin}" \
      MUX_REX_BIN="$RP_TMP/rex" MUX_LIB="$LIB" zsh -f "$PICKER" "$@" 2>"$RP_TMP/err"
    print -r -- "rc=$?"
  }
  cmdline() { jq -r '.layout.block.options.command | join(" ")' "$RP_TMP/req.json"; }
  bounds() { jq -c '.bounds | map(. * 100 | round)' "$RP_TMP/req.json"; }

  It 'opens the glyph picker over the calling block, injecting'
    run() { picker glyph; cmdline; bounds; }
    When call run
    The output should equal "rc=0
env PICK_GLYPH_PADDING=0,2,0,2 /nohome/u/.config/mux/scripts/rex-modal --origin block:origin --title Glyph Picker --inject --no-chrome -- /nohome/u/.local/libexec/pick-glyph
[15,20,70,60]"
  End

  It 'resumes the glyph picker'
    run() { picker glyph --resume >/dev/null; cmdline; }
    When call run
    The output should equal "env PICK_GLYPH_PADDING=0,2,0,2 /nohome/u/.config/mux/scripts/rex-modal --origin block:origin --title Glyph Picker (resumed) --inject --no-chrome -- /nohome/u/.local/libexec/pick-glyph --resume"
  End

  It 'opens the gitmoji picker'
    run() { picker gitmoji >/dev/null; cmdline; }
    When call run
    The output should equal "env PICK_GITMOJI_PADDING=0,2,0,2 /nohome/u/.config/mux/scripts/rex-modal --origin block:origin --title Gitmoji Picker --inject --no-chrome -- /nohome/u/.local/libexec/pick-gitmoji"
  End

  It 'opens the clipboard history taller'
    run() { picker clipboard >/dev/null; cmdline; bounds; }
    When call run
    The output should equal "/nohome/u/.config/mux/scripts/rex-modal --origin block:origin --title Clipboard history --inject --no-chrome -- /nohome/u/.local/libexec/pick-clipboard
[15,13,70,75]"
  End

  It 'opens the notification history WITHOUT injecting'
    run() { picker notifications >/dev/null; cmdline; }
    When call run
    The output should equal "/nohome/u/.config/mux/scripts/rex-modal --origin block:origin --title Notifications --no-chrome -- /nohome/u/.local/libexec/pick-notifications"
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
