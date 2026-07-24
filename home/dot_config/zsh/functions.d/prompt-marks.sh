# prompt-marks.sh — emit OSC 133;A (FinalTerm "prompt start") before every
# prompt. p10k does not emit these itself.
#
# Consumers: tmux copy-mode next-prompt / previous-prompt (mux migration
# D11 — the n/p prompt jumps in keymap.conf). Zellij passes the sequence
# through unharmed and ignores it (zj-prompt-jumper keeps its own
# scrollback-scan approach there); plain terminals that support FinalTerm
# marks (WezTerm) get semantic prompt zones for free.
#
# Guarded to interactive shells so scripts never register the hook — but the
# tty test must live INSIDE the hook: p10k's instant prompt redirects stdout
# while zshrc sources, so a load-time `-t 1` always fails and the hook would
# never register (Mode B find, 2026-07-24). Per-prompt it also keeps captures
# (`zsh -ic` pipes) free of escape bytes.
[[ -o interactive ]] || return 0

_prompt_mark_precmd() {
  [[ -t 1 ]] && printf '\033]133;A\007'
  return 0
}
autoload -Uz add-zsh-hook
add-zsh-hook precmd _prompt_mark_precmd
