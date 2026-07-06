# backup-drift.sh — surface a backup-freshness banner above the prompt.
#
# The Terminal Time Machine captures on a 30-minute launchd cadence; when it
# silently stops (a dead agent, a wedged repo), nothing tells you until you
# need a restore. This registers a precmd that reads the workers' heartbeat
# and, ONLY when capture is overdue or failed, prints one line above the
# prompt. Healthy = silent. The check is a single small-file read (no restic,
# no locks), so it is safe on the prompt's hot path.
#
# Non-interactive shells never see a prompt; skip the wiring entirely.
[[ -o interactive ]] || return 0

_bkp_drift_lib="$HOME/.local/lib/backup-drift.zsh"
[[ -r "$_bkp_drift_lib" ]] || return 0
source "$_bkp_drift_lib"
unset _bkp_drift_lib

autoload -Uz add-zsh-hook
add-zsh-hook precmd bkp::drift::banner
