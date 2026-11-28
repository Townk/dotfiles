# exec_warm_helper.sh — pay for the first exec of the pooled stub inodes
# before the examples, not inside one.
#
# spec_helper.sh moves every `#!` script an example makes executable onto a
# pooled inode ("THE EXEC POOL" there), because macOS vets a script the first
# time its inode is exec'd: 40-180 ms, measured, against ~5 ms afterwards. The
# pool makes that a cost per spec FILE instead of per stub. But it is still
# paid inside an example: by the first few that write stubs. In the complete
# suite those are whatever examples come first; in the fast suite, once the
# heavy examples of a file are complete-only, they are otherwise cheap
# examples that then show up over the 0.1 s budget for no reason of their own.
#
#   Include tests/exec_warm_helper.sh
#   BeforeAll 'spec_exec_pool_warm 6'    # as many slots as one example fills
#
# spec_exec_pool_warm [n] (default 4) claims the first n slots the way an
# example would (n trivial stubs, made executable through the pooled `chmod`),
# runs each once, all at the same time, and gives the slots back. Nothing an
# example can observe changes: the same slots, already vetted. The time is in
# no example (a BeforeAll is in the file's total only), and it is not new
# time: the same vetting used to happen inside the examples.
#
# It leans on two internals of spec_helper.sh, $_SPEC_IN_EXAMPLE and
# spec_exec_pool_drain, and belongs beside them; it lives here only because
# spec_helper.sh was not this change's to edit.
spec_exec_pool_warm() {
  [ "${SPEC_EXEC_POOL:-1}" != 0 ] && [ -n "${SPEC_HELPER_TMPBASE:-}" ] || return 0
  _ew_dir="$SPEC_HELPER_TMPBASE/.exec-warm"
  mkdir -p "$_ew_dir" || return 0
  _SPEC_IN_EXAMPLE=1
  _ew_n=1
  while [ "$_ew_n" -le "${1:-4}" ]; do
    printf '#!/bin/sh\n:\n' >"$_ew_dir/$_ew_n" && chmod +x "$_ew_dir/$_ew_n"
    _ew_n=$((_ew_n + 1))
  done
  # One subshell holds the jobs, so a hook's job table stays empty.
  (
    for _ew_f in "$_ew_dir"/*; do "$_ew_f" & done
    wait
  ) >/dev/null 2>&1
  spec_exec_pool_drain
  unset _SPEC_IN_EXAMPLE
  return 0
}

# spec_clock_warm — the same for the virtual clock's own stubs, after a
# spec_clock_set made in a BeforeAll (where they are made once for the group
# and, being made outside an example, are not pooled): run each of them once.
# They are the FAKES, and return at once; the journal is left empty again.
#
#   clock_once() { spec_clock_set && spec_clock_warm; }
#   BeforeAll 'clock_once'
#   rewind() { : >"$SPEC_CLOCK_FILE"; spec_clock_set 1000; }   # one fork, not ten
#   BeforeEach 'rewind'
spec_clock_warm() {
  [ -n "${SPEC_CLOCK_BIN:-}" ] && [ -d "$SPEC_CLOCK_BIN" ] || return 0
  for _ew_f in "$SPEC_CLOCK_BIN"/*; do
    case ${_ew_f##*/} in
      *.log | spec-clock-gate) ;;
      date) "$_ew_f" +%s >/dev/null 2>&1 ;;
      *) "$_ew_f" 0 >/dev/null 2>&1 ;;
    esac
  done
  rm -f "$SPEC_CLOCK_BIN"/*.log
  : >"$SPEC_CLOCK_FILE"
  return 0
}
