# Key bindings. Sourced (deferred) from ~/.config/zsh/.zshrc after the ZLE plugins and
# tool init, so every widget referenced here is already defined:
#   - smart-space-expansion, cd-*, smart-paste  → functions.d/widgets.sh (synchronous)
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

# Ctrl+Alt+A — summon ai-assist. The chord arrives as the legacy sequence
# ESC Ctrl-A (\e^A) and passes straight through WezTerm → SSH → Zellij to the
# pane (verified via `cat -v`), so no Zellij bind / plugin routing is needed —
# just this bindkey. (Ctrl+Shift+/ was unusable: no distinct legacy encoding for
# zsh, and Zellij can't bind Ctrl+punctuation.)
#
# tmux does NOT change this, despite `extended-keys always`: measured by feeding
# a real client all three encodings WezTerm can emit (legacy \e^A, xterm
# modifyOtherKeys CSI 27;7;97~, kitty CSI 97;7u) — tmux decodes each and
# re-emits the SAME legacy \e^A, because `always` only means "use CSI-u where
# there is no other way to send the key", and this key has one. So one bindkey
# covers both backends; do not add a CSI-u twin for it.
bindkey '\e^A' ai-assist-trigger

# Ctrl+Alt+P — pick a saved playbook from the ai-playbook store (fzf). Arrives as
# the legacy sequence ESC Ctrl-P (\e^P), same encoding family as the assist
# chord above. Enter runs the pick (adapt-on-run); Alt+Enter edits it.
bindkey '\e^P' ai-playbook-pick

# Alt+p — smart paste: files clip runs `pbpaste --files` as a visible command,
# anything else inserts the clipboard text at the cursor.
bindkey '\ep' smart-paste
