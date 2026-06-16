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
