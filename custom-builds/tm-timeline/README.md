# tm-timeline

The compiled timeline pane for `tm` scrub sessions (spec 2026-07-04 §5.1),
built on the pty-frame pattern: a small libexec binary doing the one thing
the shell does badly — raw-mode input, event-driven flicker-free truecolor
rendering, resize handling, near-instant zellij focus tracking.

All session logic stays in shell: `j`/`k`/`a` shell out to
`system-backup-tm ctl|apply`, and the pane just reflects the session dir's
state files (`ladder`, `rung`, `closed`). Theme colors arrive as flags from
the single-source palette; nothing is hardcoded.

`system-backup-tm timeline` falls back to its zsh loop when this binary (or
Go) is missing.

Build: `make install` → `~/.local/libexec/tm-timeline` (auto via the
run_onchange chezmoi hook when main.go/go.mod change).
