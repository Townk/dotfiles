#!/usr/bin/env zsh
# image-protocol-support.zsh — detect the terminal's usable image protocol.
# SOURCED, never executed: defines get_terminal_image_protocol(), called by the
# `preview` script to choose a renderer (Kitty / iTerm2 / Sixel). Dual-shell
# (bash + zsh); no zsh-only runtime syntax.

get_terminal_image_protocol() {
  local host_support=()
  local final_capability=()

  # Safe expansion wraps to prevent 'parameter not set' errors
  local term_prog="${TERM_PROGRAM:-}"
  local iterm_sess="${ITERM_SESSION_ID:-}"
  local lc_term="${LC_TERMINAL:-}"
  local zellij_env="${ZELLIJ:-}"
  local tmux_env="${TMUX:-}"

  # 1. STEP ONE: Accumulate ALL protocols natively supported by the Host
  if [ "$term_prog" = "Alacritty" ] || [ "$term_prog" = "Apple_Terminal" ]; then
    : # Explicitly skip adding anything to the array
  elif [ "$term_prog" = "Ghostty" ] || [ "$term_prog" = "Kitty" ]; then
    host_support+=("Kitty")
  elif [ -n "$iterm_sess" ] || [ "$lc_term" = "iTerm2" ]; then
    host_support+=("iTerm2" "Sixel")
  elif [ "$term_prog" = "WezTerm" ]; then
    host_support+=("Kitty" "Sixel" "iTerm2")
  elif [ "$term_prog" = "foot" ] || [ "$term_prog" = "contour" ]; then
    host_support+=("Sixel")
  fi

  # 2. STEP TWO: Resolve capability through the multiplexer constraint.
  # Zellij: only Sixel survives its VTE (host_support gates it).
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
  if [ -n "$zellij_env" ]; then
    local has_sixel=false
    for proto in "${host_support[@]}"; do
      if [ "$proto" = "Sixel" ]; then
        has_sixel=true
        break
      fi
    done

    if [ "$has_sixel" = true ]; then
      final_capability+=("Sixel")
    fi
  elif [ -n "$tmux_env" ]; then
    local tmux_outer
    tmux_outer=$(tmux show-environment TERM_PROGRAM 2>/dev/null)
    case "${tmux_outer#TERM_PROGRAM=}" in
      WezTerm) final_capability+=("Sixel") ;;
      Ghostty) final_capability+=("Kitty") ;;
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
