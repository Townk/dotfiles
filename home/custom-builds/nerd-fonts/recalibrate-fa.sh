#!/usr/bin/env bash
# ===========================================================================
# recalibrate-fa.sh — re-bake the relocated Font Awesome upscale, fast.
# ===========================================================================
# The relocated FA icons and the local custom SVG icons (both Plane-16 PUA)
# are not sized by Ghostty's Nerd-Font icon constraint, so build-updated-font.sh
# bakes a uniform upscale into them (FA_RELOCATED_SCALE, step 7b). The right
# value is perceptual and depends on your primary font / line-height, so you
# usually need to eyeball it once.
#
# This script re-applies any scale WITHOUT re-running the (slow) patcher: it
# restores the pristine, native-size TTFs that step 7b stashed under
# build/work/prescale, scales ONLY the relocated + custom glyphs (driven by
# fa-map.json), and (optionally) installs the result into your user font dir.
#
# Usage:
#   ./recalibrate-fa.sh <scale> [dy_em] [-i|--install]
#   ./recalibrate-fa.sh 1.25 0.18 --install   # x1.25, lift 0.18em, install
#   ./recalibrate-fa.sh 1.30 --install        # x1.30, keep current dy default
#
# <scale> upscales the relocated icons; [dy_em] lifts them (em, +=up) to match
# Ghostty's vertical centering. Once you settle on values, set them as the
# defaults in build-updated-font.sh (FA_RELOCATED_SCALE / FA_RELOCATED_DY) so
# a full rebuild reproduces them.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_ROOT="${WORK_ROOT:-${SCRIPT_DIR}/build}"
OUT_DIR="${WORK_ROOT}/output"
WORK_DIR="${WORK_ROOT}/work"
PRESCALE_DIR="${WORK_DIR}/prescale"
FA_MAP="${WORK_DIR}/fa-map.json"
SCALE_PY="${WORK_DIR}/_scale_fa.py"
PY_VENV_BIN="${WORK_ROOT}/.venv/bin/python"

FA_SCALE="${FA_SCALE:-1.0}"
RELOC_SCALE=""
RELOC_DY="${FA_RELOCATED_DY:-0.22}"
INSTALL=0
# Positional: first non-flag arg is scale, second (if numeric) is dy_em.
for a in "$@"; do
  case "$a" in
    -i|--install) INSTALL=1 ;;
    *)
      if [[ -z "${RELOC_SCALE}" ]]; then RELOC_SCALE="$a"
      else RELOC_DY="$a"; fi
      ;;
  esac
done

die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[[ -n "${RELOC_SCALE}" ]] \
  || die "usage: $(basename "$0") <scale> [dy_em] [--install]   (e.g. 1.25 0.18 -i)"
[[ -x "${PY_VENV_BIN}" ]] || die "venv python missing (${PY_VENV_BIN}); run build-updated-font.sh first."
[[ -f "${FA_MAP}" ]]      || die "fa-map.json missing (${FA_MAP}); run build-updated-font.sh first."
[[ -d "${PRESCALE_DIR}" ]] || die "prescale stash missing (${PRESCALE_DIR}); run build-updated-font.sh first."
[[ -f "${SCALE_PY}" ]]   || die "_scale_fa.py missing (${SCALE_PY}); run build-updated-font.sh first."

shopt -s nullglob
PRISTINE=( "${PRESCALE_DIR}"/Symbols*.ttf )
[[ ${#PRISTINE[@]} -ge 1 ]] || die "no pristine TTFs in ${PRESCALE_DIR}"

# Restore native-size TTFs into the output dir, then bake the new transform.
BUILT=()
for p in "${PRISTINE[@]}"; do
  dest="${OUT_DIR}/$(basename "$p")"
  cp -f "$p" "$dest"
  BUILT+=( "$dest" )
done

printf '\033[34m==\033[0m restoring pristine TTFs and baking relocated x%s dy=%sem (native x%s)\n' \
  "${RELOC_SCALE}" "${RELOC_DY}" "${FA_SCALE}"
"${PY_VENV_BIN}" "${SCALE_PY}" "${FA_MAP}" "${FA_SCALE}" "${RELOC_SCALE}" "${RELOC_DY}" "${BUILT[@]}"

if [[ "${INSTALL}" == "1" ]]; then
  case "$(uname -s)" in
    Darwin) USER_FONT_DIR="${HOME}/Library/Fonts" ;;
    Linux)  USER_FONT_DIR="${HOME}/.local/share/fonts" ;;
    *)      USER_FONT_DIR="" ;;
  esac
  [[ -n "${USER_FONT_DIR}" ]] || die "unknown OS; copy ${OUT_DIR}/Symbols*.ttf manually."
  mkdir -p "${USER_FONT_DIR}"
  for f in "${BUILT[@]}"; do cp -f "$f" "${USER_FONT_DIR}/"; done
  if [[ "$(uname -s)" == "Linux" ]] && command -v fc-cache >/dev/null 2>&1; then
    fc-cache -f "${USER_FONT_DIR}" >/dev/null 2>&1 || true
  fi
  printf '\033[32m==\033[0m installed -> %s  (restart the terminal to pick it up)\n' "${USER_FONT_DIR}"
else
  printf '\033[34m==\033[0m wrote -> %s  (pass --install to copy into your font dir)\n' "${OUT_DIR}"
fi
