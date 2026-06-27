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
  _dir_ring_pos=$pos
  _dir_ring_nav=1
  \builtin cd -- "${_dir_ring[pos]}" 2>/dev/null
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
# Delegate the flow to `ai-playbook assist`. With the multiplexer integration
# OFF (the default), assist runs INLINE in this pane: it captures the origin
# context (last command/exit via atuin, cwd, scrollback), renders its input box
# directly on /dev/tty, and drives the user's REAL interactive shell under a pty
# (loading this .zshrc). When the request classifies to a COMMAND it prints that
# command to STDOUT; an ANSWER or a playbook takes over the screen itself (the
# fullscreen viewer on /dev/tty) and returns nothing on stdout.
#
# So we run it in the FOREGROUND (not backgrounded) and capture stdout: a
# COMMAND result fills the command line for the user to review and run; anything
# else leaves the line untouched. Because the UI is on /dev/tty, capturing
# stdout doesn't suppress it. (The old backgrounded + stdio-detached form was for
# the zellij float UI, which no longer activates by default — opt back in with
# `[mux] backend = "zellij"` in the ai-playbook config.)
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
# Browse the saved-playbook store with fzf and act on the pick:
#   Enter      → `ai-playbook run --playbook <slug>` (adapt-on-run + drive)
#   Alt+Enter  → `ai-playbook edit <slug>` ($EDITOR)
# `ai-playbook list --format fuzzy-data-source` emits one US(\x1f)-delimited
# record per playbook: <display>\x1f<slug>\x1f<path>. fzf shows/searches only
# field 1 (--with-nth 1) and previews the file (field 3). --expect tells us
# which key accepted so we branch run vs edit. run/edit take over /dev/tty in
# the foreground (no mux), then we return to a clean prompt — same model as the
# assist trigger above. An empty store (no stdout) or a cancel just resets.
ai-playbook-pick() {
  local out key sel slug
  out=$(ai-playbook list --format fuzzy-data-source \
        | fzf --height=60% --reverse --prompt='playbook > ' \
              --delimiter=$'\x1f' --with-nth=1 --expect=alt-enter \
              --preview='cat {3}' --preview-window='right,60%,wrap') \
    || { zle -R; return; }
  # --expect layout: line 1 = pressed key ("" for plain Enter), line 2 = record.
  key=${out%%$'\n'*}
  sel=${out#*$'\n'}
  [[ -n $sel ]] || { zle -R; return; }
  slug=${sel#*$'\x1f'}        # drop the display field → slug\x1fpath
  slug=${slug%%$'\x1f'*}      # keep the slug
  [[ -n $slug ]] || { zle -R; return; }
  if [[ $key == alt-enter ]]; then
    ai-playbook edit "$slug"
  else
    ai-playbook run --playbook "$slug"
  fi
  zle reset-prompt
}
zle -N ai-playbook-pick
