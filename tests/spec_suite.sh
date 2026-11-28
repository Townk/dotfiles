# spec_suite.sh — suite membership and per-example timing, for every spec file.
#
# Loaded by shellspec for each spec file (`--require spec_suite` in
# .shellspec), after spec_helper.sh. Two jobs, both driven by the environment
# tests/run-shellspec.sh sets:
#
# 1. MEMBERSHIP. There are two suites: FAST and COMPLETE. Every example is in
#    COMPLETE; an example is in FAST unless it says otherwise:
#
#      It 'mounts the scratch volume'
#        Skip if 'complete-only: real hdiutil mount' spec_complete_only
#        ...
#      End
#
#      Describe 'against a scratch rex server'
#        Skip if 'complete-only: starts a real server' spec_complete_only
#        BeforeAll 'start_server'      # not run in the fast suite
#        ...
#      End
#
#    spec_complete_only is true (so the example is skipped) only when
#    SPEC_SUITE=fast. Unset, `complete`, or anything else runs everything, so
#    `make test-one`, `make test-changed` and a bare `shellspec` are complete.
#    The reason always starts with `complete-only:` and says what makes the
#    example slow; `grep -rn spec_complete_only tests/` is the whole list.
#
#    WHERE the line goes matters. In a Describe/Context it skips the group's
#    examples AND its BeforeAll/BeforeEach/AfterEach/AfterAll hooks. In an It,
#    the hooks around that example still run (shellspec evaluates a Skip
#    inside the example body, after BeforeEach). So an example whose COST is in
#    its setup gets a Context of its own carrying the Skip.
#
# 2. TIMING. With SPEC_PROFILE_DIR naming a directory, each example appends
#    one line to $SPEC_PROFILE_DIR/examples.tsv:
#      <specfile> TAB <line of the It> TAB <seconds> TAB <description>
#    Wall time of the example as shellspec runs it: BeforeEach hooks, body,
#    AfterEach hooks, and shellspec's own bookkeeping (~3 ms). BeforeAll hooks
#    and the file's start-up are NOT in any example's time. It replaces
#    shellspec's two profiler hooks, so `--profile` (whose tick counter is one
#    file shared by every job, and which shellspec refuses under --jobs) must
#    not be combined. Each spec FILE also appends one line to files.tsv:
#      <specfile> TAB <seconds>
#    from the file's first before-all hook to its last after-all hook: the
#    examples and the BeforeAll/AfterAll hooks, but not the translation of the
#    file, the shell's start nor spec_helper's load (~0.1 s and up, growing
#    with the file's length).
#
# Both variables are taken out of the environment here, so a spec that runs
# the wrapper, make, or a nested shellspec does not hand them down by accident.
SPEC_SUITE_ACTIVE=${SPEC_SUITE:-}
unset SPEC_SUITE

spec_complete_only() { [ "$SPEC_SUITE_ACTIVE" = fast ]; }

# shellspec defines its two profiler hooks AFTER it loads the --require
# modules, so they are replaced from a before-all hook: it runs once per spec
# file, in the file's own shell, before the first example.
SPEC_SUITE_PROFILE_LOG=
if [ -n "${ZSH_VERSION:-}" ] && [ -n "${SPEC_PROFILE_DIR:-}" ] && [ -d "${SPEC_PROFILE_DIR:-}" ]; then
  SPEC_SUITE_PROFILE_LOG=$SPEC_PROFILE_DIR/examples.tsv
fi
unset SPEC_PROFILE_DIR

spec_suite_configure() {
  [ -n "$SPEC_SUITE_PROFILE_LOG" ] || return 0
  zmodload zsh/datetime
  before_all spec_suite_profile_on
  after_all spec_suite_profile_file
}
spec_suite_profile_file() {
  printf '%s\t%.3f\n' "$SHELLSPEC_SPECFILE" "$(( EPOCHREALTIME - SPEC_SUITE_FILE_T0 ))" \
    >>"${SPEC_SUITE_PROFILE_LOG%/*}/files.tsv"
}
spec_suite_profile_on() {
  SPEC_SUITE_FILE_T0=$EPOCHREALTIME
  shellspec_profile_start() { SPEC_SUITE_T0=$EPOCHREALTIME; }
  # One short O_APPEND write per example: whole lines even with every job
  # writing the same file. Groups are joined by VT in shellspec's description.
  shellspec_profile_end() {
    printf '%s\t%s\t%.3f\t%s\n' "$SHELLSPEC_SPECFILE" "${SHELLSPEC_LINENO_BEGIN:-0}" \
      "$(( EPOCHREALTIME - SPEC_SUITE_T0 ))" "${${SHELLSPEC_DESCRIPTION//$'\v'/ }//[$'\t\n']/ }" \
      >>"$SPEC_SUITE_PROFILE_LOG"
  }
}
