# ~/.config/zsh/secrets.sh — non-secret loader for per-machine secret fragments.
#
# This file holds NO secrets. Each machine's actual secret env vars live in
# ~/.config/zsh/secrets.d/<slot>.sh (mode 0600), materialized by chezmoi from
# the slot fragment selected for this host (see .chezmoiignore.tmpl gating).
# Headless fragments are SOPS+age decrypted at apply; human fragments resolve
# 1Password references at apply. Either way the fragment lands as a plain
# `export NAME=value` snippet here, and this loader sources every fragment.
#
# Sourced by BOTH zsh (~/.zshenv → environment.sh) and /bin/sh (the launchd
# environment agent), so it must stay POSIX. An absent/empty secrets.d is a
# no-op. The wrinkle: zsh aborts on an unmatched glob (NOMATCH), while /bin/sh
# leaves the pattern literal. So branch by shell — the zsh arm uses the (N)
# null-glob qualifier (parsed only by zsh, since it lives inside an eval string
# /bin/sh never interprets); the POSIX arm relies on the `[ -r ]` guard.
if [ -n "${ZSH_VERSION:-}" ]; then
  eval 'for _sf in "$HOME/.config/zsh/secrets.d"/*.sh(N); do
          [ -r "$_sf" ] && . "$_sf"
        done'
else
  for _sf in "$HOME/.config/zsh/secrets.d"/*.sh; do
    # shellcheck disable=SC1090  # dynamic per-host fragment path
    [ -r "$_sf" ] && . "$_sf"
  done
fi
unset _sf 2>/dev/null || true
