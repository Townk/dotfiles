# A tmux server keeps its config in MEMORY. `chezmoi apply` rewrites
# ~/.config/tmux/*.conf; a server started before that keeps the old key
# tables, hooks and status-right until something says `source-file`. The
# drift is silent and it reads as a bug in the file you just edited — the
# bar still paints, the keys still do something, and the deployed config is
# correct the whole time. So the reload rides along with the change.
Describe 'tmux config reload hook'
  HOOK="$SHELLSPEC_PROJECT_ROOT/home/.chezmoiscripts/run_onchange_after_58-reload-tmux.sh.tmpl"

  It 'exists and runs after the theme is generated'
    exists() { [ -f "$HOOK" ] && echo yes; }
    When call exists
    The output should equal "yes"
    # 58 > 54-generate-theme: the theme conf tmux.conf sources must be on disk
    # before any server is told to re-read it.
    The path "$HOOK" should be file
  End

  Describe 'the change detector'
    src() { cat "$HOOK"; }

    # onchange hooks fire on a content hash. Every input that can change what
    # a running server SHOULD have must be in it, or the reload silently
    # stops happening for that class of edit.
    It 'hashes every input that changes a running server'
      When call src
      The output should include 'dot_config/tmux/tmux.conf.tmpl" | sha256sum'
      The output should include 'dot_config/tmux/status.conf.tmpl" | sha256sum'
      The output should include 'dot_config/tmux/keymap.conf.tmpl" | sha256sum'
      The output should include 'dot_config/tmux/keymap-base.conf.tmpl" | sha256sum'
      # the generated keymap and theme are data-driven: the templates can sit
      # still while keymap.yaml or the palette moves underneath them
      The output should include '.chezmoidata/keymap.yaml" | sha256sum'
      The output should include '.chezmoidata/theme.yaml" | sha256sum'
    End
  End

  Describe 'reaching every server'
    src() { cat "$HOOK"; }

    # `tmux source-file` alone only reaches the DEFAULT socket. The mux
    # backend runs named servers (-L), and a scratch or remote-workspace
    # server is exactly the one that drifts unnoticed.
    It 'walks the socket directory rather than assuming the default server'
      When call src
      The output should include 'TMUX_TMPDIR:-/tmp'
      The output should include 'tmux -L "$name" source-file'
    End

    # A socket file outlives its server. Sourcing into a corpse must not fail
    # the apply — and removing the corpse is not this hook's business.
    It 'skips dead sockets instead of failing the apply'
      When call src
      The output should include 'has-session'
      The output should include 'continue'
    End

    It 'degrades quietly when tmux is not installed'
      When call src
      The output should include 'command -v tmux'
    End
  End

  # The hook must be a real POSIX script once rendered — a syntax error here
  # fails `chezmoi apply` itself, which is a far worse outcome than a stale
  # server.
  Describe 'the rendered script'
    render() {
      cd "$SHELLSPEC_PROJECT_ROOT" || return 1
      chezmoi execute-template --source ./home < "$HOOK"
    }

    It 'renders to a script sh can parse'
      check() {
        out=$(render) || return 1
        printf '%s' "$out" > "$SHELLSPEC_TMPBASE/reload.sh"
        sh -n "$SHELLSPEC_TMPBASE/reload.sh" && echo ok
      }
      When call check
      The output should equal "ok"
      The status should be success
    End
  End
End
