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
#   6b. Copy a tiny allowlist of real Unicode keyboard/symbol glyphs from
#      OFL-licensed donor fonts into the finished Symbols variants. This keeps
#      slow broad-coverage fonts out of the terminal fallback path.
#   7b. Normalize icon sizing. Measure the curated md/oct box in the built
#      font, then scale every FA glyph (native + relocated) and every custom
#      SVG icon to that box (aspect preserved, centred on the md/oct centre),
#      advance untouched, via fontTools. Renderer-agnostic: no terminal has to
#      re-size icons at render time, and nothing bleeds out of the cell. See
#      the long comment on the step itself.
#   7. Strip out codepoints that belong to the colour-emoji domain (Misc
#      Symbols + Dingbats U+2600-U+27BF and the SMP emoji planes
#      U+1F300-U+1FFFF) so terminal font lookups for ♻ ✏ 🚀 etc. fall
#      through to the system colour-emoji font (Apple Color Emoji on
#      macOS, Noto Emoji on Linux), while preserving explicitly imported
#      donor symbols. See the long comment on the step itself for the full
#      rationale.
#   8. Use `fonttools` to verify the result and print a glyph-count diff
#      against the upstream-shipped TTFs in patched-fonts/NerdFontsSymbolsOnly.
#   9. Emit a glyphs.json index of every codepoint in the built font, with
#      Nerd-Fonts curated names, FA 7 names (prefixed `fa-` to avoid colliding
#      with the `nf-fa-*` curated set) and natural-language metadata
#      (labels, search terms, aliases, Unicode names). Written to
#      ~/.local/share/fonts/nerd-font/glyphs.json — handy for an fzf picker.
#  6c. Patch JetBrains Mono Regular ITSELF with the same merged-FA payload
#      (single-cell) to produce a fully-embedded "JetBrainsMono Nerd Font Mono"
#      — text + every icon in one self-contained TTF, for Blink Shell. It goes
#      through steps 6b/7/7b like the Symbols Mono font and is installed too.
#  10. Emit ONE self-contained Blink Shell CSS file to ~/.local/share/fonts/blink:
#      jetbrains-mono-nerd-font.css — the embedded JetBrains Mono Nerd Font as
#      the catch-all face, an iPad system-font fallback chain (local() +
#      unicode-range, mirroring the WezTerm font_with_fallback config), and
#      embedded Noto OT-SVG colour emoji (WOFF2) for emoji — split into two faces
#      by hterm's terminal width so each emoji fills its reserved cell(s). Serve
#      it for import with serve-blink-fonts.sh.
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
#                    (jetbrains-mono-nerd-font.css). It embeds the fully-patched
#                    JetBrains Mono Nerd Font and references iPad system fonts by
#                    name for fallback. Default: ~/.local/share/fonts/blink
#                    Pass BLINK_OUT_DIR="" to skip the CSS step entirely.
#                    Serve it for Blink import with ./serve-blink-fonts.sh.
#   JETBRAINS_TTF    JetBrains Mono Regular TTF that is patched into the embedded
#                    Blink font AND embedded as its text face. Default:
#                    auto-detect (~/Library/Fonts -> /Library/Fonts -> brew
#                    Caskroom font-jetbrains-mono -> ~/.local/share/fonts).
#                    Override to pin a specific file/weight. If unfound, the
#                    embedded JBM build and the Blink CSS are both skipped.
#   ICON_FILL        Multiplier on the measured curated md/oct box that every
#                    FA + custom icon is normalized to in step 7b. Default: 1.0
#                    (match md/oct exactly; ≈0.83em in the Propo variant).
#                    Lower insets the icons; higher fills more of the cell.
#                    Tunable — recalibrate fast with
#                    ./recalibrate-fa.sh <fill> [dy] -i.
#   ICON_DY          Extra vertical nudge (em, +=up) on top of the measured
#                    md/oct centre, for ALL icons, in step 7b. Default: 0.0.
#   CUSTOM_DY        Extra vertical nudge (em, +=up) for the custom SVG icons
#                    ONLY, on top of ICON_DY. Brand logos read optically low at
#                    the bbox centre; lift just them. Default: 0.0. Tunable
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

# Append a line to a global array. Works on bash 3.2 (no `mapfile`).
# Usage:  arr_append ARRAY_NAME "value"
arr_append() {
  local _name="$1"; shift
  eval "${_name}+=(\"\$@\")"
}

# ---------------------------------------------------------------------------
# Layout.
# ---------------------------------------------------------------------------
SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd -P )"
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
# Where the Blink Shell CSS files land. Set to "" to skip emission.
BLINK_OUT_DIR="${BLINK_OUT_DIR-${HOME}/.local/share/fonts/blink}"
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
log "step 1/8  resolve nerd-fonts source"

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
log "step 2/8  resolve Font Awesome assets"

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
log "step 3/8  ensure FontForge"

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
log "step 4/8  python venv with fonttools"

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

# ===========================================================================
# Step 5 — Merge FA's 3 OTFs (Brands/Regular/Solid) into one.
# ===========================================================================
log "step 5/8  merge Font Awesome Brands/Regular/Solid -> single OTF"

FA_MERGED="${WORK_DIR}/FontAwesomeCombined-Regular.otf"
MERGER_PY="${WORK_DIR}/_merge_fa.py"
cat >"${MERGER_PY}" <<'PYEOF'
# Run inside FontForge: merge Brands/Regular/Solid into one OTF.
# Solid wins overlaps, then Regular, then Brands.
import os, sys
import subprocess
import tempfile
import fontforge

PRIORITY = ["Solid", "Regular", "Brands"]

def find_fa_files(srcdir):
    found = {}
    for name in os.listdir(srcdir):
        lower = name.lower()
        if not (lower.endswith(".otf") or lower.endswith(".ttf")):
            continue
        full = os.path.join(srcdir, name)
        if "brands" in lower:
            found["Brands"] = full
        elif "solid" in lower:
            found["Solid"] = full
        elif "regular" in lower:
            found["Regular"] = full
    return found

def load_free_icon_cps(icons_json):
    """Map {codepoint: icon-name} for every FREE Font Awesome icon."""
    if not icons_json or not os.path.exists(icons_json):
        return {}
    try:
        import json
        with open(icons_json) as fh:
            data = json.load(fh)
    except Exception:
        return {}
    out = {}
    for name, info in data.items():
        if not isinstance(info, dict) or not info.get("free"):
            continue
        u = info.get("unicode")
        if not isinstance(u, str):
            continue
        try:
            out[int(u, 16)] = name
        except ValueError:
            pass
    return out


def curated_occupancy(ttf_path):
    """Codepoints already claimed by the curated Nerd Fonts layout, read
    from the upstream-shipped Symbols-Only TTF. A free FA icon whose
    native codepoint is in here would be skipped by the patcher's
    careful mode, so we relocate it instead."""
    occ = set()
    if not ttf_path or not os.path.exists(ttf_path):
        return occ
    try:
        f = fontforge.open(ttf_path)
    except Exception:
        return occ
    for g in f.glyphs():
        if g.unicode is not None and g.unicode >= 0:
            occ.add(g.unicode)
    f.close()
    return occ


def load_custom_meta(path):
    """Flat {icon-name: info} from custom-icons/metadata.json (or {} if
    absent/invalid). Accepts an "icons" wrapper and ignores header keys
    starting with _ or $."""
    if not path or not os.path.exists(path):
        return {}
    try:
        import json
        with open(path) as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return {}
    if isinstance(data, dict) and isinstance(data.get("icons"), dict):
        data = data["icons"]
    if not isinstance(data, dict):
        return {}
    return {
        name: info for name, info in data.items()
        if isinstance(info, dict) and not name.startswith(("_", "$"))
    }


def normalize_svg(src_path, usvg_bin):
    """Return a path to a cleaned-up copy of src_path for FontForge to import.

    Runs the SVG through `usvg` (the resvg project's SVG simplifier), which
    resolves CSS `<style>` fills, converts basic shapes to paths, bakes/
    flattens references, and resolves clips/masks into a minimal, well-defined
    SVG. FontForge's own SVG importer is unreliable on those features, so this
    makes the import faithful regardless of where the source SVG came from.

    usvg does NOT crop the canvas, and it doesn't need to: the downstream
    bounding-box normalization (here and in step 7b) trims to the real drawing
    extent from the imported contours. Returns a temp path the caller must
    delete; falls back to src_path (and prints a note) if usvg is unavailable
    or fails."""
    if not usvg_bin:
        return src_path, False
    try:
        fd, tmp = tempfile.mkstemp(suffix=".svg", prefix="usvg_")
        os.close(fd)
        subprocess.run([usvg_bin, src_path, tmp],
                       check=True, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL)
        return tmp, True
    except Exception as exc:
        sys.stderr.write("  usvg failed for %s (%s); importing raw\n"
                         % (os.path.basename(src_path), exc))
        return src_path, False


def import_custom_svgs(dest, custom_dir, start_cp, meta, used, usvg_bin=""):
    """Import every *.svg under custom_dir into a Plane-16 PUA glyph and
    return {icon-name: codepoint}.

    Codepoint assignment is STABLE so a downstream TUI can hard-code one:
      * An icon with a "code" pin in metadata.json (a hex string) always
        lands at exactly that codepoint.
      * Everything else is auto-assigned from start_cp, skipping any
        codepoint already taken (FA natives, relocated FA, pinned customs,
        and earlier auto customs). `used` is the live occupancy set and is
        mutated in place. Pins are reserved BEFORE any auto-assignment so an
        unpinned icon can never squat on a pinned slot.

    Each SVG is first run through usvg (see normalize_svg) so the import is
    faithful regardless of source quirks (CSS fills, shapes, clips, transforms).

    The icon name is the filename without extension (cursor-ai.svg ->
    usr-cursor-ai in glyphs.json). Each outline is normalised to roughly the box
    the FA icons occupy in this combined OTF (em-tall, on the FA descent),
    aspect preserved, centred, advance = one em, so the patcher treats it like
    every other FA glyph. Final sizing is set uniformly for all icons in step
    7b (normalized to the curated md/oct box), so this placement only needs to
    be sane, not exact."""
    out = {}
    try:
        names = sorted(n for n in os.listdir(custom_dir)
                       if n.lower().endswith(".svg"))
    except OSError:
        return out
    EM = 512.0      # unitsPerEm of the FA combined OTF (see find_fa_files)
    DESC = -64.0    # FA descent; the FA icon box is DESC .. DESC + EM

    # Pass 1: reserve every valid pin so auto-assignment can't grab it.
    pinned = {}
    for fn in names:
        name = os.path.splitext(fn)[0]
        info = meta.get(name)
        pin = info.get("code") if isinstance(info, dict) else None
        if pin is None:
            continue
        try:
            cp = int(str(pin), 16)
        except ValueError:
            sys.stderr.write("  custom pin for %s is not hex (%r); auto-assigning\n"
                             % (name, pin))
            continue
        if cp in used:
            sys.stderr.write("  custom pin U+%X for %s already in use; auto-assigning\n"
                             % (cp, name))
            continue
        pinned[name] = cp
        used.add(cp)

    nxt = [start_cp]

    def alloc():
        while nxt[0] in used:
            nxt[0] += 1
        cp = nxt[0]
        used.add(cp)
        nxt[0] += 1
        return cp

    # Pass 2: import each icon at its pinned or freshly-allocated codepoint.
    for fn in names:
        name = os.path.splitext(fn)[0]
        path = os.path.join(custom_dir, fn)
        was_pinned = name in pinned
        cp = pinned[name] if was_pinned else alloc()
        g = dest.createChar(cp, "customsvg_%05x" % cp)
        g.clear()
        norm_path, is_tmp = normalize_svg(path, usvg_bin)
        try:
            g.importOutlines(norm_path)
        except Exception as exc:
            sys.stderr.write("  custom SVG import failed for %s: %s\n" % (fn, exc))
            continue
        finally:
            if is_tmp:
                try:
                    os.unlink(norm_path)
                except OSError:
                    pass
        bb = g.boundingBox()
        if not bb or (bb[2] - bb[0]) <= 0 or (bb[3] - bb[1]) <= 0:
            sys.stderr.write("  custom SVG produced an empty glyph: %s\n" % fn)
            continue
        xmin, ymin, xmax, ymax = bb
        scale = EM / max(xmax - xmin, ymax - ymin)
        g.transform((scale, 0, 0, scale, 0, 0))
        xmin, ymin, xmax, ymax = g.boundingBox()
        w = xmax - xmin
        h = ymax - ymin
        dx = -xmin + (EM - w) / 2.0       # centre in the 0..EM cell
        dy = DESC - ymin + (EM - h) / 2.0  # centre in the DESC..DESC+EM box
        g.transform((1, 0, 0, 1, dx, dy))
        g.width = int(round(EM))
        g.removeOverlap()
        g.correctDirection()
        out[name] = cp
        print("  custom: %-20s -> U+%X  (%s%s)"
              % (name, cp, fn, ", pinned" if was_pinned else ""))
    return out


def main(argv):
    if len(argv) < 3:
        sys.stderr.write(
            "usage: <srcdir> <output_otf> "
            "[icons_json] [curated_ttf] [fa_map_out] [reserved_start_hex] "
            "[custom_svg_dir] [custom_start_hex] [custom_meta_json] [usvg_bin]\n")
        return 2
    srcdir, outpath = argv[1], argv[2]
    icons_json       = argv[3] if len(argv) > 3 else ""
    curated_ttf      = argv[4] if len(argv) > 4 else ""
    fa_map_out       = argv[5] if len(argv) > 5 else ""
    reserved_start   = int(argv[6], 16) if len(argv) > 6 and argv[6] else 0
    custom_dir       = argv[7] if len(argv) > 7 else ""
    custom_start     = int(argv[8], 16) if len(argv) > 8 and argv[8] else 0
    custom_meta_file = argv[9] if len(argv) > 9 else ""
    usvg_bin         = argv[10] if len(argv) > 10 else ""
    files = find_fa_files(srcdir)
    for label in PRIORITY:
        if label not in files:
            sys.stderr.write("missing FA '%s' OTF in %s\n" % (label, srcdir)); return 3

    print("Merging Font Awesome OTFs from %s" % srcdir)
    for label in PRIORITY:
        print("  %-8s -> %s" % (label, files[label]))

    dest = fontforge.open(files[PRIORITY[0]])
    dest.encoding = "UnicodeFull"
    dest.fontname  = "FontAwesomeCombined-Regular"
    dest.familyname = "Font Awesome Combined"
    dest.fullname  = "Font Awesome Combined"
    dest.copyright = "Fonticons, Inc."

    seen = set(g.unicode for g in dest.glyphs() if g.unicode >= 0)
    print("  baseline (%s): %d codepoints" % (PRIORITY[0], len(seen)))

    for label in PRIORITY[1:]:
        src = fontforge.open(files[label])
        src.encoding = "UnicodeFull"
        added = 0
        for glyph in src.glyphs():
            cp = glyph.unicode
            if cp < 0 or cp in seen:
                continue
            src.selection.select(glyph.encoding)
            src.copy()
            dest.selection.select(("unicode",), cp)
            dest.paste()
            try: dest[cp].glyphname = glyph.glyphname
            except Exception: pass
            seen.add(cp); added += 1
        src.close()
        print("  merged %s: +%d glyphs (total: %d)" % (label, added, len(seen)))

    # -- Relocate colliding free icons so they survive the patcher --
    # The patcher's `--custom` careful mode only fills EMPTY codepoints,
    # so any free FA icon whose native codepoint is already owned by a
    # curated Nerd Fonts collection (Powerline, Devicons, Seti, ...) gets
    # dropped. We give those icons a *copy* at a fresh Plane-16 Private
    # Use codepoint (the original stays put and is harmlessly skipped at
    # patch time). The patcher then imports and scales the copy through
    # the exact same path as every other custom glyph, so all free icons
    # end up present and visually consistent. The native->relocated map
    # is written out for the JSON step so each icon keeps its `fa-<name>`.
    relocations = {}
    fa_cps = []
    if icons_json and reserved_start:
        free_cps = load_free_icon_cps(icons_json)
        occ = curated_occupancy(curated_ttf)
        present = set(g.unicode for g in dest.glyphs() if g.unicode is not None and g.unicode >= 0)
        for cp in sorted(free_cps):
            if cp not in present:
                continue
            # Relocate any free icon that would otherwise land on top of a real
            # glyph when this merged FA is patched onto a font:
            #   * cp in occ  -> collides with a curated Nerd Fonts glyph.
            #   * non-PUA cp -> Font Awesome 7 places some free icons at ASCII /
            #     text positions (fa-0..9 at U+0030.., fa-a..z at U+0041.., plus
            #     fa-equals/plus/at/asterisk/... at their ASCII codepoints).
            #     Harmless in the Symbols-Only font (no text there), but when
            #     patched onto JetBrains Mono they would clobber its real '=',
            #     digits and A-Z, and the icon-sizing step (7b) would then
            #     mis-scale those text glyphs. Relocate them to Plane-16 too.
            is_pua = (0xE000 <= cp <= 0xF8FF) or (0xF0000 <= cp <= 0xFFFFD) \
                or (0x100000 <= cp <= 0x10FFFD)
            if cp in occ or not is_pua:
                # Deterministic, update-stable slot: native + reserved_start.
                # Colliding free natives sit in the BMP PUA (0xE000..0xF8FF) ->
                # 0x10E000..0x10F8FF; the non-PUA (ASCII) ones land in
                # 0x100021..0x10005A. Both are well inside Plane-16 and clear of
                # the custom block above. The slot is a pure function of the
                # icon's own native codepoint, so it stays stable across updates.
                new_cp = reserved_start + cp
                if new_cp > 0x10FFFD:
                    sys.stderr.write("  skip relocate U+%X: lands outside Plane-16\n" % cp)
                    fa_cps.append(cp)
                    continue
                dest.selection.select(("unicode",), cp)
                dest.copy()
                dest.selection.select(("unicode",), new_cp)
                dest.paste()
                try:
                    dest[new_cp].glyphname = "farelo_%05x" % new_cp
                except Exception:
                    pass
                if not is_pua:
                    # The original sits at a TEXT codepoint, so remove it: unlike
                    # a curated collision (where the patcher's careful mode skips
                    # the original because the curated glyph occupies that slot),
                    # the Symbols-Only font has nothing at ASCII, so a leftover
                    # original would be added there as a stray icon (and claim
                    # the codepoint in any fallback chain). Drop it entirely.
                    try:
                        dest.removeGlyph(dest[cp])
                    except Exception:
                        pass
                relocations["%04x" % cp] = "%04x" % new_cp
                fa_cps.append(new_cp)
            else:
                fa_cps.append(cp)
        print("  relocated %d free FA icons off curated/text codepoints (stable: native+U+%X) (%d kept at native)"
              % (len(relocations), reserved_start, len(fa_cps) - len(relocations)))

    # -- Import local custom SVG icons (Plane-16 PUA) --
    # Each SVG is normalized with usvg first, then imported and (in step 7b)
    # sized to the curated md/oct box like every other icon. Codepoints are
    # pinnable via metadata.json so a TUI can hard-code them.
    customs = {}
    if custom_dir and custom_start and os.path.isdir(custom_dir):
        used = set(g.unicode for g in dest.glyphs()
                   if g.unicode is not None and g.unicode >= 0)
        meta = load_custom_meta(custom_meta_file)
        customs = import_custom_svgs(dest, custom_dir, custom_start, meta, used, usvg_bin)
        for c in customs.values():
            fa_cps.append(c)
        print("  imported %d custom SVG icon(s)" % len(customs))

    if fa_map_out:
        import json
        with open(fa_map_out, "w") as fh:
            json.dump({
                "relocations": relocations,
                "reserved_start": ("%04x" % reserved_start) if reserved_start else None,
                "custom": {name: "%04x" % c for name, c in customs.items()},
                "fa_cps": ["%04x" % c for c in sorted(fa_cps)],
            }, fh)
        print("  wrote FA codepoint map: %s (%d icons, %d custom)"
              % (fa_map_out, len(fa_cps), len(customs)))

    print("Writing %s" % outpath)
    dest.generate(outpath, flags=("opentype", "no-FFTM-table"))
    dest.close()
    return 0

sys.exit(main(sys.argv))
PYEOF
# Inputs for the collision-relocation pass (see _merge_fa.py):
#   * FA icons.json  -> which codepoints are *free* icons we must keep.
#   * shipped curated TTF -> codepoints already owned by Nerd Fonts.
#   * FA_MAP -> native->relocated map, consumed by steps 7b and 9.
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
log "step 6/8  patch Symbols-Only SFD (Mono + Propo variants)"

# run_patcher <label> <input-font> [extra patcher flags...]
# Patches <input-font> with the merged FA payload. <input-font> is the blank
# Symbols SFD for the Symbols-Only variants, or JetBrains Mono Regular for the
# fully-embedded Blink font. --careful never overwrites glyphs the input font
# already has (matters for JBM's own text glyphs).
run_patcher() {
  local label="$1" srcfont="$2"; shift 2
  log "  -> [${label}] $* $(basename "${srcfont}")"
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
  ) 2>&1 | tee -a "${LOG_FILE}" | grep -E '===>|WARNING:|ERROR' || true
}

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
# Step 6b — Import selected Unicode glyphs from OFL donor fonts.
# ===========================================================================
# The terminal fallback list used to include broad text fonts just to cover a
# comparatively small set of glyphs. Loading those fonts in WezTerm was
# expensive, so this step copies only the explicitly allowlisted codepoints into
# Symbols Nerd Font and leaves the broad fonts out of the runtime fallback path.
log "step 6b/9  import selected Unicode glyphs from donor fonts"

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

if [[ -z "${DONOR_GLYPH_FILE}" ]]; then
  info "skipped: DONOR_GLYPH_FILE is empty (explicitly disabled)."
elif [[ ! -f "${DONOR_GLYPH_FILE}" ]]; then
  warn "skipped: donor glyph allowlist missing at ${DONOR_GLYPH_FILE}"
else
  install_donor_casks
  DONOR_IMPORT_PY="${WORK_DIR}/_import_donor_glyphs.py"
  cat >"${DONOR_IMPORT_PY}" <<'PYEOF'
"""Copy a small Unicode allowlist from OFL donor fonts into Symbols Nerd Font.

Uses fontTools instead of FontForge so the donor step copies only glyph outlines,
metrics, and cmap entries. That avoids FontForge's expensive GPOS validation path
("Bad pair position" floods) while keeping the generated font tiny and simple.
"""
from __future__ import annotations

import os
import re
import sys
from pathlib import Path

from fontTools.misc.transform import Identity, Transform
from fontTools.pens.boundsPen import BoundsPen
from fontTools.pens.cu2quPen import Cu2QuPen
from fontTools.pens.recordingPen import DecomposingRecordingPen
from fontTools.pens.transformPen import TransformPen
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.ttLib import TTCollection, TTFont


DEFAULT_DIRS = [
    "~/Library/Fonts",
    "/Library/Fonts",
    "/System/Library/Fonts",
    "/System/Library/Fonts/Supplemental",
    "/opt/homebrew/share/fonts",
    "/usr/local/share/fonts",
    "~/.local/share/fonts",
    "/usr/share/fonts",
]

KNOWN_PATHS = {
    "Iosevka": [
        "~/Library/Fonts/Iosevka.ttc",
        "/Library/Fonts/Iosevka.ttc",
        "/opt/homebrew/share/fonts/Iosevka.ttc",
        "/usr/local/share/fonts/Iosevka.ttc",
    ],
    "Noto Sans Symbols 2": [
        "~/Library/Fonts/NotoSansSymbols2-Regular.ttf",
        "/Library/Fonts/NotoSansSymbols2-Regular.ttf",
        "/opt/homebrew/share/fonts/NotoSansSymbols2-Regular.ttf",
        "/usr/local/share/fonts/NotoSansSymbols2-Regular.ttf",
    ],
    "Noto Sans Math": [
        "~/Library/Fonts/NotoSansMath-Regular.ttf",
        "/Library/Fonts/NotoSansMath-Regular.ttf",
        "/opt/homebrew/share/fonts/NotoSansMath-Regular.ttf",
        "/usr/local/share/fonts/NotoSansMath-Regular.ttf",
    ],
    "Noto Music": [
        "~/Library/Fonts/NotoMusic-Regular.ttf",
        "/Library/Fonts/NotoMusic-Regular.ttf",
        "/opt/homebrew/share/fonts/NotoMusic-Regular.ttf",
        "/usr/local/share/fonts/NotoMusic-Regular.ttf",
    ],
    "STIX Two Math": [
        "/System/Library/Fonts/Supplemental/STIXTwoMath.otf",
        "~/Library/Fonts/STIXTwoMath-Regular.otf",
        "/Library/Fonts/STIXTwoMath-Regular.otf",
        "/opt/homebrew/share/fonts/STIXTwoMath-Regular.otf",
        "/usr/local/share/fonts/STIXTwoMath-Regular.otf",
    ],
}


def expand(path: str) -> str:
    return os.path.abspath(os.path.expanduser(path))


def load_codepoints(path: str) -> list[int]:
    cps: list[int] = []
    seen: set[int] = set()
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.split("#", 1)[0]
            for match in re.finditer(r"(?:U\+)?([0-9A-Fa-f]{4,6})\b", line):
                cp = int(match.group(1), 16)
                if cp in (0xFE0E, 0xFE0F) or cp in seen:
                    continue
                seen.add(cp)
                cps.append(cp)
    return cps


def name_records(font: TTFont, name_id: int) -> list[str]:
    out: list[str] = []
    for rec in font["name"].names:
        if rec.nameID != name_id:
            continue
        try:
            value = rec.toUnicode().strip()
        except Exception:
            continue
        if value and value not in out:
            out.append(value)
    return out


def family_matches(font: TTFont, family: str, path: str) -> bool:
    wanted = family.casefold()
    for name_id in (1, 4, 6):
        for name in name_records(font, name_id):
            folded = name.casefold()
            if folded == wanted or folded.startswith(wanted + " "):
                return True
    basename = os.path.basename(path).casefold().replace("-", "").replace("_", "")
    return wanted.replace(" ", "") in basename


def font_cmap(font: TTFont) -> dict[int, str]:
    best = font.getBestCmap() or {}
    out = {int(cp): name for cp, name in best.items()}
    for table in font["cmap"].tables:
        if not table.isUnicode():
            continue
        for cp, name in table.cmap.items():
            out.setdefault(int(cp), name)
    return out


def open_font_faces(path: str) -> list[TTFont]:
    suffix = Path(path).suffix.lower()
    if suffix in {".ttc", ".otc"}:
        return list(TTCollection(path).fonts)
    return [TTFont(path)]


def candidate_paths(family: str, explicit_paths: list[str]) -> list[str]:
    paths: list[str] = []
    paths.extend(expand(path) for path in explicit_paths)
    paths.extend(expand(path) for path in KNOWN_PATHS.get(family, []))

    suffixes = (".ttf", ".otf", ".ttc", ".otc")
    for root in DEFAULT_DIRS:
        root = expand(root)
        if not os.path.isdir(root):
            continue
        try:
            entries = os.listdir(root)
        except OSError:
            continue
        for entry in entries:
            if entry.lower().endswith(suffixes):
                paths.append(os.path.join(root, entry))

    out: list[str] = []
    seen: set[str] = set()
    for path in paths:
        if path in seen or not os.path.exists(path):
            continue
        seen.add(path)
        out.append(path)
    return out


def open_donor(family: str, needed: set[int], explicit_paths: list[str]):
    for path in candidate_paths(family, explicit_paths):
        try:
            faces = open_font_faces(path)
        except Exception:
            continue
        for font in faces:
            if not family_matches(font, family, path):
                continue
            cmap = font_cmap(font)
            if any(cp in cmap for cp in needed):
                return path, font, cmap
    return None, None, {}


def cmap_accepts_cp(table, cp: int) -> bool:
    if not table.isUnicode():
        return False
    if table.format in {0, 6}:
        return cp <= 0xFF
    if table.format == 4:
        return cp <= 0xFFFF
    return True


def unique_glyph_name(order: set[str], cp: int) -> str:
    base = "u%04X" % cp if cp <= 0xFFFF else "u%06X" % cp
    name = base
    i = 1
    while name in order:
        i += 1
        name = f"{base}.{i}"
    return name


def draw_donor_glyph(donor: TTFont, donor_gname: str, transform, max_err: float):
    donor_set = donor.getGlyphSet()
    rec = DecomposingRecordingPen(donor_set)
    donor_set[donor_gname].draw(rec)

    tt_pen = TTGlyphPen(None)
    cu2qu_pen = Cu2QuPen(tt_pen, max_err=max_err)
    rec.replay(TransformPen(cu2qu_pen, transform))
    return tt_pen.glyph()


# Symbols for Legacy Computing (U+1FB00-1FBFF): cell-fraction block/box glyphs
# (sextants, eighth/quadrant blocks, shades, ...) that must tile the character
# cell exactly. Donor fonts draw them on their OWN cell, so for a monospace text
# font they must be remapped onto its cell and given its advance, or they leave
# gaps / overlap. We only do this for the embedded mono text font (see main()).
LEGACY_LO, LEGACY_HI = 0x1FB00, 0x1FBFF


def glyphset_bounds(font: TTFont, gname: str):
    """(xMin,yMin,xMax,yMax) of a glyph's outline (any outline format), or None."""
    try:
        gs = font.getGlyphSet()
        pen = BoundsPen(gs)
        gs[gname].draw(pen)
        return pen.bounds
    except Exception:
        return None


def target_cell(font: TTFont):
    """The monospace cell rect (x0,y0,x1,y1) from the font's FULL BLOCK U+2588:
    x 0..advance, y blockYMin..blockYMax. None if U+2588 is absent."""
    gname = (font.getBestCmap() or {}).get(0x2588)
    if not gname:
        return None
    bb = glyphset_bounds(font, gname)
    if not bb:
        return None
    adv = font["hmtx"].metrics.get(gname, (0, 0))[0]
    if adv <= 0:
        return None
    return (0.0, float(bb[1]), float(adv), float(bb[3]))


def donor_block_cell(donor: TTFont, donor_cmap: dict[int, str]):
    """The donor's design cell for the legacy-computing block, from the union of
    its U+1FB00-1FBFF glyphs: x 0..max(xMax) (full-width blocks reach the right
    edge), y min(yMin)..max(yMax) (the set spans the whole cell). None if empty."""
    xmax = ymin = ymax = None
    for cp in range(LEGACY_LO, LEGACY_HI + 1):
        gname = donor_cmap.get(cp)
        if not gname:
            continue
        bb = glyphset_bounds(donor, gname)
        if not bb:
            continue
        xmax = bb[2] if xmax is None else max(xmax, bb[2])
        ymin = bb[1] if ymin is None else min(ymin, bb[1])
        ymax = bb[3] if ymax is None else max(ymax, bb[3])
    if xmax is None or xmax <= 0 or ymax <= ymin:
        return None
    return (0.0, float(ymin), float(xmax), float(ymax))


def import_one(dest: TTFont, donor: TTFont, donor_cmap: dict[int, str], cp: int,
               cell=None) -> str:
    if "glyf" not in dest:
        raise SystemExit("destination font is not TrueType/glyf-based")

    donor_gname = donor_cmap[cp]
    dest_upm = dest["head"].unitsPerEm
    donor_upm = donor["head"].unitsPerEm

    order = dest.getGlyphOrder()
    order_set = set(order)
    new_name = unique_glyph_name(order_set, cp)
    order.append(new_name)
    dest.setGlyphOrder(order)

    if cell is not None:
        # Cell-normalize: affine-map the donor's block cell onto the target cell
        # so the glyph tiles, and override the advance to the target cell width.
        (dx0, dy0, dx1, dy1), (tx0, ty0, tx1, ty1) = cell
        sx = (tx1 - tx0) / (dx1 - dx0)
        sy = (ty1 - ty0) / (dy1 - dy0)
        xform = Transform(sx, 0, 0, sy, tx0 - dx0 * sx, ty0 - dy0 * sy)
        glyph = draw_donor_glyph(donor, donor_gname, xform, max(1.0, sx, sy))
        dest["glyf"][new_name] = glyph
        glyph.recalcBounds(dest["glyf"])
        dest["hmtx"].metrics[new_name] = (int(round(tx1 - tx0)),
                                          int(getattr(glyph, "xMin", 0)))
    else:
        scale = dest_upm / donor_upm
        glyph = draw_donor_glyph(donor, donor_gname, Identity.scale(scale),
                                 max(1.0, scale))
        dest["glyf"][new_name] = glyph
        advance, lsb = donor["hmtx"].metrics.get(donor_gname, (donor_upm, 0))
        dest["hmtx"].metrics[new_name] = (int(round(advance * scale)),
                                          int(round(lsb * scale)))

    for table in dest["cmap"].tables:
        if cmap_accepts_cp(table, cp):
            table.cmap[cp] = new_name

    dest["maxp"].numGlyphs = len(order)
    return new_name


def main(argv: list[str]) -> int:
    if len(argv) < 5:
        sys.stderr.write(
            "usage: <glyph-file> <family-csv> <path-list> <ttf> [<ttf> ...]\n")
        return 2

    glyph_file, family_csv, path_list = argv[1], argv[2], argv[3]
    built_paths = argv[4:]
    cps = load_codepoints(glyph_file)
    families = [f.strip() for f in family_csv.split(",") if f.strip()]
    explicit_paths = [p for p in path_list.split(os.pathsep) if p]

    if not cps:
        print("  no donor codepoints listed")
        return 0
    if not families:
        print("  no donor font families configured")
        return 0

    donors = []
    unresolved = set(cps)
    for family in families:
        path, font, cmap = open_donor(family, unresolved, explicit_paths)
        if not font:
            print("  donor missing or unused: %s" % family)
            continue
        covered = sorted(cp for cp in unresolved if cp in cmap)
        donors.append((family, path, font, cmap, covered))
        unresolved.difference_update(covered)
        print("  donor: %-20s %3d glyph(s)  %s" %
              (family, len(covered), path))
        if not unresolved:
            break

    for dest_path in built_paths:
        dest = TTFont(dest_path)
        present = set(dest.getBestCmap() or {})
        # Cell-normalize the legacy-computing block ONLY for the embedded mono
        # text font (JetBrainsMono*): it renders directly as terminal text, so
        # its block glyphs must tile the cell. The Symbols-Only fonts are used as
        # resize-on-render fallbacks, so they keep the donor glyphs verbatim.
        tcell = target_cell(dest) if os.path.basename(dest_path).startswith("JetBrains") else None
        norm = 0
        imported = 0
        already = 0
        for _family, _path, donor, cmap, covered in donors:
            dcell = donor_block_cell(donor, cmap) if tcell is not None else None
            for cp in covered:
                if cp in present:
                    already += 1
                    continue
                cell = None
                if tcell is not None and dcell is not None and LEGACY_LO <= cp <= LEGACY_HI:
                    cell = (dcell, tcell)
                    norm += 1
                import_one(dest, donor, cmap, cp, cell=cell)
                present.add(cp)
                imported += 1
        dest.save(dest_path)
        print("  %s: imported %d glyph(s), skipped %d already present%s" %
              (os.path.basename(dest_path), imported, already,
               (" (%d legacy-computing cell-normalized)" % norm) if norm else ""))

    if unresolved:
        print("  unresolved donor glyph(s): " +
              ", ".join("U+%04X" % cp for cp in sorted(unresolved)))
    return 0


sys.exit(main(sys.argv))

PYEOF
  if [[ -z "${PY_VENV_BIN}" || ! -x "${PY_VENV_BIN}" ]]; then
    warn "skipped: donor Unicode import requires the fonttools venv"
  else
    "${PY_VENV_BIN}" "${DONOR_IMPORT_PY}" \
      "${DONOR_GLYPH_FILE}" \
      "${DONOR_FONT_FAMILIES}" \
      "${DONOR_FONT_PATHS}" \
      "${BUILT[@]}" \
      2>&1 | tee -a "${LOG_FILE}"
  fi
  done_ "donor Unicode glyph import complete"
fi

# ===========================================================================
# Step 7 — Strip colour-emoji codepoints from the built TTFs.
# ===========================================================================
# Why we do this:
#   Symbols Nerd Font ships monochrome 1-cell text-style glyphs for a lot
#   of codepoints that the rest of the world wants to render as 2-cell
#   colour emoji (e.g. ♻ U+267B, ✏ U+270F, 🚀 U+1F680). When this font
#   sits in a terminal's font-family chain alongside a colour-emoji font
#   like Apple Color Emoji, ghostty's font lookup walks the chain in
#   order and stops at the first match. Symbols Nerd Font claims those
#   codepoints, wins the lookup, and prints a 1-cell monochrome glyph.
#   The Variation-Selector-16 (U+FE0F) hint that's supposed to force
#   colour emoji presentation gets ignored, and column-aligned UIs (like
#   our gitmoji picker) end up misaligned and ugly.
#
#   The fix is to remove those codepoints from this font entirely so the
#   chain falls through to the next entry. On macOS that's Apple Color
#   Emoji (the system default emoji fallback that ghostty falls back to
#   automatically when no `font-family` claims a codepoint); on Linux
#   it's Noto Emoji or whatever the distro provides. Either way: 2-cell
#   colour emoji rendering for the dropped codepoints, untouched
#   monochrome rendering for everything else.
#
#   Trade-off: the dropped codepoints also disappear from glyphs.json
#   (step 9), so the symbol picker no longer lists them under the
#   `nerd-fonts-curated` source. That's intentional — those codepoints
#   were never legitimately part of a "symbols" font anyway, and the
#   picker still surfaces them through its `unicode-stdlib` supplement.
#
# Ranges deliberately kept (NOT stripped):
#   * U+2300-U+23FF Misc Technical (⌚⌛⏰⏳ are emoji but ⌘⌥⌃ aren't,
#                   and ⌘ et al. are heavily used in Mac key bindings).
#   * U+2B00-U+2BFF Misc Symbols and Arrows (⬇⬆ etc. — Apple Color
#                   Emoji renders these uncomfortably small inside the
#                   cell, so we prefer Symbols Nerd Font's text-style
#                   monochrome arrows here).
#   * Explicit DONOR_GLYPH_FILE entries. Some Iosevka delta symbols live in
#                   U+1Fxxx blocks that are not emoji; if we intentionally
#                   imported them in step 6b, do not strip them here.
#   * U+1FB00-U+1FBFF Symbols for Legacy Computing (box drawing / terminal
#                   graphics pieces; not emoji despite living in the broad
#                   U+1F300-U+1FFFF strip range below).
#   * U+E000-U+F8FF + U+F0000-U+10FFFD Private Use Areas (the actual
#                   nerd-font icons live here; nothing else competes).
log "step 7/9  strip colour-emoji codepoints from built TTFs"

if [[ -n "${PY_VENV_BIN}" && -x "${PY_VENV_BIN}" ]]; then
  STRIP_PY="${WORK_DIR}/_strip_emoji.py"
  cat >"${STRIP_PY}" <<'PYEOF'
"""Drop codepoints in the colour-emoji ranges from each TTF's cmap.

We touch the cmap subtables only — glyf and other tables are left alone.
Subsetting the actual glyph outlines would shrink the file further but
also requires running pyftsubset which we'd have to plumb through the
patcher's already-non-trivial state machine. Removing the codepoint→
glyph mapping is enough for terminal font lookup: ghostty walks
font cmaps in order, so a missing entry here means the next font in
the chain gets asked.

Idempotent: running twice on the same file has no effect after the
first pass (already-stripped codepoints are simply not present).
"""
import re
import sys
from fontTools.ttLib import TTFont

# Inclusive (low, high) Unicode codepoint pairs to strip. Keep in sync
# with the long comment on `step 7/9` in build-updated-font.sh.
EMOJI_RANGES = [
    (0x2600,  0x27BF),    # Miscellaneous Symbols + Dingbats
    (0x1F300, 0x1FFFF),   # SMP emoji planes
]
KEEP_RANGES = [
    (0x1FB00, 0x1FBFF),   # Symbols for Legacy Computing, not emoji
]

def load_keep_codepoints(path):
    if not path:
        return set()
    try:
        text = open(path, encoding="utf-8").read()
    except OSError:
        return set()
    keep = set()
    for match in re.finditer(r"U\+([0-9A-Fa-f]{4,6})\b", text):
        keep.add(int(match.group(1), 16))
    return keep

EXPLICIT_KEEP = load_keep_codepoints(sys.argv[1] if len(sys.argv) > 1 else "")

def in_strip_range(cp):
    if cp in EXPLICIT_KEEP:
        return False
    if any(lo <= cp <= hi for lo, hi in KEEP_RANGES):
        return False
    return any(lo <= cp <= hi for lo, hi in EMOJI_RANGES)

removed_total = 0
if EXPLICIT_KEEP:
    print("  preserving %d explicit donor codepoint(s)" % len(EXPLICIT_KEEP))
for path in sys.argv[2:]:
    font = TTFont(path)
    removed_in_file = 0
    removed_cps = set()
    for table in font["cmap"].tables:
        # `table.cmap` is a dict {codepoint: glyph_name}. Mutating it
        # while iterating is unsafe; collect first, delete second.
        victims = [cp for cp in table.cmap if in_strip_range(cp)]
        for cp in victims:
            del table.cmap[cp]
        removed_in_file += len(victims)
        removed_cps.update(victims)
    font.save(path)
    # Sidecar: the exact set removed from THIS font, so the Blink CSS step can
    # route precisely these codepoints to Apple Color Emoji. One source of
    # truth — the CSS unicode-range can never drift from what the font lost.
    with open(path + ".emoji-stripped.txt", "w", encoding="utf-8") as fh:
        for cp in sorted(removed_cps):
            fh.write("U+%04X\n" % cp)
    print("  stripped %5d codepoints from %s" % (removed_in_file, path.rsplit('/', 1)[-1]))
    removed_total += removed_in_file

print("  total removed: %d codepoint→glyph mappings" % removed_total)
PYEOF
  "${PY_VENV_BIN}" "${STRIP_PY}" "${DONOR_GLYPH_FILE:-}" "${BUILT[@]}" 2>&1 | tee -a "${LOG_FILE}"
  done_ "emoji codepoints stripped"
else
  warn "skipped: no fonttools venv -> emoji codepoints remain in the cmap"
fi

# ===========================================================================
# Step 7b — Normalize icon sizing (FA + custom) to the curated md/oct box.
# ===========================================================================
# Goal: every icon glyph renders at one consistent size and vertical position
# in ANY terminal, with nothing spilling above the ascent or below the descent
# (vertical "bleed"). This has to hold WITHOUT a renderer re-sizing glyphs at
# render time: WezTerm, unlike Ghostty, does not re-scale Nerd-Font icons, so
# the size must already be correct *in the font*.
#
# Approach (absolute normalization, via fontTools — never by editing the
# patcher): measure the curated Material-Design + Octicons glyphs already in
# THIS font (their median box and vertical centre), then scale every Font
# Awesome glyph (native AND relocated) and every custom SVG icon to that box,
# aspect preserved, about its own centre, and move it onto that centre. Advance
# widths are left untouched so cell alignment holds; with the Propo variant the
# only overflow that remains is horizontal (right), which is harmless.
#
# md/oct is the reference because it's the largest, most uniform curated family
# and defines the visual "icon size" of the font. It is measured per-variant,
# so the Propo build (icons ~0.83em) and the Mono build (~1.0em) each match
# their own curated glyphs automatically. Curated glyphs are the reference and
# are NOT modified.
#
# Ghostty interaction: it re-fits the populations it recognises (curated +
# native FA) to its own icon_height at render time, so baking native FA here is
# harmless there (Ghostty overrides it) and necessary for WezTerm. The
# relocated + custom PUA glyphs Ghostty leaves alone, so the size baked here is
# also what Ghostty shows for them.
#
#   ICON_FILL  multiplier on the measured md/oct box. 1.0 = match md/oct
#              exactly (≈0.83em in Propo, i.e. the "~0.85" target). Lower
#              insets the icons; higher fills more of the cell. Tunable —
#              recalibrate fast (no rebuild) with
#              ./recalibrate-fa.sh <fill> [dy] --install.
#   ICON_DY    extra vertical nudge in em (+=up) on top of the measured md/oct
#              centre, for ALL icons. Normally 0.0; the measured centre matches.
#   CUSTOM_DY  extra vertical nudge in em (+=up) for the custom SVG icons ONLY,
#              on top of ICON_DY. Brand logos tend to read optically low at the
#              bbox centre, so a small positive value lifts just them.
log "step 7b/9 normalize icon sizing (FA + custom -> md/oct box)"

ICON_FILL="${ICON_FILL:-1.05}"
ICON_DY="${ICON_DY:-0.0}"
CUSTOM_DY="${CUSTOM_DY:-0.07}"
if [[ -n "${PY_VENV_BIN}" && -x "${PY_VENV_BIN}" && -f "${FA_MAP}" ]]; then
  # Stash pristine (native-size) copies so recalibrate-fa.sh can re-derive
  # any scale without re-running the patcher.
  PRESCALE_DIR="${WORK_DIR}/prescale"
  mkdir -p "${PRESCALE_DIR}"
  for f in "${BUILT[@]}"; do cp -f "$f" "${PRESCALE_DIR}/$(basename "$f")"; done
  info "stashed pristine TTFs -> ${PRESCALE_DIR}"

  SCALE_PY="${WORK_DIR}/_scale_fa.py"
  cat >"${SCALE_PY}" <<'PYEOF'
"""Normalize icon glyph sizing to the curated md/oct box (see step 7b).

Measures the curated Material-Design + Octicons glyphs in each font (median
max-dimension and median vertical centre), then scales every Font Awesome
glyph (native + relocated) and every custom SVG icon to ICON_FILL x that box,
aspect preserved, about its own bbox centre, and moves it onto that centre +
ICON_DY. Advance widths are untouched; composite glyphs are decomposed.

argv:
  1  fa_map.json   relocations / custom / fa_cps written by _merge_fa.py
  2  repo_dir      nerd-fonts checkout (glyphnames.json -> md/oct codepoints)
  3  icon_fill     multiplier on the md/oct median box (1.0 = match md/oct)
  4  icon_dy_em    extra vertical nudge in em (+=up) on the md/oct centre, all
                   icons
  5  custom_dy_em  extra vertical nudge in em (+=up) for the custom SVG icons
                   ONLY, on top of icon_dy_em. Their optical centre tends to sit
                   below the bbox centre (brand logos etc.), so at dy=0 they
                   read a touch low next to md/oct; this lifts just them.
  6: paths         TTFs to edit in place
"""
import json
import statistics
import sys

from fontTools.ttLib import TTFont
from fontTools.misc.transform import Identity
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.pens.transformPen import TransformPen
from fontTools.pens.recordingPen import DecomposingRecordingPen

fa_map = json.load(open(sys.argv[1]))
repo_dir = sys.argv[2]
icon_fill = float(sys.argv[3])
icon_dy_em = float(sys.argv[4])
custom_dy_em = float(sys.argv[5])
paths = sys.argv[6:]

# Every FA-origin glyph (native + relocated) plus the custom SVG icons.
targets = [int(h, 16) for h in fa_map.get("fa_cps", [])]
# Custom SVG icons get an extra vertical nudge on top of the shared centre.
custom_cps = {int(h, 16) for h in fa_map.get("custom", {}).values()}

# Curated reference family: Material Design + Octicons. glyphnames.json keys
# are unprefixed (e.g. "md-account", "oct-x"); the font carries them as nf-*.
glyphnames = json.load(open(repo_dir + "/glyphnames.json"))
ref_cps = set()
for _name, _info in glyphnames.items():
    if _name == "METADATA" or not isinstance(_info, dict):
        continue
    if _name.startswith(("md-", "oct-")):
        try:
            ref_cps.add(int(_info["code"], 16))
        except (KeyError, ValueError, TypeError):
            pass


def _bbox(glyf, gname):
    g = glyf[gname]
    g.recalcBounds(glyf)
    if g.numberOfContours == 0:
        return None
    return g.xMin, g.yMin, g.xMax, g.yMax


def measure_ref(glyf, cmap):
    centers, sizes = [], []
    for cp in ref_cps:
        gname = cmap.get(cp)
        if not gname:
            continue
        b = _bbox(glyf, gname)
        if not b:
            continue
        xmin, ymin, xmax, ymax = b
        centers.append((ymin + ymax) / 2.0)
        sizes.append(max(xmax - xmin, ymax - ymin))
    if not sizes:
        raise SystemExit("no md/oct reference glyphs found in font")
    return statistics.median(centers), statistics.median(sizes)


def transform_one(glyf, glyph_set, gname, factor, target_cy):
    glyph = glyf[gname]
    glyph.recalcBounds(glyf)
    if glyph.numberOfContours == 0:
        return False
    cx = (glyph.xMin + glyph.xMax) / 2.0
    cy = (glyph.yMin + glyph.yMax) / 2.0
    rec = DecomposingRecordingPen(glyph_set)
    glyph.draw(rec, glyf)
    pen = TTGlyphPen(glyph_set)
    # Scale about the bbox centre, then move that centre to target_cy.
    t = (Identity
         .translate(0, target_cy - cy)
         .translate(cx, cy).scale(factor).translate(-cx, -cy))
    rec.replay(TransformPen(pen, t))
    ng = pen.glyph()
    ng.recalcBounds(glyf)
    glyf[gname] = ng
    return True


for path in paths:
    font = TTFont(path)
    upm = font["head"].unitsPerEm
    glyf = font["glyf"]
    cmap = font.getBestCmap()
    gs = font.getGlyphSet()

    ref_cy, ref_size = measure_ref(glyf, cmap)
    target_size = icon_fill * ref_size
    base_cy = ref_cy + icon_dy_em * upm
    custom_offset = custom_dy_em * upm

    n = 0
    tops, bots = [], []
    for cp in targets:
        gname = cmap.get(cp)
        if not gname:
            continue
        b = _bbox(glyf, gname)
        if not b:
            continue
        cur = max(b[2] - b[0], b[3] - b[1])
        if cur <= 0:
            continue
        cy = base_cy + (custom_offset if cp in custom_cps else 0)
        if transform_one(glyf, gs, gname, target_size / cur, cy):
            n += 1
            g = glyf[gname]
            tops.append(g.yMax)
            bots.append(g.yMin)

    asc = font["hhea"].ascent
    desc = font["hhea"].descent
    bleed = bool(tops) and (max(tops) > asc or min(bots) < desc)
    font.save(path)
    print("  %s: md/oct box=%.3fem center=%+.3f -> %d icons @ %.3fem%s%s"
          % (path.rsplit('/', 1)[-1], ref_size / upm, ref_cy / upm, n,
             target_size / upm,
             (" dy=%+.2fem" % icon_dy_em) if icon_dy_em else "",
             (" custom_dy=%+.2fem" % custom_dy_em) if custom_dy_em else ""))
    if tops:
        span = ("  top<=%.3f bot>=%.3f (cell %.3f..%.3f)"
                % (max(tops) / upm, min(bots) / upm, desc / upm, asc / upm))
        print(("  WARNING: vertical bleed!" + span) if bleed else ("  ok," + span))
PYEOF
  "${PY_VENV_BIN}" "${SCALE_PY}" "${FA_MAP}" "${REPO_DIR}" "${ICON_FILL}" "${ICON_DY}" "${CUSTOM_DY}" "${BUILT[@]}" \
    2>&1 | tee -a "${LOG_FILE}"
  done_ "icons normalized to md/oct box (fill x${ICON_FILL}, dy ${ICON_DY}em, custom_dy ${CUSTOM_DY}em)"
else
  warn "skipped: needs fonttools venv + fa-map.json -> FA glyphs left at full size"
fi

# ===========================================================================
# Step 7c — Bleed block + legacy-computing glyphs past the cell edges.
# ===========================================================================
# JetBrains Mono bleeds its BOX-DRAWING glyphs (U+2500-257F) ~100 units past the
# cell top/bottom so they tile seamlessly, but its BLOCK ELEMENTS (U+2580-259F)
# stop exactly at the cell box. A renderer that rounds the cell a hair taller
# (Blink/hterm) then leaves a 1px seam at the top/bottom of those exact-edge
# blocks (▌ ▋ ▂, and the imported legacy-computing blocks 🮂 ...). This gives the
# block + legacy-computing glyphs the SAME overshoot JBM already uses for box
# drawing, but only on points sitting on the cell boundary (interior points like
# a half-block's mid-line are untouched, so the fill fraction is preserved).
# Embedded mono font only — the Symbols variants are resize-on-render fallbacks.
log "step 7c/9 bleed block + legacy-computing glyphs past the cell edges"

JBM_MONO=""
for f in "${BUILT[@]}"; do
  case "$(basename "$f")" in JetBrains*) JBM_MONO="$f" ;; esac
done

if [[ -n "${PY_VENV_BIN}" && -x "${PY_VENV_BIN}" && -n "${JBM_MONO}" ]]; then
  BLEED_PY="${WORK_DIR}/_bleed_blocks.py"
  cat >"${BLEED_PY}" <<'PYEOF'
"""Bleed block-element + legacy-computing glyphs past the cell top/bottom so they
tile without a 1px seam (see step 7c).

The cell box is taken from the FULL BLOCK U+2588 (yMin..yMax). The overshoot is
taken from JetBrains Mono's own box-drawing bleed (the vertical line U+2502
extends past the cell by this much), so we match the font's existing design
exactly. Only points sitting ON the cell top/bottom edge are moved; interior
points are untouched, so each glyph keeps its fill fraction.
"""
import sys
from fontTools.ttLib import TTFont

EPS = 4
# Block Elements + Symbols for Legacy Computing. Box Drawing (2500-257F) already
# bleeds and is the reference, so it is intentionally NOT included here.
RANGES = [(0x2580, 0x259F), (0x1FB00, 0x1FBFF)]

def main(path):
    f = TTFont(path)
    cmap = f.getBestCmap()
    glyf = f["glyf"]

    fb = cmap.get(0x2588)
    if not fb:
        print("  no U+2588 full block; skipping"); return 0
    fbg = glyf[fb]; fbg.recalcBounds(glyf)
    cell_top, cell_bot = fbg.yMax, fbg.yMin

    over_top = over_bot = 100
    vl = cmap.get(0x2502)
    if vl:
        vlg = glyf[vl]; vlg.recalcBounds(glyf)
        over_top = max(0, vlg.yMax - cell_top)
        over_bot = max(0, cell_bot - vlg.yMin)
    if over_top == 0 and over_bot == 0:
        over_top = over_bot = 100

    top_to, bot_to = cell_top + over_top, cell_bot - over_bot
    changed = 0
    for cp in (c for lo, hi in RANGES for c in range(lo, hi + 1)):
        gn = cmap.get(cp)
        if not gn:
            continue
        g = glyf[gn]
        if getattr(g, "numberOfContours", 0) <= 0:
            continue
        coords = g.coordinates
        moved = False
        for i in range(len(coords)):
            x, y = coords[i]
            if abs(y - cell_top) <= EPS:
                coords[i] = (x, top_to); moved = True
            elif abs(y - cell_bot) <= EPS:
                coords[i] = (x, bot_to); moved = True
        if moved:
            g.recalcBounds(glyf)
            changed += 1
    f.save(path)
    print("  bled %d block/legacy glyphs (cell %d..%d, overshoot +%d/-%d -> %d..%d)"
          % (changed, cell_bot, cell_top, over_top, over_bot, bot_to, top_to))
    return 0

sys.exit(main(sys.argv[1]))
PYEOF
  "${PY_VENV_BIN}" "${BLEED_PY}" "${JBM_MONO}" 2>&1 | tee -a "${LOG_FILE}"
  done_ "block + legacy-computing glyphs bled past the cell edges"
elif [[ -z "${JBM_MONO}" ]]; then
  info "skipped: no embedded JBM mono font built."
else
  warn "skipped: block bleed needs the fonttools venv."
fi

# ===========================================================================
# Step 8 — Verify with fonttools (if available).
# ===========================================================================
log "step 8/9  verification"

if [[ -n "${PY_VENV_BIN}" && -x "${PY_VENV_BIN}" ]]; then
  VERIFY_PY="${WORK_DIR}/_verify.py"
  cat >"${VERIFY_PY}" <<'PYEOF'
import os, sys
from fontTools.ttLib import TTFont

PROBES = [
    ("Seti-UI + Custom",       0xE5FA),
    ("Devicons",               0xE700),
    ("Font Awesome (curated)", 0xF015),
    ("Material Design Icons",  0xF0001),
    ("Octicons",               0xF400),
    ("Weather Icons",          0xE300),
    ("Font Logos",             0xF300),
    ("Codicons",               0xEA60),
    ("Heavy Angle Brackets",   0x276C),
    ("Progress Indicators",    0xEE00),
]

def cmap(f): return set(TTFont(f).getBestCmap().keys())
def name_(f, i):
    t = TTFont(f)["name"]
    rec = t.getName(i, 3, 1, 0x409) or t.getName(i, 1, 0, 0)
    return str(rec) if rec else "?"

built_dir, fa_merged, shipped_dir = sys.argv[1], sys.argv[2], sys.argv[3]

fa_pts = cmap(fa_merged) if os.path.exists(fa_merged) else set()

def report(label, path):
    pts = cmap(path)
    print("=== %s: %s (%s bytes) ===" % (label, os.path.basename(path), f"{os.path.getsize(path):,}"))
    print("  family : %s" % name_(path, 1))
    print("  cmap   : %s codepoints" % f"{len(pts):,}")
    for col, cp in PROBES:
        print("    [%s] %s" % ("x" if cp in pts else " ", col))
    if fa_pts:
        inter = len(fa_pts & pts)
        print("  FA glyphs from merged OTF present: %s / %s" % (f"{inter:,}", f"{len(fa_pts):,}"))
    print()

for f in sorted(os.listdir(built_dir)):
    if f.endswith(".ttf") and f.startswith("Symbols"):
        report("BUILT", os.path.join(built_dir, f))

if os.path.isdir(shipped_dir):
    for f in sorted(os.listdir(shipped_dir)):
        if f.endswith(".ttf") and f.startswith("Symbols"):
            report("SHIPPED (in repo)", os.path.join(shipped_dir, f))
PYEOF
  "${PY_VENV_BIN}" "${VERIFY_PY}" \
    "${OUT_DIR}" \
    "${FA_MERGED}" \
    "${REPO_DIR}/patched-fonts/NerdFontsSymbolsOnly"
else
  warn "skipped: no fonttools venv."
fi

# ===========================================================================
# Step 9 — Emit glyphs.json index (for fzf-style symbol pickers).
# ===========================================================================
log "step 9/9  emit glyphs.json index"

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

  GLYPHS_PY="${WORK_DIR}/_glyphs_json.py"
  cat >"${GLYPHS_PY}" <<'PYEOF'
"""Emit a glyphs.json index describing every codepoint in the built font.

Sources merged into the JSON:
  * Curated Nerd-Fonts glyph names from <repo>/glyphnames.json
    (e.g. nf-fa-house, nf-md-account_check, nf-cod-zap).
  * Font Awesome 7 native additions from <fa>/metadata/icons.json
    (keyed `fa-<icon-name>` so they never collide with curated nf-fa-*).
    Pulls FA's label / search.terms / aliases / styles for free-text search.
    Icons that the merge step relocated off a colliding curated codepoint
    are followed to their Plane-16 slot via fa-map.json and tagged with a
    `relocated_from` field.
  * Anything else still in the font's cmap that stdlib `unicodedata` knows
    by name (Box Drawing etc.), keyed `u-<hex>`.

Designed to feed an fzf-style picker that wants per-glyph natural-language
hints (think wezterm's CharSelect popup).
"""

from __future__ import annotations

import json
import os
import sys
import unicodedata
from datetime import datetime, timezone
from pathlib import Path

from fontTools.ttLib import TTFont


NF_COLLECTION_NAMES = {
    "fa":      "font-awesome",
    "fae":     "font-awesome-extension",
    "md":      "material-design",
    "mdi":     "material-design-legacy",
    "oct":     "octicons",
    "cod":     "codicons",
    "dev":     "devicons",
    "iec":     "iec-power",
    "linux":   "font-logos",
    "pl":      "powerline",
    "ple":     "powerline-extra",
    "pom":     "pomicons",
    "seti":    "seti-ui+custom",
    "weather": "weather-icons",
    "custom":  "seti-ui+custom",
    "indent":  "indent",
}


def _load_json(path):
    if not path:
        return None
    try:
        with open(path) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def _safe_unicode_name(cp):
    try:
        return unicodedata.name(chr(cp))
    except (ValueError, OSError):
        return None


def _enrich_with_fa(entry, fa_info):
    if isinstance(fa_info.get("label"), str):
        entry["label"] = fa_info["label"]
    styles = fa_info.get("styles")
    if isinstance(styles, list) and styles:
        entry["styles"] = list(styles)
    search = fa_info.get("search")
    if isinstance(search, dict):
        terms = search.get("terms")
        if isinstance(terms, list) and terms:
            entry["terms"] = [str(t) for t in terms]
    aliases = fa_info.get("aliases")
    if isinstance(aliases, dict) and isinstance(aliases.get("names"), list):
        entry["aliases"] = list(aliases["names"])
    elif isinstance(aliases, list):
        entry["aliases"] = list(aliases)


def _pick_canonical_ttf(built_dir):
    preferred = os.path.join(built_dir, "SymbolsNerdFont-Regular.ttf")
    if os.path.isfile(preferred):
        return preferred
    for entry in sorted(os.listdir(built_dir)):
        if entry.endswith(".ttf") and entry.startswith("Symbols"):
            return os.path.join(built_dir, entry)
    raise SystemExit("no TTFs found under " + built_dir)


def _load_custom_meta(path):
    """Sidecar metadata for the local custom SVG icons (custom-icons/
    metadata.json). Keyed by icon name (filename minus .svg). Accepts either
    a flat map or one wrapped under an "icons" key, and ignores header keys
    beginning with "_" or "$" so the file can carry its own notes."""
    data = _load_json(path)
    if isinstance(data, dict) and isinstance(data.get("icons"), dict):
        data = data["icons"]
    if not isinstance(data, dict):
        return {}
    return {
        name: info for name, info in data.items()
        if isinstance(info, dict) and not name.startswith(("_", "$"))
    }


def main():
    args = sys.argv[1:]
    (
        built_dir,
        repo_dir,
        fa_metadata_file,
        fa_version,
        nf_ref,
        nf_commit,
        output_path,
        fa_map_file,
    ) = args[:8]
    custom_meta_file = args[8] if len(args) > 8 else ""

    ttf_path = _pick_canonical_ttf(built_dir)
    font = TTFont(ttf_path)
    cmap = font.getBestCmap()
    font_codepoints = set(cmap.keys())

    # native-hex -> relocated-hex for free FA icons the merge step had to
    # move off a colliding curated codepoint (see _merge_fa.py).
    fa_map = _load_json(fa_map_file) or {}
    relocations = fa_map.get("relocations", {}) if isinstance(fa_map, dict) else {}
    # name -> Plane-16 hex codepoint for local custom SVG icons (step 5).
    customs = fa_map.get("custom", {}) if isinstance(fa_map, dict) else {}
    # name -> {label, terms, aliases, comment, ...} sidecar (optional).
    custom_meta = _load_custom_meta(custom_meta_file)

    nf_glyphs_raw = _load_json(os.path.join(repo_dir, "glyphnames.json")) or {}
    nf_glyphs = {
        name: info for name, info in nf_glyphs_raw.items()
        if name != "METADATA" and isinstance(info, dict) and "code" in info
    }

    fa_icons_raw = _load_json(fa_metadata_file) or {}
    fa_icons = {
        name: info for name, info in fa_icons_raw.items()
        if isinstance(info, dict) and isinstance(info.get("unicode"), str)
    }

    glyphs = {}
    by_source = {
        "nerd-fonts-curated": 0,
        "font-awesome-7": 0,
        "custom-svg": 0,
        "unicode-only": 0,
    }
    used = set()

    for nf_name, info in nf_glyphs.items():
        try:
            cp = int(info["code"], 16)
        except (TypeError, ValueError):
            continue
        if cp not in font_codepoints:
            continue
        entry = {
            "code": format(cp, "04x"),
            "char": chr(cp),
            "source": "nerd-fonts-curated",
        }
        parts = nf_name.split("-", 2)
        if len(parts) >= 2 and parts[0] == "nf":
            entry["collection"] = NF_COLLECTION_NAMES.get(parts[1], parts[1])
        # Cross-reference FA metadata for nf-fa-* entries so curated FA
        # icons inherit FA's natural-language tags too.
        if len(parts) == 3 and parts[1] == "fa":
            fa_lookup = parts[2].replace("_", "-")
            fa_info = fa_icons.get(fa_lookup)
            if fa_info:
                _enrich_with_fa(entry, fa_info)
        unicode_name = _safe_unicode_name(cp)
        if unicode_name:
            entry["unicode_name"] = unicode_name
        glyphs[nf_name] = entry
        used.add(cp)
        by_source["nerd-fonts-curated"] += 1

    for fa_name, fa_info in fa_icons.items():
        try:
            native = int(fa_info["unicode"], 16)
        except (TypeError, ValueError):
            continue
        # If this icon was relocated off a colliding curated codepoint,
        # follow it to its Plane-16 landing slot; otherwise it sits at its
        # native FA codepoint.
        relocated_hex = relocations.get(format(native, "04x"))
        cp = int(relocated_hex, 16) if relocated_hex else native
        if cp not in font_codepoints or cp in used:
            continue
        entry = {
            "code": format(cp, "04x"),
            "char": chr(cp),
            "source": "font-awesome-7",
            "collection": "font-awesome",
        }
        if relocated_hex:
            entry["relocated_from"] = format(native, "04x")
        _enrich_with_fa(entry, fa_info)
        unicode_name = _safe_unicode_name(cp)
        if unicode_name:
            entry["unicode_name"] = unicode_name
        glyphs["fa-" + fa_name] = entry
        used.add(cp)
        by_source["font-awesome-7"] += 1

    # Local custom SVG icons, keyed `usr-<filename>` (the `usr-` namespace keeps
    # them distinct from FA 7's `fa-*` additions in a picker; cursor-ai.svg ->
    # usr-cursor-ai). Per-icon metadata comes from custom-icons/metadata.json
    # when present, otherwise falls back to hints derived from the file name.
    for custom_name, custom_hex in customs.items():
        try:
            cp = int(custom_hex, 16)
        except (TypeError, ValueError):
            continue
        if cp not in font_codepoints or cp in used:
            continue
        meta = custom_meta.get(custom_name, {})
        keywords = meta.get("keywords")
        if not isinstance(keywords, list) or not keywords:
            keywords = meta.get("terms")  # accept the older field name
        if not isinstance(keywords, list) or not keywords:
            keywords = [t for t in custom_name.replace("_", "-").split("-") if t]
        else:
            keywords = [str(t) for t in keywords]
        entry = {
            "code": format(cp, "04x"),
            "char": chr(cp),
            "source": "custom-svg",
            "collection": "custom",
            "keywords": keywords,
        }
        shortcode = meta.get("shortcode")
        if isinstance(shortcode, str) and shortcode:
            entry["shortcode"] = shortcode
        aliases = meta.get("aliases")
        if isinstance(aliases, list) and aliases:
            entry["aliases"] = [str(a) for a in aliases]
        description = meta.get("description") or meta.get("comment") or meta.get("notes")
        if isinstance(description, str) and description:
            entry["description"] = description
        glyphs["usr-" + custom_name] = entry
        used.add(cp)
        by_source["custom-svg"] += 1

    for cp in sorted(font_codepoints - used):
        name = _safe_unicode_name(cp)
        if not name:
            continue
        glyphs["u-{:04x}".format(cp)] = {
            "code": format(cp, "04x"),
            "char": chr(cp),
            "source": "unicode-only",
            "unicode_name": name,
        }
        by_source["unicode-only"] += 1

    out = {
        "schema_version": 1,
        "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "font_family": "Symbols Nerd Font",
        "font_files": sorted(
            os.path.abspath(os.path.join(built_dir, f))
            for f in os.listdir(built_dir)
            if f.endswith(".ttf") and f.startswith("Symbols")
        ),
        "sources": {
            "nerd_fonts_ref": nf_ref or None,
            "nerd_fonts_commit": nf_commit or None,
            "font_awesome_version": fa_version or None,
            "font_awesome_metadata_file": fa_metadata_file or None,
        },
        "stats": {
            "total_codepoints_in_font": len(font_codepoints),
            "total_named_entries": len(glyphs),
            "by_source": by_source,
        },
        "glyphs": glyphs,
    }

    Path(output_path).parent.mkdir(parents=True, exist_ok=True)
    with open(output_path, "w", encoding="utf-8") as fh:
        json.dump(out, fh, ensure_ascii=False, indent=2, sort_keys=True)
        fh.write("\n")

    print(
        "glyphs.json: {total:,} entries "
        "(curated={c:,}, fa7={f:,}, custom={x:,}, unicode-only={u:,}) -> {p}".format(
            total=len(glyphs),
            c=by_source["nerd-fonts-curated"],
            f=by_source["font-awesome-7"],
            x=by_source["custom-svg"],
            u=by_source["unicode-only"],
            p=output_path,
        )
    )


if __name__ == "__main__":
    main()
PYEOF

  # Optional sidecar metadata for the custom SVG icons (label/terms/aliases/
  # comment/code). Resolved in step 5 as CUSTOM_META; absent on a default setup.
  custom_meta_file="${CUSTOM_META:-}"
  [[ -n "${custom_meta_file}" ]] && info "custom icon metadata: ${custom_meta_file}"

  json_out_path="${JSON_OUT_DIR}/glyphs.json"
  mkdir -p "${JSON_OUT_DIR}"
  "${PY_VENV_BIN}" "${GLYPHS_PY}" \
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
# We emit ONE file, jetbrains-mono-nerd-font.css, embedding the fully-embedded
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
#   jetbrains-mono-nerd-font.css  -> save in Blink as "JetBrainsMono NF"
log "step 10  emit Blink Shell CSS"

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
  # Remove the legacy two-file output (Propo/Mono symbols fallback) so a stale
  # copy isn't advertised by serve-blink-fonts.sh alongside the new single file.
  rm -f "${BLINK_OUT_DIR}"/jetbrains-custom-nerd-fonts.css \
        "${BLINK_OUT_DIR}"/jetbrains-custom-nerd-fonts-mono.css
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
    EMOJI_SPLIT_PY="${WORK_DIR}/_emoji_noto.py"
    cat >"${EMOJI_SPLIT_PY}" <<'PYEOF'
"""Subset Noto OT-SVG to its cmap-reachable emoji and split into two WOFF2 faces
(wide / narrow) for the Blink CSS. Width comes from hterm's own wcwidth table
(hterm_all.js -> lib.wc.unambiguous), baked in below so classification matches
Blink exactly (unicodedata's east_asian_width does not). Layout features are
dropped so ZWJ/skin-tone/flag closure can't inflate the SVG-document count past
Safari's ~2000 ceiling. Each glyph is embedded once (wide glyphs in one file,
narrow in the other). Prints four lines: wide-range, narrow-range, wide-woff2,
narrow-woff2; per-face SVG-document counts go to stderr."""
import sys, os
from fontTools.ttLib import TTFont
from fontTools import subset

# hterm.wc.unambiguous: width-2 (wide) intervals. Anything not here is width 1.
HTERM_WIDE = [
    (4352,4447),(8986,8987),(9001,9002),(9193,9196),(9200,9200),(9203,9203),
    (9725,9726),(9748,9749),(9800,9811),(9855,9855),(9875,9875),(9889,9889),
    (9898,9899),(9917,9918),(9924,9925),(9934,9934),(9940,9940),(9962,9962),
    (9970,9971),(9973,9973),(9978,9978),(9981,9981),(9989,9989),(9994,9995),
    (10024,10024),(10060,10060),(10062,10062),(10067,10069),(10071,10071),
    (10133,10135),(10160,10160),(10175,10175),(11035,11036),(11088,11088),
    (11093,11093),(11904,12255),(12272,12350),(12352,12871),(12880,19903),
    (19968,42191),(43360,43391),(44032,55203),(63744,64255),(65040,65049),
    (65072,65135),(65281,65376),(65504,65510),(94176,94180),(94192,94193),
    (94208,101589),(101632,101640),(110576,110579),(110581,110587),
    (110589,110590),(110592,110895),(110898,110898),(110928,110930),
    (110933,110933),(110948,110951),(110960,111359),(126980,126980),
    (127183,127183),(127374,127374),(127377,127386),(127488,127490),
    (127504,127547),(127552,127560),(127568,127569),(127584,127589),
    (127744,127776),(127789,127797),(127799,127868),(127870,127891),
    (127904,127946),(127951,127955),(127968,127984),(127988,127988),
    (127992,128062),(128064,128064),(128066,128252),(128255,128317),
    (128331,128334),(128336,128359),(128378,128378),(128405,128406),
    (128420,128420),(128507,128591),(128640,128709),(128716,128716),
    (128720,128722),(128725,128727),(128732,128735),(128747,128748),
    (128756,128764),(128992,129003),(129008,129008),(129292,129338),
    (129340,129349),(129351,129535),(129648,129660),(129664,129672),
    (129680,129725),(129727,129733),(129742,129755),(129760,129768),
    (129776,129784),(131072,196605),(196608,262141),
]

def is_wide(cp):
    for lo, hi in HTERM_WIDE:
        if lo <= cp <= hi:
            return True
    return False

def is_text(cp):
    # Keep JBM's own glyph for these: the whole ASCII/Latin-1 text region (digits,
    # # and * keycap bases, (c)/(r)), plus TM and the zero-width joiner/selectors.
    return cp < 0x2000 or cp in (0x2122, 0x200D, 0xFE0F, 0x20E3)

def compress(xs):
    runs, i = [], 0
    while i < len(xs):
        j = i
        while j + 1 < len(xs) and xs[j + 1] == xs[j] + 1:
            j += 1
        runs.append("U+%X" % xs[i] if i == j else "U+%X-%X" % (xs[i], xs[j]))
        i = j + 1
    return ", ".join(runs)

def subset_to(unicodes, path):
    f = TTFont(sys.argv[1])
    ss = subset.Subsetter()
    # Drop layout closure so ligature/ZWJ glyphs can't pull extra SVG docs back in.
    ss.options.layout_features = []
    ss.options.layout_scripts = []
    ss.options.notdef_outline = False
    ss.populate(unicodes=unicodes)
    ss.subset(f)
    f.flavor = "woff2"
    f.save(path)
    g = TTFont(path)
    return len(g["SVG "].docList) if "SVG " in g else 0

outdir = sys.argv[2]
os.makedirs(outdir, exist_ok=True)
cmap = TTFont(sys.argv[1]).getBestCmap()
emoji = sorted(c for c in cmap if not is_text(c))
wide = [c for c in emoji if is_wide(c)]
narrow = [c for c in emoji if not is_wide(c)]
wide_path = os.path.join(outdir, "noto-emoji-wide.woff2")
narrow_path = os.path.join(outdir, "noto-emoji-narrow.woff2")
wdocs = subset_to(wide, wide_path) if wide else 0
ndocs = subset_to(narrow, narrow_path) if narrow else 0
sys.stderr.write("  SVG docs: wide=%d narrow=%d (Safari ceiling ~2000)\n" % (wdocs, ndocs))
print(compress(wide))
print(compress(narrow))
print(wide_path if wide else "")
print(narrow_path if narrow else "")
PYEOF
    EMOJI_OUT_DIR="${WORK_DIR}/emoji-split"
    EMOJI_SPLIT="$("${PY_VENV_BIN}" "${EMOJI_SPLIT_PY}" "${NOTO_EMOJI_OTF}" "${EMOJI_OUT_DIR}")"
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
  emit_blink_css "${JBM_TTF}" "${BLINK_OUT_DIR}/jetbrains-mono-nerd-font.css" \
    "JetBrainsMono NF" "${EMOJI_WIDE_WOFF2}" "${EMOJI_NARROW_WOFF2}" \
    "${EMOJI_WIDE}" "${EMOJI_NARROW}" "${EMOJI_WIDE_ADJUST}" "${EMOJI_NARROW_ADJUST}"
  info 'wrote jetbrains-mono-nerd-font.css -> save in Blink as "JetBrainsMono NF"'
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
    - ${BLINK_OUT_DIR:-(disabled)}/jetbrains-mono-nerd-font.css  -> save in Blink as "JetBrainsMono NF"

${C_BLU}== Install manually if you skipped --install ==${C_RST}
  cp -f "${OUT_DIR}"/Symbols*.ttf "${OUT_DIR}"/JetBrains*.ttf ~/Library/Fonts/
  # Linux: cp ... ~/.local/share/fonts/ && fc-cache -fv

${C_BLU}== Import the font into Blink Shell ==${C_RST}
  # Serve the CSS dir over HTTP, then in Blink: Settings -> Appearance ->
  # Add a new font -> point it at the printed URL. Save the font under the EXACT
  # name "JetBrainsMono NF" (must match the font-family inside the .css). One
  # self-contained font: text + icons + embedded Noto OT-SVG colour emoji, with
  # an iPad system-font fallback chain (PingFang SC / Hiragino Sans / Euphemia
  # UCAS / Apple Symbols) referenced by name. Menlo is auto-appended by Blink.
  ./serve-blink-fonts.sh        # serves ${BLINK_OUT_DIR:-~/.local/share/fonts/blink} on :8000

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
