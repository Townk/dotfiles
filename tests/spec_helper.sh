# spec_helper.sh — suite-wide hermetic guard for ShellSpec tests.
#
# Unset ambient Zellij environment variables so specs that do NOT explicitly
# stub/set ZELLIJ always take the non-Zellij (test) path.  Specs that need
# Zellij (workers, action-broker, zellij_spec, assist-agent-common) export
# ZELLIJ=1 themselves in their BeforeEach/setup(), which runs per-example and
# takes precedence over this module-level unset.
unset ZELLIJ ZELLIJ_PANE_ID ZELLIJ_SESSION_NAME

# Render the single-source palette (.chezmoidata/theme.yaml ->
# custom-builds/theme/templates/palette.zsh.tmpl) to a temp file and point
# common.zsh at it via THEME_PALETTE_FILE, so palette-dependent specs resolve the
# canonical, machine-independent palette rather than any per-machine build
# artifact the ambient shell exported (e.g. ~/.cache/theme/chezmoi-system.zsh,
# which carries this box's background wash). Overriding THEME_PALETTE_FILE here
# keeps the suite hermetic regardless of the invoking shell's environment.
_palette_tpl="custom-builds/theme/templates/palette.zsh.tmpl"
if command -v chezmoi >/dev/null 2>&1 && [ -f "$_palette_tpl" ]; then
  _palette_tmp="$(mktemp 2>/dev/null)"
  if [ -n "${_palette_tmp:-}" ] \
    && chezmoi execute-template <"$_palette_tpl" >"$_palette_tmp" 2>/dev/null \
    && [ -s "$_palette_tmp" ]; then
    export THEME_PALETTE_FILE="$_palette_tmp"
  fi
fi
