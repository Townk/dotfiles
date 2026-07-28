# Tests for theme-apply's tmux branch — effective theme derivation + live reload.
# Sandbox $HOME (not just XDG vars: theme-apply is exec'd as a fresh zsh, which
# would source the real ~/.zshenv → environment.sh and re-export the XDG vars
# back to the real config dirs — a sandbox $HOME has no zshenv to clobber with)
# + a PATH-shimmed `tmux` that records its argv; the zellij canonical kdl is
# absent so only the tmux (and json/zsh) branches run.
Describe 'theme-apply (tmux branch)'
  setup() {
    SANDBOX=$(mktemp -d)
    export HOME="$SANDBOX"
    export XDG_CONFIG_HOME="$SANDBOX/.config"
    export XDG_CACHE_HOME="$SANDBOX/.cache"
    unset SSH_CONNECTION SSH_CLIENT SSH_TTY
    mkdir -p "$XDG_CONFIG_HOME/theme" "$XDG_CONFIG_HOME/tmux/themes" "$SANDBOX/bin"
    printf '{"palette":{"base":"#1e1e2e","text":"#cdd6f4"}}\n' \
      >"$XDG_CONFIG_HOME/theme/chezmoi-system.json"
    printf 'C_HEX_BASE="#1e1e2e"\nif [ -t 1 ]; then\n:\nfi\n' \
      >"$XDG_CONFIG_HOME/theme/chezmoi-system.zsh"
    printf 'set -g status-style "bg=#1e1e2e,fg=#cdd6f4"\n%%hidden win_pill="#[bg=#1e1e2e]▌"\nsetw -g window-status-format "$win_pill"\n' \
      >"$XDG_CONFIG_HOME/tmux/themes/chezmoi-system-base.conf"
    export TMUX_SHIM_LOG="$SANDBOX/tmux.log"
    cat >"$SANDBOX/bin/tmux" <<'SHIM'
#!/bin/sh
echo "$@" >>"$TMUX_SHIM_LOG"
exit 0
SHIM
    chmod +x "$SANDBOX/bin/tmux"
    PATH="$SANDBOX/bin:$PATH"
  }
  cleanup() { rm -rf "$SANDBOX"; }
  BeforeEach setup
  AfterEach cleanup

  apply() { zsh home/dot_local/libexec/executable_theme-apply; }

  It 'copies the canonical tmux theme to effective when no override applies'
    When call apply
    The status should be success
    The file "$XDG_CONFIG_HOME/tmux/themes/chezmoi-system.conf" should be exist
    The contents of file "$XDG_CONFIG_HOME/tmux/themes/chezmoi-system.conf" should include "#1e1e2e"
  End

  It 'substitutes overridden tokens into the effective tmux theme (remote session)'
    printf 'base = "#101020"\n' >"$XDG_CONFIG_HOME/theme/override.toml"
    export SSH_CONNECTION="1.2.3.4 1 5.6.7.8 22"
    When call apply
    The status should be success
    The contents of file "$XDG_CONFIG_HOME/tmux/themes/chezmoi-system.conf" should include "#101020"
    The contents of file "$XDG_CONFIG_HOME/tmux/themes/chezmoi-system.conf" should not include "#1e1e2e"
  End

  It 'keeps non-overridden tokens intact under an override'
    printf 'base = "#101020"\n' >"$XDG_CONFIG_HOME/theme/override.toml"
    export SSH_CONNECTION="1.2.3.4 1 5.6.7.8 22"
    When call apply
    The contents of file "$XDG_CONFIG_HOME/tmux/themes/chezmoi-system.conf" should include "#cdd6f4"
  End

  It 'live-reloads a running tmux server via source-file'
    When call apply
    The contents of file "$TMUX_SHIM_LOG" should include "source-file"
  End

  It 'carries the rebuilt window pill into the live-reloaded theme'
    printf 'base = "#101020"\n' >"$XDG_CONFIG_HOME/theme/override.toml"
    export SSH_CONNECTION="1.2.3.4 1 5.6.7.8 22"
    When call apply
    The contents of file "$XDG_CONFIG_HOME/tmux/themes/chezmoi-system.conf" should include '#[bg=#101020]▌'
    The contents of file "$XDG_CONFIG_HOME/tmux/themes/chezmoi-system.conf" should include 'window-status-format'
  End

  It 'ignores the override in a local (non-SSH) session'
    printf 'base = "#101020"\n' >"$XDG_CONFIG_HOME/theme/override.toml"
    When call apply
    The contents of file "$XDG_CONFIG_HOME/tmux/themes/chezmoi-system.conf" should include "#1e1e2e"
  End
End
