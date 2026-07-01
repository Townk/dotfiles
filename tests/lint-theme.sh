#!/usr/bin/env bash
# lint-theme.sh — guard the single-source theme.
#
# Fails if a raw 6-digit hex color (#rrggbb) appears in a themed config outside
# the single source (home/.chezmoidata/theme.yaml). Every themeable surface must
# resolve its colors from theme.yaml (via the generated palette bridges or a
# `{{ ... }}` template ref), so editing theme.active re-colors everything.
#
# The allowlist below exempts files where a raw hex is legitimate:
#   * runtime FALLBACKS that load the palette bridge and fall back to literals
#     only if it is missing (nvim lualine, the file viewers, wezterm.lua, yazi
#     init.lua);
#   * NON-theme subsystems (Hammerspoon Stream Deck, the notify swatch, icon
#     assets) that are not terminal-theme surfaces;
#   * COMMENTS/examples that merely mention a hex (theme-apply override example,
#     a couple of explanatory comments).
# theme.yaml itself stores hex WITHOUT a leading '#', so it never matches.
#
# Add a file here (with a reason) only when its hex is a real fallback/non-theme
# value — never to paper over a color that should live in theme.yaml.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 2

matches=$(rg -n '#[0-9a-fA-F]{6}' home/ \
  -g '!**/Assets/**' -g '!*.svg' -g '!*.css' \
  -g '!**/hammerspoon/**' \
  -g '!**/lualine/**' \
  -g '!**/libexec/executable_ics-view' \
  -g '!**/libexec/executable_sqlite-view' \
  -g '!**/libexec/executable_disk-image-view' \
  -g '!**/wezterm/wezterm.lua' \
  -g '!**/yazi/init.lua' \
  -g '!**/ghostty/config' \
  -g '!**/lib/zellij.zsh' \
  -g '!**/bin/executable_ai-commit' \
  -g '!**/bin/executable_notify' \
  -g '!**/bin/executable_theme-apply' \
  2>/dev/null)

if [ -n "$matches" ]; then
  echo "theme lint: raw hex color(s) found outside theme.yaml — single-source them" >&2
  echo "via home/.chezmoidata/theme.yaml (a slot/role ref or palette bridge):" >&2
  echo "$matches" >&2
  echo "(if this is a genuine runtime fallback or non-theme asset, add the file to" >&2
  echo " the allowlist in tests/lint-theme.sh with a reason.)" >&2
  exit 1
fi

echo "theme lint: OK — no raw hex outside theme.yaml"
