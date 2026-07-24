#!/usr/bin/env zsh
# zellij-session.zsh — COMPAT SHIM (mux migration Phase 1).
#
# resolve_session / zellij_wezterm_sessions / zellij_attached_sessions moved
# VERBATIM into ~/.local/lib/mux/zellij.zsh (the Zellij backend of the mux::*
# shim); they keep their names there — this file exists so the current
# consumers (zellij-open, quick-launch-window, tab-edit) keep sourcing the
# path they always did. They rewire to mux::* in Phase 6.
source "$HOME/.local/lib/mux/zellij.zsh"
