#!/bin/bash

# 1. SET PATHS
WEZTERM_BIN="/opt/homebrew/bin/wezterm"
NVIM_BIN="/opt/homebrew/bin/nvim"

# 2. CALCULATE TAB TITLE
COUNT=$#
if [ "$COUNT" -eq 0 ]; then
  TAB_TITLE="NeoVim"
elif [ "$COUNT" -eq 1 ]; then
  TAB_TITLE=$(basename "$1")
else
  FIRST_BASE=$(basename "$1")
  OTHERS=$((COUNT - 1))
  TAB_TITLE="$FIRST_BASE +$OTHERS"
fi

# 3. FIND ACTIVE PROCESS & SOCKET
W_PID=$(pgrep -x "wezterm-gui" || pgrep -x "wezterm")

if [ -z "$W_PID" ]; then
  # CASE: COLD START
  open -a WezTerm --args start -- "$NVIM_BIN" "$@"

  # Wait for socket and apply title to the active tab of the new PID
  sleep 1.2
  NEW_PID=$(pgrep -x "wezterm-gui" || pgrep -x "wezterm")
  if [ -n "$NEW_PID" ]; then
    export WEZTERM_UNIX_SOCKET="$HOME/.local/share/wezterm/gui-sock-$NEW_PID"
    "$WEZTERM_BIN" cli set-tab-title "$TAB_TITLE" 2>/dev/null
  fi
else
  # CASE: ALREADY RUNNING (Multiplexer aware)
  export WEZTERM_UNIX_SOCKET="$HOME/.local/share/wezterm/gui-sock-$W_PID"

  # Bring to front
  osascript -e 'tell application "WezTerm" to activate'

  # 4. SPAWN AND CAPTURE PANE ID
  # Using --new-window or just spawn.
  # We capture the PANE_ID because it's the most stable reference in multiplexing.
  PANE_ID=$("$WEZTERM_BIN" cli spawn -- "$NVIM_BIN" "$@" 2>/dev/null)

  if [ -z "$PANE_ID" ]; then
    sleep 0.5
    PANE_ID=$("$WEZTERM_BIN" cli spawn -- "$NVIM_BIN" "$@")
  fi

  # 5. SET TITLE VIA PANE CONTEXT
  # Instead of --tab-id, we use --pane-id.
  # WezTerm will resolve the tab that contains this pane.
  if [ -n "$PANE_ID" ]; then
    "$WEZTERM_BIN" cli set-tab-title "$TAB_TITLE" --pane-id "$PANE_ID"
  fi
fi
