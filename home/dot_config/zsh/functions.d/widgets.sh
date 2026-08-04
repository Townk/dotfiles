smart-space-expansion() {
  # Save current state
  local old_buffer=$BUFFER    # This is the entire line LBUFFER + RBUFFER
  local old_cursor=$CURSOR

  # Try to expand an abbreviation (widget form)
  zle abbr-expand-and-insert

  # If BUFFER or CURSOR changed, an abbreviation was expanded → we're done.
  # Notice that we are NOT quoting the variables, and this IS the right
  # behavior we want. Using [[ … ]] ensures the comparison is literal and
  # robust without needing quotes.
  if [[ $BUFFER != $old_buffer || $CURSOR != $old_cursor ]]; then
    return
  fi

  # Otherwise, fall back to magic-space (history expansion + space insertion)
  zle magic-space
}
zle -N smart-space-expansion

# ── Directory-navigation widgets (Shift+arrows) ────────────────────────────
# Replacements for the z4h-cd-* widgets. Defined here (sourced synchronously
# via functions.sh) so they exist before zsh-syntax-highlighting loads.
autoload -Uz add-zsh-hook

# Back/forward ring of visited directories, maintained on every cwd change.
typeset -ga _dir_ring=("$PWD")
typeset -gi _dir_ring_pos=1
typeset -g  _dir_ring_nav=''

_dir_ring_record() {
  # Don't record cwd changes that came from back/forward navigation itself.
  [[ -n $_dir_ring_nav ]] && { _dir_ring_nav=''; return; }
  # Drop any forward history, then append the new directory.
  _dir_ring=("${(@)_dir_ring[1,_dir_ring_pos]}" "$PWD")
  _dir_ring_pos=$#_dir_ring
}
add-zsh-hook chpwd _dir_ring_record

_dir_ring_go() {  # $1 = target position in the ring
  local pos=$1
  (( pos >= 1 && pos <= $#_dir_ring )) || { zle -R; return; }
  local prev_pos=$_dir_ring_pos
  _dir_ring_pos=$pos
  _dir_ring_nav=1
  \builtin cd -- "${_dir_ring[pos]}" 2>/dev/null || {
    # The ring entry vanished (deleted since it was recorded): no chpwd fired,
    # so undo the bookkeeping armed above — a surviving _dir_ring_nav makes the
    # hook swallow the NEXT legitimate cd, and pos would point at a directory
    # never reached.
    _dir_ring_nav=''
    _dir_ring_pos=$prev_pos
    zle -R
    return
  }
  zle reset-prompt
}

cd-back()    { _dir_ring_go $(( _dir_ring_pos - 1 )) }   # Shift+Left
cd-forward() { _dir_ring_go $(( _dir_ring_pos + 1 )) }   # Shift+Right
cd-up()      { \builtin cd -- .. 2>/dev/null; zle reset-prompt }  # Shift+Up
cd-down() {                                              # Shift+Down
  # Pick an immediate subdirectory with fzf.
  local d
  d=$(fd --type d --max-depth 1 --hidden --exclude .git . 2>/dev/null \
        | fzf --height=40% --reverse --prompt='cd > ') || { zle -R; return; }
  [[ -n $d ]] || { zle -R; return; }
  \builtin cd -- "$d" 2>/dev/null
  zle reset-prompt
}
zle -N cd-back
zle -N cd-forward
zle -N cd-up
zle -N cd-down

# ── ai-playbook assist trigger (Ctrl+Alt+A) ────────────────────────────────
# Delegate the flow to `ai-playbook assist`: it captures the origin context
# (last command/exit via atuin, cwd, scrollback), puts up its input widget, and
# drives the user's REAL interactive shell under a pty (loading this .zshrc).
# When the request classifies to a COMMAND it prints that command to STDOUT; an
# ANSWER or a playbook takes over the screen itself and returns nothing on
# stdout.
#
# So we run it in the FOREGROUND (not backgrounded) and capture stdout: a
# COMMAND result fills the command line for the user to review and run; anything
# else leaves the line untouched. Capturing stdout does not suppress the UI,
# which draws on /dev/tty (inline) or in a float of its own.
#
# The float is a mux action, and ai-playbook's [mux] preset is STATIC (one
# backend, chosen in its config, no runtime detection). Ours points every
# action at ~/.config/mux/scripts/mux-playbook, which resolves zellij-vs-tmux
# per call — so this widget behaves the same in either, and neither needs a
# knob. Before that the config named zellij outright, and under tmux every
# action silently did nothing: Ctrl+Alt+A opened a blank pane.
ai-assist-trigger() {
  local cmd
  cmd="$(ai-playbook assist)"
  if [[ -n "$cmd" ]]; then
    BUFFER="$cmd"
    CURSOR=${#BUFFER}
  fi
  zle reset-prompt
}
zle -N ai-assist-trigger

# ── ai-playbook store picker (Ctrl+Alt+P) ──────────────────────────────────
# Thin ZLE delegate to the libexec picker (~/.local/libexec/pick-playbook),
# which sources the mux::pick framework (a float inside a mux, inline fzf
# otherwise) and acts on the choice: Enter runs the playbook (adapt-on-run),
# Alt+Enter edits it. Both take over the terminal in the foreground (ai-playbook
# runs no-mux by default), then we redraw the prompt. Cancel/empty just resets.
ai-playbook-pick() {
  # Pass the interactive-shell-resolved binary down: the libexec picker runs as a
  # non-interactive zsh script and may not inherit the mise/go-bin PATH.
  AI_PLAYBOOK_BIN="${commands[ai-playbook]:-}" "$HOME/.local/libexec/pick-playbook"
  zle reset-prompt
}
zle -N ai-playbook-pick

# ── Command index picker (Alt+x) ────────────────────────────────────────────
# No body here: the widget IS `cmds` (functions.d/commands.sh). One function
# serves both entry points and branches on $WIDGET, which zsh sets only inside
# ZLE — from the prompt the pick goes to `print -z`, from Alt+x it is inserted
# at the cursor and the picker floats. Declared here so this file stays the
# index of every widget.
zle -N command-pick cmds

# ── Clipboard: smart paste (Alt+p) ──────────────────────────────────────────
# Alt+p — smart paste: files clip → run `pbpaste --files` as a visible,
# cancellable command; anything else → insert clipboard text at the cursor.
# All clipboard logic lives in pbpaste; this is pure ZLE glue (spec §7).
smart-paste() {
  if pbpaste --manifest >/dev/null 2>&1; then
    BUFFER="pbpaste --files"
    zle accept-line
  else
    LBUFFER+="$(pbpaste)"
  fi
}
zle -N smart-paste
