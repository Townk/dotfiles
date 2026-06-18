# Key bindings. Sourced (deferred) from ~/.config/zsh/.zshrc after the ZLE plugins and
# tool init, so every widget referenced here is already defined:
#   - smart-space-expansion, cd-*  → functions.d/widgets.sh (synchronous)
#   - autosuggest-*                → zsh-autosuggestions
#   - history-substring-search-*   → zsh-history-substring-search
#   - atuin-search                 → `atuin init zsh`
#
# These replace the z4h `bindkey` DSL with raw bindkey + escape sequences.
# The CSI sequences below (Shift/Alt-modified arrows, Shift+Tab) are what
# WezTerm and Ghostty emit; adjust here if a future terminal differs.

# Abbreviation-aware space: expand an abbreviation, else magic-space.
bindkey ' ' smart-space-expansion

# Undo / redo (builtin ZLE widgets).
bindkey '^_'   undo   # Ctrl+/
bindkey '^[[Z' undo   # Shift+Tab
bindkey '^[/'  redo   # Option+/ (Alt+/)

# Directory navigation — Shift+arrows.
bindkey '^[[1;2D' cd-back     # Shift+Left  : previous dir in the ring
bindkey '^[[1;2C' cd-forward  # Shift+Right : next dir in the ring
bindkey '^[[1;2A' cd-up       # Shift+Up    : parent dir
bindkey '^[[1;2B' cd-down     # Shift+Down  : pick a child dir (fzf)

# Autosuggestions.
bindkey '^@' autosuggest-accept   # Ctrl+Space
bindkey '^Y' autosuggest-accept   # Ctrl+Y
bindkey '^E' autosuggest-clear    # Ctrl+E

# History substring search on Up/Down (both normal and application cursor
# modes) and Ctrl+P / Ctrl+N.
bindkey '^[[A' history-substring-search-up
bindkey '^[OA' history-substring-search-up
bindkey '^[[B' history-substring-search-down
bindkey '^[OB' history-substring-search-down
bindkey '^P'   history-substring-search-up
bindkey '^N'   history-substring-search-down

# Atuin owns Ctrl+R (overrides fzf's and the plugin defaults).
command -v atuin >/dev/null && bindkey '^R' atuin-search

# Ctrl+? (Ctrl+Shift+/) — summon ai-assist. zj-context-keys delivers it as the
# kitty CSI-u form \e[63;5u (`?`=63, ctrl=5); see config.kdl's "Ctrl ?" bind.
# (Plain Ctrl+/ is ^_ = undo, so the chord needs this distinct sequence.)
bindkey '\e[63;5u' ai-assist-trigger
