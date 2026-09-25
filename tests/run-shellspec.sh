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
#
# Every run, pass or fail, ends with one line on stderr:
#   run-shellspec: <N> examples, <N> failures, <N> skips in <M>m <S>s
# parsed from shellspec's own summary line, so a nine-minute lane's outcome
# is readable without scrolling back through the failure listing.
setopt pipefail no_multios  # multios would copy stdout into the stderr pipe too
zmodload -F zsh/datetime p:EPOCHSECONDS

log=$(mktemp) || exit 1
out=$(mktemp) || { rm -f "$log"; exit 1; }
trap 'rm -f "$log" "$out"' EXIT

# stdout is teed through $out to read the summary from, which makes it a pipe;
# keep shellspec's colours on a terminal (NO_COLOR still wins inside shellspec).
[[ -t 1 && -z ${NO_COLOR-} ]] && export FORCE_COLOR=${FORCE_COLOR:-1}

# stdout goes straight through and is kept in $out; stderr is shown as it
# comes and kept in $log.
start=$EPOCHSECONDS
{ shellspec "$@" 2>&1 1>&3 3>&- | tee "$log" >&2 } 3>&1 | tee "$out"
rc=$?
elapsed=$(( EPOCHSECONDS - start ))

if (( rc == 0 )) && grep -q 'Aborted with status code' "$log"; then
  print -u2 'run-shellspec: shellspec aborted but exited 0 (shellspec 0.28.1 exit-status bug); failing the run'
  rc=102
fi

# shellspec's summary: "4 examples, 1 failure, 1 skip, 1 fix" — the skip field
# only appears when there are skips. Colour codes are stripped first.
summary=$(sed $'s/\e\\[[0-9;]*m//g' "$out" | grep -E '^[0-9]+ examples?, [0-9]+ failures?' | tail -n 1)
examples=? failures=? skips=0
if [[ $summary =~ '^([0-9]+) examples?, ([0-9]+) failures?' ]]; then
  examples=$match[1] failures=$match[2]
  [[ $summary =~ '([0-9]+) skips?' ]] && skips=$match[1]
fi
print -u2 "run-shellspec: $examples examples, $failures failures, $skips skips in $(( elapsed / 60 ))m $(( elapsed % 60 ))s"
exit $rc
