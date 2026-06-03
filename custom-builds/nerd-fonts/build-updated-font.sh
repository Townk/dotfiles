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
#   3. Make sure FontForge is installed (asks before `brew install`).
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
#   7b. Re-size the FA glyphs. NATIVE-codepoint FA glyphs are left alone
#      (Ghostty applies its own icon constraint to them, like nf-fa-*).
#      RELOCATED FA glyphs (Plane-16 PUA) sit outside Ghostty's recognised
#      ranges, so Ghostty never upscales them and they render small; we bake
#      an upscale (FA_RELOCATED_SCALE) into ONLY those, about their centre,
#      via fontTools. See the long comment on the step itself.
#   7. Strip out codepoints that belong to the colour-emoji domain (Misc
#      Symbols + Dingbats U+2600-U+27BF and the SMP emoji planes
#      U+1F300-U+1FFFF) so terminal font lookups for ♻ ✏ 🚀 etc. fall
#      through to the system colour-emoji font (Apple Color Emoji on
#      macOS, Noto Emoji on Linux). See the long comment on the step
#      itself for the full rationale.
#   8. Use `fonttools` to verify the result and print a glyph-count diff
#      against the upstream-shipped TTFs in patched-fonts/NerdFontsSymbolsOnly.
#   9. Emit a glyphs.json index of every codepoint in the built font, with
#      Nerd-Fonts curated names, FA 7 names (prefixed `fa-` to avoid colliding
#      with the `nf-fa-*` curated set) and natural-language metadata
#      (labels, search terms, aliases, Unicode names). Written to
#      ~/.local/share/fonts/nerd-font/glyphs.json — handy for an fzf picker.
#  10. Print the caveats below so you remember them next year.
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
#   FA_RELOCATED_SCALE  Upscale baked into the Plane-16 relocated FA icons AND
#                    the local custom SVG icons in step 7b. Default: 1.30.
#                    These live outside Ghostty's Nerd-Font ranges so Ghostty
#                    won't size them up to match curated/native icons; this
#                    knob compensates. Tunable — recalibrate fast with
#                    ./recalibrate-fa.sh <scale> -i.
#   CUSTOM_ICON_DIR  Directory of local *.svg icons to bake into Plane-16 PUA
#                    glyphs at CUSTOM_START+. The filename (minus .svg) becomes
#                    the glyphs.json key `fa-<name>` (cursor-ai.svg ->
#                    fa-cursor-ai). Default: <script-dir>/custom-icons.
#                    Set CUSTOM_ICON_DIR="" to skip. An optional
#                    <dir>/metadata.json supplies per-icon label/terms/aliases/
#                    comment for glyphs.json (the custom-icon analogue of FA's
#                    icons.json) AND an optional "code" hex codepoint to PIN an
#                    icon to a fixed slot; missing entries fall back to the file
#                    name and auto-assignment.
#   CUSTOM_START     First auto-assigned codepoint of the custom-icon block
#                    (hex). Default: 10fb00 — above the relocation zone, whose
#                    icons now use the stable slot native+0x100000 (<=0x10f8ff).
#   FA_SCALE         Scale factor applied to the NATIVE-codepoint Font Awesome
#                    glyphs in step 7b. Default: 1.0 (no-op; Ghostty already
#                    constrains these to match the curated nf-fa-* size).
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
  if ! ask "Run 'brew install fontforge'?"; then
    die "Need FontForge."
  fi
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
if [[ ! -x "${PY_VENV_BIN}" ]]; then
  if ! ask "Create a Python venv with 'fonttools' for verification at ${VENV_DIR}?"; then
    warn "skipping fonttools verification."
    PY_VENV_BIN=""
  else
    if command -v uv >/dev/null 2>&1; then
      info "using uv to provision the venv"
      uv venv --quiet "${VENV_DIR}"
      uv pip install --quiet --python "${PY_VENV_BIN}" "fonttools>=4.55.0"
    else
      info "using stdlib venv + pip"
      command -v python3 >/dev/null 2>&1 || die "python3 not found on PATH."
      python3 -m venv "${VENV_DIR}"
      "${PY_VENV_BIN}" -m pip install --quiet --upgrade pip
      "${PY_VENV_BIN}" -m pip install --quiet "fonttools>=4.55.0"
    fi
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


def import_custom_svgs(dest, custom_dir, start_cp, meta, used):
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

    The icon name is the filename without extension (cursor-ai.svg ->
    fa-cursor-ai in glyphs.json). Each outline is normalised to the box the
    FA icons occupy in this combined OTF (em-tall, on the FA descent),
    aspect preserved, centred, advance = one em, so the patcher treats it
    like every other FA glyph; living in Plane-16 it also picks up the
    FA_RELOCATED_SCALE upscale in step 7b."""
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
        try:
            g.importOutlines(path)
        except Exception as exc:
            sys.stderr.write("  custom SVG import failed for %s: %s\n" % (fn, exc))
            continue
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
            "[custom_svg_dir] [custom_start_hex] [custom_meta_json]\n")
        return 2
    srcdir, outpath = argv[1], argv[2]
    icons_json       = argv[3] if len(argv) > 3 else ""
    curated_ttf      = argv[4] if len(argv) > 4 else ""
    fa_map_out       = argv[5] if len(argv) > 5 else ""
    reserved_start   = int(argv[6], 16) if len(argv) > 6 and argv[6] else 0
    custom_dir       = argv[7] if len(argv) > 7 else ""
    custom_start     = int(argv[8], 16) if len(argv) > 8 and argv[8] else 0
    custom_meta_file = argv[9] if len(argv) > 9 else ""
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
            if cp in occ:
                # Deterministic, update-stable slot: native + reserved_start.
                # FA's colliding free natives all sit in the BMP PUA
                # (0xE000..0xF8FF), so this lands in 0x10E000..0x10F8FF: well
                # inside Plane-16 and clear of the custom block above it. The
                # slot is a pure function of the icon's own native codepoint,
                # so it does NOT depend on which *other* icons collide — a
                # given icon keeps the same codepoint across FA / nerd-fonts
                # updates (unlike a running counter, which reshuffles).
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
                relocations["%04x" % cp] = "%04x" % new_cp
                fa_cps.append(new_cp)
            else:
                fa_cps.append(cp)
        print("  relocated %d colliding free FA icons (stable: native+U+%X) (%d kept at native)"
              % (len(relocations), reserved_start, len(fa_cps) - len(relocations)))

    # -- Import local custom SVG icons (Plane-16 PUA) --
    # Treated exactly like relocated FA icons downstream: they go through the
    # patcher's --custom path and pick up the FA_RELOCATED_SCALE upscale in
    # step 7b (they live outside the ranges Ghostty constrains). Codepoints
    # are pinnable via metadata.json so a TUI can hard-code them.
    customs = {}
    if custom_dir and custom_start and os.path.isdir(custom_dir):
        used = set(g.unicode for g in dest.glyphs()
                   if g.unicode is not None and g.unicode >= 0)
        meta = load_custom_meta(custom_meta_file)
        customs = import_custom_svgs(dest, custom_dir, custom_start, meta, used)
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
# Plane-16 PUA glyph and keyed `fa-<filename>` in glyphs.json (e.g.
# cursor-ai.svg -> fa-cursor-ai). Codepoints are STABLE: pin one with a "code"
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

"${FONTFORGE_BIN}" -lang=py -script "${MERGER_PY}" \
  "${FA_SRC_DIR}" "${FA_MERGED}" \
  "${FA_ICONS_JSON}" "${SHIPPED_REGULAR}" "${FA_MAP}" "${RESERVED_START}" \
  "${CUSTOM_ICON_DIR}" "${CUSTOM_START}" "${CUSTOM_META}" \
  2>&1 | tee "${LOG_FILE}"
[[ -f "${FA_MERGED}" ]] || die "FA merge produced no output."
done_ "merged FA -> ${FA_MERGED}"

# ===========================================================================
# Step 6 — Patch the empty Symbols SFD twice (Mono + Propo).
# ===========================================================================
log "step 6/8  patch Symbols-Only SFD (Mono + Propo variants)"

run_patcher() {
  local label="$1"; shift
  log "  -> [${label}] $*"
  ( cd "${REPO_DIR}" && \
    "${FONTFORGE_BIN}" -quiet -script "${PATCHER}" \
      --debug 1 \
      --no-progressbars \
      -c \
      --custom "${FA_MERGED}" \
      --ext ttf \
      --outputdir "${OUT_DIR}" \
      "$@" \
      "${BLANK_SFD}" \
  ) 2>&1 | tee -a "${LOG_FILE}" | grep -E '===>|WARNING:|ERROR' || true
}

run_patcher "Mono"  --single-width-glyphs
run_patcher "Propo" --variable-width-glyphs

BUILT=()
shopt -s nullglob
for f in "${OUT_DIR}"/Symbols*.ttf; do BUILT+=("$f"); done
shopt -u nullglob
[[ ${#BUILT[@]} -ge 2 ]] || die "expected 2 output TTFs in ${OUT_DIR}"
done_ "built ${#BUILT[@]} variants:"
for f in "${BUILT[@]}"; do
  info "  $(stat -f '%z' "$f" 2>/dev/null || stat -c '%s' "$f") bytes  $(basename "$f")"
done

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
import sys
from fontTools.ttLib import TTFont

# Inclusive (low, high) Unicode codepoint pairs to strip. Keep in sync
# with the long comment on `step 7/9` in build-updated-font.sh.
EMOJI_RANGES = [
    (0x2600,  0x27BF),    # Miscellaneous Symbols + Dingbats
    (0x1F300, 0x1FFFF),   # SMP emoji planes
]

def in_strip_range(cp):
    return any(lo <= cp <= hi for lo, hi in EMOJI_RANGES)

removed_total = 0
for path in sys.argv[1:]:
    font = TTFont(path)
    removed_in_file = 0
    for table in font["cmap"].tables:
        # `table.cmap` is a dict {codepoint: glyph_name}. Mutating it
        # while iterating is unsafe; collect first, delete second.
        victims = [cp for cp in table.cmap if in_strip_range(cp)]
        for cp in victims:
            del table.cmap[cp]
        removed_in_file += len(victims)
    font.save(path)
    print("  stripped %5d codepoints from %s" % (removed_in_file, path.rsplit('/', 1)[-1]))
    removed_total += removed_in_file

print("  total removed: %d codepoint→glyph mappings" % removed_total)
PYEOF
  "${PY_VENV_BIN}" "${STRIP_PY}" "${BUILT[@]}" 2>&1 | tee -a "${LOG_FILE}"
  done_ "emoji codepoints stripped"
else
  warn "skipped: no fonttools venv -> emoji codepoints remain in the cmap"
fi

# ===========================================================================
# Step 7b — Re-size Font Awesome glyphs (relocated icons need an upscale).
# ===========================================================================
# There are two distinct populations of FA glyphs, and they need DIFFERENT
# treatment because of how Ghostty sizes Nerd-Font icons:
#
#   * NATIVE-codepoint FA glyphs (kept at their upstream FA codepoint).
#     These land inside the Nerd-Fonts codepoint ranges that Ghostty
#     recognises, so Ghostty applies its own per-glyph icon constraint
#     (src/font/nerd_font_attributes.zig: size=.cover/.fit_cover1,
#     height=.icon) and scales them to icon_height_single at render time —
#     exactly like the curated nf-fa-* glyphs. They must be left at native
#     size (FA_SCALE=1.0); anything we bake in just fights Ghostty.
#
#   * RELOCATED FA glyphs (the colliding free icons the merge step moved
#     into the Plane-16 PUA at U+100000+, see fa-map.json "relocations").
#     Plane-16 is OUTSIDE every range in Ghostty's table, so Ghostty never
#     applies the icon constraint to them. Per its PUA rule it only scales
#     such glyphs DOWN to fit the cell, never UP — so they render at their
#     raw size while their curated/native neighbours get enlarged to
#     icon_height_single. The visible result: relocated icons look smaller.
#     We compensate by baking an upscale into ONLY these glyphs.
#
# Both scales transform the outline about its own bounding-box centre and
# leave the advance width untouched, so monospace cell alignment holds.
# Done via fontTools, never by editing font-patcher.
#
#   FA_RELOCATED_SCALE  upscale for the Plane-16 relocated icons. This is a
#                       perceptual match to Ghostty's icon_height_single and
#                       can drift with the primary font / line-height, so it
#                       is a tunable. Recalibrate quickly (no full rebuild)
#                       with ./recalibrate-fa.sh <scale> [dy] --install.
#   FA_RELOCATED_DY     vertical shift (em, +=up) for the relocated icons.
#                       Ghostty centres the icons it constrains (center1) but
#                       leaves relocated PUA glyphs on the baseline, so they
#                       render lower; this lifts them to match. Tunable.
#   FA_SCALE            global scale for the NATIVE FA glyphs (default 1.0;
#                       normally leave alone — Ghostty already sizes these).
log "step 7b/9 size Font Awesome glyphs"

FA_SCALE="${FA_SCALE:-1.0}"
FA_RELOCATED_SCALE="${FA_RELOCATED_SCALE:-0.90}"
FA_RELOCATED_DY="${FA_RELOCATED_DY:-0.0}"
if [[ -n "${PY_VENV_BIN}" && -x "${PY_VENV_BIN}" && -f "${FA_MAP}" ]]; then
  # Stash pristine (native-size) copies so recalibrate-fa.sh can re-derive
  # any scale without re-running the patcher.
  PRESCALE_DIR="${WORK_DIR}/prescale"
  mkdir -p "${PRESCALE_DIR}"
  for f in "${BUILT[@]}"; do cp -f "$f" "${PRESCALE_DIR}/$(basename "$f")"; done
  info "stashed pristine TTFs -> ${PRESCALE_DIR}"

  SCALE_PY="${WORK_DIR}/_scale_fa.py"
  cat >"${SCALE_PY}" <<'PYEOF'
"""Re-size and re-position Font Awesome glyphs about their own bounding-box
centre, leaving advance widths untouched so the monospace cell stays aligned.
Composite glyphs are decomposed to simple contours.

Applied to two disjoint codepoint sets (see step 7b in build-updated-font.sh):

  argv[2] fa_scale     -> NATIVE FA codepoints (everything in fa_cps that is
                          NOT a relocation target). Ghostty constrains these,
                          so this is normally 1.0 (no-op).
  argv[3] reloc_scale  -> RELOCATED codepoints (the Plane-16 values of the
                          "relocations" map). Ghostty does NOT constrain
                          these, so we bake the upscale here.
  argv[4] reloc_dy_em  -> vertical shift, in em, applied to the RELOCATED
                          glyphs only (positive = up). Ghostty vertically
                          centres the icons it constrains (center1) but leaves
                          relocated PUA glyphs on the baseline, so they sit
                          lower; this lifts them to match.
  argv[5:] paths       -> TTFs to edit in place.
"""
import json
import sys

from fontTools.ttLib import TTFont
from fontTools.misc.transform import Identity
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.pens.transformPen import TransformPen
from fontTools.pens.recordingPen import DecomposingRecordingPen

fa_map = json.load(open(sys.argv[1]))
fa_scale = float(sys.argv[2])
reloc_scale = float(sys.argv[3])
reloc_dy_em = float(sys.argv[4])
paths = sys.argv[5:]

# Relocated FA icons AND local custom SVG icons both live in Plane-16 PUA,
# outside the ranges Ghostty constrains, so both need the reloc upscale/lift.
relocated = {int(h, 16) for h in fa_map.get("relocations", {}).values()}
relocated |= {int(h, 16) for h in fa_map.get("custom", {}).values()}
all_fa = [int(h, 16) for h in fa_map.get("fa_cps", [])]


def transform_one(glyf, glyph_set, gname, factor, dy_units):
    glyph = glyf[gname]
    glyph.recalcBounds(glyf)
    if glyph.numberOfContours == 0:
        return False
    cx = (glyph.xMin + glyph.xMax) / 2.0
    cy = (glyph.yMin + glyph.yMax) / 2.0
    rec = DecomposingRecordingPen(glyph_set)
    glyph.draw(rec, glyf)
    pen = TTGlyphPen(glyph_set)
    # Scale about the bbox centre, then lift by dy_units.
    t = Identity.translate(0, dy_units).translate(cx, cy).scale(factor).translate(-cx, -cy)
    rec.replay(TransformPen(pen, t))
    new_glyph = pen.glyph()
    new_glyph.recalcBounds(glyf)
    glyf[gname] = new_glyph
    return True


for path in paths:
    font = TTFont(path)
    upm = font["head"].unitsPerEm
    dy_units = reloc_dy_em * upm
    glyf = font["glyf"]
    cmap = font.getBestCmap()
    gs = font.getGlyphSet()
    n_native = n_reloc = 0
    for cp in all_fa:
        gname = cmap.get(cp)
        if not gname:
            continue
        if cp in relocated:
            factor, dy = reloc_scale, dy_units
        else:
            factor, dy = fa_scale, 0.0
        if factor == 1.0 and dy == 0.0:
            continue
        if transform_one(glyf, gs, gname, factor, dy):
            if cp in relocated:
                n_reloc += 1
            else:
                n_native += 1
    font.save(path)
    print("  %s: native x%.3f (%d), relocated x%.3f dy=%+.3fem (%d)"
          % (path.rsplit('/', 1)[-1], fa_scale, n_native, reloc_scale, reloc_dy_em, n_reloc))
PYEOF
  "${PY_VENV_BIN}" "${SCALE_PY}" "${FA_MAP}" "${FA_SCALE}" "${FA_RELOCATED_SCALE}" "${FA_RELOCATED_DY}" "${BUILT[@]}" \
    2>&1 | tee -a "${LOG_FILE}"
  done_ "FA sized (native x${FA_SCALE}, relocated x${FA_RELOCATED_SCALE} dy=${FA_RELOCATED_DY}em)"
else
  warn "skipped: needs fonttools venv + fa-map.json -> FA glyphs left at full size"
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

    # Local custom SVG icons, keyed `fa-<filename>` so they sit alongside the
    # FA 7 additions in a picker (cursor-ai.svg -> fa-cursor-ai). Per-icon
    # metadata comes from custom-icons/metadata.json when present, otherwise
    # falls back to hints derived from the file name.
    for custom_name, custom_hex in customs.items():
        try:
            cp = int(custom_hex, 16)
        except (TypeError, ValueError):
            continue
        if cp not in font_codepoints or cp in used:
            continue
        meta = custom_meta.get(custom_name, {})
        label = meta.get("label")
        if not isinstance(label, str) or not label:
            label = custom_name.replace("-", " ").replace("_", " ").title()
        terms = meta.get("terms")
        if not isinstance(terms, list) or not terms:
            terms = [t for t in custom_name.replace("_", "-").split("-") if t]
        else:
            terms = [str(t) for t in terms]
        entry = {
            "code": format(cp, "04x"),
            "char": chr(cp),
            "source": "custom-svg",
            "collection": "custom",
            "label": label,
            "terms": terms,
        }
        aliases = meta.get("aliases")
        if isinstance(aliases, list) and aliases:
            entry["aliases"] = [str(a) for a in aliases]
        comment = meta.get("comment") or meta.get("notes")
        if isinstance(comment, str) and comment:
            entry["comment"] = comment
        glyphs["fa-" + custom_name] = entry
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
# Done. Print caveats.
# ===========================================================================
cat <<EOF

${C_GRN}Build complete.${C_RST}

  Output directory: ${OUT_DIR}
  Variants:
    - SymbolsNerdFont-Regular.ttf       (variable-width / "Propo")
    - SymbolsNerdFontMono-Regular.ttf   (monospaced)
  Glyph index:
    - ${JSON_OUT_DIR:-(disabled)}/glyphs.json

${C_BLU}== Install manually if you skipped --install ==${C_RST}
  cp -f "${OUT_DIR}"/Symbols*.ttf ~/Library/Fonts/
  # Linux: cp ... ~/.local/share/fonts/ && fc-cache -fv

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
