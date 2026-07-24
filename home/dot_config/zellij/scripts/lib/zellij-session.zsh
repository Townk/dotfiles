#!/usr/bin/env zsh
# zellij-session.zsh — COMPAT SHIM (mux migration Phase 1).
#
# resolve_session / zellij_wezterm_sessions / zellij_attached_sessions moved
# VERBATIM into ~/.local/lib/mux/zellij.zsh (the Zellij backend of the mux::*
# shim); they keep their names there — this file exists so the current
# consumers (zellij-open, quick-launch-window, tab-edit) keep sourcing the
# path they always did. They rewire to mux::* in Phase 6.
# Resolve the backend self-relatively first so repo/worktree consumers (specs,
# ad-hoc runs) get the checkout's copy; the deployed tree falls through to the
# chezmoi-rendered path under $HOME.
_zjs_self="${(%):-%x}"
_zjs_repo="${_zjs_self:A:h}/../../../../dot_local/lib/mux/zellij.zsh"
if [[ -r "$_zjs_repo" ]]; then
  source "$_zjs_repo"
else
  source "$HOME/.local/lib/mux/zellij.zsh"
fi
unset _zjs_self _zjs_repo
