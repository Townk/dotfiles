#!/usr/bin/env bash
# verify-sixel.sh — D1 gate: live-render a sixel image inside tmux.
#
# tmux exposes NO runtime flag reporting sixel support (tmux/tmux#4177), so the
# only reliable probe is drawing sixels and looking at them. Run INSIDE a tmux
# session hosted by a sixel-capable terminal (WezTerm):
#
#   tmux new -A -s sixel-check
#   ~/.local/share/chezmoi/custom-builds/tmux/verify-sixel.sh [image]
#
# With an optional [image] argument and chafa on PATH, it additionally renders
# that image via `chafa -f sixel` (closer to what preview/yazi emit).
#
# PASS: six solid color bars (and the image). FAIL: raw escape garbage or
# nothing → the tmux build lacks sixel; add custom-builds/tmux/ with
# --enable-sixel per the migration spec (D1/R1).
set -euo pipefail

if [ -z "${TMUX:-}" ]; then
  echo "verify-sixel: run this inside a tmux session (tmux new -A -s sixel-check)." >&2
  exit 2
fi

# Six-band color-bar test pattern, pure DCS — zero image-tool dependencies.
# Sixel grammar: "#i;2;R;G;B" defines color i (RGB 0-100); "#i!N~" repeats a
# full 6-pixel column N times; "-" starts the next 6-pixel band.
printf '\033Pq'
printf '#0;2;96;88;86#1;2;98;70;53#2;2;98;89;69#3;2;65;89;63#4;2;54;71;98#5;2;80;65;97'
for _ in 1 2 3 4 5 6 7 8; do
  printf '#0!40~#1!40~#2!40~#3!40~#4!40~#5!40~-'
done
printf '\033\\'
printf '\n'

if [ $# -ge 1 ] && command -v chafa >/dev/null 2>&1; then
  chafa -f sixel --size 60x20 "$1"
fi

echo "Six solid color bars above  = sixel PASS (D1 gate met — no custom build)."
echo "Garbage / blank             = FAIL → custom-builds/tmux/ --enable-sixel (D1/R1)."
