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

# Line navigation and editing.
# z4h bound these; replacing its DSL with raw sequences left them unbound, and
# ZLE silently ignores a sequence it has no binding for — which is why Delete
# does nothing at the prompt while working in every other macOS app. Nothing
# upstream is at fault: the keyboard sends KC_DEL and the terminal emits the
# sequence; only ZLE was missing its half.
# Both the CSI (^[[…) and application-mode (^[O…) forms are bound, because which
# one arrives depends on the terminal's keypad mode — and inside a multiplexer,
# on the TERM it advertises to the shell.
bindkey '^[[3~'   delete-char        # Delete  (Shift+Backspace on the Svalboard)
bindkey '^[[3;5~' kill-word          # Ctrl+Delete: eat the word ahead

# Ctrl+Backspace, the mirror of Ctrl+Delete. Unlike Ctrl+Alt+A above, this key
# has no usable legacy encoding — terminals send plain ^? for it, the same byte
# as Backspace — so it only arrives distinctly as an extended key.
#
# Which extended form reaches ZLE is NOT the one the terminal sends. Measured on
# a scratch tmux server with `extended-keys always` (same method as the \e^A note
# below), feeding an attached client each encoding and reading the pane back:
#
#   client sends kitty      CSI 127;5u    → pane receives CSI 27;5;127~
#   client sends modifyOther CSI 27;5;127~ → pane receives CSI 27;5;127~
#
# tmux decodes whatever it is given and re-emits xterm modifyOtherKeys, so
# `^[[27;5;127~` is the one that matters. The kitty form is kept for a terminal
# talking straight to zsh with no multiplexer in between.
bindkey '^[[27;5;127~' backward-kill-word  # Ctrl+Backspace, via tmux
bindkey '^[[127;5u'    backward-kill-word  # Ctrl+Backspace, no multiplexer
# Legacy fallback. Costs Ctrl+H its usual backward-delete-char, since the two are
# the same byte; drop this line if the extended forms above prove sufficient.
bindkey '^H'           backward-kill-word  # Ctrl+Backspace (legacy)

bindkey '^[[H'    beginning-of-line  # Home
bindkey '^[OH'    beginning-of-line  # Home, application mode
bindkey '^[[1~'   beginning-of-line  # Home, vt-style
bindkey '^[[F'    end-of-line        # End
bindkey '^[OF'    end-of-line        # End, application mode
bindkey '^[[4~'   end-of-line        # End, vt-style

bindkey '^[[1;5D' backward-word      # Ctrl+Left
bindkey '^[[1;5C' forward-word       # Ctrl+Right
bindkey '^[[1;3D' backward-word      # Alt+Left
bindkey '^[[1;3C' forward-word       # Alt+Right

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

# Alt+x — pick a command from the curated index and insert its name at the
# cursor. This displaces zsh's default `execute-named-cmd` (the `execute:`
# prompt for running a ZLE widget by name), which \ez / execute-last-named-cmd
# still reaches; \ep above already overrides a default the same way.
bindkey '\ex' command-pick
