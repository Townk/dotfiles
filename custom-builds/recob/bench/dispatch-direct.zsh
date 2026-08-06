#!/usr/bin/env zsh
# Arm: the REAL dispatcher, spawned once per frame -- today's cost, measured
# without any listener in the way. Reads the source tree so it measures the
# dispatcher as written rather than as applied.
src="${RECOB_BENCH_DISPATCH:-$(chezmoi source-path ~/.local/libexec/clipboard-bridge-dispatch 2>/dev/null)}"
[[ -n $src && -r $src ]] || { print -ru2 -- "dispatch-direct: cannot locate dispatcher source"; exit 1 }
printf 'H\000\000\000\000' | zsh "$src" > /dev/null
