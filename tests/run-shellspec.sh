#!/usr/bin/env zsh
# shellspec, with an exit status that can be trusted. Every make lane runs this.
#
# shellspec 0.28.1 (the latest release) exits 0 when its error handler fires:
# the handler `exit`s its pipeline subshell before the status echo, the third
# status arrives empty, and the empty value overwrites a real 101. It prints
# "Aborted with status code ..." to stderr and reports success, so a run with
# failures goes green. Its stderr is teed here, and an aborted run fails with
# shellspec's own error status (102). tests/run-shellspec_spec.sh pins both
# the upstream bug and this behaviour.
setopt pipefail no_multios  # multios would copy stdout into the stderr pipe too

log=$(mktemp) || exit 1
trap 'rm -f "$log"' EXIT

# stdout goes straight through; stderr is shown as it comes and kept in $log.
{ shellspec "$@" 2>&1 1>&3 3>&- | tee "$log" >&2 } 3>&1
rc=$?

if (( rc == 0 )) && grep -q 'Aborted with status code' "$log"; then
  print -u2 'run-shellspec: shellspec aborted but exited 0 (shellspec 0.28.1 exit-status bug); failing the run'
  rc=102
fi
exit $rc
