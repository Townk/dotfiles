#!/usr/bin/env bash
# render-matrix.sh — render the profile-gated chezmoi templates and the
# ignored-target list for ONE profile against a given source tree.
#
# Used two ways:
#   - by tests/profile-traits_spec.sh for semantic assertions;
#   - by hand during gate refactors, to byte-diff renders across profiles
#     against a captured baseline.
#
# Read-only outside --out: builds a throwaway chezmoi config there and never
# touches the repo, $HOME, or the machine's real chezmoi state.
#
# usage: render-matrix.sh --source <repo>/home --profile <p> --out <dir>
set -euo pipefail

SRC="" PROFILE="" OUT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --source)  SRC="$2"; shift 2 ;;
    --profile) PROFILE="$2"; shift 2 ;;
    --out)     OUT="$2"; shift 2 ;;
    *) echo "render-matrix: unknown arg: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$SRC" && -n "$PROFILE" && -n "$OUT" ]] || {
  echo "usage: render-matrix.sh --source <repo>/home --profile <p> --out <dir>" >&2
  exit 2
}

mkdir -p "$OUT/dest" "$OUT/rendered"
CFG="$OUT/chezmoi.toml"
cat > "$CFG" <<EOF
[data]
    profile = "$PROFILE"
    secretsSlot = ""
    [data.pi]
        [data.pi.devExtensions]
            pi-cockpit = ""
            pi-plannotator-bridge = ""
EOF

unset CHEZMOI_PROFILE
cz() { chezmoi --config "$CFG" --source "$SRC" --destination "$OUT/dest" "$@"; }

# Every template the server-profile work touches or that branches on
# .profile. Renders are compared byte-for-byte across refactors.
TEMPLATES=(
  dot_config/ai-playbook/config.toml.tmpl
  dot_config/git/config.tmpl
  dot_config/mise/conf.d/rclone.toml.tmpl
  dot_config/mise/conf.d/dev-shell.toml.tmpl
  dot_config/yazi/keymap.toml.tmpl
  dot_config/packages/Uvfile.tmpl
  dot_config/packages/Cargofile.tmpl
  dot_config/packages/Npmfile.tmpl
  dot_config/packages/Gofile.tmpl
  dot_config/packages/services.toml.tmpl
  dot_config/private_gnupg/private_gpg.conf.tmpl
  dot_pi/agent/modify_settings.json.tmpl
  dot_pi/agent-local/modify_settings.json.tmpl
  dot_local/share/zsh/site-functions/_ai-commit.tmpl
  dot_bashrc.tmpl
  dot_bash_profile.tmpl
  dot_profile.tmpl
  .chezmoiscripts/run_once_after_10-setup-bootstrap-tools.sh.tmpl
  .chezmoiscripts/run_once_after_15-setup-dev-shell-tools.sh.tmpl
  .chezmoiscripts/run_after_35-install-dev-shell-sudo-tool-links.sh.tmpl
  .chezmoiscripts/run_onchange_after_36-setup-gpg-agent-forwarding.sh.tmpl
  .chezmoiscripts/run_onchange_after_37-setup-clipboard-bridge.sh.tmpl
  .chezmoiscripts/run_onchange_after_36-generate-tab-edit-desktop.sh.tmpl
  .chezmoiscripts/run_onchange_after_40-install-snaps.sh.tmpl
  .chezmoiscripts/run_after_90-prune-dev-shell-state.sh.tmpl
)
for t in "${TEMPLATES[@]}"; do
  cz execute-template < "$SRC/$t" > "$OUT/rendered/${t//\//__}"
done
cz ignored | sort > "$OUT/ignored.txt"
