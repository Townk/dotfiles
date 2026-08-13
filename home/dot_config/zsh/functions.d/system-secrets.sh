# system-secrets — shell front-end, so a secret you just added is live in the
# shell you added it from.
#
# The binary is a subprocess: it rewrites ~/.config/zsh/secrets.d/<slot>.sh but
# cannot touch its parent's environment, and that fragment is sourced exactly
# once, at startup (.zshenv -> environment.sh -> secrets.sh). Without this
# front-end the session that ran `system-secrets add` keeps the old values until
# it is restarted — you add a token in order to use it, then find it missing.
#
# Only interactive zsh loads functions.d (zshrc sources functions.sh), so run
# scripts, system-onboard and non-zsh callers keep getting the bare binary. They
# are not left guessing: the binary prints its own "source the loader" hint
# whenever this front-end is not the one calling it (sec::shell_reload_hint).
system-secrets() {
  # `whence -p`, not `command -v`: we are shadowing the name we are looking for,
  # and command -v would happily report this function.
  if ! whence -p system-secrets >/dev/null 2>&1; then
    print -u2 "system-secrets: not deployed on this host (secrets silo)"
    return 127
  fi

  # A one-shot assignment, so the marker reaches the child and nothing else — a
  # later bare run in this same shell must still get the binary's hint.
  SYSTEM_SECRETS_SHELL_RELOAD=1 command system-secrets "$@"
  local rc=$?

  # Reload only when a value can actually have changed (`list` changes nothing)
  # and only when the run succeeded — a run that died halfway may have left the
  # fragment untouched or partial, and silently swapping the environment under
  # the operator on a failure is worse than leaving it stale.
  if ((rc == 0)); then
    case "${1:-}" in
      add | rotate)
        if [[ -r "$HOME/.config/zsh/secrets.sh" ]]; then
          source "$HOME/.config/zsh/secrets.sh"
          print -r -- "✓ loaded into this shell"
        fi
        ;;
    esac
  fi
  return $rc
}
