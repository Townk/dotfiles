# Loading a freshly-added secret into the shell you are standing in.
#
# `system-secrets` is a subprocess: it can rewrite ~/.config/zsh/secrets.d/
# but it cannot put the new value into its parent's environment. The fragment
# is sourced once, at startup (.zshenv -> environment.sh -> secrets.sh), so the
# shell that ran the command keeps the old set until it is restarted — the
# surprise reported after adding UNIFI_API_TOKEN.
#
# Two halves close that gap, and this spec covers both:
#   * functions.d/system-secrets.sh — an interactive-zsh front-end that
#     re-sources the loader after a mutating run, the `tm()` pattern.
#   * sec::shell_reload_hint — what the tool prints when nothing is going to
#     re-source for you (bash, sh, a non-interactive run, a host where the
#     function is not deployed).

Describe 'sec::shell_reload_hint'
  Include home/dot_local/lib/system-secrets-common.zsh

  # The bare case: no front-end is going to reload anything, so the tool has to
  # say how. Naming the loader (not "restart your shell") keeps the current
  # session usable.
  It 'tells the user how to load the new value into this shell'
    When call sec::shell_reload_hint
    The output should include '.config/zsh/secrets.sh'
    The status should be success
  End

  # The wrapper exports the marker before calling the binary, and reloads on
  # its own afterwards. Printing the hint too would contradict it.
  It 'stays quiet when the caller is going to reload for us'
    export SYSTEM_SECRETS_SHELL_RELOAD=1
    When call sec::shell_reload_hint
    The output should equal ''
    The status should be success
  End
End

Describe 'functions.d/system-secrets.sh — shell front-end'
  # Fully sandboxed: HOME, PATH and the loader are all inside TEST_TMP, so the
  # spec can never source the real secrets.d or shadow the real binary.
  setup() {
    TEST_TMP="$(mktemp -d)"
    PRELUDE="$TEST_TMP/prelude.zsh"
    {
      printf 'export HOME=%s\n' "$TEST_TMP"
      printf 'mkdir -p "$HOME/bin" "$HOME/.config/zsh"\n'
      printf 'export PATH="$HOME/bin:$PATH"\n'
      # Stand-in for the loader: sourcing it is the observable effect.
      printf 'print -r -- %s > "$HOME/.config/zsh/secrets.sh"\n' \
        "'print -r -- RELOADED'"
      # mkfake <exit-code> — a system-secrets on PATH that records each call.
      printf 'mkfake() {\n'
      printf '  { print -r -- "#!/usr/bin/env zsh"\n'
      printf '    print -r -- "print -r -- ran >> $HOME/calls"\n'
      printf '    print -r -- "exit $1"\n'
      printf '  } > "$HOME/bin/system-secrets"\n'
      printf '  chmod +x "$HOME/bin/system-secrets"\n'
      # $HOME/bin was on PATH before this file existed, so zsh has it hashed as
      # absent; without a rehash `whence -p` would not find the stand-in.
      printf '  rehash\n'
      printf '}\n'
      printf 'calls() { [[ -r "$HOME/calls" ]] && wc -l < "$HOME/calls" | tr -d " " || print -r -- 0 }\n'
      printf 'source "%s/home/dot_config/zsh/functions.d/system-secrets.sh"\n' \
        "$SHELLSPEC_PROJECT_ROOT"
    } > "$PRELUDE"
  }
  cleanup() { rm -rf "$TEST_TMP"; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  # The whole point: after a successful add the value is in THIS shell.
  # `calls=1` is the no-recursion assertion — a wrapper that called itself
  # instead of `command` would either loop or re-enter the function.
  It 'reloads the fragment after a successful add'
    When run zsh -c "source $PRELUDE; mkfake 0; system-secrets add FOO; print -r -- calls=\$(calls)"
    The output should include 'RELOADED'
    The output should include 'calls=1'
    The status should be success
  End

  It 'reloads the fragment after a successful rotate'
    When run zsh -c "source $PRELUDE; mkfake 0; system-secrets rotate FOO"
    The output should include 'RELOADED'
    The status should be success
  End

  # A read-only subcommand changes nothing, so re-sourcing would be noise.
  It 'does not reload for a read-only subcommand'
    When run zsh -c "source $PRELUDE; mkfake 0; system-secrets list"
    The output should not include 'RELOADED'
    The status should be success
  End

  # A run that died halfway may have left the fragment untouched or partial;
  # the caller's environment must not silently change on a failure.
  It 'does not reload when the command fails, and preserves its status'
    When run zsh -c "source $PRELUDE; mkfake 3; system-secrets add FOO"
    The output should not include 'RELOADED'
    The status should equal 3
  End

  # The binary decides what to print about reloading; it can only do that if
  # the wrapper tells it someone is listening.
  It 'marks the child so the binary suppresses its own hint'
    When run zsh -c "source $PRELUDE; print -r -- '#!/usr/bin/env zsh' > \$HOME/bin/system-secrets; print -r -- 'print -r -- marker=\${SYSTEM_SECRETS_SHELL_RELOAD:-unset}' >> \$HOME/bin/system-secrets; chmod +x \$HOME/bin/system-secrets; rehash; system-secrets add FOO"
    The output should include 'marker=1'
    The status should be success
  End

  # The marker is for the child only — leaking it would make a later bare run
  # (or any other tool reading it) think a reload is coming when it is not.
  It 'does not leak the marker into the calling shell'
    When run zsh -c "source $PRELUDE; mkfake 0; system-secrets add FOO; print -r -- after=\${SYSTEM_SECRETS_SHELL_RELOAD:-unset}"
    The output should include 'after=unset'
    The status should be success
  End
End
