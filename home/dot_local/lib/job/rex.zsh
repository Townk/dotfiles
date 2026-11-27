# job/rex.zsh — the Rex terminal side of jobs. SOURCED by job.zsh. Every rex
# call from job code passes --autostart=false and is best-effort: a missing,
# slow or restarting Rex must never fail or hang a job operation.

# job::_rex — resolve the rex client. JOB_REX_BIN is the test seam; rc 1 when
# neither it nor a rex on PATH exists.
job::_rex() {
  if [ -n "${JOB_REX_BIN:-}" ]; then
    print -r -- "$JOB_REX_BIN"
    return 0
  fi
  command -v rex >/dev/null 2>&1 || return 1
  print -r -- rex
}
