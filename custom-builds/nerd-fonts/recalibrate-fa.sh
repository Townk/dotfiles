#!/usr/bin/env bash
# ===========================================================================
# recalibrate-fa.sh — re-bake the icon sizing, fast (no patcher rerun).
# ===========================================================================
# build-updated-font.sh step 7b normalizes every Font Awesome glyph (native +
# relocated) and every custom SVG icon to the curated md/oct box, so they
# render at one consistent size with no cell bleed. The fill fraction is mostly
# a matter of taste, so this script lets you re-bake it without re-running the
# (slow) patcher: it restores the pristine, pre-7b TTFs stashed under
# build/work/prescale, re-normalizes, and (optionally) installs the result.
#
# Usage:
#   ./recalibrate-fa.sh <fill> [dy_em] [custom_dy_em] [-i|--install]
#   ./recalibrate-fa.sh 1.0 0.0 0.04 --install  # lift custom icons +0.04em
#   ./recalibrate-fa.sh 0.95 --install          # inset to 95% of md/oct
#
# <fill> multiplies the measured md/oct box (1.0 = match md/oct; ≈0.83em in
# Propo). [dy_em] nudges ALL icons vertically (em, +=up) off the md/oct centre;
# [custom_dy_em] nudges the custom SVG icons only, on top of dy_em (they read
# optically low at the bbox centre). Once you settle on values, set them as
# ICON_FILL / ICON_DY / CUSTOM_DY defaults in build-updated-font.sh so a full
# rebuild reproduces them.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_ROOT="${WORK_ROOT:-${SCRIPT_DIR}/build}"
OUT_DIR="${WORK_ROOT}/output"
WORK_DIR="${WORK_ROOT}/work"
REPO_DIR="${WORK_ROOT}/nerd-fonts"
PRESCALE_DIR="${WORK_DIR}/prescale"
FA_MAP="${WORK_DIR}/fa-map.json"
SCALE_PY="${WORK_DIR}/_scale_fa.py"
PY_VENV_BIN="${WORK_ROOT}/.venv/bin/python"

ICON_FILL=""
ICON_DY="${ICON_DY:-0.0}"
CUSTOM_DY="${CUSTOM_DY:-0.0}"
_pos=0
INSTALL=0
# Positional: 1st non-flag = fill, 2nd = dy_em, 3rd = custom_dy_em.
for a in "$@"; do
  case "$a" in
    -i|--install) INSTALL=1 ;;
    *)
      case "${_pos}" in
        0) ICON_FILL="$a" ;;
        1) ICON_DY="$a" ;;
        2) CUSTOM_DY="$a" ;;
      esac
      _pos=$((_pos + 1))
      ;;
  esac
done

die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[[ -n "${ICON_FILL}" ]] \
  || die "usage: $(basename "$0") <fill> [dy_em] [--install]   (e.g. 1.0 0.0 -i)"
[[ -x "${PY_VENV_BIN}" ]] || die "venv python missing (${PY_VENV_BIN}); run build-updated-font.sh first."
[[ -f "${FA_MAP}" ]]      || die "fa-map.json missing (${FA_MAP}); run build-updated-font.sh first."
[[ -d "${REPO_DIR}" ]]    || die "nerd-fonts checkout missing (${REPO_DIR}); run build-updated-font.sh first."
[[ -d "${PRESCALE_DIR}" ]] || die "prescale stash missing (${PRESCALE_DIR}); run build-updated-font.sh first."
[[ -f "${SCALE_PY}" ]]   || die "_scale_fa.py missing (${SCALE_PY}); run build-updated-font.sh first."

shopt -s nullglob
PRISTINE=( "${PRESCALE_DIR}"/Symbols*.ttf )
[[ ${#PRISTINE[@]} -ge 1 ]] || die "no pristine TTFs in ${PRESCALE_DIR}"

# Restore pre-7b TTFs into the output dir, then bake the new normalization.
BUILT=()
for p in "${PRISTINE[@]}"; do
  dest="${OUT_DIR}/$(basename "$p")"
  cp -f "$p" "$dest"
  BUILT+=( "$dest" )
done

printf '\033[34m==\033[0m restoring pristine TTFs and normalizing to md/oct box (fill x%s dy=%sem custom_dy=%sem)\n' \
  "${ICON_FILL}" "${ICON_DY}" "${CUSTOM_DY}"
"${PY_VENV_BIN}" "${SCALE_PY}" "${FA_MAP}" "${REPO_DIR}" "${ICON_FILL}" "${ICON_DY}" "${CUSTOM_DY}" "${BUILT[@]}"

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
