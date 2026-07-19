# Tests for the unified preview script (spec:
# docs/superpowers/specs/2026-07-18-unified-preview-design.md).
#
# The script normally ends by running main "$@"; PREVIEW_NO_RUN=1 is the
# test-only escape hatch (same convention as PICK_CLIPBOARD_NO_RUN in
# executable_pick-clipboard) that lets a test source the functions and call
# them directly. XDG_CACHE_HOME is sandboxed so raster-cache tests never
# touch the real ~/.cache/preview.
Describe 'preview: geometry + CLI'
  SCRIPT="$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_preview"

  setup() {
    export XDG_CACHE_HOME="$SHELLSPEC_TMPBASE/cache"
  }
  BeforeEach 'setup'

  It 'uses FZF vars, minus the scrollbar column'
    When run zsh -c "FZF_PREVIEW_COLUMNS=100 FZF_PREVIEW_LINES=50 PREVIEW_NO_RUN=1; source '$SCRIPT'; geometry; print \$w \$h"
    The output should equal "99 50"
  End

  It 'falls back to piper w/h env, no scrollbar adjustment'
    When run zsh -c "w=90 h=30 PREVIEW_NO_RUN=1; source '$SCRIPT'; geometry; print \$w \$h"
    The output should equal "90 30"
  End

  It 'prefers explicit -W/-H flags over FZF vars'
    When run zsh -c "FZF_PREVIEW_COLUMNS=100 FZF_PREVIEW_LINES=50 PREVIEW_NO_RUN=1; source '$SCRIPT'; OPT_W=70 OPT_H=20; geometry; print \$w \$h"
    The output should equal "70 20"
  End

  It 'defaults to 80x40'
    When run zsh -c "PREVIEW_NO_RUN=1; source '$SCRIPT'; geometry; print \$w \$h"
    The output should equal "80 40"
  End

  It 'parses -W/-H flags before the target path'
    # A directory listing (eza) proves main ran with the flag-parsed path.
    When run zsh "$SCRIPT" -W 60 -H 20 "$SHELLSPEC_PROJECT_ROOT/tests"
    The status should be success
    The output should include "preview_spec.sh"
  End

  It 'no longer hardcodes the Catppuccin Mocha bat theme'
    When run grep -c 'Catppuccin Mocha' "$SCRIPT"
    The status should be failure
    The output should equal "0"
  End

  It 'does not loop on a trailing valueless flag'
    When run zsh "$SCRIPT" -W
    The status should be success
    # The banner is figlet art, so no literal text to match — the flag
    # consuming cleanly and the banner rendering at all is the assertion.
    The output should not equal ""
  End
End

Describe 'preview: raster cache'
  SCRIPT="$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_preview"

  setup() {
    export XDG_CACHE_HOME="$SHELLSPEC_TMPBASE/rcache"
    rm -rf "$XDG_CACHE_HOME"
    SRC="$SHELLSPEC_TMPBASE/rcache-src.txt"
    print hello >"$SRC"
  }
  BeforeEach 'setup'

  It 'produces a stable key for same src+tag+skip'
    When run zsh -f -c "PREVIEW_NO_RUN=1; source '$SCRIPT'
      a=\$(raster-cache-path '$SRC' video 5)
      b=\$(raster-cache-path '$SRC' video 5)
      [[ \$a == \$b && \$a == *.png ]] && print same"
    The output should equal "same"
  End

  It 'varies the key with tag and skip'
    When run zsh -f -c "PREVIEW_NO_RUN=1; source '$SCRIPT'
      a=\$(raster-cache-path '$SRC' video 0)
      b=\$(raster-cache-path '$SRC' video 5)
      c=\$(raster-cache-path '$SRC' pdf 0)
      [[ \$a != \$b && \$a != \$c && \$b != \$c ]] && print distinct"
    The output should equal "distinct"
  End

  It 'renders once, then serves the cache'
    When run zsh -f -c "PREVIEW_NO_RUN=1; source '$SCRIPT'
      count=0
      fake-render() { count=\$((count+1)); print -n x >\"\$RASTER_OUT\"; }
      cache=\$(raster-cache-path '$SRC' t)
      render-cached \"\$cache\" fake-render
      render-cached \"\$cache\" fake-render
      print \$count; [[ -s \$cache ]] && print cached"
    The line 1 of output should equal "1"
    The line 2 of output should equal "cached"
  End

  It 'leaves no cache file when the render fails'
    When run zsh -f -c "PREVIEW_NO_RUN=1; source '$SCRIPT'
      bad-render() { return 1; }
      cache=\$(raster-cache-path '$SRC' t)
      render-cached \"\$cache\" bad-render && print unexpected
      [[ ! -e \$cache ]] && print clean"
    The output should equal "clean"
  End
End

Describe 'preview: fonts'
  SCRIPT="$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_preview"

  setup() {
    export XDG_CACHE_HOME="$SHELLSPEC_TMPBASE/fcache"
    rm -rf "$XDG_CACHE_HOME"
    FONT=$(zsh -c 'print -l /System/Library/Fonts/Supplemental/*.ttf(N) ~/Library/Fonts/*.ttf(N) 2>/dev/null | head -1')
  }
  BeforeEach 'setup'

  It 'renders a glyph sheet instead of a hex dump'
    [ -n "$FONT" ] || skip "no .ttf font found on this machine"
    When run zsh -f "$SCRIPT" -W 80 -H 24 "$FONT"
    The status should be success
    The output should not equal ""
    The output should not include "┌────────┬"
  End

  It 'caches the rendered sheet'
    [ -n "$FONT" ] || skip "no .ttf font found on this machine"
    When run zsh -f -c "zsh -f '$SCRIPT' -W 80 -H 24 '$FONT' >/dev/null; files=(\$XDG_CACHE_HOME/preview/*.png(N)); print \${#files}"
    The output should equal "1"
  End
End
