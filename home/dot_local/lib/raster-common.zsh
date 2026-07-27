#!/usr/bin/env zsh
# raster-common.zsh — "give me a PNG for this file", cached.
#
# SOURCED, never executed. This is the file→raster pipeline that used to live
# inside `preview`: the cache, the per-format converters, and the dispatch
# that picks one. It was extracted when a SECOND consumer needed it —
# term-quick-view renders the same PDFs, office docs and fonts with its own
# geometry and chrome — because the alternative was that consumer imitating
# preview's internals through environment knobs.
#
# The split is: this library produces a RASTER, callers decide how to PAINT
# it. `preview` fits it to an fzf pane with metadata underneath;
# term-quick-view centres it in a tab. Neither knows how the other draws.
#
#   raster::for_file <path> [page-or-seek]  → prints a cached PNG path, rc 0
#                                             rc 1 = nothing can rasterise it
#
# Conversions write to $RASTER_OUT (a temp path keeping its .png suffix —
# fontimage and pdftocairo key their output format off the extension) and the
# result is moved into place, so a killed render never leaves a truncated
# raster to be served later.

[[ -n "${__RASTER_COMMON_LOADED:-}" ]] && return 0
typeset -g __RASTER_COMMON_LOADED=1

zmodload zsh/stat 2>/dev/null

# Shared with preview's own cache: the same file rasterised for either
# consumer is the same PNG, converted once.
: ${RASTER_CACHE_DIR:="${PREVIEW_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/preview}"}

# raster::cache_path <src> <tag> [variant] — content-addressed by path +
# mtime + size + tag + variant, so touching the source invalidates it and PDF
# pages / video seeks get distinct entries.
raster::cache_path() {
  local src="$1" tag="$2" variant="${3:-0}" mt sz key
  mt=$(zstat +mtime "$src" 2>/dev/null) || mt=0
  sz=$(zstat +size "$src" 2>/dev/null) || sz=0
  key=$(print -rn -- "$src|$mt|$sz|$tag|$variant" | shasum | cut -d' ' -f1)
  print -rn -- "$RASTER_CACHE_DIR/$key.png"
}

# raster::cached <cache-file> <render-fn> [args…] — run the converter only
# when the cache file is missing.
raster::cached() {
  local out="$1"
  shift
  [[ -s $out ]] && return 0
  mkdir -p "${out:h}" 2>/dev/null || return 1
  local tmp="$out.$$.png"
  RASTER_OUT="$tmp" "$@" >/dev/null 2>&1
  local rc=$?
  if (( rc == 0 )) && [[ -s $tmp ]]; then
    mv -f "$tmp" "$out"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# raster::prune — drop rasters untouched for 30 days, at most once a day.
raster::prune() {
  [[ -d $RASTER_CACHE_DIR ]] || return 0
  local stamp="$RASTER_CACHE_DIR/.prune-stamp" now mt
  now=$(date +%s)
  mt=$(zstat +mtime "$stamp" 2>/dev/null) || mt=0
  ((now - mt < 86400)) && return 0
  touch "$stamp"
  find "$RASTER_CACHE_DIR" -type f -name '*.png' -mtime +30 -delete 2>/dev/null
}

# --- converters (each writes $RASTER_OUT) -----------------------------------

raster::office() {
  command -v qlmanage >/dev/null 2>&1 || return 1
  local tmpd
  tmpd=$(mktemp -d) || return 1
  {
    qlmanage -t -s 1600 -o "$tmpd" "$1" >/dev/null 2>&1
    local -a made=("$tmpd"/*.png(N))
    ((${#made})) || return 1
    mv -f "${made[1]}" "$RASTER_OUT"
  } always {
    rm -rf "$tmpd"
  }
}

# iWork bundles are zips embedding a full-size preview.jpg; Quick Look covers
# the ones saved without it.
raster::iwork() {
  if command -v magick >/dev/null 2>&1; then
    unzip -p "$1" preview.jpg 2>/dev/null | magick - "$RASTER_OUT" 2>/dev/null
    [[ -s $RASTER_OUT ]] && return 0
    rm -f "$RASTER_OUT"
  fi
  raster::office "$1"
}

raster::video_frame() { ffmpegthumbnailer -i "$1" -o "$RASTER_OUT" -s 0 -t "${2:-10}%" -q 8; }

raster::audio_cover() {
  command -v ffmpeg >/dev/null 2>&1 || return 1
  ffmpeg -y -v error -i "$1" -an -frames:v 1 -update 1 "$RASTER_OUT"
}

# EPS needs ghostscript behind magick; without it the render fails and the
# caller falls through to metadata.
raster::adobe() { magick "$1[0]" -flatten -background white -alpha remove "$RASTER_OUT"; }

# raster::pdf_page_no <pdf> [skip] — 1-based page, clamped to the page count
# so seeking past the end sticks on the last page.
raster::pdf_page_no() {
  local pages page
  pages=$(pdfinfo "$1" 2>/dev/null | awk '/^Pages:/{print $2}')
  [[ -n $pages ]] || pages=1
  page=$(( ${2:-0} + 1 ))
  ((page > pages)) && page=$pages
  print -n -- "$page"
}

raster::pdf_page() {
  local prefix="${RASTER_OUT%.png}"
  pdftocairo -png -f "$2" -l "$2" -singlefile -scale-to 1600 "$1" "$prefix" || return 1
  # Extreme-portrait pages (continuous-scroll docs) fit-to-1600 as an
  # unreadable sliver — re-render width-bound and keep the top slice.
  command -v magick >/dev/null 2>&1 || return 0
  local dims w_px h_px
  dims=$(magick identify -format '%w %h' "$RASTER_OUT" 2>/dev/null) || return 0
  w_px=${dims%% *}; h_px=${dims##* }
  if ((h_px > 0 && w_px > 0 && h_px > w_px * 5 / 2)); then
    pdftocairo -png -f "$2" -l "$2" -singlefile -scale-to-x 1600 -scale-to-y -1 \
      "$1" "$prefix" &&
      magick "$RASTER_OUT" -gravity north -crop 1600x2000+0+0 +repage \
        "$RASTER_OUT" 2>/dev/null
  fi
  return 0
}

# Formats chafa cannot decode directly (icns, heic, svg, raw).
raster::convert() {
  if [[ ${1:l} == *.svg ]] && command -v rsvg-convert >/dev/null 2>&1; then
    rsvg-convert --width 1024 --keep-aspect-ratio -o "$RASTER_OUT" "$1" && return 0
  fi
  if command -v magick >/dev/null 2>&1; then
    magick "$1[0]" -flatten "$RASTER_OUT" 2>/dev/null && [[ -s $RASTER_OUT ]] && return 0
  fi
  # sips: the macOS-native decoder for Apple-side formats this magick build
  # has no delegate for.
  command -v sips >/dev/null 2>&1 || return 1
  sips -s format png "$1" --out "$RASTER_OUT" >/dev/null 2>&1 && [[ -s $RASTER_OUT ]]
}

raster::font_sheet() {
  local -a lines glyphs
  lines=("${(@f)$(font-sample-text "$1")}")
  local sep="  "
  if ((${#lines} > 1)); then
    [[ ${lines[1]} == nospace ]] && sep=""
    glyphs=("${(@)lines[2,-1]}")
  fi

  # Preferred: per-glyph hb-view tiles composed with magick montage —
  # uniform cells and real padding regardless of the font's metrics (a
  # spacing character can't be used: emoji-only cmaps draw it as tofu),
  # and HarfBuzz rasterizes color-glyph tables (COLR/SVG/CBDT) that
  # fontimage renders blank.
  if command -v hb-view >/dev/null 2>&1 && command -v magick >/dev/null 2>&1 &&
    ((${#glyphs})); then
    local tmpd
    tmpd=$(mktemp -d) || return 1
    {
      local g i=0 tile
      for g in "${glyphs[@]}"; do
        [[ -n $g ]] || continue
        tile=$(printf '%s/%02d.png' "$tmpd" "$i")
        hb-view --font-file="$1" --font-size=96 --margin=4 \
          --output-file="$tile" "$g" 2>/dev/null || rm -f "$tile"
        ((i++))
      done
      local -a tiles=("$tmpd"/*.png(N))
      if ((${#tiles} >= 8)); then
        # Normalize each tile to a uniform padded cell (shrink-only), then
        # append rows of 6 and stack them. montage(1) would be the obvious
        # tool but it insists on resolving ImageMagick's annotation font
        # even for unlabeled grids, which this build doesn't have.
        local t
        for t in "${tiles[@]}"; do
          magick "$t" -resize '128x128>' -background white -gravity center \
            -extent 176x176 "$t" 2>/dev/null
        done
        local -a rowfiles=()
        local r rowf
        for ((r = 1; r <= ${#tiles}; r += 6)); do
          rowf="$tmpd/zrow$r.png"
          magick "${tiles[@]:$((r - 1)):6}" +append "$rowf" 2>/dev/null || continue
          rowfiles+=("$rowf")
        done
        ((${#rowfiles})) &&
          magick "${rowfiles[@]}" -background white -append "$RASTER_OUT" \
            2>/dev/null &&
          return 0
      fi
    } always {
      rm -rf "$tmpd"
    }
  fi

  # Fallbacks: single-pass renderers (glyph gaps only when the cmap has a
  # real space; row layout only in fontimage's --text lines).
  local -a row rows
  local g
  for g in "${glyphs[@]}"; do
    [[ -n $g ]] || continue
    row+=("$g")
    if ((${#row} == 8)); then
      rows+=("${(pj.$sep.)row}")
      row=()
    fi
  done
  ((${#row})) && rows+=("${(pj.$sep.)row}")

  if command -v hb-view >/dev/null 2>&1 && ((${#rows})); then
    hb-view --font-file="$1" --font-size=80 --margin=24 --line-space=40 \
      --output-file="$RASTER_OUT" "${(pj:\n:)rows}" 2>/dev/null && return 0
  fi
  if command -v fontimage >/dev/null 2>&1; then
    if ((${#rows})); then
      local -a targs=()
      for g in "${rows[@]}"; do targs+=(--text "$g"); done
      fontimage --width 1600 --pixelsize 80 "${targs[@]}" \
        -o "$RASTER_OUT" "$1" 2>/dev/null && return 0
    fi
    fontimage --width 1600 --pixelsize 80 -o "$RASTER_OUT" "$1" \
      2>/dev/null && return 0
  fi
  command -v magick >/dev/null 2>&1 || return 1
  local flat="${(j: :)glyphs}"
  magick -size 1600x -background black -fill white -font "$1" -pointsize 80 \
    label:"${flat:-AaBbCcDdEe FfGgHhIiJj 0123456789}" "$RASTER_OUT"
}

raster::video_pct() {
  local skip="${1:-0}"
  if ((skip <= 0)); then
    print -n 10
  elif ((skip * 5 > 95)); then
    print -n 95
  else
    print -n $((skip * 5))
  fi
}

# --- the dispatch -----------------------------------------------------------

# raster::rasterisable <path> — true when raster::for_file would produce
# something, WITHOUT doing the conversion. Callers that route a file
# somewhere (WezTerm's CMD+click deciding viewer-vs-editor) need the answer
# before they commit, and converting a 300-page PDF to find out is not it.
raster::rasterisable() {
  local f="$1" mime
  [[ -n "$f" && -r "$f" ]] || return 1
  case "${f:l}" in
    *.ttf|*.otf|*.woff|*.woff2|*.ttc|*.psd|*.ai|*.eps) return 0 ;;
    *.docx|*.xlsx|*.pptx|*.doc|*.xls|*.ppt|*.odt|*.ods|*.odp) return 0 ;;
    *.pages|*.numbers|*.key) return 0 ;;
  esac
  mime=$(file --mime-type --brief --dereference "$f" 2>/dev/null)
  case "$mime" in
    image/*|video/*|audio/*|application/pdf) return 0 ;;
    font/*|application/vnd.ms-opentype|application/postscript) return 0 ;;
    application/vnd.openxmlformats-officedocument.*|application/msword) return 0 ;;
    application/vnd.ms-excel|application/vnd.ms-powerpoint) return 0 ;;
    application/vnd.oasis.opendocument.*|application/vnd.apple.*) return 0 ;;
  esac
  return 1
}

# raster::for_file <path> [variant] — the one call a consumer needs. Prints
# the path of a cached PNG; non-zero when nothing here can rasterise it (text,
# archives, binaries — the caller's own business).
#
# <variant> is the page/seek selector: a PDF page offset or a video seek step.
# It keys the cache, so page 3 and page 1 are separate entries.
#
# Extension beats MIME for the formats where `file` is unhelpful (office
# containers all look like zip; fonts and Adobe files vary by build).
raster::for_file() {
  local target="$1" variant="${2:-0}" mime
  [[ -n "$target" && -r "$target" ]] || return 1
  mime=$(file --mime-type --brief --dereference "$target" 2>/dev/null)
  case "${target:l}" in
    *.ttf | *.otf | *.woff | *.woff2 | *.ttc) mime="font/generic" ;;
    *.psd | *.ai | *.eps) mime="image/vnd.adobe.photoshop" ;;
    *.docx | *.xlsx | *.pptx | *.doc | *.xls | *.ppt | *.odt | *.ods | *.odp)
      mime="application/msword" ;;
    *.pages) mime="application/vnd.apple.pages" ;;
    *.numbers) mime="application/vnd.apple.numbers" ;;
    *.key) mime="application/vnd.apple.keynote" ;;
  esac
  raster::by_mime "$target" "$mime" "$variant"
}

# raster::by_mime <path> <mime> [variant] — the dispatch itself, for callers
# that already know the type (preview's --pixels path resolves it once and
# reuses it for its metadata decision).
raster::by_mime() {
  local target="$1" mime="$2" variant="${3:-0}"

  local cache
  case "$mime" in
    image/png | image/jpeg | image/gif | image/webp | image/bmp | image/tiff)
      print -rn -- "$target"
      ;;
    image/vnd.adobe.photoshop | application/postscript)
      cache=$(raster::cache_path "$target" adobe) &&
        raster::cached "$cache" raster::adobe "$target" &&
        print -rn -- "$cache"
      ;;
    image/*)
      cache=$(raster::cache_path "$target" imgconv) &&
        raster::cached "$cache" raster::convert "$target" &&
        print -rn -- "$cache"
      ;;
    video/*)
      local pct
      pct=$(raster::video_pct "$variant")
      cache=$(raster::cache_path "$target" video "$pct") &&
        raster::cached "$cache" raster::video_frame "$target" "$pct" &&
        print -rn -- "$cache"
      ;;
    audio/*)
      cache=$(raster::cache_path "$target" cover) &&
        raster::cached "$cache" raster::audio_cover "$target" &&
        print -rn -- "$cache"
      ;;
    application/pdf)
      local page
      page=$(raster::pdf_page_no "$target" "$variant")
      cache=$(raster::cache_path "$target" pdf-fit "$page") &&
        raster::cached "$cache" raster::pdf_page "$target" "$page" &&
        print -rn -- "$cache"
      ;;
    font/* | application/vnd.ms-opentype)
      cache=$(raster::cache_path "$target" font-grid5) &&
        raster::cached "$cache" raster::font_sheet "$target" &&
        print -rn -- "$cache"
      ;;
    application/vnd.openxmlformats-officedocument.* | application/msword | \
      application/vnd.ms-excel | application/vnd.ms-powerpoint | \
      application/vnd.oasis.opendocument.*)
      cache=$(raster::cache_path "$target" office) &&
        raster::cached "$cache" raster::office "$target" &&
        print -rn -- "$cache"
      ;;
    application/vnd.apple.pages | application/vnd.apple.numbers | \
      application/vnd.apple.keynote)
      cache=$(raster::cache_path "$target" iwork) &&
        raster::cached "$cache" raster::iwork "$target" &&
        print -rn -- "$cache"
      ;;
  esac
  return 0
}
