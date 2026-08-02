#!/usr/bin/env bash
# generate-theme.sh — render every app's theme from .chezmoidata/theme.yaml
# directly into the home dir as the `chezmoi-system` theme.
#
# This is the single generator for the unified theme: theme.yaml is the source,
# and the per-app theme files it produces (colorschemes, syntax themes, palettes,
# plugins) are BUILD ARTIFACTS — generated here, never committed (see .gitignore /
# the repo-root .gitignore guards). Each app's config points at `chezmoi-system`.
#
# The rendering logic still lives in Go templates (templates/*.tmpl); we run them
# OUTSIDE chezmoi's managed-file flow via `chezmoi execute-template`, which has
# full access to .chezmoidata (.theme.*) and the shared .chezmoitemplates partials
# (hex2rgb, …). So nothing was re-implemented — the templates just moved here.
#
#   generate-theme.sh            # render into $HOME
#   THEME_DEST=/tmp/x …          # render into an alternate root (for diffing/tests)
#
# Invoked on apply by home/.chezmoiscripts/run_onchange_after_54-generate-theme.sh
# whenever theme.yaml or this generator/templates change; runnable by hand any time.

set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TPL="$SELF/templates"
DEST="${THEME_DEST:-$HOME}"

# Source-guard: sourcing this file must NOT run the render pipeline — it writes
# generated theme files into $HOME/$THEME_DEST. Tests invoke it as a subprocess
# (with THEME_DEST pointed at a temp dir); only a real exec proceeds. This is the
# guard whose absence (on build-zsh.sh) let sourcing an unguarded build script
# clobber a live artifact.
[[ "${BASH_SOURCE[0]}" == "${0}" ]] || return 0

command -v chezmoi >/dev/null 2>&1 || {
  echo "generate-theme: chezmoi not found on PATH" >&2
  exit 1
}

# render <template-basename> <dest-relative-path>
# Renders to a temp file in the SAME directory and mv's it over $out only on a
# successful render, so a template/chezmoi failure never truncates the LIVE
# artifact (the redirect-into-live bug). A failed render returns non-zero, which
# under `set -e` aborts the generator — surfacing the breakage instead of
# leaving a half-written theme file behind.
render() {
  local tpl="$TPL/$1" out="$DEST/$2"
  [[ -r "$tpl" ]] || { echo "generate-theme: missing template $tpl" >&2; return 1; }
  mkdir -p "$(dirname "$out")"
  local tmp="$out.tmp.$$"
  if ! chezmoi execute-template <"$tpl" >"$tmp" 2>/dev/null; then
    rm -f "$tmp"
    echo "generate-theme: render failed for $2 (live file left intact)" >&2
    return 1
  fi
  mv -f "$tmp" "$out"
  echo "  ✓ $2"
}

echo "generate-theme: rendering chezmoi-system into $DEST"

# --- shared palette bridges (consumed by shells, viewers, nvim, wezterm, yazi) -
render palette.zsh.tmpl  ".config/theme/chezmoi-system.zsh"
render palette.json.tmpl ".config/theme/chezmoi-system.json"
render palette.lua.tmpl  ".config/theme/chezmoi-system.lua"

# --- terminals ---------------------------------------------------------------
render ghostty.tmpl           ".config/ghostty/themes/chezmoi-system"
render wezterm.toml.tmpl      ".config/wezterm/colors/chezmoi-system.toml"
render tint-palette.toml.tmpl ".config/wezterm/tint-palette.toml"

# --- viewers / tools ---------------------------------------------------------
render bat.tmTheme.tmpl   ".config/bat/themes/chezmoi-system.tmTheme"
render glow.json.tmpl     ".config/glow/chezmoi-system.json"
render themes.sh.tmpl     ".config/zsh/themes.sh"

# --- zellij ------------------------------------------------------------------
# Pristine theme block is `chezmoi-system-base`; theme-apply derives the active
# `chezmoi-system.kdl` (block `chezmoi-system`) by overlaying any session tint.
render zellij-theme.kdl.tmpl ".config/zellij/themes/chezmoi-system-base.kdl"

# --- tmux ---------------------------------------------------------------------
# Pristine theme is `chezmoi-system-base.conf`; theme-apply derives the active
# `chezmoi-system.conf` by overlaying any session tint (mirrors the zellij pair).
render tmux-theme.conf.tmpl ".config/tmux/themes/chezmoi-system-base.conf"

# --- pi agent ----------------------------------------------------------------
render pi.json.tmpl ".pi/agent/themes/chezmoi-system.json"

# --- Claude Code -------------------------------------------------------------
# Custom theme JSON discovered from ~/.claude/themes/; selected via settings.json
# ("theme": "custom:chezmoi-system", set by home/dot_claude/modify_settings.json).
# Claude watches the dir and reloads on change.
render claude-code.json.tmpl ".claude/themes/chezmoi-system.json"

# --- yazi (flavor) -----------------------------------------------------------
# yazi reads a fixed theme.toml; to carry the chezmoi-system name we ship a
# flavor. Under a flavor yazi ignores syntect_theme and uses the flavor's own
# tmtheme.xml for code preview, so we symlink that to the bat syntax theme
# (same TextMate format, single source). theme.toml just selects the flavor.
render yazi-flavor.toml.tmpl ".config/yazi/flavors/chezmoi-system.yazi/flavor.toml"
ln -sfn "$DEST/.config/bat/themes/chezmoi-system.tmTheme" \
        "$DEST/.config/yazi/flavors/chezmoi-system.yazi/tmtheme.xml"
echo "  ✓ .config/yazi/flavors/chezmoi-system.yazi/tmtheme.xml (→ bat theme)"
mkdir -p "$DEST/.config/yazi"
yazi_theme_tmp="$DEST/.config/yazi/theme.toml.tmp.$$"
cat >"$yazi_theme_tmp" <<'EOF'
# GENERATED by custom-builds/theme/generate-theme.sh — selects the chezmoi-system flavor.
[flavor]
dark = "chezmoi-system"
light = "chezmoi-system"
EOF
mv -f "$yazi_theme_tmp" "$DEST/.config/yazi/theme.toml"
echo "  ✓ .config/yazi/theme.toml (flavor selector)"

# --- nvim (fetch-and-patch the catppuccin engine at a PINNED ref) ------------
# The ctp/ highlight-group definitions are vendored engine code (no theme.yaml
# data) fetched into a kept cache (build/, gitignored) and copied into $HOME, so
# they're not committed. PINNED: upstream restructures groups/ periodically, so a
# fixed SHA keeps the driver's module list valid. Bump = change NVIM_REF + re-run
# the verify diff. The driver + the 2 require-patches live in the generator.
#
# THEME_CTP_CACHE overrides the cache dir; THEME_CTP_NO_FETCH skips the network
# fetch/clone (both seams for tests + offline runs).
NVIM_REF="e068ab5f8261f23f6f71ffd8791ae40315b77b9c"
CTP_CACHE="${THEME_CTP_CACHE:-$SELF/build/catppuccin-nvim}"
if [[ -z "${THEME_CTP_NO_FETCH:-}" ]] && command -v git >/dev/null 2>&1; then
  if [[ -d "$CTP_CACHE/.git" ]]; then
    git -C "$CTP_CACHE" fetch --quiet origin 2>/dev/null || true
    git -C "$CTP_CACHE" checkout --quiet --detach "$NVIM_REF" 2>/dev/null || true
  else
    git clone --quiet https://github.com/catppuccin/nvim "$CTP_CACHE" 2>/dev/null \
      && git -C "$CTP_CACHE" checkout --quiet --detach "$NVIM_REF" 2>/dev/null || true
  fi
fi
if [[ -r "$CTP_CACHE/lua/catppuccin/groups/editor.lua" ]] && command -v perl >/dev/null 2>&1; then
  u="$CTP_CACHE/lua/catppuccin"
  ctp="$DEST/.config/nvim/lua/chezmoi_theme/ctp"
  # Build the whole engine tree in a sibling .new dir and only swap it over the
  # live ctp/ once every required source file has been copied + patched. A
  # renamed/removed upstream file makes a `cp` fail under `set -e` BEFORE the
  # swap, leaving the live nvim theme-engine dir untouched (was: rm -rf "$ctp"
  # first, which wiped :colorscheme's engine mid-loop with no rollback).
  ctp_new="$ctp.new"
  ctp_old="$ctp.old"
  rm -rf "$ctp_new" "$ctp_old"; mkdir -p "$ctp_new/groups/integrations"
  for g in editor syntax treesitter semantic_tokens lsp; do
    cp "$u/groups/$g.lua" "$ctp_new/groups/$g.lua"
  done
  for i in blink_cmp dap dap_ui flash gitsigns illuminate lsp_trouble mason mini \
           navic noice render_markdown snacks treesitter_context which_key; do
    cp "$u/groups/integrations/$i.lua" "$ctp_new/groups/integrations/$i.lua"
  done
  cp "$CTP_CACHE/LICENSE.md" "$ctp_new/LICENSE"
  # Re-apply our 2 local patches (drop the runtime require("catppuccin"…)).
  # perl -i is identical on macOS+Linux; \Q…\E quotes the literal match.
  perl -i -pe 's/\Qrequire("catppuccin").options.transparent_background\E/O.transparent_background -- vendored: use injected O (was require("catppuccin").options)/' \
    "$ctp_new/groups/integrations/mini.lua"
  perl -i -pe 's/\Qrequire("catppuccin.groups.syntax").get()\E/require("chezmoi_theme.ctp.groups.syntax").get() -- vendored path (was catppuccin.groups.syntax)/' \
    "$ctp_new/groups/integrations/render_markdown.lua"
  # Atomic swap with rollback: park the live tree, move the new one in, restore
  # on a failed move so :colorscheme is never left half-populated.
  mkdir -p "$(dirname "$ctp")"
  if [[ -e "$ctp" ]]; then
    mv -- "$ctp" "$ctp_old" || { echo "generate-theme: could not park live nvim ctp dir" >&2; exit 1; }
  fi
  if ! mv -- "$ctp_new" "$ctp"; then
    [[ -e "$ctp_old" ]] && mv -- "$ctp_old" "$ctp"
    echo "generate-theme: nvim ctp swap failed; rolled back live engine dir" >&2
    exit 1
  fi
  rm -rf "$ctp_old"
  mkdir -p "$DEST/.config/nvim/colors"
  cp "$TPL/nvim-driver.lua" "$DEST/.config/nvim/colors/chezmoi-system.lua"
  echo "  ✓ .config/nvim (ctp engine @ ${NVIM_REF:0:7} + colors/chezmoi-system.lua)"
else
  echo "  ⚠ nvim: catppuccin cache or perl unavailable — skipped (re-run with network+perl)" >&2
fi

# --- Blink Shell -------------------------------------------------------------
# Blink imports its theme over HTTP from the repo's assets/ dir (served by
# serve-blink-assets.sh), not from $HOME — so this one renders into the repo
# working tree (gitignored), regardless of $DEST. Render to a temp file and mv
# over the live asset only on success (same redirect-into-live guard as render).
BLINK_DIR="$SELF/../../assets/blink-shell"
if [[ -d "$BLINK_DIR" ]]; then
  blink_tmp="$BLINK_DIR/chezmoi-system.js.tmp.$$"
  if ! chezmoi execute-template <"$TPL/blink.js.tmpl" >"$blink_tmp" 2>/dev/null; then
    rm -f "$blink_tmp"
    echo "generate-theme: render failed for blink (live file left intact)" >&2
    exit 1
  fi
  mv -f "$blink_tmp" "$BLINK_DIR/chezmoi-system.js"
  echo "  ✓ assets/blink-shell/chezmoi-system.js"
fi

echo "generate-theme: done"
