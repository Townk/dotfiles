# Spec scaffolding

Shared setup for the shellspec suite. The helpers live in `tests/spec_helper.sh`
(loaded for every spec; each has a contract comment there) and are pinned in
`tests/spec_helper_spec.sh`.

## Policy

1. **Two suites.** FAST must finish in 60 s, COMPLETE in 180 s (`--jobs 6` on
   the owner's machine). A spec that cannot run in the fast suite says why.
2. **No test waits.** No `sleep`, `timeout`, `read -t`, polling loop or
   "took at least / less than N seconds" assertion in a spec (the words
   `sleep` and `timeout` do not appear as commands at all: move time with
   `spec_clock_advance`, and in a stub body with `spec-clock-advance`).
   Approved alternatives, in order of preference:
   - **Model it as a count or a state file.** The fake rex's layer lives for
     `STUB_LAYER_LIFE` polls; a stub answers "gone" once a file the example
     writes says so. Assert the number of polls.
   - **The virtual clock** (`spec_clock_set`), when the subject IS time: a
     poll loop giving up, a deadline, a TTL, a debounce. Assert how long the
     code believes it waited.
   - **An env seam** the code already has (`MUX_MODAL_REX_MISSES`,
     `_MUX_RX_AWAIT_MISSES`, `JOB_FOLLOW_DELAY`, `JOB_FOLLOW_POLL`,
     `BKP_TM_SCRUB_DEBOUNCE` …) to shrink a bound, never to "wait less".
   - `touch -t` for a file's age, relative to the virtual now.
   - **To join something that runs beside the example**: `wait <pid>` for a
     child; for anything else a rendezvous, never a poll: a fake (or a
     test-owned wrapper) writes one line to a FIFO the example made, and the
     example blocks on `read -r _ <fifo` (`tests/job_follow_spec.sh`:
     `started`, `decided`, `held`/`release`; `tests/job_rex_spec.sh`:
     `joined`). A production `&!` that tests must join gets a foreground
     mode (`SSH_PREPARE_FOREGROUND=1`).
   A wait that none of these removes is a missing production seam: leave the
   example, and list it (file, example, seam needed) for the owner.
3. **No test reaches the desktop.** No real notification, sound, dialog, app,
   Quick Look panel or clipboard write. `spec_helper.sh` denies by default,
   for every spec file: recording stubs for `hs`, `osascript`, `afplay`, `say`,
   `terminal-notifier`, `open` (and `pbcopy`) first on `PATH`, and the
   absolute-path seams (`HS`, `WIDGETS_OSASCRIPT_BIN`) pinned to them. Assert
   on what the code asked for with `spec_notifications`, `spec_sounds` or
   `spec_desktop_calls [tool]` (clear first with `spec_desktop_reset`: the log
   is per file). A spec that builds its own `PATH` or uses `env -i` keeps the
   guard: `env -i PATH="$SPEC_DESKTOP_GUARD:/usr/bin:/bin" HS="$HS" …`. A spec
   that needs the real thing says `Skip if '…' spec_real_desktop_off` and runs
   only under `SPEC_REAL_DESKTOP=1`; it belongs to neither suite.
   **The one exception** is the end-of-run toast of `tests/run-shellspec.sh`:
   one notification per run (suite name from `$SPEC_SUITE`, counts, duration),
   sent after shellspec has exited. `SPEC_RUN_TOAST=0` silences it, `=1` forces
   it; unset, it fires only at a local terminal (not over SSH, in CI, or under
   an agent). Specs inherit `SPEC_RUN_TOAST=0`.

## Helpers

| Call | What you get |
| --- | --- |
| `spec_sandbox [name]` | `$SANDBOX`: a fresh directory under `$SHELLSPEC_TMPBASE`. No cleanup. |
| `spec_stub <dir> <name> [body-line…]` | `<dir>/<name>`: logs argv on one line to `<dir>/<name>.log`, then runs the body. `$STUB_DIR`, `$STUB_LOG` inside. |
| `spec_stub_calls <dir> <name>` | That log (empty if never run). |
| `spec_path_prepend <dir>…` | The directories first on `PATH`, exported. Nothing to undo. |
| `spec_fake_rex <dir> [arm…] [--offline arm…]` | `<dir>/rex`: answers `client ls`, `ls --json`, `session.view`, `session.new_layer`, `block inspect/close`, `block call … process`, `window new`, `whoami` from `<dir>/*.json` or defaults. `STUB_SERVER=down` exits 4. |
| `spec_render_template <tmpl> [dest]` | `$SPEC_RENDERED`: the template rendered against this source tree. Loud on failure. |
| `spec_clock_set [t]` / `_advance <s>` / `_now [ms]` / `_slept` | A virtual clock: `common::now` / `common::sleep` in production (`$COMMON_CLOCK_FILE`), a fake `sleep` and `date` on `PATH`, shared by every child process. `spec-clock-advance <s>` is the command form, for stub bodies. |
| `spec_clock_await <s>` / `spec_clock_guard <pid> [s]` / `_guard_off` | Stay in step with code that naps beside the example: block until IT has napped that long; kill it if it naps past a bound. |
| `spec_notifications` / `spec_sounds` / `spec_desktop_calls [tool]` | What the code under test asked of the desktop (nothing real happened). |

### Controlling time: a worked example

`mux-modal` polls `rex block inspect` every 0.2 s until its layer is gone.
"It does not return while the layer is open" used to open a layer that lived
1.2 s and assert `EPOCHREALTIME - t0 >= 1.0`. Now (`tests/mux_modal_rex_spec.sh`):

```sh
setup() { spec_sandbox; MM_TMP=$SANDBOX; spec_fake_rex "$MM_TMP"; spec_clock_set 1000; }
BeforeEach 'setup'

It 'does not return while the layer is open'
  export STUB_LAYER_LIFE=3            # alive for three polls, gone on the fourth
  run() { modal -- true; waited; }    # waited: polls counted in rex.log, clock delta
  When call run
  The output should equal "polls=4 slept=600ms"
End
```

The script runs as a child (`zsh "$MODAL"`); it reaches the fake `sleep`
through `PATH` and the clock through `$SPEC_CLOCK_FILE`. The clock is an
append-only journal (`= <ms>` sets, `+ <ms>` advances), one atomic append per
event, so concurrent processes never lose an update and nothing needs a lock.

What the fake `sleep`/`date` cannot reach, and what to do:

| The code under test… | Control it with |
| --- | --- |
| calls `sleep N` (zsh has no builtin: it is the external one) or `date` | the clock, as is |
| waits with `common::sleep` (so: `spin::nap`, `poll::until`, `job::_follow_nap`) or reads `common::now` | the clock, as is: the production seam, below |
| still reads `$EPOCHSECONDS`/`$EPOCHREALTIME`/`$SECONDS` directly, naps with a bare `zselect`, `read -t` | route it through the seam if it is a wait or an age/deadline decision; else an env seam, or leave and list |
| runs `timeout N cmd` / `gtimeout` | stub `timeout` on `PATH` to log the limit and `exec` the command (see `pinentry_backend_repair_spec.sh`) |
| passes `--timeout 3s` to a tool (`rex`, `curl`, `ssh -o ConnectTimeout`) | the tool is a stub: assert the flag in its log, and make the stub answer "timed out" by exit code |
| compares mtimes (`find -mtime`, `(mh+24)`, `stat`) | `touch -t` the file relative to `spec_clock_now`; the comparison's "now" needs the seam |
| is POSIX sh (apply hooks, `pinentry-auto`, `preview-wipe-images`) | the same `PATH` stubs: sh has no other clock than `date` and `sleep` |
| resets `PATH`, or is `zsh` without `-f` under a `.zshenv` that rebuilds it | pass the tool by its `*_BIN` seam, or leave and list |

The production seam, in `home/dot_local/lib/common.zsh`: `common::now` (sets
`REPLY`: seconds; `-f` fractional; `-m` milliseconds) and `common::sleep
<seconds>`. Real path: `$EPOCHSECONDS` / `$EPOCHREALTIME` and `zselect`, no
fork. When `$COMMON_CLOCK_FILE` names a readable file (`spec_clock_set` exports
it, the same file as `$SPEC_CLOCK_FILE`) they fold and append to that journal
instead. Code decides on time through these two; a timestamp that is only
written (a log line, an id) still reads `$EPOCHSECONDS`. Two files that do not
load common.zsh have a local equivalent honouring the same variable:
`mux-bootstrap.zsh` (`_mux_sleep`) and `backup-drift.zsh` (`bkp::drift::_now`).

What the virtual clock cannot do: hold a process still. Code napping on it
beside the example runs at about 20,000 naps a second, and nothing can be
slipped in between two naps from outside. So:

- an event that must land at one exact point comes from a fake the code calls
  at that point (`at_poll <n> '<snippet>'` in `job_follow_spec.sh`), not from
  "advance, then act";
- a signal for a zsh with trap functions is sent from such a fake too: sent
  from outside it lands inside the nap loop, and a trap that forks from there
  can deadlock;
- an example whose point is an outside event landing INSIDE a bounded wait
  that has no such call, or the absence of something over time, stays on the
  real clock and says so in a comment (four in `job_follow_spec.sh`, one in
  `job_rex_spec.sh`). The seam that would free them is a stepped clock:
  `common::sleep` waiting for the test to release each nap.

## Converting a spec

Replace:

| Found | Becomes |
| --- | --- |
| `X=$(mktemp -d)` in a setup | `spec_sandbox; X=$SANDBOX` (keep the spec's variable name) |
| `rm -rf "$X"` in a cleanup, `AfterEach` that only removes and `unset`s | delete it: examples run in subshells, the tmpbase goes after the file |
| `ORIG_PATH=$PATH … PATH=$ORIG_PATH` | `spec_path_prepend "$dir"` |
| a heredoc stub that logs `"$*"` and exits, or adds a few lines | `spec_stub`, body single-quoted, `$X/…` written as `$STUB_DIR/…` |
| `cat "$X/tool.log" 2>/dev/null \|\| true` | `spec_stub_calls "$X" tool` |
| a hand-written fake `rex` | `spec_fake_rex`, its special arms as arguments, inline JSON moved to `view.json` / `clients.json` / `sessions.json` |
| `chezmoi … execute-template <f >out` in any shape | `spec_render_template f out` (keep a `2>file` the spec asserts on) |
| `sleep`, timing assertions, `( sleep N; … ) &` | see Policy 2 |

Do NOT touch:

- **Assertions.** `When`/`The` lines stay byte-identical, except a time-based
  one replaced by its deterministic equivalent (polls counted, virtual time).
- **Stubs with real behaviour**: a fake that is mostly logic, prints to stdout
  what the assertion reads, or shares ONE ordered log with other stubs
  (`echo "name $*" >>"$LOG"`). `spec_stub` logs per stub.
- **A log an example reads raw.** `spec_stub` flattens newlines in arguments;
  `rex_modal_spec.sh` asserts on them, so its fake stays.
- **Fixtures**: `Data` blocks, heredoc JSON/YAML, `$SHELLSPEC_TMPBASE/fixed-name`
  paths that an assertion spells out.
- **A spec you cannot run** (needs a daemon, a device, another OS).
- Anything where the helper call is not clearer than what it replaces.

Checklist, per file:

1. `shellspec tests/X_spec.sh` — note `N examples, F failures, S skips` and `wc -l`.
2. Convert setup/cleanup/stubs only. One mechanism at a time.
3. Run the file. Same N, F=0, same S. A changed count means an example was
   lost to a syntax slip: stop and diff.
4. `grep -n 'mktemp\|rm -rf\|sleep\|EPOCHREALTIME' tests/X_spec.sh` — each
   remaining hit is deliberate (say why in a comment) or a missed spot.
5. Run it twice more if it starts anything in the background.

## Pitfalls

- **The translator rewrites lines by their first word, everywhere** — inside
  heredocs and multi-line quoted arguments too. A stub body line starting with
  `The`, `It`, `End`, `Data`, `When`, `Describe`, `Context`, `Skip`, `Set`,
  `Path`, `Include`, `Before…`/`After…`, `Todo`, `Parameters` or `%text`/`%puts`
  becomes shellspec DSL and the FILE fails to parse ("0 examples"). Indent does
  not help; start the line with something else (`: ; The…`, a leading quote).
- **A hook must be silent.** Anything a `BeforeEach`/`AfterEach` writes to
  stderr fails the example (even with status 0); stdout leaks into the report.
  That is why the helpers print nothing and set a variable instead.
- **`dir=$(spec_sandbox)` loses the assignment** — and so does any helper
  called in `$(…)`. Call it plainly, then read `$SANDBOX` / `$SPEC_RENDERED`.
- **Subshell scoping cuts both ways.** What a `BeforeEach` exports reaches the
  example and dies with it (so no restore); what an example function sets is
  not visible to a later `The variable X` unless it ran under `When call`.
- **`When call` vs `When run`.** `call` runs a function in the example's shell:
  plain variables and functions are visible. `run` starts a process: only
  EXPORTED variables arrive (`export STUB_SERVER=down`, not `STUB_SERVER=down`).
  Stubs are processes too: every `STUB_*` knob must be exported.
- **A setup() fails only on its last command.** `spec_render_template` is loud
  in a hook because it writes to stderr; in a function an example calls, add
  `|| return 1`.
- **`echo "$*"` is not `printf '%s\n' "$*"`** under macOS `/bin/sh` (it expands
  backslashes). `spec_stub` uses printf; a log line with a backslash changes.
- **The clock's fake `sleep` is on the example's `PATH` too.** A spec's own
  watchdog loop would spin through it; that loop is the thing to remove.
- **Socket paths.** A sandbox path is one component longer than `mktemp -d`;
  bind Unix sockets (103 bytes on macOS) directly under `$SHELLSPEC_TMPBASE`.
- **Background stragglers.** Code that disowns work (`cmd &!`) outlives the
  example and writes into the next one's fixtures. The after-all hook now
  survives it; the example still needs the code to offer a foreground mode.

## The no-waits lint

`tests/no_real_waits_spec.sh` fails the suite when a test file waits on the
real clock: `sleep`, `timeout`/`gtimeout`, `zselect`, a timed `read`, or a
read of `EPOCHREALTIME`/`EPOCHSECONDS`/`$SECONDS`. Only commands count (see
`tests/no-real-waits.sh` for what is and is not one).

Until the old waits are converted, `tests/no-real-waits.baseline` lists
`<file> <waits> <clock-reads>` for each file that still has some. A file may
not exceed its line, and when you remove a wait you must lower the line (the
lint says which). Regenerate with `zsh tests/no-real-waits.sh >
tests/no-real-waits.baseline` after converting. When the file is empty, delete
it: the rule is then "none, anywhere".

## The two suites

| | `make test` (FAST) | `make test-all` (COMPLETE) |
| --- | --- | --- |
| Runs | every example not marked complete-only | every example |
| Suite budget (wall time, `--jobs $(JOBS)`) | 60 s | 180 s |
| Per-example budget | 0.1 s | none |
| `SPEC_SUITE` | `fast` | `complete` |

Both run every spec FILE. Membership is per EXAMPLE, and there is no list of
slow files: an example is in the fast suite unless it says otherwise.
`make test-one SPEC=…` and `make test-changed` set no suite: they run every
example of the specs they pick, with no budget. (`test-mux` is gone: the lane
was a hand-kept file list for the tmux migration; `make test-all` covers it.)

### Marking an example complete-only

An example that costs more than ~0.1 s (it needs a real scratch server, a real
daemon, real restic/git/hdiutil work, a nested shellspec, a cargo build…) says
so with one line, the reason starting with `complete-only:`:

```sh
It 'mounts the scratch volume'
  Skip if 'complete-only: real hdiutil mount' spec_complete_only
  When call mount_it
  The status should be success
End

Describe 'against a scratch rex server'
  Skip if 'complete-only: starts a real rex server' spec_complete_only
  BeforeAll 'start_server'     # not run in the fast suite
  AfterAll 'stop_server'
  It '…'
End
```

`spec_complete_only` (in `tests/spec_suite.sh`, loaded for every spec by
`.shellspec`) is true only under `SPEC_SUITE=fast`. Where the line goes
matters:

- in a `Describe`/`Context`, the group's examples are skipped AND none of its
  `BeforeAll`/`BeforeEach`/`AfterEach`/`AfterAll` hooks run (≈1 ms per example);
- in an `It`, the hooks around that example still run: shellspec evaluates a
  `Skip` inside the example, after `BeforeEach`. So when the cost is in the
  setup, give the example a `Context` of its own that carries the line. The
  fast run tells you: a skipped example that still shows up over budget is
  paying for its hooks.

One slow example does not take its file out of the fast suite; the rest of the
file still runs. The fast lane passes `--skip-message quiet`, so the skips are
counted in the summary but not listed. `grep -rn spec_complete_only tests/`
is the whole complete-only list.

Why not shellspec tags (`It 'x' slow` + `--tag`)? 0.28.1 has no negative
filter (`--tag '!slow'` selects nothing), so every FAST example would need the
tag; and a filtered-out group still runs its `BeforeAll`, which is where a
scratch server starts.

### Budgets

`tests/run-shellspec.sh` measures every run. After shellspec's report and its
own summary line it prints, on stderr, what was over:

```
run-shellspec: fast suite took 72 s, budget 60 s
run-shellspec: 2 examples over the fast budget of 0.1 s each (1.70 s in total), slowest first:
    1.250 s  tests/b_spec.sh:7  b runs restic
    0.450 s  tests/a_spec.sh:40  a starts a server
run-shellspec: OVER BUDGET (suite 72 s > 60 s; 2 slow examples); not failing the run (SPEC_BUDGET=warn)
```

| Variable | Default | |
| --- | --- | --- |
| `SPEC_BUDGET` | `warn` (set in the Makefile) | `fail`: a blown budget exits 103 when the run was otherwise green. `off`: no budgets. |
| `SPEC_SUITE_BUDGET` | 60 (`fast`), 180 (`complete`) | seconds of wall time for the run |
| `SPEC_EXAMPLE_BUDGET` | 0.1 (`fast`), none (`complete`) | seconds for one example |
| `SPEC_BUDGET_LIST` | 30 | how many offenders to print |

The end-of-run toast carries the same verdict (`— OVER BUDGET (…)`).
`make test SPEC_BUDGET=fail` tries the strict mode; the default flips in the
Makefile (`SPEC_BUDGET ?= warn`) once the examples over 0.1 s are marked.
An example's time is wall time under `--jobs`, so one sitting just under the
budget will cross it on a loaded machine: between two identical runs about
100 of 3,800 examples changed sides of 0.1 s, 5 went from under 0.1 s to over
0.15 s, 1 to over 0.2 s (2026-11-27, `--jobs 6`, other work on the machine).
So 0.1 s is the line for MARKING; before `SPEC_BUDGET=fail` becomes the
default, either mark with a margin or give the failing run a looser
`SPEC_EXAMPLE_BUDGET` (0.25) than the one the report is read against.
`tests/run-shellspec_budget_spec.sh` pins all of this against a fake shellspec
and the virtual clock (the wrapper reads its clock from `$COMMON_CLOCK_FILE`
when that is set), so none of those examples waits.

### Profiling

Every run through the wrapper times every example: `tests/spec_suite.sh`
replaces shellspec's two profiler hooks and appends one line per example to
`$SPEC_PROFILE_DIR/examples.tsv` (`file TAB line TAB seconds TAB
description`). The time is the example as shellspec runs it: `BeforeEach`,
body, `AfterEach`. `BeforeAll` and the file's start-up are in no example's
time; `files.tsv` beside it has each file's total. shellspec's own `--profile`
is not used: it refuses `--jobs`, and it reports shares of a busy-loop
counter, not a clock.

```sh
make test-all                # leaves $TMPDIR/spec-profile.complete.tsv (make test: …fast.tsv)
make test-profile            # totals, histogram, the 30 slowest  (SUITE=fast for the other)
tests/spec-profile.sh over  "$TMPDIR/spec-profile.complete.tsv"   # every example over 0.1 s: the to-do list
tests/spec-profile.sh files "$TMPDIR/spec-profile.complete.tsv"   # per file: seconds, examples, over budget
tests/spec-profile.sh run -o /tmp/p.tsv tests/job_spec.sh         # profile any selection
```

## The stepped clock

This replaces the last bullet of "What the virtual clock cannot do" above:
the five examples it lists no longer wait, and `job_follow_spec.sh` and
`job_rex_spec.sh` have no line left in the no-waits baseline.

The free-running clock makes every nap instant, so nothing can happen WHILE
the code is asleep. Stepped, each nap stops at a gate until the example lets
it through:

| Call | What it does |
| --- | --- |
| `spec_clock_stepped` | After `spec_clock_set`: from now on every nap stops at the gate (`common::sleep` and what is built on it, the fake `sleep`, in every process that inherits the environment). |
| `spec_clock_held` | Blocks until a sleeper is at the gate and leaves it there. `$SPEC_CLOCK_HELD` is `<pid> <ms> <request>`. |
| `spec_clock_step [n]` | n times: blocks until a sleeper is at the gate, advances the clock by what it asked for, lets it through. |
| `spec_clock_release` | Back to free-running. The sleeper at the gate and those queued go on. Never blocks. |

Neither side sleeps or polls. The sleeper reads a FIFO it has opened
read-write; the example opens that FIFO write-only, and the kernel holds that
open until the FIFO has a reader, which is "a sleeper is there".

**When to use which.**

- Free-running (`spec_clock_set` alone), the default: the code naps and the
  example only needs the outcome (how many polls, how long it believes it
  waited), or acts from a fake the code calls (`at_poll`).
- Stepped, when the example must act while the code is INSIDE a nap or a
  bounded wait that calls nothing (a signal, another process ending), or when
  its point is that the code is still napping after so many naps: an absence
  over the code's own time. Also for a signal sent from outside to a zsh with
  trap functions: held, it lands in a blocking read, as it does in the real
  `zselect`, not in the free-running clock's tight loop of appends.
- A wait in the kernel (a blocking `zsystem flock`) is invisible to both. The
  code announces it with `common::blocking <what>`, which stops at the same
  gate (`$SPEC_CLOCK_HELD` is `<pid> - <what>`) and moves no clock;
  `job::_rex_lock` does, on a test clock only.

**A worked example.** A failed job's follower stays in its tab until the tab
is closed. "It stays" used to be `sleep 0.5; kill -0 $FPID`. Now
(`tests/job_follow_spec.sh`):

```sh
FOLLOW_STEPPED=1 follow_bg j1        # spec_clock_set 1000; spec_clock_stepped; follower &
( spec_clock_step 5                  # five naps of its stay loop go by ...
  spec_clock_held                    # ... and it is at a sixth: it stays
  echo staying > "$JOB_SANDBOX/stayed"
  kill -HUP "$FPID" ) &              # the tab closes while it is in that nap
stepper=$!
wait "$FPID"; rc=$?                  # 129
kill "$stepper" 2>/dev/null; wait "$stepper" 2>/dev/null
cat "$JOB_SANDBOX/stayed" 2>/dev/null || echo "gone-early rc=$rc"
```

The stepping runs beside the `wait` because `spec_clock_step` and
`spec_clock_held` block until a sleeper comes: a follower that left instead of
staying would never come, and this way the example fails (`gone-early`)
instead of hanging. Step in the example's own shell when the nap is certain.

**Several sleepers.** One is at the gate at a time; the others queue on the
gate's lock, unseen, and reach the gate in no promised order. A step lets
exactly one through. To see two things blocked at once, hold one of them with
a fake's own FIFO and the other at the gate (`creates one session for two
simultaneous jobs` in `job_rex_spec.sh`), and when the example must tell
which of two events came, send both down one FIFO.

**The deadlock rule: a held sleeper never outlives its example.** An example
does nothing for this; it only `wait`s for what it started.

1. After every example of the suite, `spec_clock_after_each` (registered in
   `spec_helper_configure`) releases the gate the example set up.
2. Before a file's tmpbase is removed, `spec_helper_drop_tmpbase` releases
   every gate still closed under it.
3. A sleeper that finds no FIFO at the gate (released, or gone with the
   tmpbase) does not stop.
4. A sleeper nobody came for gives up after `COMMON_CLOCK_STEP_BOUND` real
   seconds (300) and takes the gate's FIFO away, so the ones queued behind it
   pass at once. This is a dead man's switch for a run that was killed
   outright, the only real timer in the mechanism; no passing example meets
   it.

Not stepped: whatever the free-running clock does not reach either, and the
two local stand-ins for `common::sleep` (`_mux_sleep` in `mux-bootstrap.zsh`
when common.zsh is not loaded, `backup-drift.zsh`), which run free.

### Marking: what a `Skip` does not skip

In shellspec 0.28.1 a `Skip if` inside an `It` skips the `When` and `The`
lines only. Statements written before `When` still run, so an example whose
body builds a fixture first pays for it in the fast suite while reporting
SKIPPED. Two ways out:

```sh
It 'retags a real m4b'
  Skip if 'complete-only: real ffmpeg' spec_complete_only
  spec_complete_only && return 0        # nothing below runs in the fast suite
  build_real_media
  When call retag
  ...
End
```

or give the examples a `Describe`/`Context` of their own and mark that: a
skipped group runs neither its hooks nor its examples' bodies. A body that
only DEFINES a function before `When` needs neither.

Decide marks from a quiet run with the exec pool warm (below): the first
examples of a file to write stubs pay macOS's first-exec charge for the
pool's slots, and look slow for no reason of their own.

## Per-example cost: what to know

- **The exec pool** (`spec_helper.sh`, "THE EXEC POOL"): a `#!` script made
  executable inside an example runs from a pooled inode and is removed when
  the example ends. Write stubs that several examples share in `BeforeAll`.
  `Include tests/exec_warm_helper.sh` and `BeforeAll 'spec_exec_pool_warm 6'`
  pay for the slots before the first example instead of inside it.
- **Build static fixtures once per file** (stubs, schema databases, git
  repositories, rendered templates) and copy or link them per example. A
  shared stub logs into a per-example path named by an exported variable; an
  example that needs its own version of a stub writes it to its own
  directory, ahead of the shared one on PATH.
- **`HOME=/home/…` costs 100 ms per dotfile lookup on macOS**: `/home` is an
  autofs mount point, and every jq (`~/.jq`) and every zsh without `-f` waits
  for it to answer. Use a path that does not exist anywhere else, such as
  `/nohome/u`.
- **`-f` on every zsh the spec starts**: without it `~/.zshenv` is read, which
  costs time and lets the machine's configuration into the example.
- **A sandbox path contains `//`** (`$TMPDIR` ends in a slash): compare
  against `${SANDBOX:a}` when the code under test prints `$PWD`.
- **`spec_clock_set` forks about ten times.** In a group where every example
  needs the clock, set it in `BeforeAll` and reset per example with
  `: >"$SPEC_CLOCK_FILE"; spec_clock_set N`.

