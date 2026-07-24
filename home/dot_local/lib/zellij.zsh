#!/usr/bin/env zsh
# zellij.zsh — COMPAT SHIM (mux migration Phase 1).
#
# The zj::* library moved into the mux-agnostic shim: mux.zsh (dispatcher +
# widgets) and mux/zellij.zsh (the Zellij backend — float mechanics + the
# session resolvers). Every zj::* name keeps working: they are defined as
# permanent aliases in mux.zsh (spec §2). Consumers migrate to mux::* in
# Phase 6; this file stays for anything sourcing the old path.
_zjc_self="${(%):-%x}"
source "$(dirname "$_zjc_self")/mux.zsh"
unset _zjc_self
