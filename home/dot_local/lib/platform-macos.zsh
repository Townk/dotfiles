#!/usr/bin/env zsh
# platform-macos.zsh — macOS implementation of the `platform::` interface.
# SOURCED by platform.zsh on Darwin. See platform.zsh for the contract.
# Dual-shell (bash + zsh); no zsh-only runtime syntax.

# platform::launch_gui <macos-app> <linux-bin> -- <argv...>
# Launch the GUI app by bundle name via `open -a`, passing <argv...> to it.
# <linux-bin> is ignored here. `open` returns immediately (the app runs
# detached from this process), which is what a Finder droplet needs.
platform::launch_gui() {
  local app="$1"
  shift 2 # drop <macos-app> and the unused <linux-bin>
  [ "${1:-}" = "--" ] && shift
  open -a "$app" --args "$@"
}

# platform::raise_app <macos-app> [<linux-wm-class>]
# Bring the app's window to the foreground via AppleScript. Best-effort: a
# failure (app not scriptable, no GUI session) is swallowed.
platform::raise_app() {
  osascript -e "tell application \"$1\" to activate" >/dev/null 2>&1 || true
}
