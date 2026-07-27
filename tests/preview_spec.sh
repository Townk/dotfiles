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
    When run zsh -c "FZF_PREVIEW_COLUMNS=100 FZF_PREVIEW_LINES=50 PREVIEW_NO_RUN=1 PREVIEW_LIB='$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib'; source '$SCRIPT'; geometry; print \$w \$h"
    The output should equal "99 50"
  End

  It 'falls back to piper w/h env, no scrollbar adjustment'
    When run zsh -c "w=90 h=30 PREVIEW_NO_RUN=1 PREVIEW_LIB='$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib'; source '$SCRIPT'; geometry; print \$w \$h"
    The output should equal "90 30"
  End

  It 'prefers explicit -W/-H flags over FZF vars'
    When run zsh -c "FZF_PREVIEW_COLUMNS=100 FZF_PREVIEW_LINES=50 PREVIEW_NO_RUN=1 PREVIEW_LIB='$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib'; source '$SCRIPT'; OPT_W=70 OPT_H=20; geometry; print \$w \$h"
    The output should equal "70 20"
  End

  It 'defaults to 80x40'
    When run zsh -c "PREVIEW_NO_RUN=1 PREVIEW_LIB='$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib'; source '$SCRIPT'; geometry; print \$w \$h"
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
    When run zsh -f -c "PREVIEW_NO_RUN=1 PREVIEW_LIB='$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib'; source '$SCRIPT'
      a=\$(raster::cache_path '$SRC' video 5)
      b=\$(raster::cache_path '$SRC' video 5)
      [[ \$a == \$b && \$a == *.png ]] && print same"
    The output should equal "same"
  End

  It 'varies the key with tag and skip'
    When run zsh -f -c "PREVIEW_NO_RUN=1 PREVIEW_LIB='$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib'; source '$SCRIPT'
      a=\$(raster::cache_path '$SRC' video 0)
      b=\$(raster::cache_path '$SRC' video 5)
      c=\$(raster::cache_path '$SRC' pdf 0)
      [[ \$a != \$b && \$a != \$c && \$b != \$c ]] && print distinct"
    The output should equal "distinct"
  End

  It 'renders once, then serves the cache'
    When run zsh -f -c "PREVIEW_NO_RUN=1 PREVIEW_LIB='$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib'; source '$SCRIPT'
      count=0
      fake-render() { count=\$((count+1)); print -n x >\"\$RASTER_OUT\"; }
      cache=\$(raster::cache_path '$SRC' t)
      raster::cached \"\$cache\" fake-render
      raster::cached \"\$cache\" fake-render
      print \$count; [[ -s \$cache ]] && print cached"
    The line 1 of output should equal "1"
    The line 2 of output should equal "cached"
  End

  It 'leaves no cache file when the render fails'
    When run zsh -f -c "PREVIEW_NO_RUN=1 PREVIEW_LIB='$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib'; source '$SCRIPT'
      bad-render() { return 1; }
      cache=\$(raster::cache_path '$SRC' t)
      raster::cached \"\$cache\" bad-render && print unexpected
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

Describe 'preview: video'
  SCRIPT="$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_preview"

  setup() {
    export XDG_CACHE_HOME="$SHELLSPEC_TMPBASE/vcache"
    rm -rf "$XDG_CACHE_HOME"
    # The XDG sandbox hides bat's compiled-theme cache, making the
    # chezmoi-system theme "unknown" (stderr warning → shellspec WARNED).
    # Point bat at the real cache read-only; renders stay sandboxed.
    export BAT_CACHE_PATH="$HOME/.cache/bat"
    VID="$SHELLSPEC_TMPBASE/clip.mp4"
    [ -f "$VID" ] || ffmpeg -v error -f lavfi -i testsrc=duration=1:size=128x96:rate=10 \
      -pix_fmt yuv420p "$VID"
  }
  BeforeEach 'setup'

  It 'shows a frame thumbnail plus mediainfo metadata'
    When run zsh -f "$SCRIPT" -W 80 -H 24 "$VID"
    The status should be success
    The output should include "Video"
  End

  It 'caches the extracted frame, distinct per seek position'
    When run zsh -f -c "zsh -f '$SCRIPT' -W 80 -H 24 '$VID' >/dev/null
      zsh -f '$SCRIPT' -W 80 -H 24 --skip 4 '$VID' >/dev/null
      files=(\$XDG_CACHE_HOME/preview/*.png(N)); print \${#files}"
    The output should equal "2"
  End
End

Describe 'preview: audio'
  SCRIPT="$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_preview"

  setup() {
    export XDG_CACHE_HOME="$SHELLSPEC_TMPBASE/acache"
    rm -rf "$XDG_CACHE_HOME"
    export BAT_CACHE_PATH="$HOME/.cache/bat"
    ART="$SHELLSPEC_TMPBASE/art.mp3"
    NOART="$SHELLSPEC_TMPBASE/noart.mp3"
    if [ ! -f "$ART" ]; then
      magick -size 64x64 xc:navy "$SHELLSPEC_TMPBASE/cover.png"
      ffmpeg -v error -f lavfi -i sine=frequency=440:duration=1 \
        -i "$SHELLSPEC_TMPBASE/cover.png" -map 0:a -map 1:v \
        -c:a libmp3lame -c:v png -disposition:v:0 attached_pic \
        -id3v2_version 3 "$ART"
      ffmpeg -v error -f lavfi -i sine=frequency=440:duration=1 \
        -c:a libmp3lame "$NOART"
    fi
  }
  BeforeEach 'setup'

  It 'extracts embedded cover art into the cache'
    When run zsh -f -c "zsh -f '$SCRIPT' -W 80 -H 24 '$ART' >/dev/null
      files=(\$XDG_CACHE_HOME/preview/*.png(N)); print \${#files}"
    The output should equal "1"
  End

  It 'still shows metadata when there is no art'
    When run zsh -f "$SCRIPT" -W 80 -H 24 "$NOART"
    The status should be success
    The output should include "Audio"
  End

  It 'caches nothing for artless audio'
    When run zsh -f -c "zsh -f '$SCRIPT' -W 80 -H 24 '$NOART' >/dev/null
      files=(\$XDG_CACHE_HOME/preview/*.png(N)); print \${#files}"
    The output should equal "0"
  End
End

Describe 'preview: pdf paging'
  SCRIPT="$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_preview"

  setup() {
    export XDG_CACHE_HOME="$SHELLSPEC_TMPBASE/pcache"
    rm -rf "$XDG_CACHE_HOME"
    PDF="$SHELLSPEC_TMPBASE/two.pdf"
    [ -f "$PDF" ] || magick -size 100x100 xc:red xc:blue "$PDF"
  }
  BeforeEach 'setup'

  It 'caches pages; --skip past the end clamps to the last page'
    When run zsh -f -c "zsh -f '$SCRIPT' -W 40 -H 12 '$PDF' >/dev/null
      zsh -f '$SCRIPT' -W 40 -H 12 --skip 1 '$PDF' >/dev/null
      zsh -f '$SCRIPT' -W 40 -H 12 --skip 99 '$PDF' >/dev/null
      files=(\$XDG_CACHE_HOME/preview/*.png(N)); print \${#files}"
    The output should equal "2"
  End
End

Describe 'preview: adobe'
  SCRIPT="$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_preview"

  setup() {
    export XDG_CACHE_HOME="$SHELLSPEC_TMPBASE/adcache"
    rm -rf "$XDG_CACHE_HOME"
    export BAT_CACHE_PATH="$HOME/.cache/bat"
    PSD="$SHELLSPEC_TMPBASE/pic.psd"
    [ -f "$PSD" ] || magick -size 32x32 xc:tomato "$PSD"
  }
  BeforeEach 'setup'

  It 'renders PSD visually (cached), not as a hex dump'
    When run zsh -f -c "zsh -f '$SCRIPT' -W 80 -H 24 '$PSD' >/dev/null
      files=(\$XDG_CACHE_HOME/preview/*.png(N)); print \${#files}"
    The output should equal "1"
  End
End

Describe 'preview: archives'
  SCRIPT="$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_preview"

  setup() {
    export XDG_CACHE_HOME="$SHELLSPEC_TMPBASE/arcache"
    D="$SHELLSPEC_TMPBASE/ar"; mkdir -p "$D"
    [ -f "$D/f.txt" ] || print "zstd archive member" >"$D/f.txt"
    [ -f "$D/a.tar.zst" ] || (cd "$D" && ouch compress -q -y f.txt a.tar.zst)
    [ -f "$D/f.txt.gz" ] || gzip -kf "$D/f.txt"
  }
  BeforeEach 'setup'

  It 'lists tar.zst contents instead of hex-dumping'
    When run zsh -f "$SCRIPT" -W 80 -H 24 "$D/a.tar.zst"
    The status should be success
    The output should include "f.txt"
    The output should not include "┌────────┬"
  End

  It 'lists gzip contents'
    When run zsh -f "$SCRIPT" -W 80 -H 24 "$D/f.txt.gz"
    The status should be success
    The output should include "f.txt"
  End
End

Describe 'preview: --pixels machine interface'
  SCRIPT="$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_preview"

  setup() {
    export XDG_CACHE_HOME="$SHELLSPEC_TMPBASE/xcache"
    rm -rf "$XDG_CACHE_HOME"
    export BAT_CACHE_PATH="$HOME/.cache/bat"
    PNG="$SHELLSPEC_TMPBASE/dot.png"
    [ -f "$PNG" ] || magick -size 8x8 xc:lime "$PNG"
    VID2="$SHELLSPEC_TMPBASE/clip2.mp4"
    [ -f "$VID2" ] || ffmpeg -v error -f lavfi -i testsrc=duration=1:size=128x96:rate=10 \
      -pix_fmt yuv420p "$VID2"
    TXT="$SHELLSPEC_TMPBASE/plain.txt"
    print "plain text body" >"$TXT"
  }
  BeforeEach 'setup'

  It 'returns the source path as raster for displayable images'
    When run zsh -f "$SCRIPT" --pixels "$PNG"
    The status should be success
    The line 1 of output should equal "$PNG"
    The output should include "Image"
  End

  It 'returns a cached frame as raster for video'
    When run zsh -f -c "line=\$(zsh -f '$SCRIPT' --pixels '$VID2' | head -1)
      [[ \$line == \$XDG_CACHE_HOME/preview/*.png && -s \$line ]] && print ok"
    The output should equal "ok"
  End

  It 'returns an empty raster line plus text for text files'
    When run zsh -f "$SCRIPT" --pixels "$TXT"
    The status should be success
    The line 1 of output should equal ""
    The output should include "plain text body"
  End

  It 'exits 2 when --pixels has no path'
    When run zsh -f "$SCRIPT" --pixels
    The status should equal 2
    The stderr should include "Usage"
  End
End

Describe 'preview: raw-path handling'
  SCRIPT="$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_preview"

  setup() {
    export XDG_CACHE_HOME="$SHELLSPEC_TMPBASE/qcache"
    export BAT_CACHE_PATH="$HOME/.cache/bat"
    RAW="$SHELLSPEC_TMPBASE/back\\slash.txt"
    print "raw path body" >"$RAW"
  }
  BeforeEach 'setup'

  It 'prefers an existing raw path over fzf unquoting (yazi hands raw paths)'
    When run zsh -f "$SCRIPT" -W 60 -H 20 "$RAW"
    The status should be success
    The output should include "raw path body"
  End
End

Describe 'preview: svg + font sample (Mode B fixes)'
  SCRIPT="$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_preview"

  setup() {
    export XDG_CACHE_HOME="$SHELLSPEC_TMPBASE/mcache"
    rm -rf "$XDG_CACHE_HOME"
    export BAT_CACHE_PATH="$HOME/.cache/bat"
    SVG="$SHELLSPEC_TMPBASE/box.svg"
    [ -f "$SVG" ] || printf '%s' '<svg xmlns="http://www.w3.org/2000/svg" width="40" height="40"><rect width="40" height="40" fill="teal"/></svg>' >"$SVG"
    FONT=$(zsh -c 'print -l /System/Library/Fonts/Supplemental/*.ttf(N) ~/Library/Fonts/*.ttf(N) 2>/dev/null | head -1')
  }
  BeforeEach 'setup'

  It 'converts svg to a cached raster for --pixels (rsvg-convert path)'
    command -v rsvg-convert >/dev/null || skip "rsvg-convert not installed"
    When run zsh -f -c "line=\$(zsh -f '$SCRIPT' --pixels '$SVG' | head -1)
      [[ \$line == \$XDG_CACHE_HOME/preview/*.png && -s \$line ]] && print ok"
    The output should equal "ok"
  End

  It 'builds the font sample from the font cmap'
    [ -n "$FONT" ] || skip "no .ttf font found on this machine"
    command -v fc-query >/dev/null || skip "fc-query not installed"
    When run zsh -f -c "PREVIEW_NO_RUN=1 PREVIEW_LIB='$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib'; source '$SCRIPT'
      s=\$(font-sample-text '$FONT') && [[ -n \$s ]] && print sampled"
    The output should equal "sampled"
  End
End

Describe 'preview: office + iwork'
  SCRIPT="$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_preview"

  setup() {
    export XDG_CACHE_HOME="$SHELLSPEC_TMPBASE/ocache"
    rm -rf "$XDG_CACHE_HOME"
    export BAT_CACHE_PATH="$HOME/.cache/bat"
    DOCX="$SHELLSPEC_TMPBASE/qa.docx"
    [ -f "$DOCX" ] || printf '# Office QA\n\nhello\n' | pandoc -f markdown -o "$DOCX"
    NUMBERS="$SHELLSPEC_TMPBASE/qa.numbers"
    if [ ! -f "$NUMBERS" ]; then
      magick -size 120x90 xc:orchid "$SHELLSPEC_TMPBASE/preview.jpg"
      (cd "$SHELLSPEC_TMPBASE" && zip -q qa.numbers preview.jpg)
    fi
  }
  BeforeEach 'setup'

  It 'renders a docx first page via Quick Look into the cache'
    command -v qlmanage >/dev/null || skip "qlmanage not available (macOS only)"
    command -v pandoc >/dev/null || skip "pandoc not installed"
    When run zsh -f -c "line=\$(zsh -f '$SCRIPT' --pixels '$DOCX' | head -1)
      [[ \$line == \$XDG_CACHE_HOME/preview/*.png && -s \$line ]] && print ok"
    The output should equal "ok"
  End

  It 'extracts the embedded iWork preview.jpg as the raster'
    When run zsh -f -c "line=\$(zsh -f '$SCRIPT' --pixels '$NUMBERS' | head -1)
      [[ \$line == \$XDG_CACHE_HOME/preview/*.png && -s \$line ]] && print ok"
    The output should equal "ok"
  End
End

# The standalone image viewer centres its picture; the fzf/yazi preview panes
# must NOT (the image sits above the metadata there). The knob is an env var,
# so the contract is "chafa gets --align only when it is set".
Describe 'preview: image alignment knob'
  setup() {
    T=$(mktemp -d); mkdir -p "$T/bin"
    printf '#!/bin/sh\necho "chafa $*" >> %s/chafa.calls\n' "$T" > "$T/bin/chafa"
    chmod +x "$T/bin/chafa"
    printf 'x' > "$T/img.png"
  }
  cleanup() { rm -rf "$T"; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  It 'passes --align through when PREVIEW_IMAGE_ALIGN is set'
    run_it() {
      PATH="$T/bin:$PATH" PREVIEW_IMAGE_ALIGN="center,center" \
        zsh -c 'w=100 h=25; source "$1"; preview-raster "$2"' _ \
        "$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_preview" "$T/img.png" 2>/dev/null || true
      cat "$T/chafa.calls" 2>/dev/null
    }
    When call run_it
    The output should include "--align center,center"
  End

  It 'omits --align when the knob is unset (the fzf preview pane)'
    run_it() {
      PATH="$T/bin:$PATH" \
        zsh -c 'unset PREVIEW_IMAGE_ALIGN; w=100 h=25; source "$1"; preview-raster "$2"' _ \
        "$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_preview" "$T/img.png" 2>/dev/null || true
      cat "$T/chafa.calls" 2>/dev/null
    }
    When call run_it
    The output should not include "--align"
  End
End
