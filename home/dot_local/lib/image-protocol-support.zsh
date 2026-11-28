#!/usr/bin/env zsh
# image-protocol-support.zsh — what the terminal that will finally draw the
# pixels can take. SOURCED, never executed. Dual-shell (bash + zsh); no
# zsh-only runtime syntax.
#
#   get_terminal_image_protocol [outer]  its image protocols (Kitty / iTerm2 /
#                                        Sixel), rc 1 when it has none
#   get_chafa_format_args [outer]        the chafa arguments for it — THE one
#                                        answer (`preview`, term-quick-view)
#   get_image_max_bytes                  the largest single image stream it
#                                        takes; 0 = no cap
#
# [outer] names the outer terminal (a $TERM_PROGRAM value) for a caller that
# knows it by other means; without it the environment (tmux's, inside tmux)
# says.

get_terminal_image_protocol() {
  local host_support=()
  local final_capability=()

  # Safe expansion wraps to prevent 'parameter not set' errors
  local term_prog="${1:-${TERM_PROGRAM:-}}"
  local iterm_sess="${ITERM_SESSION_ID:-}"
  local lc_term="${LC_TERMINAL:-}"
  local tmux_env="${TMUX:-}"

  # 1. STEP ONE: Accumulate ALL protocols natively supported by the Host
  if [ "$term_prog" = "Alacritty" ] || [ "$term_prog" = "Apple_Terminal" ]; then
    : # Explicitly skip adding anything to the array
  elif [ "$term_prog" = "Ghostty" ] || [ "$term_prog" = "ghostty" ] || [ "$term_prog" = "Kitty" ] || [ "$term_prog" = "rex" ]; then
    # Rex draws with libghostty: Kitty graphics, no sixel. Measured
    # 2026-11-27 — it answers the Kitty query with OK and its device
    # attributes carry no sixel flag. It names itself in lower case.
    host_support+=("Kitty")
  elif [ -n "$iterm_sess" ] || [ "$lc_term" = "iTerm2" ]; then
    host_support+=("iTerm2" "Sixel")
  elif [ "$term_prog" = "WezTerm" ]; then
    host_support+=("Kitty" "Sixel" "iTerm2")
  elif [ "$term_prog" = "foot" ] || [ "$term_prog" = "contour" ]; then
    host_support+=("Sixel")
  fi

  # 2. STEP TWO: Resolve capability through the multiplexer constraint.
  # tmux: the pane env LIES — tmux sets TERM_PROGRAM=tmux — so the outer
  # terminal comes from the tmux SESSION environment, which our tmux.conf
  # keeps fresh via `update-environment TERM_PROGRAM` (same trick yazi's
  # Mux::term_program uses). Per-outer choice, validated live (Phase 0.5):
  #   WezTerm → native tmux sixel: tmux ingests the DCS, owns the placement,
  #             redraws it, and keeps coordinates pane-local. Passthrough
  #             tiers (iTerm2/kitty overlays) get wiped on tmux repaints,
  #             and WezTerm lacks kitty unicode placeholders (wezterm#4531).
  #   Ghostty → kitty unicode placeholders (placeholder cells are ordinary
  #             text to tmux, so they persist; Ghostty has no sixel).
  # Unknown outer (e.g. detached, or over SSH without the env) → no image
  # protocol; consumers fall back to character art.
  if [ -n "$tmux_env" ]; then
    local tmux_outer="${1:-}"
    [ -n "$tmux_outer" ] || tmux_outer=$(tmux show-environment TERM_PROGRAM 2>/dev/null)
    case "${tmux_outer#TERM_PROGRAM=}" in
      WezTerm) final_capability+=("Sixel") ;;
      Ghostty | ghostty | rex) final_capability+=("Kitty") ;;
    esac
  else
    # 3. STEP THREE: Direct Connection -> Inherit all natively supported protocols
    final_capability=("${host_support[@]}")
  fi

  # 4. STEP FOUR: Dynamic Output and Exit Code Generation
  if [ ${#final_capability[@]} -gt 0 ]; then
    echo "${final_capability[*]}"
    return 0
  else
    return 1
  fi
}

# get_chafa_format_args [outer] — the chafa arguments that draw a picture on
# this terminal, one line. The yazi shim (yazi/plugins/preview-shim.yazi/
# main.lua, draw_tty_sixel) carries the tmux-sixel line as a Lua literal — it
# cannot source this; tests/image_protocol_support_spec.sh keeps the two equal.
get_chafa_format_args() {
  local protocols

  # Inside tmux, chafa's defaults sabotage both viable tiers (chafa 1.18):
  # `--passthrough auto` wraps sixel in the passthrough envelope, handing the
  # image to the OUTER terminal as an overlay tmux wipes on its next repaint —
  # native (unwrapped) sixel is what tmux ingests, owns, and redraws. And the
  # active terminal probe can't complete through the mux, leaking query text
  # (`]10;?`) into captured output. Pin passthrough explicitly per tier and
  # disable probing whenever tmux is in the loop.
  #   Sixel (WezTerm outer) → --passthrough none: tmux-native placement.
  #   Kitty (Ghostty outer) → --passthrough tmux: unicode placeholders ARE
  #   plain cells to tmux, but the image transmission needs the envelope.
  if protocols=$(get_terminal_image_protocol "${1:-}" 2>/dev/null); then
    if [[ " $protocols " == *" Sixel "* ]]; then
      if [[ -n "${TMUX:-}" ]]; then
        echo "-f sixel --passthrough none --probe off"
      else
        echo "-f sixel"
      fi
    elif [[ " $protocols " == *" iTerm2 "* ]]; then
      echo "-f iterm"
    elif [[ " $protocols " == *" Kitty "* ]]; then
      if [[ -n "${TMUX:-}" ]]; then
        echo "-f kitty --passthrough tmux --probe off"
      else
        echo "-f kitty"
      fi
    else
      echo "-f symbols"
    fi
  else
    echo "-f symbols"
  fi
}

# get_image_max_bytes — the largest single image stream this terminal takes;
# 0 = no cap. A sixel image reaches tmux as ONE DCS string and tmux DISCARDS a
# string sequence past its `input-buffer-size` (a SERVER option, default
# 1 MiB — measured: 1,032,961 bytes rendered, 1,174,685 did not), so ASK the
# server; our tmux.conf raises it. 5% margin for the bytes around the image.
# The cap is tmux's, and only tmux's: elsewhere shrinking to fit it only makes
# the picture small.
get_image_max_bytes() {
  local max=0 lim
  if [ -n "${TMUX:-}" ]; then
    max=1000000
    lim="$(tmux show -sv input-buffer-size 2>/dev/null)"
    case "$lim" in
      '' | *[!0-9]*) ;;
      *) [ "$lim" -gt 1000 ] && max=$((lim * 95 / 100)) ;;
    esac
  fi
  echo "$max"
}
