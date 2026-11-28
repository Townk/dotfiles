# Spec scaffolding

Shared setup for the shellspec suite. The helpers live in `tests/spec_helper.sh`
(loaded for every spec; each has a contract comment there) and are pinned in
`tests/spec_helper_spec.sh`.

## Policy

1. **Two suites.** FAST must finish in 60 s, COMPLETE in 180 s (`--jobs 6` on
   the owner's machine). A spec that cannot run in the fast suite says why.
2. **No test waits.** No `sleep`, `timeout`, `read -t`, polling loop or
   "took at least / less than N seconds" assertion in a spec. Approved
   alternatives, in order of preference:
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
| `spec_clock_set [t]` / `_advance <s>` / `_now [ms]` / `_slept` | A virtual clock, with a fake `sleep` and `date` on `PATH`, shared by every child process. |
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
| reads `$EPOCHSECONDS`/`$EPOCHREALTIME`/`$SECONDS`, naps with `zselect` (`spin::nap`, `poll::until`, `job::_follow_nap`), `read -t` | the production seam (below); until then an env seam, or leave and list |
| runs `timeout N cmd` / `gtimeout` | stub `timeout` on `PATH` to log the limit and `exec` the command (see `pinentry_backend_repair_spec.sh`) |
| passes `--timeout 3s` to a tool (`rex`, `curl`, `ssh -o ConnectTimeout`) | the tool is a stub: assert the flag in its log, and make the stub answer "timed out" by exit code |
| compares mtimes (`find -mtime`, `(mh+24)`, `stat`) | `touch -t` the file relative to `spec_clock_now`; the comparison's "now" needs the seam |
| is POSIX sh (apply hooks, `pinentry-auto`, `preview-wipe-images`) | the same `PATH` stubs: sh has no other clock than `date` and `sleep` |
| resets `PATH`, or is `zsh` without `-f` under a `.zshenv` that rebuilds it | pass the tool by its `*_BIN` seam, or leave and list |

Proposed production seam (NOT built; owner approves first): in
`home/dot_local/lib/common.zsh`, `common::now` (sets `REPLY`; `-f` for
fractional) and `common::sleep <seconds>`. Real path: `$EPOCHSECONDS` /
`$EPOCHREALTIME` and `zselect`, no fork. When `$SPEC_CLOCK_FILE` is set they
fold and append to that journal instead (a `while read` loop, no fork either).
`spin::nap`, `poll::until` and `job::_follow_nap` are the first three callers.

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
