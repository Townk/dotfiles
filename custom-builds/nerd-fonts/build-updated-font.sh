#!/usr/bin/env bash
# =============================================================================
# build-updated-font.sh
#
# Self-contained builder for "Symbols Nerd Font" (Mono + Propo) with the
# latest Font Awesome glyphs merged in via the patcher's --custom hook.
#
# Designed so you can drop *just this file* somewhere safe (~/bin/, a USB
# stick, a gist), come back 12 months later, run it, and walk away with two
# usable TTF files in ./symbols-nerd-font-build/output/.
#
# The fontTools post-patch steps (donor import, emoji strip, icon sizing, cell
# bleed, glyphs.json, verification, Blink emoji split) and the FontForge merge
# live as importable modules under the sibling `fontbuild/` package, run via
# `python -m fontbuild <subcommand>` (and `fontforge -script` for the merge).
#
# What it does, in order:
#   1. Locate (or `git clone`) the upstream ryanoasis/nerd-fonts repo.
#   2. Locate (or `curl`) the latest Font Awesome Free *desktop* archive.
#   3. Make sure FontForge is installed (auto-`brew install` if missing).
#   4. Make sure a Python venv with `fonttools` exists (asks first).
#   5. Merge FA's three OTFs (Brands/Regular/Solid) into one via FontForge,
#      then RELOCATE any free FA icon whose native codepoint collides with
#      a curated Nerd Fonts glyph (the patcher's careful mode would drop
#      those ~1000 icons) to a reserved Plane-16 PUA block, so all free FA
#      icons survive. Emits a native->relocated map (fa-map.json).
#   6. Run `font-patcher` twice against the empty Symbols-Only SFD to produce
#      the Mono and Propo variants of "Symbols Nerd Font", with the merged
#      FA file layered in via --custom (additive, careful: it never replaces
#      curated NF glyphs).
#   6b-7c. One fontTools pass per built font (fontbuild pipeline): import a
#      tiny allowlist of real Unicode keyboard/symbol glyphs from OFL-licensed
#      donor fonts; strip the colour-emoji domain from the cmap so terminal
#      lookups for ♻ ✏ 🚀 fall through to the system colour-emoji font; stash a
#      pristine pre-scale copy (for recalibrate-fa.sh); normalize every FA +
#      custom icon to the curated md/oct box (renderer-agnostic sizing); and
#      bleed block/legacy glyphs past the cell edges (embedded JBM only).
#   8. Use `fonttools` to verify the result and print a glyph-count diff
#      against the upstream-shipped TTFs in patched-fonts/NerdFontsSymbolsOnly.
#   9. Emit a glyphs.json index of every codepoint in the built font, with
#      Nerd-Fonts curated names (prefixed `nf-`), FA 7 names (prefixed `fa-`)
#      and natural-language metadata
#      (labels, search terms, aliases, Unicode names). Written to
#      ~/.local/share/fonts/nerd-font/glyphs.json — handy for an fzf picker.
#   6c. Patch JetBrains Mono Regular ITSELF with the same merged-FA payload
#      (single-cell) to produce a fully-embedded "JetBrainsMono Nerd Font Mono"
#      — text + every icon in one self-contained TTF, for Blink Shell. It goes
#      through the 6b-7c pipeline like the Symbols Mono font and is installed too.
#  10. Emit ONE self-contained Blink Shell CSS file to assets/blink-shell/:
#      jetbrains-mono-nerd-font-custom.css — the embedded JetBrains Mono Nerd Font as
#      the catch-all face, an iPad system-font fallback chain (local() +
#      unicode-range, mirroring the WezTerm font_with_fallback config), and
#      embedded Noto OT-SVG colour emoji (WOFF2) for emoji — split into two faces
#      by hterm's terminal width so each emoji fills its reserved cell(s). Serve
#      it for import with assets/blink-shell/serve-blink-assets.sh.
#  11. Print the caveats below so you remember them next year.
#
# Overrides (export before running, or pass as `KEY=val ./build-updated-font.sh`):
#   WORK_ROOT        Where to put the cloned repo + outputs.
#                    Default: <script-dir>/build  (so the work tree lives
#                    next to this script regardless of cwd).
#   FA_SRC_DIR       Directory containing the 3 FA *.otf files (Brands,
#                    Regular, Solid). If unset, the script auto-detects
#                    in this order (highest version wins within each step):
#                      1. The Homebrew cask `font-fontawesome` Caskroom dir
#                         (e.g. /opt/homebrew/Caskroom/font-fontawesome/
#                         <ver>/fontawesome-free-<ver>-desktop/otfs/).
#                      2. ~/Downloads/fontawesome-free-*-desktop/otfs/
#                      3. The script's own download cache under WORK_ROOT.
#                      4. Falling back to downloading the latest FA Free
#                         release from github.com/FortAwesome/Font-Awesome.
#   NERDFONTS_REF    Git ref to check out from ryanoasis/nerd-fonts.
#                    Default: master  (use a tag like "v3.4.0" for repro).
#   ASSUME_YES=1     Skip all confirmation prompts (or pass -y).
#   INSTALL=1        Copy the built TTFs into the user font dir at the end
#                    (~/Library/Fonts on macOS, ~/.local/share/fonts on
#                    Linux + fc-cache). Equivalent to passing --install.
#   JSON_OUT_DIR     Where glyphs.json should land.
#                    Default: ~/.local/share/fonts/nerd-font
#                    Pass JSON_OUT_DIR="" to skip the JSON step entirely.
#   BLINK_OUT_DIR    Where the self-contained Blink Shell CSS file lands
#                    (jetbrains-mono-nerd-font-custom.css). It embeds the
#                    fully-patched JetBrains Mono Nerd Font and references iPad
#                    system fonts by name for fallback.
#                    Default: <repo>/assets/blink-shell
#                    Pass BLINK_OUT_DIR="" to skip the CSS step entirely.
#                    Serve it for Blink import with
#                    assets/blink-shell/serve-blink-assets.sh.
#   JETBRAINS_TTF    JetBrains Mono Regular TTF that is patched into the embedded
#                    Blink font AND embedded as its text face. Default:
#                    auto-detect (~/Library/Fonts -> /Library/Fonts -> brew
#                    Caskroom font-jetbrains-mono -> ~/.local/share/fonts).
#                    Override to pin a specific file/weight. If unfound, the
#                    embedded JBM build and the Blink CSS are both skipped.
#   ICON_FILL        Multiplier on the measured curated md/oct box that every
#                    FA + custom icon is normalized to in step 7b. Default: 1.05
#                    (≈0.87em in the Propo variant). 1.0 matches md/oct exactly.
#                    Lower insets the icons; higher fills more of the cell.
#                    Tunable — recalibrate fast with
#                    ./recalibrate-fa.sh <fill> [dy] -i.
#   ICON_DY          Extra vertical nudge (em, +=up) on top of the measured
#                    md/oct centre, for ALL icons, in step 7b. Default: 0.0.
#   CUSTOM_DY        Extra vertical nudge (em, +=up) for the custom SVG icons
#                    ONLY, on top of ICON_DY. Brand logos read optically low at
#                    the bbox centre; lift just them. Default: 0.07. Tunable
#                    with ./recalibrate-fa.sh <fill> [dy] [custom_dy] -i.
#   CUSTOM_ICON_DIR  Directory of local *.svg icons to bake into Plane-16 PUA
#                    glyphs at CUSTOM_START+. The filename (minus .svg) becomes
#                    the glyphs.json key `usr-<name>` (cursor-ai.svg ->
#                    usr-cursor-ai). Default: <script-dir>/custom-icons.
#                    Set CUSTOM_ICON_DIR="" to skip. An optional
#                    <dir>/metadata.json supplies per-icon keywords/
#                    shortcode/aliases/description for glyphs.json (the custom-icon analogue of FA's
#                    icons.json) AND an optional "code" hex codepoint to PIN an
#                    icon to a fixed slot; missing entries fall back to the file
#                    name and auto-assignment.
#   CUSTOM_START     First auto-assigned codepoint of the custom-icon block
#                    (hex). Default: 10fb00 — above the relocation zone, whose
#                    icons now use the stable slot native+0x100000 (<=0x10f8ff).
#   DONOR_GLYPH_FILE Allowlist of Unicode codepoints to copy from donor fonts.
#                    Default: <script-dir>/unicode-donor-glyphs.txt
#                    Set DONOR_GLYPH_FILE="" to skip.
#   DONOR_FONT_FAMILIES
#                    Comma-separated donor family preference order.
#                    Default: STIX Two Math,Noto Music,Noto Sans Symbols 2,
#                    Noto Sans Math,Iosevka
#   DONOR_FONT_PATHS Optional colon-separated explicit donor font files. Useful
#                    for temporary build-only fonts that are not installed.
#   DONOR_INSTALL    Install missing donor casks for the build, then uninstall
#                    only those this script installed. Default: 1.
#
# Conflict with Homebrew cask `font-symbols-only-nerd-font`:
#   That cask installs the upstream-shipped variants under the same filenames
#   into ~/Library/Fonts. If both are present, macOS will pick whichever was
#   written last and a future `brew upgrade` will overwrite this script's
#   output without warning. To avoid that:
#     1. Remove the cask from your Brewfile (chezmoi source if applicable).
#     2. brew uninstall --cask font-symbols-only-nerd-font
#     3. Re-run this script with --install (or INSTALL=1).
#
# Cleanup (after you're done):
#   brew uninstall fontforge && brew autoremove
#   rm -rf ./symbols-nerd-font-build       # repo clone + venv + outputs
#
# License: MIT (this script). The fonts it builds inherit the upstream
# licenses (Nerd Fonts is MIT, Font Awesome Free is CC-BY-4.0 + SIL OFL 1.1).
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Pretty-printing helpers.
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RED=$'\033[1;31m'; C_GRN=$'\033[1;32m'; C_YLW=$'\033[1;33m'
  C_BLU=$'\033[1;34m'; C_DIM=$'\033[2m';    C_RST=$'\033[0m'
else
  C_RED= C_GRN= C_YLW= C_BLU= C_DIM= C_RST=
fi
log()   { printf '%s[build]%s %s\n'   "${C_BLU}" "${C_RST}" "$*"; }
info()  { printf '%s   ·%s %s\n'       "${C_DIM}" "${C_RST}" "$*"; }
warn()  { printf '%s[warn]%s %s\n'     "${C_YLW}" "${C_RST}" "$*" >&2; }
die()   { printf '%s[fail]%s %s\n'     "${C_RED}" "${C_RST}" "$*" >&2; exit 1; }
done_() { printf '%s[ ok ]%s %s\n'     "${C_GRN}" "${C_RST}" "$*"; }

ASSUME_YES="${ASSUME_YES:-0}"
INSTALL="${INSTALL:-0}"
for arg in "$@"; do
  case "${arg}" in
    -y|--yes)     ASSUME_YES=1 ;;
    --install)    INSTALL=1 ;;
    --no-install) INSTALL=0 ;;
    -h|--help)
      sed -n '1,60p' "$0" | sed -n 's/^# \{0,1\}//p' | head -n 50
      exit 0 ;;
    *) ;;
  esac
done

# ask "<question>"  ->  returns 0 (yes) or 1 (no). Default is yes.
ask() {
  local q="$1"
  if [[ "${ASSUME_YES}" == "1" ]]; then
    info "${q}  [auto-yes via ASSUME_YES]"
    return 0
  fi
  printf '%s[?]%s %s [Y/n] ' "${C_BLU}" "${C_RST}" "${q}"
  local ans
  read -r ans </dev/tty || ans=""
  # NB: macOS still ships bash 3.2 -> no `${ans,,}`. Use tr for portability.
  ans=$(printf '%s' "${ans}" | tr '[:upper:]' '[:lower:]')
  case "${ans}" in n|no) return 1 ;; *) return 0 ;; esac
}

# ---------------------------------------------------------------------------
# Layout.
# ---------------------------------------------------------------------------
SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd -P )"
# Repo root — this script lives in custom-builds/nerd-fonts/. The Blink assets
# (font CSS + committed theme) live under assets/blink-shell/ at the repo root.
REPO_ROOT="$( cd -- "${SCRIPT_DIR}/../.." >/dev/null 2>&1 && pwd -P )"
WORK_ROOT="${WORK_ROOT:-${SCRIPT_DIR}/build}"
NERDFONTS_REF="${NERDFONTS_REF:-master}"
REPO_DIR="${WORK_ROOT}/nerd-fonts"
FA_DIR="${WORK_ROOT}/fontawesome"
OUT_DIR="${WORK_ROOT}/output"
WORK_DIR="${WORK_ROOT}/work"
VENV_DIR="${WORK_ROOT}/.venv"
LOG_FILE="${WORK_DIR}/build.log"
# Where the glyphs.json index lands. Set to "" to skip emission.
JSON_OUT_DIR="${JSON_OUT_DIR-${HOME}/.local/share/fonts/nerd-font}"
# Where the Blink Shell CSS file lands (alongside the committed theme). Set to
# "" to skip emission.
BLINK_OUT_DIR="${BLINK_OUT_DIR-${REPO_ROOT}/assets/blink-shell}"
# JetBrains Mono Regular TTF embedded as the primary face in the Blink CSS.
# Empty -> auto-detect (see emit_blink_css). Override to pin a specific file.
JETBRAINS_TTF="${JETBRAINS_TTF:-}"
# Colour emoji for the Blink CSS. The build embeds Adobe's Noto Color Emoji in
# OT-SVG form (the OpenType 'SVG ' table — gradient-rich VECTOR art). iOS WebKit
# renders OT-SVG (since iOS Safari 12.2) but NOT COLRv1, and unlike Apple's sbix
# bitmap an OT-SVG glyph is resizable. The font is subset to its cmap-reachable
# single-codepoint emoji (dropping ZWJ/skin-tone/flag ligature glyphs) so it
# stays under Safari's ~2000 SVG-document ceiling, then SPLIT by hterm's terminal
# width into two WOFF2 faces (each glyph embedded ONCE): WIDE emoji (hterm
# width-2) fill their reserved 2 cells, the rest fit 1 cell. Noto advances every
# glyph at ~1.245em (2550/2048) and JBM's cell is 0.6em, so 48% ~= one cell and
# 96% ~= two cells. Tune if your terminal cell ratio differs.
EMOJI_NARROW_ADJUST="${EMOJI_NARROW_ADJUST:-48}"   # width-1 emoji -> one cell
EMOJI_WIDE_ADJUST="${EMOJI_WIDE_ADJUST:-96}"       # width-2 emoji -> two cells
# Embedded colour-emoji font. Empty -> download Adobe Noto OT-SVG to
# WORK_ROOT/emoji and cache it. Override NOTO_EMOJI_OTF to pin a local OT-SVG
# font (must carry an OpenType 'SVG ' table), or NOTO_EMOJI_URL to fetch a
# different release. Set NOTO_EMOJI_OTF="" + unreachable URL to skip (emoji then
# fall back to the system colour-emoji font via WebKit's last resort).
NOTO_EMOJI_OTF="${NOTO_EMOJI_OTF:-}"
NOTO_EMOJI_URL="${NOTO_EMOJI_URL:-https://github.com/adobe-fonts/noto-emoji-svg/releases/download/2.100/NotoColorEmoji-SVG.otf}"

# Resolve JetBrains Mono Regular for the embedded Blink font (and the patch
# pass that produces it). Honours an explicit JETBRAINS_TTF, else probes the
# usual install locations (cask -> system -> Linux). Leaves JETBRAINS_TTF empty
# if nothing is found; callers warn and skip the embedded JBM build + CSS.
resolve_jetbrains_ttf() {
  [[ -n "${JETBRAINS_TTF}" && -f "${JETBRAINS_TTF}" ]] && return 0
  local jb_candidates=(
    "${HOME}/Library/Fonts/JetBrainsMono-Regular.ttf"
    "/Library/Fonts/JetBrainsMono-Regular.ttf"
    "${HOME}/.local/share/fonts/JetBrainsMono-Regular.ttf"
  )
  if command -v brew >/dev/null 2>&1; then
    local brew_prefix cask_jb
    brew_prefix=$(brew --prefix 2>/dev/null || true)
    if [[ -n "${brew_prefix}" ]]; then
      cask_jb=$( { \
          ls -1 "${brew_prefix}/Caskroom/font-jetbrains-mono/"*"/fonts/ttf/JetBrainsMono-Regular.ttf" \
                "${brew_prefix}/Caskroom/font-jetbrains-mono/"*"/JetBrainsMono-Regular.ttf" 2>/dev/null \
          || true; } | sort -V | tail -n 1 || true )
      [[ -n "${cask_jb}" ]] && jb_candidates+=("${cask_jb}")
    fi
  fi
  local c
  for c in "${jb_candidates[@]}"; do
    [[ -f "${c}" ]] && { JETBRAINS_TTF="${c}"; return 0; }
  done
  return 0
}

# Resolve the embedded colour-emoji font. Honours an explicit NOTO_EMOJI_OTF,
# else uses the cached download, else fetches NOTO_EMOJI_URL into WORK_ROOT/emoji.
# Leaves NOTO_EMOJI_OTF empty on failure; the CSS then omits the embedded emoji.
resolve_noto_emoji() {
  [[ -n "${NOTO_EMOJI_OTF}" && -f "${NOTO_EMOJI_OTF}" ]] && return 0
  local cache="${WORK_ROOT}/emoji/NotoColorEmoji-SVG.otf"
  if [[ -f "${cache}" ]]; then NOTO_EMOJI_OTF="${cache}"; return 0; fi
  if ! command -v curl >/dev/null 2>&1; then
    warn "curl not found; cannot fetch Noto OT-SVG colour-emoji font."; return 1
  fi
  mkdir -p "$(dirname "${cache}")"
  info "downloading Noto OT-SVG colour-emoji font ..."
  if curl -fL --progress-bar -o "${cache}" "${NOTO_EMOJI_URL}"; then
    NOTO_EMOJI_OTF="${cache}"; info "Noto OT-SVG -> ${cache}"; return 0
  fi
  warn "Noto download failed (${NOTO_EMOJI_URL}); emoji fall back to the system font."
  rm -f "${cache}"; return 1
}

mkdir -p "${WORK_ROOT}" "${WORK_DIR}" "${OUT_DIR}"

log "Workspace : ${WORK_ROOT}"
log "Nerd Fonts: ${REPO_DIR}  (ref=${NERDFONTS_REF})"
log "Output    : ${OUT_DIR}"

# ===========================================================================
# Step 1 — Locate / clone the nerd-fonts repo.
# ===========================================================================
log "step 1/10  resolve nerd-fonts source"

# If we are *already* sitting in a nerd-fonts clone, prefer that.
if [[ -x "${SCRIPT_DIR}/font-patcher" && -d "${SCRIPT_DIR}/src/glyphs" ]]; then
  REPO_DIR="${SCRIPT_DIR}"
  info "running from inside a nerd-fonts clone -> using ${REPO_DIR}"
elif [[ -x "${REPO_DIR}/font-patcher" && -d "${REPO_DIR}/src/glyphs" ]]; then
  info "existing clone found -> ${REPO_DIR}"
  if ask "Update existing clone to latest of '${NERDFONTS_REF}'? (n = use as-is)"; then
    # NB: stay shallow. `git pull --ff-only` against a depth=1 clone tries to
    # backfill the whole history and stalls on large repos like nerd-fonts.
    # `git fetch --depth=1` + `git reset --hard FETCH_HEAD` is the safe pattern.
    ( cd "${REPO_DIR}" && \
        git fetch --depth=1 --quiet origin "${NERDFONTS_REF}" </dev/null && \
        git reset --hard --quiet FETCH_HEAD </dev/null \
    ) || warn "could not update to ${NERDFONTS_REF}; using current state."
  fi
else
  if ! ask "Clone ryanoasis/nerd-fonts (~150 MB) into ${REPO_DIR}?"; then
    die "Need the nerd-fonts repo to proceed."
  fi
  command -v git >/dev/null 2>&1 || die "git not found on PATH."
  git clone --depth 1 --branch "${NERDFONTS_REF}" \
    https://github.com/ryanoasis/nerd-fonts.git "${REPO_DIR}" </dev/null \
    || die "git clone failed."
fi

PATCHER="${REPO_DIR}/font-patcher"
BLANK_SFD="${REPO_DIR}/src/unpatched-fonts/NerdFontsSymbolsOnly/NerdFontsSymbolsNerdFontBlank.sfd"
[[ -x "${PATCHER}"   ]] || die "font-patcher not executable at ${PATCHER}"
[[ -f "${BLANK_SFD}" ]] || die "blank SFD missing at ${BLANK_SFD}"
done_ "nerd-fonts ready"

# ===========================================================================
# Step 2 — Locate / fetch Font Awesome.
# ===========================================================================
log "step 2/10  resolve Font Awesome assets"

resolve_fa() {
  if [[ -n "${FA_SRC_DIR:-}" ]]; then
    [[ -d "${FA_SRC_DIR}" ]] || die "FA_SRC_DIR='${FA_SRC_DIR}' does not exist."
    info "using FA_SRC_DIR='${FA_SRC_DIR}'"
    return 0
  fi

  # ---- Priority 1: Homebrew cask `font-fontawesome` ----
  # The cask is the user's canonical, version-managed source. Prefer it over
  # ad-hoc Downloads when present so re-runs track whatever brew has synced.
  if command -v brew >/dev/null 2>&1; then
    local brew_prefix
    brew_prefix=$(brew --prefix 2>/dev/null || true)
    if [[ -n "${brew_prefix}" ]]; then
      local cask_candidate
      cask_candidate=$( { \
          ls -1d "${brew_prefix}/Caskroom/font-fontawesome/"*"/fontawesome-free-"*"-desktop/otfs" 2>/dev/null || true; \
        } | sort -V | tail -n 1 || true )
      if [[ -n "${cask_candidate}" && -d "${cask_candidate}" ]]; then
        FA_SRC_DIR="${cask_candidate}"
        local cask_version
        cask_version=$(printf '%s' "${cask_candidate}" \
          | sed -E 's|.*/Caskroom/font-fontawesome/([^/]+)/.*|\1|')
        info "using Homebrew cask 'font-fontawesome' v${cask_version}"
        info "  ${FA_SRC_DIR}"
        return 0
      fi
    fi
  fi

  # ---- Priority 2/3: Downloads or our own cache ----
  # We swallow non-zero exits from `ls` on empty globs (they would
  # otherwise trip pipefail / set -e).
  local candidate
  candidate=$( { \
      ls -1d "${HOME}/Downloads/fontawesome-free-"*"-desktop/otfs" 2>/dev/null || true; \
      ls -1d "${WORK_ROOT}/fontawesome-free-"*"-desktop/otfs"      2>/dev/null || true; \
      ls -1d "${FA_DIR}/fontawesome-free-"*"-desktop/otfs"          2>/dev/null || true; \
    } | sort -V | tail -n 1 || true )
  if [[ -n "${candidate}" && -d "${candidate}" ]]; then
    FA_SRC_DIR="${candidate}"
    info "auto-detected FA otfs at ${FA_SRC_DIR}"
    return 0
  fi
  # Fall back to downloading the latest Font Awesome Free desktop release.
  if ! ask "No Font Awesome found locally. Download the latest FA Free desktop archive?"; then
    die "Font Awesome assets required."
  fi
  command -v curl  >/dev/null 2>&1 || die "curl not found on PATH."
  command -v unzip >/dev/null 2>&1 || die "unzip not found on PATH."

  mkdir -p "${FA_DIR}"
  log "querying GitHub for latest FA release..."
  local api_url="https://api.github.com/repos/FortAwesome/Font-Awesome/releases/latest"
  local zip_url
  zip_url=$(curl -fsSL "${api_url}" \
    | grep -Eo '"browser_download_url"[^"]*"[^"]*fontawesome-free-[0-9.]+-desktop\.zip"' \
    | head -n1 \
    | sed -E 's/.*"(https:[^"]+)"$/\1/')
  [[ -n "${zip_url}" ]] || die "could not find latest FA desktop zip in GitHub API response."
  local zip_path="${FA_DIR}/$(basename "${zip_url}")"
  log "downloading ${zip_url}"
  curl -fL --progress-bar -o "${zip_path}" "${zip_url}" \
    || die "FA download failed."
  log "unzipping..."
  ( cd "${FA_DIR}" && unzip -q -o "${zip_path}" ) || die "FA unzip failed."
  FA_SRC_DIR=$(ls -1d "${FA_DIR}/fontawesome-free-"*"-desktop/otfs" | sort -V | tail -n1)
  [[ -d "${FA_SRC_DIR}" ]] || die "FA otfs dir not found after unzip."
  info "FA extracted to ${FA_SRC_DIR}"
}
resolve_fa
done_ "Font Awesome ready"

# ===========================================================================
# Step 3 — Ensure FontForge.
# ===========================================================================
log "step 3/10  ensure FontForge"

FONTFORGE_BIN="$( command -v fontforge || true )"
if [[ -z "${FONTFORGE_BIN}" ]]; then
  if ! command -v brew >/dev/null 2>&1; then
    die "FontForge not installed and Homebrew is unavailable. Install FontForge manually and re-run."
  fi
  cat <<'NOTE'

FontForge is required (its Python C-extension is bundled inside the
binary; it is NOT installable via pip/uv/mise — there is no plugin).
The cheapest path on macOS is Homebrew. Pulls in ~80 MB total.

NOTE
  # FontForge is a build-only dependency (see caveat 4 — not in the Brewfile,
  # swept on the next brew sync). Install it without prompting, the same way
  # the temporary donor casks below install automatically.
  info "installing FontForge via Homebrew (temporary build dependency)"
  brew install fontforge || die "brew install fontforge failed."
  FONTFORGE_BIN="$( command -v fontforge )"
fi
info "$( "${FONTFORGE_BIN}" --version 2>&1 | head -n1 )"
done_ "FontForge ready: ${FONTFORGE_BIN}"

# ===========================================================================
# Step 4 — Python venv with fonttools (for verification).
# ===========================================================================
log "step 4/10  python venv with fonttools"

PY_VENV_BIN="${VENV_DIR}/bin/python"
# fonttools = verification + subsetting; lxml = subset the OT-SVG 'SVG ' table;
# brotli = save the emoji subset as WOFF2.
PY_PKGS=("fonttools>=4.55.0" lxml brotli)
if [[ ! -x "${PY_VENV_BIN}" ]]; then
  if ! ask "Create a Python venv with 'fonttools' for verification at ${VENV_DIR}?"; then
    warn "skipping fonttools verification."
    PY_VENV_BIN=""
  else
    if command -v uv >/dev/null 2>&1; then
      info "using uv to provision the venv"
      uv venv --quiet "${VENV_DIR}"
    else
      info "using stdlib venv + pip"
      command -v python3 >/dev/null 2>&1 || die "python3 not found on PATH."
      python3 -m venv "${VENV_DIR}"
      "${PY_VENV_BIN}" -m pip install --quiet --upgrade pip
    fi
  fi
fi
# Ensure deps are present (idempotent) even when reusing an existing venv, so an
# older venv without lxml/brotli still gains OT-SVG + WOFF2 support.
if [[ -n "${PY_VENV_BIN}" && -x "${PY_VENV_BIN}" ]]; then
  if command -v uv >/dev/null 2>&1; then
    uv pip install --quiet --python "${PY_VENV_BIN}" "${PY_PKGS[@]}"
  else
    "${PY_VENV_BIN}" -m pip install --quiet "${PY_PKGS[@]}"
  fi
fi
[[ -n "${PY_VENV_BIN}" && -x "${PY_VENV_BIN}" ]] && \
  done_ "venv ready: $("${PY_VENV_BIN}" --version)" || \
  warn  "no venv (verification step will be skipped)"

# fontbuild package dispatch (fonttools steps). Run from the venv with the
# package's parent dir on PYTHONPATH so `python -m fontbuild` resolves it.
fontbuild() {
  PYTHONPATH="${SCRIPT_DIR}" "${PY_VENV_BIN}" -m fontbuild "$@"
}

# ===========================================================================
# Step 5 — Merge FA's 3 OTFs (Brands/Regular/Solid) into one.
# ===========================================================================
log "step 5/10  merge Font Awesome Brands/Regular/Solid -> single OTF"

FA_MERGED="${WORK_DIR}/FontAwesomeCombined-Regular.otf"
# FontForge merge step. Runs under FontForge's own interpreter (it imports the
# `fontforge` C-extension, which the venv lacks), so it stays a standalone
# script rather than a `python -m fontbuild` subcommand.
MERGER_PY="${SCRIPT_DIR}/fontbuild/_fontforge_merge.py"
# Inputs for the collision-relocation pass (see fontbuild/_fontforge_merge.py):
#   * FA icons.json  -> which codepoints are *free* icons we must keep.
#   * shipped curated TTF -> codepoints already owned by Nerd Fonts.
#   * FA_MAP -> native->relocated map, consumed by the pipeline + glyphs steps.
#   * RESERVED_START -> first codepoint of the Plane-16 PUA landing zone.
FA_MAP="${WORK_DIR}/fa-map.json"
RESERVED_START="100000"
SHIPPED_REGULAR="${REPO_DIR}/patched-fonts/NerdFontsSymbolsOnly/SymbolsNerdFont-Regular.ttf"
FA_ICONS_JSON=""
if [[ -n "${FA_SRC_DIR:-}" && -f "$(dirname "${FA_SRC_DIR}")/metadata/icons.json" ]]; then
  FA_ICONS_JSON="$(dirname "${FA_SRC_DIR}")/metadata/icons.json"
fi
[[ -f "${SHIPPED_REGULAR}" ]] || warn "shipped curated TTF missing (${SHIPPED_REGULAR}); relocation will be a no-op."
[[ -n "${FA_ICONS_JSON}" ]]   || warn "FA icons.json not found; relocation will be a no-op."

# Local custom SVG icons. Every *.svg under CUSTOM_ICON_DIR is imported into a
# Plane-16 PUA glyph and keyed `usr-<filename>` in glyphs.json (e.g.
# cursor-ai.svg -> usr-cursor-ai). Codepoints are STABLE: pin one with a "code"
# field in CUSTOM_ICON_DIR/metadata.json, otherwise it is auto-assigned from
# CUSTOM_START. CUSTOM_START sits above the relocation landing zone — those use
# native+RESERVED_START (=0x100000), i.e. up to ~0x10F8FF for FA's BMP-PUA
# range — so 0x10fb00 leaves the two blocks clear. Override CUSTOM_ICON_DIR=""
# to skip.
CUSTOM_ICON_DIR="${CUSTOM_ICON_DIR-${SCRIPT_DIR}/custom-icons}"
CUSTOM_START="${CUSTOM_START:-10fb00}"
CUSTOM_META=""
if [[ -n "${CUSTOM_ICON_DIR}" && -d "${CUSTOM_ICON_DIR}" ]]; then
  [[ -f "${CUSTOM_ICON_DIR}/metadata.json" ]] && CUSTOM_META="${CUSTOM_ICON_DIR}/metadata.json"
  info "custom SVG icons: ${CUSTOM_ICON_DIR} (auto from U+${CUSTOM_START}; pins via metadata.json)"
else
  CUSTOM_ICON_DIR=""
fi

# usvg normalizes each custom SVG (resolves CSS fills, shapes, clips,
# transforms) before FontForge imports it, so arbitrary source SVGs import
# faithfully. Declared canonically in ~/.config/packages/Cargofile (synced by
# `system-package cargo sync`); installed on-demand here if missing so this
# script stays self-contained. Only needed when there are custom icons; if it
# can't be provided, the import falls back to the raw SVG (with a note).
USVG_BIN="$( command -v usvg || true )"
if [[ -z "${USVG_BIN}" && -n "${CUSTOM_ICON_DIR}" ]]; then
  if command -v cargo >/dev/null 2>&1 && ask "usvg not found; run 'cargo install usvg' to normalize custom SVGs?"; then
    cargo install usvg || warn "cargo install usvg failed; custom SVGs will import raw."
    USVG_BIN="$( command -v usvg || true )"
  else
    warn "usvg unavailable; custom SVGs will import raw (less robust to source quirks)."
  fi
fi
[[ -n "${USVG_BIN}" ]] && info "usvg: ${USVG_BIN}"

"${FONTFORGE_BIN}" -lang=py -script "${MERGER_PY}" \
  "${FA_SRC_DIR}" "${FA_MERGED}" \
  "${FA_ICONS_JSON}" "${SHIPPED_REGULAR}" "${FA_MAP}" "${RESERVED_START}" \
  "${CUSTOM_ICON_DIR}" "${CUSTOM_START}" "${CUSTOM_META}" "${USVG_BIN}" \
  2>&1 | tee "${LOG_FILE}"
[[ -f "${FA_MERGED}" ]] || die "FA merge produced no output."
done_ "merged FA -> ${FA_MERGED}"

# ===========================================================================
# Step 6 — Patch the empty Symbols SFD twice (Mono + Propo).
# ===========================================================================
log "step 6/10  patch Symbols-Only SFD (Mono + Propo variants)"

# run_patcher <label> <input-font> [extra patcher flags...]
# Patches <input-font> with the merged FA payload. <input-font> is the blank
# Symbols SFD for the Symbols-Only variants, or JetBrains Mono Regular for the
# fully-embedded Blink font. --careful never overwrites glyphs the input font
# already has (matters for JBM's own text glyphs).
run_patcher() {
  local label="$1" srcfont="$2"; shift 2
  log "  -> [${label}] $* $(basename "${srcfont}")"
  # Run the patcher, tee its full output to the log, and surface only the
  # notable lines on the console. The grep finding no matches must NOT look like
  # a patcher failure, and a patcher crash MUST be caught — so disable `set -e`
  # around the pipeline and read the patcher's own exit from PIPESTATUS[0]
  # (a trailing `|| true` would clobber PIPESTATUS via the `true`).
  local pstat
  set +e
  ( cd "${REPO_DIR}" && \
    "${FONTFORGE_BIN}" -quiet -script "${PATCHER}" \
      --debug 1 \
      --no-progressbars \
      -c \
      --careful \
      --custom "${FA_MERGED}" \
      --ext ttf \
      --outputdir "${OUT_DIR}" \
      "$@" \
      "${srcfont}" \
  ) 2>&1 | tee -a "${LOG_FILE}" | grep -E '===>|WARNING:|ERROR'
  pstat=("${PIPESTATUS[@]}")
  set -e
  [[ "${pstat[0]}" -eq 0 ]] \
    || die "font-patcher [${label}] failed (exit ${pstat[0]}); see ${LOG_FILE}"
}

# Clear stale output so a failed patch can't leave a previous run's TTFs behind
# (which would pass the count check below and ship a partial build downstream).
rm -f "${OUT_DIR}"/Symbols*.ttf "${OUT_DIR}"/JetBrains*.ttf \
      "${OUT_DIR}"/*.emoji-stripped.txt

run_patcher "Mono"  "${BLANK_SFD}" --single-width-glyphs
run_patcher "Propo" "${BLANK_SFD}" --variable-width-glyphs

BUILT=()
shopt -s nullglob
for f in "${OUT_DIR}"/Symbols*.ttf; do BUILT+=("$f"); done
shopt -u nullglob
[[ ${#BUILT[@]} -ge 2 ]] || die "expected 2 output TTFs in ${OUT_DIR}"

# --- Fully-embedded JetBrains Mono Nerd Font (single-cell) for Blink Shell ---
# Patch JetBrains Mono Regular ITSELF with the same merged-FA payload, so one
# self-contained font carries text + every icon, each added glyph forced into
# JBM's single cell (--single-width-glyphs = "inside the JBM bounding box").
# This is what Blink imports; it removes the need for a CSS-level icon fallback.
# Appended to BUILT so it flows through the same donor-import (6b), emoji-strip
# (7) and icon-sizing (7b) steps as the Symbols Mono font, and is picked up by
# --install. glyphs.json (step 9) stays scoped to Symbols*.ttf, so JBM's text
# glyphs never enter the picker index.
resolve_jetbrains_ttf
JBM_TTF=""
if [[ -n "${JETBRAINS_TTF}" && -f "${JETBRAINS_TTF}" ]]; then
  info "embedding JetBrains Mono: ${JETBRAINS_TTF}"
  run_patcher "JetBrainsMono" "${JETBRAINS_TTF}" --single-width-glyphs
  shopt -s nullglob
  for f in "${OUT_DIR}"/JetBrains*.ttf; do JBM_TTF="$f"; done
  shopt -u nullglob
  if [[ -n "${JBM_TTF}" ]]; then
    BUILT+=("${JBM_TTF}")
  else
    warn "JetBrains Mono patch produced no output; Blink CSS will be skipped."
  fi
else
  warn "JetBrains Mono Regular not found; skipping embedded JBM build + Blink CSS.
   Install the 'font-jetbrains-mono' cask or set JETBRAINS_TTF=/path/to/JetBrainsMono-Regular.ttf"
fi

done_ "built ${#BUILT[@]} variants:"
for f in "${BUILT[@]}"; do
  info "  $(stat -f '%z' "$f" 2>/dev/null || stat -c '%s' "$f") bytes  $(basename "$f")"
done

# ===========================================================================
# Steps 6b-7c — Post-patch per-font pipeline (donor / strip / scale / bleed).
# ===========================================================================
# These four steps each used to load and re-save every built TTF on their own.
# The fontbuild pipeline threads a single in-memory TTFont through all of them
# per font:
#   6b  import a tiny allowlist of real Unicode keyboard/symbol glyphs from
#       OFL-licensed donor fonts (keeps slow broad fonts out of the terminal
#       fallback path);
#   7   strip the colour-emoji domain (U+2600-27BF + U+1F300-1FFFF, minus the
#       explicit donor allowlist and the legacy-computing block) from the cmap
#       so terminal lookups for ♻ ✏ 🚀 fall through to the system colour-emoji
#       font;
#   7b  stash a pristine pre-scale copy (for recalibrate-fa.sh), then normalize
#       every FA + custom icon to the curated md/oct box (renderer-agnostic
#       sizing — WezTerm, unlike Ghostty, does not re-size icons at render time);
#   7c  bleed block + legacy-computing glyphs past the cell edges so they tile
#       without a 1px seam (embedded JBM mono only).
# Each font is parsed once and serialized twice (pre-scale stash + final) rather
# than ~4x, and the donor fonts are resolved once and shared across outputs.
log "step 7/10  post-patch pipeline: donor import, emoji strip, icon sizing, cell bleed"

DONOR_GLYPH_FILE="${DONOR_GLYPH_FILE-${SCRIPT_DIR}/unicode-donor-glyphs.txt}"
DONOR_FONT_FAMILIES="${DONOR_FONT_FAMILIES:-STIX Two Math,Noto Music,Noto Sans Symbols 2,Noto Sans Math,Iosevka}"
DONOR_FONT_PATHS="${DONOR_FONT_PATHS:-}"
DONOR_INSTALL="${DONOR_INSTALL:-1}"
DONOR_TEMP_CASKS=()

donor_family_cask() {
  case "$1" in
    "Iosevka")             printf '%s\n' "font-iosevka" ;;
    "Noto Music")          printf '%s\n' "font-noto-music" ;;
    "Noto Sans Symbols 2") printf '%s\n' "font-noto-sans-symbols-2" ;;
    "Noto Sans Math")      printf '%s\n' "font-noto-sans-math" ;;
    "STIX Two Math")       printf '%s\n' "font-stix-two-math" ;;
    *)                     return 1 ;;
  esac
}

donor_family_has_font_file() {
  case "$1" in
    "Iosevka")
      [[ -f "${HOME}/Library/Fonts/Iosevka.ttc" \
        || -f "/Library/Fonts/Iosevka.ttc" \
        || -f "/opt/homebrew/share/fonts/Iosevka.ttc" \
        || -f "/usr/local/share/fonts/Iosevka.ttc" ]]
      ;;
    "Noto Music")
      [[ -f "${HOME}/Library/Fonts/NotoMusic-Regular.ttf" \
        || -f "/Library/Fonts/NotoMusic-Regular.ttf" \
        || -f "/opt/homebrew/share/fonts/NotoMusic-Regular.ttf" \
        || -f "/usr/local/share/fonts/NotoMusic-Regular.ttf" ]]
      ;;
    "Noto Sans Symbols 2")
      [[ -f "${HOME}/Library/Fonts/NotoSansSymbols2-Regular.ttf" \
        || -f "/Library/Fonts/NotoSansSymbols2-Regular.ttf" \
        || -f "/opt/homebrew/share/fonts/NotoSansSymbols2-Regular.ttf" \
        || -f "/usr/local/share/fonts/NotoSansSymbols2-Regular.ttf" ]]
      ;;
    "Noto Sans Math")
      [[ -f "${HOME}/Library/Fonts/NotoSansMath-Regular.ttf" \
        || -f "/Library/Fonts/NotoSansMath-Regular.ttf" \
        || -f "/opt/homebrew/share/fonts/NotoSansMath-Regular.ttf" \
        || -f "/usr/local/share/fonts/NotoSansMath-Regular.ttf" ]]
      ;;
    "STIX Two Math")
      [[ -f "/System/Library/Fonts/Supplemental/STIXTwoMath.otf" \
        || -f "${HOME}/Library/Fonts/STIXTwoMath-Regular.otf" \
        || -f "/Library/Fonts/STIXTwoMath-Regular.otf" \
        || -f "/opt/homebrew/share/fonts/STIXTwoMath-Regular.otf" \
        || -f "/usr/local/share/fonts/STIXTwoMath-Regular.otf" ]]
      ;;
    *) return 1 ;;
  esac
}

cleanup_donor_casks() {
  local i cask
  if [[ ${#DONOR_TEMP_CASKS[@]} -eq 0 ]]; then
    return 0
  fi
  log "cleanup  uninstall temporary donor font casks"
  for (( i=${#DONOR_TEMP_CASKS[@]}-1; i>=0; i-- )); do
    cask="${DONOR_TEMP_CASKS[$i]}"
    if brew list --cask "$cask" >/dev/null 2>&1; then
      brew uninstall --cask "$cask" >/dev/null 2>&1 \
        && info "uninstalled temporary donor cask: ${cask}" \
        || warn "could not uninstall temporary donor cask: ${cask}"
    fi
  done
}
trap cleanup_donor_casks EXIT

install_donor_casks() {
  if [[ "${DONOR_INSTALL}" != "1" ]]; then
    info "donor cask install disabled (DONOR_INSTALL=${DONOR_INSTALL})"
    return 0
  fi
  if ! command -v brew >/dev/null 2>&1; then
    warn "brew unavailable; cannot install missing donor fonts"
    return 0
  fi

  local family cask old_ifs
  old_ifs="${IFS}"
  IFS=","
  for family in ${DONOR_FONT_FAMILIES}; do
    IFS="${old_ifs}"
    family="$(printf '%s' "$family" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
    [[ -n "$family" ]] || continue
    cask="$(donor_family_cask "$family" || true)"
    [[ -n "$cask" ]] || continue
    if brew list --cask "$cask" >/dev/null 2>&1; then
      info "donor cask already installed: ${cask}"
    elif donor_family_has_font_file "$family"; then
      info "donor font already present outside Homebrew cask: ${family}"
    else
      info "installing temporary donor cask: ${cask}"
      brew install --cask --force "$cask" </dev/null \
        || die "brew install --cask --force ${cask} failed."
      DONOR_TEMP_CASKS+=("$cask")
      info "will uninstall temporary donor cask at exit: ${cask}"
    fi
    IFS=","
  done
  IFS="${old_ifs}"
}

# Resolve / install donor fonts (provisioning), then run the in-memory pipeline.
if [[ -z "${DONOR_GLYPH_FILE}" ]]; then
  info "donor import disabled (DONOR_GLYPH_FILE empty)."
elif [[ ! -f "${DONOR_GLYPH_FILE}" ]]; then
  warn "donor glyph allowlist missing at ${DONOR_GLYPH_FILE}; skipping donor import."
  DONOR_GLYPH_FILE=""
else
  install_donor_casks
fi

# Icon-sizing knobs (step 7b). Tunable without a rebuild via recalibrate-fa.sh;
# once settled, set them here so a clean rebuild reproduces them.
ICON_FILL="${ICON_FILL:-1.05}"
ICON_DY="${ICON_DY:-0.0}"
CUSTOM_DY="${CUSTOM_DY:-0.07}"
PRESCALE_DIR="${WORK_DIR}/prescale"

if [[ -n "${PY_VENV_BIN}" && -x "${PY_VENV_BIN}" && -f "${FA_MAP}" ]]; then
  mkdir -p "${PRESCALE_DIR}"
  fontbuild pipeline \
    --fa-map "${FA_MAP}" \
    --repo-dir "${REPO_DIR}" \
    --donor-glyphs "${DONOR_GLYPH_FILE:-}" \
    --donor-families "${DONOR_FONT_FAMILIES}" \
    --donor-paths "${DONOR_FONT_PATHS}" \
    --icon-fill "${ICON_FILL}" \
    --icon-dy "${ICON_DY}" \
    --custom-dy "${CUSTOM_DY}" \
    --prescale-dir "${PRESCALE_DIR}" \
    "${BUILT[@]}" \
    2>&1 | tee -a "${LOG_FILE}"
  done_ "pipeline complete (icons @ md/oct x${ICON_FILL}, dy ${ICON_DY}em, custom_dy ${CUSTOM_DY}em)"
else
  warn "skipped pipeline: needs the fonttools venv + fa-map.json."
fi

# ===========================================================================
# Step 8 — Verify with fonttools (if available).
# ===========================================================================
log "step 8/10  verification"

if [[ -n "${PY_VENV_BIN}" && -x "${PY_VENV_BIN}" ]]; then
  fontbuild verify \
    "${OUT_DIR}" \
    "${FA_MERGED}" \
    "${REPO_DIR}/patched-fonts/NerdFontsSymbolsOnly"
else
  warn "skipped: no fonttools venv."
fi

# ===========================================================================
# Step 9 — Emit glyphs.json index (for fzf-style symbol pickers).
# ===========================================================================
log "step 9/10  emit glyphs.json index"

if [[ -z "${JSON_OUT_DIR}" ]]; then
  info "skipped: JSON_OUT_DIR is empty (explicitly disabled)."
elif [[ -z "${PY_VENV_BIN}" || ! -x "${PY_VENV_BIN}" ]]; then
  warn "skipped: no fonttools venv -> JSON requires fontTools."
else
  # Best-effort FA metadata discovery. icons.json lives at the package root,
  # one level up from FA_SRC_DIR (which points at .../otfs/).
  fa_pkg_dir=""
  fa_metadata_file=""
  fa_version=""
  if [[ -n "${FA_SRC_DIR:-}" ]]; then
    fa_pkg_dir=$(dirname "${FA_SRC_DIR}")
    if [[ -f "${fa_pkg_dir}/metadata/icons.json" ]]; then
      fa_metadata_file="${fa_pkg_dir}/metadata/icons.json"
    fi
    fa_version=$(printf '%s' "${FA_SRC_DIR}" \
      | sed -nE 's|.*/fontawesome-free-([0-9.]+)-desktop/.*|\1|p')
  fi
  if [[ -z "${fa_version}" ]] && command -v brew >/dev/null 2>&1; then
    fa_version=$(brew list --versions --cask font-fontawesome 2>/dev/null \
      | awk '{print $NF}')
  fi
  nf_ref="${NERDFONTS_REF}"
  nf_commit=$(cd "${REPO_DIR}" 2>/dev/null && git rev-parse --short HEAD 2>/dev/null || true)

  # Optional sidecar metadata for the custom SVG icons (label/terms/aliases/
  # comment/code). Resolved in step 5 as CUSTOM_META; absent on a default setup.
  custom_meta_file="${CUSTOM_META:-}"
  [[ -n "${custom_meta_file}" ]] && info "custom icon metadata: ${custom_meta_file}"

  json_out_path="${JSON_OUT_DIR}/glyphs.json"
  mkdir -p "${JSON_OUT_DIR}"
  fontbuild glyphs \
    "${OUT_DIR}" \
    "${REPO_DIR}" \
    "${fa_metadata_file}" \
    "${fa_version}" \
    "${nf_ref}" \
    "${nf_commit}" \
    "${json_out_path}" \
    "${FA_MAP}" \
    "${custom_meta_file}"
  done_ "wrote ${json_out_path}"
fi

# ===========================================================================
# Optional install into the user font dir.
# ===========================================================================
case "$(uname -s)" in
  Darwin) USER_FONT_DIR="${HOME}/Library/Fonts" ;;
  Linux)  USER_FONT_DIR="${HOME}/.local/share/fonts" ;;
  *)      USER_FONT_DIR="" ;;
esac

cask_warning=""
if command -v brew >/dev/null 2>&1; then
  if brew list --cask font-symbols-only-nerd-font >/dev/null 2>&1; then
    cask_warning="The Homebrew cask 'font-symbols-only-nerd-font' is installed.
   It owns these same filenames under ~/Library/Fonts and a future
   'brew upgrade' will silently overwrite this build. Uninstall first:
       brew uninstall --cask font-symbols-only-nerd-font
   And remove the corresponding line from your Brewfile."
  fi
fi

if [[ -n "${cask_warning}" ]]; then
  warn "${cask_warning}"
fi

do_install=0
if [[ "${INSTALL}" == "1" ]]; then
  do_install=1
elif [[ -n "${USER_FONT_DIR}" ]] && ask "Copy built TTFs into ${USER_FONT_DIR}?"; then
  do_install=1
fi

if [[ "${do_install}" == "1" && -n "${USER_FONT_DIR}" ]]; then
  mkdir -p "${USER_FONT_DIR}"
  for f in "${BUILT[@]}"; do
    cp -f "$f" "${USER_FONT_DIR}/"
    info "installed $(basename "$f") -> ${USER_FONT_DIR}/"
  done
  if [[ "$(uname -s)" == "Linux" ]] && command -v fc-cache >/dev/null 2>&1; then
    fc-cache -f "${USER_FONT_DIR}" >/dev/null 2>&1 && info "refreshed fontconfig cache"
  fi
  done_ "installed."
fi

# ===========================================================================
# Step 10 — Emit Blink Shell CSS (self-contained, base64-embedded).
# ===========================================================================
# Blink Shell imports a font as a single CSS file containing @font-face rules.
# We emit ONE file, jetbrains-mono-nerd-font-custom.css, embedding the fully-embedded
# JetBrains Mono Nerd Font (text + icons, single-cell) as the catch-all face,
# then a controlled fallback chain of iPad system fonts referenced by local()
# (NOT embedded — no licensing issue) and scoped by unicode-range. This mirrors
# the user's WezTerm font_with_fallback config.
#
# Why this shape: Blink sets the terminal font to `font-family: "<name>", Menlo`
# — only Menlo is appended, no broad system stack — so the whole fallback chain
# must live inside this one family as extra @font-face rules. Per CSS, the LAST
# matching face wins, so the embedded catch-all is declared FIRST and each
# higher-priority fallback later; emoji is declared last so it wins its range.
#
# Emoji: embedded Noto OT-SVG (the OpenType 'SVG ' table — gradient VECTOR art;
# iOS WebKit renders OT-SVG and resizes it, unlike COLRv1 which iOS can't render
# and unlike Apple's sbix bitmap which won't scale). hterm decides how many
# columns a glyph occupies from its own width table (font-independent), so the
# emoji are split into two WOFF2 faces — hterm-wide -> size-adjust to 2 cells,
# the rest -> 1 cell — to fill exactly what hterm reserves.
#
#   jetbrains-mono-nerd-font-custom.css  -> save in Blink as "JetBrainsMono NF"
log "step 10/10  emit Blink Shell CSS"

emit_blink_css() {
  # emit_blink_css <jbm-ttf> <output-css> <family-name> \
  #                <emoji-wide-woff2> <emoji-narrow-woff2> \
  #                <emoji-wide-range> <emoji-narrow-range> \
  #                <wide-size-adjust%> <narrow-size-adjust%>
  #
  # Emits ONE self-contained Blink font: the fully-embedded JetBrains Mono Nerd
  # Font (text + icons) as the catch-all face, then an iPad system-font fallback
  # chain via local() + unicode-range. The catch-all is declared FIRST and each
  # higher-priority fallback later, because the LAST matching face wins; emoji is
  # last so it wins its range. Each local() face is unicode-range-scoped to
  # scripts the embedded font lacks, so it can't override Latin/icons. Blink
  # auto-appends Menlo as the final broad-text fallback, so it isn't listed here.
  #
  # Emoji are EMBEDDED (Noto OT-SVG colour vector), split into TWO WOFF2 faces by
  # hterm's terminal width: hterm reserves 2 columns for "wide" emoji and 1 for
  # the rest, independent of the font. Each face is size-adjusted so the glyph
  # fills exactly the cells hterm reserves (wide -> 2 cells, narrow -> 1 cell),
  # so nothing bleeds or leaves a gap. The wide/narrow subsets are DIFFERENT
  # files (each glyph embedded once) base64'd into their respective face.
  local jbm_ttf="$1" out="$2" family="$3" emoji_wide_woff2="$4" emoji_narrow_woff2="$5"
  local emoji_wide="$6" emoji_narrow="$7" wide_adjust="$8" narrow_adjust="$9"
  {
    # NB: heredocs are UNQUOTED so ${family}/${emoji_range} interpolate. The CSS
    # body contains no other $, backtick, or backslash, so nothing else expands.
    cat <<CSS_HEAD
/* Blink Shell self-contained font: fully-embedded JetBrains Mono Nerd Font
   (text + all icons, single-cell) plus an iPad system-font fallback chain.
   The embedded face is base64 so there are NO external references. Save this
   font in Blink under the EXACT name:
       ${family}
   Generated by custom-builds/nerd-fonts/build-updated-font.sh. */

/* Catch-all: the embedded JetBrains Mono Nerd Font covers text, every Nerd-Font
   icon, and the imported donor Unicode symbols. No unicode-range = default. */
@font-face {
  font-family: "${family}";
  font-style: normal;
  font-weight: normal;
CSS_HEAD
    # The base64 payload MUST sit on the same line as "base64," — a newline in
    # the middle of an unquoted url() token can break CSS parsing. So the url(
    # prefix is printf'd WITHOUT a trailing newline, the payload is appended (tr
    # strips base64's own newlines), and the next heredoc closes the token.
    printf '  src: url(data:font/ttf;charset=utf-8;base64,'
    base64 < "${jbm_ttf}" | tr -d '\n'
    cat <<CSS_FILLERS
) format("truetype");
}

/* Fallback chain (iPad system fonts, not embedded). Declared low- to
   high-priority because the LAST matching face wins. */

/* Japanese kana extras. */
@font-face {
  font-family: "${family}";
  src: local("Hiragino Sans");
  unicode-range: U+3040-30FF, U+31F0-31FF, U+FF65-FF9F;
}

/* Unified Canadian Aboriginal Syllabics. */
@font-face {
  font-family: "${family}";
  src: local("Euphemia UCAS");
  unicode-range: U+1400-167F, U+18B0-18FF;
}

/* CJK: Han, Bopomofo, radicals, CJK symbols/punctuation. */
@font-face {
  font-family: "${family}";
  src: local("PingFang SC");
  unicode-range: U+2E80-2EFF, U+2F00-2FDF, U+3000-303F, U+3100-312F,
    U+31A0-31BF, U+3400-4DBF, U+4E00-9FFF, U+F900-FAFF;
}

/* Technical / runic / misc symbols the embedded font does not carry.
   Conservative range on purpose: too broad and Apple Symbols would steal
   curated Nerd-Font / donor symbols from the embedded face (last-wins). */
@font-face {
  font-family: "${family}";
  src: local("Apple Symbols");
  unicode-range: U+16A0-16FF, U+2900-297F, U+2B00-2BFF;
}
CSS_FILLERS
    # Emoji: embedded Noto OT-SVG, declared LAST so the two faces win their
    # ranges. Each face base64's its OWN WOFF2 subset; size-adjust scales the
    # OT-SVG vector glyph to fill its hterm cells. Skipped if the subsets are
    # unavailable (emoji then fall to the system colour font via WebKit's last
    # resort).
    if [[ -f "${emoji_wide_woff2}" && -n "${emoji_wide}" ]]; then
      cat <<CSS_EMOJI_WIDE_HEAD

/* Colour emoji (Noto OT-SVG), hterm width-2: fill the reserved 2 cells. */
@font-face {
  font-family: "${family}";
  size-adjust: ${wide_adjust}%;
CSS_EMOJI_WIDE_HEAD
      printf '  src: url(data:font/woff2;charset=utf-8;base64,'
      base64 < "${emoji_wide_woff2}" | tr -d '\n'
      cat <<CSS_EMOJI_WIDE_TAIL
) format("woff2");
  unicode-range: ${emoji_wide};
}
CSS_EMOJI_WIDE_TAIL
    fi
    if [[ -f "${emoji_narrow_woff2}" && -n "${emoji_narrow}" ]]; then
      cat <<CSS_EMOJI_NARROW_HEAD

/* Colour emoji (Noto OT-SVG), hterm width-1: fit one cell. Tune via EMOJI_NARROW_ADJUST. */
@font-face {
  font-family: "${family}";
  size-adjust: ${narrow_adjust}%;
CSS_EMOJI_NARROW_HEAD
      printf '  src: url(data:font/woff2;charset=utf-8;base64,'
      base64 < "${emoji_narrow_woff2}" | tr -d '\n'
      cat <<CSS_EMOJI_NARROW_TAIL
) format("woff2");
  unicode-range: ${emoji_narrow};
}
CSS_EMOJI_NARROW_TAIL
    fi
  } > "${out}"
}

if [[ -z "${BLINK_OUT_DIR}" ]]; then
  info "skipped: BLINK_OUT_DIR is empty (explicitly disabled)."
elif [[ -z "${JBM_TTF}" || ! -f "${JBM_TTF}" ]]; then
  warn "no embedded JetBrains Mono Nerd Font was built; skipping Blink CSS."
else
  mkdir -p "${BLINK_OUT_DIR}"
  # Remove stale outputs so serve-blink-assets.sh doesn't advertise them: the
  # legacy two-file output (Propo/Mono symbols fallback) and the pre-rename
  # single file (jetbrains-mono-nerd-font.css, now -custom.css).
  rm -f "${BLINK_OUT_DIR}"/jetbrains-custom-nerd-fonts.css \
        "${BLINK_OUT_DIR}"/jetbrains-custom-nerd-fonts-mono.css \
        "${BLINK_OUT_DIR}"/jetbrains-mono-nerd-font.css
  # Resolve (download + cache) the embedded colour-emoji font, then subset it to
  # its cmap-reachable emoji and SPLIT into wide/narrow WOFF2 faces, classified
  # by hterm's exact terminal-width table (baked below). The text region is
  # excluded so digits, # * keycap bases and (c)/(r) stay as JBM text; layout
  # closure is dropped so ZWJ/skin-tone/flag glyphs don't push the OT-SVG
  # document count past Safari's ~2000 ceiling.
  EMOJI_WIDE=""
  EMOJI_NARROW=""
  EMOJI_WIDE_WOFF2=""
  EMOJI_NARROW_WOFF2=""
  resolve_noto_emoji || true
  if [[ -n "${NOTO_EMOJI_OTF}" && -f "${NOTO_EMOJI_OTF}" && -n "${PY_VENV_BIN}" && -x "${PY_VENV_BIN}" ]]; then
    EMOJI_OUT_DIR="${WORK_DIR}/emoji-split"
    EMOJI_SPLIT="$(fontbuild emoji-split "${NOTO_EMOJI_OTF}" "${EMOJI_OUT_DIR}")"
    EMOJI_WIDE="$(printf '%s\n' "${EMOJI_SPLIT}" | sed -n 1p)"
    EMOJI_NARROW="$(printf '%s\n' "${EMOJI_SPLIT}" | sed -n 2p)"
    EMOJI_WIDE_WOFF2="$(printf '%s\n' "${EMOJI_SPLIT}" | sed -n 3p)"
    EMOJI_NARROW_WOFF2="$(printf '%s\n' "${EMOJI_SPLIT}" | sed -n 4p)"
  fi
  if [[ -n "${EMOJI_WIDE}${EMOJI_NARROW}" ]]; then
    info "emoji -> embedded Noto OT-SVG: wide(2-cell, ${EMOJI_WIDE_ADJUST}%) + narrow(1-cell, ${EMOJI_NARROW_ADJUST}%)"
    [[ -f "${EMOJI_WIDE_WOFF2}" ]] && info "  $(basename "${EMOJI_WIDE_WOFF2}") ($(($(stat -f '%z' "${EMOJI_WIDE_WOFF2}" 2>/dev/null || stat -c '%s' "${EMOJI_WIDE_WOFF2}")/1024)) KiB)"
    [[ -f "${EMOJI_NARROW_WOFF2}" ]] && info "  $(basename "${EMOJI_NARROW_WOFF2}") ($(($(stat -f '%z' "${EMOJI_NARROW_WOFF2}" 2>/dev/null || stat -c '%s' "${EMOJI_NARROW_WOFF2}")/1024)) KiB)"
  else
    warn "Noto OT-SVG unavailable; Blink CSS omits embedded emoji (system fallback)."
  fi

  info "JetBrains Mono : ${JETBRAINS_TTF}"
  emit_blink_css "${JBM_TTF}" "${BLINK_OUT_DIR}/jetbrains-mono-nerd-font-custom.css" \
    "JetBrainsMono NF" "${EMOJI_WIDE_WOFF2}" "${EMOJI_NARROW_WOFF2}" \
    "${EMOJI_WIDE}" "${EMOJI_NARROW}" "${EMOJI_WIDE_ADJUST}" "${EMOJI_NARROW_ADJUST}"
  info 'wrote jetbrains-mono-nerd-font-custom.css -> save in Blink as "JetBrainsMono NF"'
  done_ "Blink CSS -> ${BLINK_OUT_DIR}"
fi

# ===========================================================================
# Done. Print caveats.
# ===========================================================================
cat <<EOF

${C_GRN}Build complete.${C_RST}

  Output directory: ${OUT_DIR}
  Variants:
    - SymbolsNerdFont-Regular.ttf            (variable-width / "Propo")
    - SymbolsNerdFontMono-Regular.ttf        (monospaced)
    - JetBrainsMonoNerdFontMono-Regular.ttf  (embedded JBM text + icons, for Blink)
  Glyph index:
    - ${JSON_OUT_DIR:-(disabled)}/glyphs.json
  Blink Shell CSS:
    - ${BLINK_OUT_DIR:-(disabled)}/jetbrains-mono-nerd-font-custom.css  -> save in Blink as "JetBrainsMono NF"

${C_BLU}== Install manually if you skipped --install ==${C_RST}
  cp -f "${OUT_DIR}"/Symbols*.ttf "${OUT_DIR}"/JetBrains*.ttf ~/Library/Fonts/
  # Linux: cp ... ~/.local/share/fonts/ && fc-cache -fv

${C_BLU}== Import the font into Blink Shell ==${C_RST}
  # Serve the assets dir over HTTP, then in Blink: Settings -> Appearance ->
  # Fonts -> New Font -> point it at the printed .css URL. Save the font under
  # the EXACT name "JetBrainsMono NF" (must match the font-family inside the
  # .css). One self-contained font: text + icons + embedded Noto OT-SVG colour
  # emoji, with an iPad system-font fallback chain (PingFang SC / Hiragino Sans /
  # Euphemia UCAS / Apple Symbols) referenced by name. Menlo is auto-appended by
  # Blink. The same server also serves the colour theme (.js) for Themes.
  ../../assets/blink-shell/serve-blink-assets.sh   # serves ${BLINK_OUT_DIR:-<repo>/assets/blink-shell} on :8000

${C_BLU}== Feed the glyph index to fzf ==${C_RST}
  # Search by name, label, FA terms, FA aliases, or Unicode name.
  # Pipe the selected glyph through pbcopy / xclip to copy it.
  jq -r '
    .glyphs | to_entries[]
    | [ .key,
        .value.char,
        (.value.label // .value.unicode_name // ""),
        ((.value.terms // []) | join(" ")),
        ((.value.aliases // []) | join(" "))
      ] | @tsv
  ' ~/.local/share/fonts/nerd-font/glyphs.json \\
  | fzf --delimiter=$'\\t' --with-nth=1,2,3 \\
  | awk -F'\\t' '{print \$2}' \\
  | tee /dev/tty | pbcopy   # macOS; Linux: xclip -selection clipboard

${C_BLU}== Caveats / notes you'll want again next year ==${C_RST}

1. ${C_YLW}--custom is additive, not destructive.${C_RST}
   The curated Font Awesome 6.x layout shipped inside nerd-fonts continues
   to occupy the Nerd-Fonts-curated codepoint range 0xED00..0xF2FF.
   The Font Awesome version you supplied via --custom is layered on top
   at FA's *native* codepoints (mostly 0xE000..0xE5FF and gaps in
   0xF000..0xF8FF). Anything that would collide with a curated NF glyph
   is skipped (the patcher's "careful" mode).
   If you ever want FA to *replace* the curated layout, you have to
   regenerate src/glyphs/font-awesome/FontAwesome.otf by running that
   directory's remix -> analyze -> generate pipeline against the new FA
   SVGs (much more invasive — icon renames/removals in newer FA will
   shift the historically-stable NF codepoints).

   Since 2026-05: rather than dropping the ~1000 free FA icons whose
   native codepoints collide with other NF collections, step 5 copies
   them to a reserved Plane-16 Private-Use block (U+100000+). They are
   then real glyphs in the font and carry their proper fa-<name> in
   glyphs.json (with a "relocated_from" field). Caveat: a relocated icon
   no longer lives at FA's official codepoint, so it renders ONLY via
   this font (exactly like every other Nerd Font PUA icon). Fine for a
   picker that copies the glyph; not portable as a raw codepoint.

2. ${C_YLW}Box Drawing glyphs are intentionally absent.${C_RST}
   font-patcher disables Box Drawing for Symbols-Only builds. This is
   upstream behaviour, not a bug. The shipped TTFs lack them too.

3. ${C_YLW}Other collections track whatever this checkout has.${C_RST}
   Codicons / MDI / Octicons / Weather / Devicons / Font Logos /
   Pomicons / Powerline / IEC Power come from the assets committed
   to ryanoasis/nerd-fonts master at the moment of clone. If a
   downstream collection ships an upstream-newer version and nerd-fonts
   has not bumped it yet, this script will not pick it up.

3b. ${C_YLW}Font Awesome source priority.${C_RST}
   When the Homebrew cask 'font-fontawesome' is installed, this script
   uses its OTFs by default (preferred over ~/Downloads). That way your
   Brewfile keeps FA up to date and re-runs of this script auto-track.
   Override with FA_SRC_DIR=/path/to/otfs if you ever want to pin or
   test a different version.

4. ${C_YLW}FontForge is not in your Brewfile.${C_RST}
   On systems where you sync brew against a Brewfile (system-package
   brew sync / system-update), FontForge will be uninstalled on the
   next sweep. That is the intended behaviour — uninstall manually
   sooner with:
     brew uninstall fontforge && brew autoremove

4b. ${C_YLW}Do NOT keep the Homebrew cask 'font-symbols-only-nerd-font'.${C_RST}
   It installs upstream-shipped TTFs under the same filenames into
   ~/Library/Fonts. macOS only sees one font of a given family name,
   and a future 'brew upgrade' will silently overwrite this script's
   output with the older cask copy. Either remove the cask line from
   your Brewfile (chezmoi source if applicable) and re-run system sync,
   or run:
     brew uninstall --cask font-symbols-only-nerd-font

5. ${C_YLW}This script is self-contained but not hermetic.${C_RST}
   It depends on network access (git clone, brew install, optional
   FA download) and on Homebrew being available on macOS. To re-run
   later on a fresh machine, you need: brew, git, curl, unzip, bash.

6. ${C_YLW}Re-running is safe.${C_RST}
   The repo clone is reused (fast-forwarded to NERDFONTS_REF=${NERDFONTS_REF}).
   The output dir is overwritten. To start clean:  rm -rf "${WORK_ROOT}"

EOF
