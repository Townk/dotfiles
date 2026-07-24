# prompt-marks.sh — emit OSC 133;A (FinalTerm "prompt start") before every
# prompt. p10k does not emit these itself.
#
# Consumers: tmux copy-mode next-prompt / previous-prompt (mux migration
# D11 — the n/p prompt jumps in keymap.conf). Zellij passes the sequence
# through unharmed and ignores it (zj-prompt-jumper keeps its own
# scrollback-scan approach there); plain terminals that support FinalTerm
# marks (WezTerm) get semantic prompt zones for free.
#
# Guarded to interactive shells with a tty so scripts and captures never see
# the escape bytes.
[[ -o interactive && -t 1 ]] || return 0

_prompt_mark_precmd() { printf '\033]133;A\007'; }
autoload -Uz add-zsh-hook
add-zsh-hook precmd _prompt_mark_precmd
