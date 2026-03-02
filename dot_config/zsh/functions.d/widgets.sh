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
