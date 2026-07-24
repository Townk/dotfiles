# Handoff: clipboard progress-HUD freeze on the affected laptop

**Date:** 2026-07-24 · **Severity:** machine-level input freezes while the HUD is visible
**Repo:** this chezmoi repo, on `master` at `690ccd7` (all relevant commits pushed)
**You are on:** the affected laptop — the ONLY machine that reproduces this. The design
docs and session ledger for this feature are gitignored (`docs/superpowers/`,
`.superpowers/`) and therefore NOT on this machine; this document is
self-contained on purpose. Trust it over guesses, but verify everything —
several "obvious" hypotheses have already died to probes.

## 0. Stabilize first (before any debugging)

The currently deployed engine can freeze the machine during a remote-file
paste. If you need the machine stable while working:

```sh
# Roll back ONLY the engine to the last known machine-safe version
# (capsule freezes at 0% and vanishes, but no machine freeze):
git -C ~/.local/share/chezmoi checkout b21ce38 -- home/dot_local/libexec/executable_pick-clipboard
chezmoi apply ~/.local/libexec/pick-clipboard
```

Restore with `git checkout master -- home/dot_local/libexec/executable_pick-clipboard`
+ re-apply when ready to test fixes. Also useful in a freeze: killing
Hammerspoon (`pkill -9 Hammerspoon; open -a Hammerspoon`) restores input
immediately if the freeze is HS-side (see §4-H1). Kill leftovers between
runs: `pkill -f 'restore-id'; pgrep -fl 'hs -c' && pkill -f 'hs -c'`.

## 1. What this system is (30-second map)

Ctrl+Y in the clipboard pickers "materializes" a remote file clip locally so
Cmd+V is instant. All logic lives in the zsh engine
`home/dot_local/libexec/executable_pick-clipboard` (deployed at
`~/.local/libexec/pick-clipboard`):

- The GUI picker (`home/dot_config/hammerspoon/modules/apps/clipboard-picker.lua`)
  spawns `hs.task.new("/bin/zsh", cb, {"-lc", "pick-clipboard --restore-id <id>"})`.
- Case-3 of `clip::copy_files_by_id` pulls via
  `/opt/homebrew/bin/rsync -a --info=progress2 -e 'ssh -o ClearAllForwardings=yes -o BatchMode=yes -o ConnectTimeout=10' host:path dst/`,
  piping rsync's stdout into `clip::progress_stream` (last pipeline segment,
  runs in-process; zselect-timed reads, 2s stall ticks; state in
  `CLIP_PROGRESS_*` globals).
- Each throttled tick calls `clip::progress_emit`, which drives the on-screen
  capsule via quiet `hs` IPC: `hs -q -c 'require("osd").progress("glyph:nf-md-download", <pct>, "<label>"[, <state>])'`.
- The capsule (`M.progress` in `home/dot_config/hammerspoon/modules/osd/init.lua`)
  is a 300×56 hs.canvas top-right: label row + segmented bar + ✕ cancel
  (mouse events enabled), 15s idle watchdog, stalled state = hourglass + dim.
- Success toast comes from `clip::copy_toast_for_id` → `~/.local/bin/notify`
  (OSD via the same `hs` IPC). Failure (GUI): OSD toast + persistent
  `hs.notify` item. Cancel: exit 130 contract, quiet toast.

Tests: `shellspec tests/pick-clipboard-feedback_spec.sh tests/pick-clipboard-files_spec.sh`
(90 examples; shellspec runs with zsh per `.shellspec`).

## 2. Symptom timeline (all on this laptop; another machine never reproduced anything)

1. **Round 1** (engine at `21bedf5`, synchronous emits): capsule appeared,
   percent never moved, capsule vanished ~15s (watchdog), NO failure message;
   much later the "Copied from <host>" toast fired and Cmd+V worked. So the
   TRANSFER path is fine; only progress presentation is broken.
2. **Round 2** (at `b21ce38`, adds label/v2 capsule): same freeze+vanish.
   Probes on this laptop all passed in isolation:
   - zselect present in the PATH zsh; rsync 3.4.4; `hs -c` round-trip 12ms.
   - Probe A (manual `hs -c` progress/stalled/hide sequence): capsule painted
     and updated, no Lua errors.
   - Probe B (real local rsync piped into `clip::progress_stream` with a
     logging fake `hs`): perfect 0→25→51→76 cadence.
   - **Smoking gun**, real flow via `hs.task`: `pgrep -fl 'hs -c'` showed ONE
     `hs -c require("osd").progress(..., true)` process ALIVE ACROSS MANY
     SECONDS — a hung synchronous emit freezing the sink between reads.
    (Also observed: an unrelated font-sync `rsync ... symbols.db <peer>:...`
     running at that instant — the hung call was a stalled repaint whose
     hourglass glyph resolution does a cold sqlite read of that same
     `symbols.db`; and a duplicate concurrent rsync of the same clip from an
     earlier attempt.)
3. **Round 3** (current, `a81c509`+`690ccd7`): emits became supervised
   fire-and-forget — spawned `( fd-close; exec hs -c ... ) &`, at most one
   in flight, predecessor `kill -TERM`ed (after a 30ms grace, gated on a
   live predecessor), teardown kills-then-hides, stall glyph pre-warmed at
   canvas creation. Result per the user: **WORSE — the whole computer
   freezes while the overlay is up.** No further detail yet; get exact
   symptoms first (input dead? cursor moves? how long? recovers by itself?).

## 3. What is already ruled out

- Engine parsing/throttle/aggregation logic (probe B + 87 green examples).
- Lua repaint path in isolation (probe A).
- zselect availability, rsync version/buffering (3.4.4 streams ~1/s piped;
  do NOT add `--outbuf`), `hs` CLI baseline latency.
- The transfer itself (always completes; paste works).

## 4. Hypotheses for the machine freeze, ranked

- **H1 — Hammerspoon main-thread saturation → event-tap input freeze.** This
  HS config runs key event taps (`modules/keybindings/key_events_router.lua`);
  when HS's main thread is busy/blocked, macOS event taps stall ALL keyboard
  /mouse until the tap times out — reads as "computer freezes". Suspects for
  the saturation, in order:
  a. **hs client storm:** if `kill -TERM` does not actually reap spawned
     `hs` clients (e.g. stuck in Mach IPC send), they accumulate — dozens of
     concurrent CFMessagePort clients hammering HS while each `osd.progress`
     call rebuilds ~25 canvas elements + cancels/re-arms an hs.timer.
     CHECK: during a repro, sample `pgrep -f 'hs -c' | wc -l` every second;
     `ps -o stat,etime,command -p $(pgrep -f 'hs -c')` (state `U`/`Z`?).
  b. **The 2s stall ticks + kill-grace interplay** producing more concurrent
     clients than intended (the ≤1-in-flight invariant failing in practice).
  c. **Console log flood or hs.ipc error path** on killed-mid-handshake
     clients (HS console: any repeated errors? `hs -c 'print("alive")'`
     latency during repro?).
  CHECK for the freeze side: `log show --last 5m --predicate 'eventMessage CONTAINS "event tap"'`
  (look for "timeout... disabled" entries), and `sample Hammerspoon 3 -file /tmp/hs.sample.txt`
  DURING a freeze (from a shell that still responds, or via ssh from another
  machine — sshd keeps working through an input freeze).
- **H2 — killed-mid-IPC clients corrupt/park the hs.ipc port**, making every
  later `hs` call (including the watchdog-adjacent ones) slow → cascading
  backlog. CHECK: after a repro, is `time hs -c 'print("x")'` still 12ms?
- **H3 — canvas mouse-event tracking:** the capsule enables
  `canvasMouseEvents(true)`; with the pointer over/near the capsule region,
  tracking + constant full-element rebuilds every tick may run the runloop
  in tracking mode and starve IPC replies (this would ALSO explain round-2's
  hung emit!). CHECK: reproduce with the mouse parked far from the capsule
  vs. hovering it. If hover correlates → rebuild-less repaints (update
  element attributes in place instead of remove-all/insert-all) and/or
  disable mouse events except on the ✕ element.
- **H4 — something environment-specific interacting (endpoint security
  scanning each short-lived `hs` spawn?).** The storm of tiny
  process spawns (one per tick) is new in round 3. CHECK: does the process
  list show endpoint security? Does the
  freeze correlate with process-spawn bursts (try throttling emits to 1/2s
  via `PICK_CLIPBOARD_STALL_SECS` + a temporarily raised min-spacing)?

## 5. Diagnostic playbook (safe order)

1. Get exact freeze semantics from the user first (input? cursor? duration?
   self-recovers? Hammerspoon "not responding" in Activity Monitor?).
2. Instrument WITHOUT the real HUD: `PICK_CLIPBOARD_HS=<logging fake>` end-to-end
   run (see probe B shape below) — confirms engine emits cadence + process
   counts with zero HS involvement.
3. Real repro with sampling (ideally via ssh from another machine so the
   freeze can't kill your terminal): watch `pgrep -f 'hs -c' | wc -l`,
   `sample Hammerspoon`, HS console, event-tap log messages.
4. Bisect the deployed engine between `b21ce38` (sync emits — capsule
   freezes, machine fine) and `690ccd7` (async — machine freezes):
   `git checkout <sha> -- home/dot_local/libexec/executable_pick-clipboard && chezmoi apply ~/.local/libexec/pick-clipboard`.
5. Probe-B shape (engine-only, fake hs):
   ```sh
   S=/tmp/clip-probe; mkdir -p $S; : > $S/hslog
   printf '#!/bin/sh\n[ "$1" = "-c" ] && printf "%%s\\n" "$2" >> /tmp/clip-probe/hslog\n' > $S/fake-hs
   chmod +x $S/fake-hs
   PICK_CLIPBOARD_NO_RUN=1 PICK_CLIPBOARD_HS=$S/fake-hs zsh -f -c '
     source ~/.local/libexec/pick-clipboard
     clip::progress_begin
     /opt/homebrew/bin/rsync -a --info=progress2 --bwlimit=3000 <bigfile> /tmp/clip-probe/dst/ 2>/dev/null | clip::progress_stream 0 1 probe
     clip::progress_end
   '
   cat /tmp/clip-probe/hslog
   ```
6. For a real remote repro use the existing big row (find with
   `sqlite3 ~/.local/share/pick-clipboard/history.db "SELECT id, source_host FROM clips WHERE type_kind IN ('files','file','directory') ORDER BY last_ts DESC LIMIT 5;"`,
   clear `~/.cache/pick-clipboard/files` to force a re-pull, launch headless
   with `hs -c 'hs.task.new("/bin/zsh", function(c) print("exit",c) end, {"-lc","$HOME/.local/libexec/pick-clipboard --restore-id <ID>"}):start()'`).

## 6. Fix directions (in preference order — the user's UX principles govern)

Principles already ratified by the user: progress must be visible; the HUD
disappearing must mean done-or-dead, never waiting; a cancel is not a
failure; the user must always be able to tell visually what is going on.

1. If H1a/H2 (client storm / IPC pileup): stop spawning a process per tick.
   Best structural option: move progress transport OFF hs.ipc — e.g. the
   engine writes ticks to a state file and ONE long-lived Lua-side
   `hs.timer` (armed by a single `hs -c` at pull start, disarmed at hide)
   polls it 4×/s and repaints; or a single persistent `hs -c` reader fed by
   a fifo. Zero per-tick spawns, zero kill races, sink can never block.
2. If H3 (tracking-mode starvation): repaint by mutating canvas element
   attributes in place (`canvas[i].fillColor = ...`) instead of
   remove-all/insert-all; restrict mouse tracking to the ✕ element only.
3. If H4 (EDR per-spawn scanning): same fix as (1) — eliminate per-tick
   spawns; it is the robust answer regardless.
4. Whatever the root cause: keep the invariant that a wedged presentation
   layer can never stall the transfer, and the watchdog reaps a dead
   driver's capsule.

A stopgap is acceptable if the root cause runs deep: gate the HUD behind an
env/config flag (default off on this machine) so pastes are usable, keeping
toasts — document what remains broken. Better a capsule-less transfer with
honest toasts than a frozen machine.

## 7. Repo conventions that bind you

- Conventional commits; NEVER add Co-Authored-By or any AI-attribution
  trailer. GPG signing is on — if signing fails, ask the user to unlock.
- `docs/superpowers/` and `.superpowers/` are gitignored — never `git add`
  them. This handoff file (docs/handoff-clipboard-hud-freeze.md) IS tracked;
  update it with your findings as you go (it is the shared ledger between
  machines), and push your commits when green.
- shellspec: zsh shell; sandboxed tests must run `zsh -f` (the repo
  ~/.zshenv clobbers XDG dirs in every non-f zsh); NEVER embed a raw \x1f
  via $(printf) inside shellspec DSL args (collides with shellspec's field
  separator — use in-shell checker functions); `/bin/sh` `echo` mangles
  doubled backslashes — use `printf '%s\n'` in fixtures.
- zsh gotchas already paid for: the custom zsh build parses two-digit
  `exec 10>&-` as a bare command — FATAL even under `|| true` (single-digit
  fds only); under `set -eu -o pipefail` a bare `read; rc=$?` errexits on
  EOF — use `rc=0; read || rc=$?`; shellspec's internal pipe fds leak into
  detached spawns and wedge its executor — hence the `for _fd in {3..9}`
  close loop before `exec` in backgrounded spawns.
- `tests/pick-clipboard-files_spec.sh` is the regression gate for
  `clip::copy_files_by_id` — it must stay green.
- Known pre-existing/unrelated: `tests/input-common_spec.sh` has one
  environmental failure (mise-shim) on the mini — ignore if seen.

## 8. Acceptance criteria

1. No machine/input freeze at any point of a large pull from a remote peer.
2. Capsule: uses a bright `Preparing to copy <name> from <host>…` hourglass
   before the first progress record, then `Copying …` while percent climbs
   live; hourglass-dim only during genuine stalls (and holds >15s without
   vanishing), hides at completion, then "Copied from <host>" toast.
3. ✕ cancel works (quiet "Transfer cancelled", no failure notification,
   re-pick re-pulls); Ctrl+C in the TUI pane ditto.
4. Failure (e.g. peer path deleted): OSD "Copy failed — <reason>" toast +
   persistent notification; no orphaned capsule.
5. Both clipboard suites green; full `make test` green modulo the known
   environmental failure; commits pushed.

## 9. Affected-laptop diagnostic ledger

### 2026-07-24 — local continuation

- Exact freeze semantics: the pointer continues moving normally, but keyboard
  input and mouse/trackpad clicks stop for approximately as long as the HUD is
  visible. Input recovers without restarting the machine or Hammerspoon,
  although the observed recovery may have coincided with the terminal finally
  regaining focus. This is an input-event stall, not a complete OS hang.
- Playbook step 2 repeated on this machine against the deployed engine with
  real rsync 3.4.4 and a logging `PICK_CLIPBOARD_HS` fake. A 12 MiB local file
  limited to 3000 KiB/s completed in 4.56s. The sink emitted 0%, 25%, 50%, and
  76%, then `progressHide()`; no fake-HS process remained. This reconfirms the
  engine cadence and teardown without involving Hammerspoon, so the live
  Hammerspoon/IPC path remains the boundary of the failure.
- Playbook step 3, genuine uncached 2.5 GiB remote pull with the pointer parked
  at the bottom-left: 240 half-second samples over 120s saw zero resident `hs`
  clients, real IPC latency remained 10ms during and after the transfer, and
  no event-tap timeout appeared in unified logs. A 30s Hammerspoon sample was
  overwhelmingly idle in `mach_msg`; its brief active samples were IPC
  callbacks inside `canvas_insertElementAtIndex`. This evidence rejects an
  accumulating client storm (H1a) and persistent IPC-port degradation (H2).
- The same run logged `-[NSWindow makeKeyWindow]` against the non-keyable
  `HSCanvasWindow` once per stalled repaint, almost exactly every two seconds.
  The warning continued for the HUD's lifetime. With the pointer far from the
  canvas, this weakens hover-specific tracking as the trigger, while directly
  implicating the full canvas show/rebuild path. The user did not exercise
  input during this run, so it did not establish whether the warning cadence
  and input stalls coincide.
- Visible cadence on that pull: grey hourglass at 0% for a long interval,
  bright download arrow at 50% for about one second, then grey/hourglass at
  50% until hide. The completion toast appeared two to three seconds after
  hide. The transfer itself completed successfully.
- A second remote-manifest attempt referenced a path no longer present on its
  origin and correctly failed with rsync code 23. During its brief 0% stalled
  HUD interval, the user actively tested clicks and typing; both worked
  normally. Therefore HUD visibility, 2s stalled repaints, and the repeated
  non-keyable-canvas warning are not by themselves sufficient to trigger the
  input freeze. Duration, a live-progress transition, or another condition in
  the successful large-pull path is required.
- Active-input repeat of the successful 2.5 GiB pull reproduced pulsed keyboard
  and click stalls, especially with Finder focused and while the HUD was white
  (live progress, hence more frequent IPC emits). The transfer still completed;
  279 half-second samples again saw no resident CLI client, and post-run IPC
  latency was 10ms.
- Root cause: Hammerspoon 1.1.1's `hs.ipc` print-mirroring recursion bug. The
  Hammerspoon Console contained hundreds of identical `hs.ipc: Instance ...
  already recursing, refusing request` warnings from one second. A concurrent
  process sample showed the main thread spending most of that interval in
  Console `NSTextView` layout/scrolling reached from event-tap/log paths. Finder
  activity triggers this config's enabled window-drag debug prints; when a
  non-quiet `hs -c` progress request is active, the print mirror recursively
  warns and floods the Console. The flood blocks Hammerspoon's main thread and
  therefore its input event taps. Upstream Hammerspoon PR 3845 fixes this exact
  warning cascade after 1.1.1.
- Fix under validation: invoke progress and hide as `hs -q -c`. Quiet mode
  disables console mirroring for these presentation clients, removing the
  recursion trigger without changing the Lua payload or transfer isolation.
  The fake-HS fixtures now accept only `-q -c`, making every payload assertion
  a regression check. Both clipboard suites pass: 87 examples, 0 failures.
- Live validation of the quiet-IPC fix passed on the same 2.5 GiB pull while
  the user actively used Finder: no keyboard, click, or pointer stalls. The
  transfer completed, its toast followed hide immediately, post-run IPC was
  10ms, and no recursion flood returned. The freeze is fixed.
- Remaining progress defect: the percent now advances a few times, but mostly
  in large jumps; the HUD spends most of the pull grey/stalled. Instrument the
  next run at the real rsync-CR boundary and at each HUD emit to determine
  whether the 2s stall detector is misclassifying normal output gaps or rsync
  is genuinely silent.
- Progress isolation: direct remote rsync with a timestamped fake HUD produced
  108 engine frames—0%, then every integer 1–99% at roughly 1–2s spacing, then
  hide. The shell path is healthy. A prior relay trace also captured 152 rsync
  updates over the 150s pull while real Hammerspoon showed only a few live
  frames. Loss is therefore in the real Lua canvas presentation path.
- Lua fix under validation: retain the canvas elements, replace existing slots
  in place, and call `show()` only on hidden→visible transitions instead of
  removing/reinserting every element and re-showing every tick. A synthetic
  21-frame real-Hammerspoon sequence completed in 0.29s total; unified logs
  showed one `makeKeyWindow` warning for the initial show, not one per update.
- Final presentation boundary found after the first live repaint validation
  still stayed at grey 0% while 1.2 GiB had already landed: detached real `hs`
  emitters inherited fd 0, which inside `progress_stream` is rsync's progress
  pipe. The real CLI reads stdin and consumed progress records that belonged
  to the engine; the fake CLI ignored stdin, explaining its perfect 0→99
  trace. Progress and hide spawns now redirect stdin from `/dev/null`.
  Fake-HS fixtures require both `-q -c` and a character-device fd 0, so the
  regression gate covers quiet IPC and progress-pipe isolation. Clipboard
  suites remain 87/87 green.
- Final live validation passed: five genuine initial 0% stalled frames during
  the ~10s SSH/rsync setup, then every percentage 1–99% in order at ~1–2s
  spacing, then hide and successful completion. Finder input remained fully
  responsive throughout. One `makeKeyWindow` warning occurred for initial
  show, with no per-frame warnings or event-tap timeout. The user suggested
  presenting the initial no-data phase as “Preparing to copy…” rather than
  “Copying …” at a grey 0%.
- The initial no-data phase now renders a bright hourglass with “Preparing to
  copy …”; the first rsync record switches to the normal “Copying …” state,
  while later data-flow gaps still use the dim stalled state. The focused
  regression passes, bringing the clipboard suites to 88/88. A live synthetic
  preview confirmed the preparing icon and text are bright white.
- Final HUD refinement: 32 narrow bar segments, a 14px capsule radius, and a
  cancellable ✕ with reserved right-side spacing and a circular hover
  highlight. Live pointer testing confirmed the hover and click target.
- Staged copies now expire after 24 hours on an opportunistic engine-start
  sweep. The sweep removes both expired bytes and localized history rows that
  would otherwise point at missing cache paths. Interrupted transfers use
  rsync's relative `.rsync-partial` directory and retain their partial bytes;
  the next identical pull reuses them.
- Terminal UX validation passed on a real large pull: the in-pane header,
  progress meter, and Ctrl+C hint remained readable; Ctrl+C exited 130 with a
  quiet cancellation message and retained a 305 MiB partial. The next terminal
  run resumed and completed cleanly, removed its staging marker/partial
  directory, and produced the expected final file.
- This public-repository handoff was sanitized before tracking: machine roles
  and peer names are generic, with no employer, internal host, account, domain,
  or product identifiers.
