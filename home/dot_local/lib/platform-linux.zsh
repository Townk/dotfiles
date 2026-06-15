#!/usr/bin/env zsh
# platform-linux.zsh — Linux implementation of the `platform::` interface.
# SOURCED by platform.zsh on Linux. See platform.zsh for the contract.
# Dual-shell (bash + zsh); no zsh-only runtime syntax.

# platform::launch_gui <macos-app> <linux-bin> -- <argv...>
# Launch the GUI binary directly, fully detached from this process (so it
# outlives a file-manager launcher), running <argv...>. <macos-app> is ignored.
# Prefers setsid (new session, no controlling tty); falls back to nohup.
platform::launch_gui() {
  local bin="$2"; shift 2          # drop the unused <macos-app> and <linux-bin>
  [ "${1:-}" = "--" ] && shift
  if command -v setsid >/dev/null 2>&1; then
    setsid "$bin" "$@" >/dev/null 2>&1 &
  else
    nohup "$bin" "$@" >/dev/null 2>&1 &
  fi
}

# platform::raise_app <macos-app> [<linux-wm-class>]
# Best-effort window raise across the common compositors/WMs, keyed on the
# window class (defaults to the app name). Never fatal: many Wayland
# compositors forbid programmatic focus-stealing, in which case we just spawn
# the tab and leave focus alone.
platform::raise_app() {
  local class="${2:-$1}"
  if command -v hyprctl >/dev/null 2>&1; then
    hyprctl dispatch focuswindow "class:$class" >/dev/null 2>&1 || true
  elif command -v swaymsg >/dev/null 2>&1; then
    swaymsg "[app_id=\"$class\"] focus" >/dev/null 2>&1 || true
  elif command -v wmctrl >/dev/null 2>&1; then
    wmctrl -x -a "$class" >/dev/null 2>&1 || true
  elif command -v xdotool >/dev/null 2>&1; then
    xdotool search --class "$class" windowactivate >/dev/null 2>&1 || true
  fi
  return 0
}
