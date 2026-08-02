#!/usr/bin/env zsh
# pick-adapter.zsh — shared shell for the zellij floating-pane picker adapters.
#
# The four picker adapters (pick-glyph-zellij, pick-gitmoji-zellij,
# pick-clipboard-zellij, quick-launch-zellij) were near-identical: resolve a
# <PREFIX>_BIN, guard that it is executable, export the floating-pane fzf
# geometry (<PREFIX>_HEIGHT=-4, _MARGIN=0,0,0,0, _PADDING=0,2,0,2), request the
# borderless look, then exec the picker. That body now lives here once, called
# with a ~two-line adapter.
#
# HEIGHT=-4 is a hard contract with zellij-modal: that script prints a 3-row
# title block, so a picker filling the pane sizes fzf --height to -4 (pane
# height minus the block, plus the bottom frame row). Changing it misaligns the
# modal header — keep it -4 (see executable_zellij-modal's title-block note).
#
# no-border style (shared-lib consolidation Wave 2, group C5, Decision 1): the
# form is the --no-border CLI flag. Pass --flag-no-border and the adapter puts
# --no-border on the picker's command line — all four pickers now parse it
# (pick-glyph / pick-gitmoji always did; pick-clipboard gained the flag and the
# quick-launch dispatcher's `menu` forwards it to quick-launch-pick). The env
# form is retained as a generic fallback: omit --flag-no-border and the adapter
# exports <PREFIX>_NO_BORDER=1 instead, for any future picker whose reachable
# entrypoint only reads the env var.
#
# Usage:
#   zj_adapter::exec <ENV_PREFIX> <default_bin> [--flag-no-border] -- <args…>
#
#   <ENV_PREFIX>       e.g. PICK_GLYPH. Names the _BIN / _HEIGHT / _MARGIN /
#                      _PADDING / _NO_BORDER env vars this adapter honors.
#   <default_bin>      Absolute path used when <ENV_PREFIX>_BIN is unset/empty.
#   --flag-no-border   Emit no-border as the --no-border CLI flag; otherwise as
#                      the <ENV_PREFIX>_NO_BORDER=1 env var.
#   -- <args…>         Everything after -- is passed to the picker on exec.

zj_adapter::exec() {
  local prefix="${1:?zj_adapter::exec: missing ENV_PREFIX}"
  local default_bin="${2:?zj_adapter::exec: missing default_bin}"
  shift 2

  local flag_no_border=0
  while (( $# > 0 )); do
    case "$1" in
      --flag-no-border) flag_no_border=1; shift ;;
      --) shift; break ;;
      *)
        print -ru2 -- "zj_adapter::exec: unexpected argument: $1"
        return 2
        ;;
    esac
  done

  # Adapter name for diagnostics: the running script, with chezmoi's source-tree
  # executable_ prefix stripped so the message matches the deployed name in both
  # the deployed tree and the repo checkout. $0 is the function under FUNCTION_
  # ARGZERO, so use ZSH_ARGZERO (the top-level script).
  local name="${ZSH_ARGZERO:t}"
  name="${name#executable_}"

  # Resolve the picker: <PREFIX>_BIN override, else the default. Kept local (not
  # exported) — matching the originals, which never exported <PREFIX>_BIN.
  local bin_var="${prefix}_BIN"
  local bin="${(P)bin_var:-$default_bin}"
  [[ -x "$bin" ]] || {
    print -ru2 -- "${name}: missing or non-executable: $bin"
    exit 1
  }

  # Floating-pane fzf geometry. HEIGHT=-4 is the zellij-modal title-block
  # contract (see header). Honor a caller override (:- defaults on unset OR
  # empty, matching the originals' "${VAR:-default}").
  local hv="${prefix}_HEIGHT" mv="${prefix}_MARGIN" pv="${prefix}_PADDING"
  export "${hv}=${(P)hv:--4}"
  export "${mv}=${(P)mv:-0,0,0,0}"
  export "${pv}=${(P)pv:-0,2,0,2}"

  # no-border: the floating pane already draws its own frame; a second fzf
  # border would just shave columns off the usable width.
  local -a border_args=()
  if (( flag_no_border )); then
    border_args=(--no-border)
  else
    export "${prefix}_NO_BORDER=1"
  fi

  exec "$bin" "${border_args[@]}" "$@"
}
