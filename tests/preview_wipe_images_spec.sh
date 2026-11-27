# preview-wipe-images — the key-binding half of "Kitty images in an fzf
# preview pane": deletes the terminal's images when `preview` flagged one.
Describe 'preview-wipe-images'
  BIN="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_preview-wipe-images"

  setup() { PW_TMP=$(mktemp -d); }
  cleanup() { rm -rf "$PW_TMP"; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  wipe() {
    env -u TMUX TMPDIR="$PW_TMP" PREVIEW_TTY="$PW_TMP/tty" PREVIEW_TTY_NAME=/dev/ttys042 "$@" sh "$BIN" ${WIPE_ARG:-}
    print -r -- "rc=$?"
    if [[ -s "$PW_TMP/tty" ]]; then print -r -- "${${(j: :)${=$(od -An -c "$PW_TMP/tty")}}}"; else print none; fi
    [[ -e "$PW_TMP/preview-kitty.ttys042" ]] && print flag || print "no flag"
  }

  It 'deletes the images and the flag with --forget'
    : >"$PW_TMP/preview-kitty.ttys042"
    WIPE_ARG=--forget
    When call wipe
    The output should equal 'rc=0
033 _ G a = d , d = A 033 \
no flag'
  End

  It 'deletes the images and keeps the flag by default (the preview toggle)'
    : >"$PW_TMP/preview-kitty.ttys042"
    When call wipe
    The line 2 of output should equal '033 _ G a = d , d = A 033 \'
    The line 3 of output should equal "flag"
  End

  # fzf-tab splits its fzf-flags on spaces: a flag with one in it reaches fzf
  # cut in two.
  It 'is bound without a space anywhere in the fzf-tab flags'
    spaced() { grep -A3 "zstyle ':fzf-tab:\*' fzf-flags" "$SHELLSPEC_PROJECT_ROOT/home/dot_config/zsh/completion.sh" | grep -c -- "--bind=[^']* [^']*'" || true; }
    When call spaced
    The output should equal "0"
  End

  It 'does nothing when no picture was previewed in this terminal'
    : >"$PW_TMP/preview-kitty.ttys099"
    When call wipe
    The output should equal "rc=0
none
no flag"
  End

  It 'stays out of it inside tmux'
    : >"$PW_TMP/preview-kitty.ttys042"
    When call wipe TMUX=/tmp/s,1,0
    The line 2 of output should equal "none"
    The line 3 of output should equal "flag"
  End
End
