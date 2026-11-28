# job_helper.sh — fixtures for the job*_spec.sh files, and only for them
# (`Include tests/job_helper.sh`). Both exist to keep an example under the
# fast suite's 0.1 s: a fork costs 1.2-2.2 ms, and a setup that writes the
# same eight stubs again for every example was a third of that budget.
#
# job_sandbox [prefix] — a fresh, empty directory under $SHELLSPEC_TMPBASE,
# in $SANDBOX: spec_sandbox without its fork (no mktemp, no mkdir). Unique
# per example: the example's own subshell pid, and its id for the reader.
# (A parameterized It has ONE id for all its rows, hence the pid; a reused
# pid meets the existence test.) Nothing to clean up: the tmpbase goes after
# the file. It also leaves zf_rm loaded (zsh/files: rm as a builtin), for a
# helper that removes a file of its own.
job_sandbox() {
  zmodload zsh/system
  zmodload -F zsh/files b:zf_mkdir b:zf_rm
  SANDBOX=${SHELLSPEC_TMPBASE:?job_sandbox: no SHELLSPEC_TMPBASE}/${1:-sb}.${SHELLSPEC_EXAMPLE_ID:-0}.${sysparams[pid]}
  while [[ -e $SANDBOX ]]; do SANDBOX+=_; done
  zf_mkdir -p -- "$SANDBOX"
}

# job_fixture_script <path> — write stdin to <path> as an executable script,
# for a BeforeAll: a stub every example uses unchanged is written ONCE per
# file, in a directory the examples share, instead of once per example.
#
# Such a stub must keep nothing beside itself: what it records goes where an
# exported variable says (the example's own sandbox), never to "$0.log". And
# an example that needs a different stub of the same name writes its own in
# its sandbox and points the seam there; it never rewrites the shared one.
#
# macOS vets a script the first time its inode is exec'd (about 50 ms, see
# THE EXEC POOL in spec_helper.sh). The charge follows the inode, so the file
# is run once as an empty script here, then filled in place: no example pays.
job_fixture_script() {
  zmodload -F zsh/files b:zf_mkdir
  zf_mkdir -p -- "${1:h}"
  print -r -- '#!/bin/sh' > "$1" && command chmod +x "$1" && "$1" < /dev/null && cat > "$1"
}

# job_lines <file> — how many lines the file has, as `wc -l <file | tr -d ' '`
# prints it, without the two processes. Fails, printing nothing, when the
# file cannot be read.
job_lines() {
  [[ -r $1 ]] || return 1
  local -i n=0
  local line
  while IFS= read -r line; do (( ++n )); done < "$1"
  print -r -- $n
}
