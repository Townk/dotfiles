# mux-tab-path.sh — keep the tmux tab pill's path fresh.
#
# The pill shows a project-aware, abbreviated cwd (zj-hud's
# render_path_body). tmux does NOT evaluate #(shell-command) inside
# window-status-format — the same #() runs from status-right and never from
# the pill (measured 2026-07-28) — so the value is PUSHED onto the window as
# @win_path instead of pulled by the format.
#
# Here is one of the two push points: the shell, whenever it changes
# directory, which is exactly when the answer changes. The other is tmux's
# pane-focus-in hook (status.conf), covering the case where the focused pane
# changes without anyone cd'ing.
#
# Cheap by construction: one backgrounded call per cd, only inside tmux, and
# nothing at all in a zellij pane (zj-hud computes its own).
[[ -o interactive ]] || return 0

_mux_tab_path_stamp() {
  [[ -n "${TMUX:-}" ]] || return 0
  local helper="${XDG_CONFIG_HOME:-$HOME/.config}/mux/scripts/mux-tab-path"
  [[ -x "$helper" ]] || return 0
  # Backgrounded: a cd must never wait on a tmux round-trip.
  "$helper" --stamp "${TMUX_PANE:-}" "$PWD" &!
  return 0
}
autoload -Uz add-zsh-hook
add-zsh-hook chpwd _mux_tab_path_stamp
# Stamp once at startup too: a new pane starts in a directory nobody cd'd to.
_mux_tab_path_stamp
