#!/usr/bin/env zsh
# fzf-bindings.zsh — the fzf key bindings more than one fzf surface shares,
# each spelled ONCE. SOURCED, never executed.
#
# Three consumers render these: FZF_DEFAULT_OPTS and the fzf-tab zstyles
# (zsh/completion.sh, the interactive shell) and pick::build_fzf_args
# (pick-common.zsh, the standalone pickers — which clear FZF_DEFAULT_OPTS, so
# they cannot inherit them). The Ctrl+Space binding used to be written in all
# three, and the fzf-tab copy broke alone.
#
# A file of its own, constants only: the shell sources it on the way to a
# prompt and must not pay for common.zsh, and the pickers must not load the
# completion setup. It sources nothing and forks nothing.
#
# NO SPACE in any value: fzf-tab splits its fzf-flags on spaces, so a binding
# with one reaches fzf cut in two (tests/fzf_bindings_spec.sh). A binding
# that needs an argument is composed by its consumer from the parts below.

# Ctrl+Space: hide/show the preview. The helper first takes down a Kitty
# image the preview drew — it sits on the terminal, not in the pane, so
# hiding the pane alone leaves it over the list. Argument-free on purpose
# (see libexec/preview-wipe-images). pick-common binds ctrl-space to `toggle`
# instead under --multi: a different meaning, kept there.
typeset -g FZF_BIND_PREVIEW_TOGGLE='ctrl-space:execute-silent($HOME/.local/libexec/preview-wipe-images)+toggle-preview'

# Scrolling the preview without leaving the list.
typeset -ga FZF_BIND_PREVIEW_SCROLL=(
  shift-up:preview-up shift-down:preview-down
  alt-up:preview-page-up alt-down:preview-page-down
  alt-page-up:preview-page-up alt-page-down:preview-page-down
  alt-home:preview-top alt-end:preview-bottom
)

# Ctrl+O: open the highlighted file in the quick view. Key and command only —
# the argument differs per surface (plain fzf passes `{}`; fzf-tab passes
# `--fzf-tab-desc {2}`, its display key), so each composes
# "${FZF_BIND_OPEN_KEY}:execute-silent(${FZF_BIND_OPEN_CMD} <arg>)" — with the
# braces: a bare `$FZF_BIND_OPEN_KEY:e…` is zsh's :e modifier.
typeset -g FZF_BIND_OPEN_KEY='ctrl-o'
typeset -g FZF_BIND_OPEN_CMD='$HOME/.local/libexec/fzf-tab-preview-open'
