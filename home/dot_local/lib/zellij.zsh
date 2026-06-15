#!/usr/bin/env zsh
# zellij.zsh — zj::* helpers for driving Zellij from the scripts stdlib.
#
# Off-PATH internal library, SOURCED (not executed):
#     source "$HOME/.local/lib/zellij.zsh"
#
# Today it provides one feature: zj::pick, a drop-in replacement for
# pick::start (the fzf picker engine in pick-common.zsh) that renders the
# picker in a floating Zellij pane — with the same catppuccin chrome as the
# glyph/gitmoji pickers — whenever we're inside a Zellij session, and falls
# back to an ordinary inline picker otherwise. A consumer adopts it by swapping
# `pick::start` for `zj::pick`; nothing else about its call site changes.
#
# We source pick-common.zsh because the no-Zellij path IS pick::start; that in
# turn pulls in the shared base (common.zsh).

_zj_self="${(%):-%x}"
source "$(dirname "$_zj_self")/pick-common.zsh"
unset _zj_self

# zj::available — true when we're inside a Zellij session AND a zellij binary
# is usable (so we can actually spawn the floating pane). ZELLIJ_BIN overrides
# the lookup; otherwise PATH resolution keeps this portable across the
# homebrew / dev-shell split instead of hardcoding /opt/homebrew.
zj::available() {
  [[ -n "${ZELLIJ:-}" ]] || return 1
  local bin="${ZELLIJ_BIN:-$(command -v zellij 2>/dev/null)}"
  [[ -n "$bin" && -x "$bin" ]]
}

# zj::pick [zj opts] [pick::start opts...] — read picker rows on stdin, print
# the selection on stdout. Identical contract to pick::start, plus optional
# caller-defined pane geometry:
#
#   --pane-width SPEC / --pane-height SPEC   the floating pane size, a percent
#       ("70%") or an integer cell/row count. Both go straight to zellij, which
#       accepts either. Defaults: 70% / 60% (the glyph picker size).
#
#   * No Zellij  -> exactly `pick::start "$@"` (inline, unchanged); pane opts
#                   are ignored.
#   * In Zellij  -> the fzf UI runs in a floating, pinned, rounded-frame pane
#                   via the shared zellij-modal scaffolding (catppuccin title
#                   block + focus-quirk handling), and the chosen value is
#                   captured back here through a FIFO.
#
# The modal title block reuses the picker's own --header text. The float fzf
# geometry (--no-border --height -4 ...) is injected after the caller's options
# so it wins, reproducing the glyph UX without the caller repeating it.
#
# Caveat: the capture channel returns the *selection*, so --copy-only and the
# insert-without-dismiss background sink are not meaningful through the float
# (their clipboard/cache side effects would land in the pane process, not
# here). Use plain return-value pickers with the floating path.
zj::pick() {
  local pane_w="70%" pane_h="60%"
  local header=""
  local -a pick_args=()
  while (($#)); do
    case "$1" in
      --pane-width)
        pane_w="${2:-}"
        shift 2
        ;;
      --pane-width=*)
        pane_w="${1#*=}"
        shift
        ;;
      --pane-height)
        pane_h="${2:-}"
        shift 2
        ;;
      --pane-height=*)
        pane_h="${1#*=}"
        shift
        ;;
      --header)
        header="${2:-}"
        pick_args+=("$1" "${2:-}")
        shift 2
        ;;
      --header=*)
        header="${1#--header=}"
        pick_args+=("$1")
        shift
        ;;
      *)
        pick_args+=("$1")
        shift
        ;;
    esac
  done

  if ! zj::available; then
    pick::start "${pick_args[@]}"
    return
  fi

  local bin="${ZELLIJ_BIN:-$(command -v zellij)}"
  local modal="$HOME/.config/zellij/scripts/zellij-modal"
  local picklist="$HOME/.local/libexec/pick-list"

  local tmp fifo
  tmp=$(mktemp "${TMPDIR:-/tmp}/zjpick.XXXXXX") || return 1
  fifo=$(mktemp -u "${TMPDIR:-/tmp}/zjpick-fifo.XXXXXX")
  if ! mkfifo -m 600 "$fifo" 2>/dev/null; then
    rm -f -- "$tmp"
    return 1
  fi

  # Stage the picker rows to a file: the float child is a separate process and
  # cannot read our stdin pipe, so it takes the rows as a file argument.
  cat >"$tmp"

  "$bin" action new-pane --floating --close-on-exit \
    --name "" --borderless false --pinned true \
    --width "$pane_w" --height "$pane_h" --cwd "$PWD" \
    -- "$modal" --title "$header" --capture "$fifo" \
    -- "$picklist" "${pick_args[@]}" --no-border --height -4 --margin 0,0,0,0 --padding 0,2,0,2 -- "$tmp"

  # Block until the modal writes the captured selection (exactly as long as the
  # user browses); empty means the user cancelled.
  local result
  result=$(cat "$fifo")
  rm -f -- "$fifo" "$tmp"

  [[ -n "$result" ]] || return 130
  print -r -- "$result"
}
