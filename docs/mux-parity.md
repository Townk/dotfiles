# Mux parity ledger — Zellij ↔ tmux config plane

The drift **detector** for the dual-backend migration (spec §4,
`docs/superpowers/specs/2026-07-21-tmux-migration-design.md`): one row per
behavior, with each backend's implementation and its parity status. Any
keybind or chrome change on either side MUST update its row here — this is a
review gate until Phase 8 makes the keymap half drift-proof (both keymaps
generated from the shared YAML; the ledger then shrinks to chrome/widget
behaviors).

Status legend: ✅ parity · 🟡 approximation (documented divergence) ·
⏳ pending (later phase, backend column names the owner) · ❌ n/a by design
(§6 disposition).

## Modes / key tables

| Behavior | Zellij impl | tmux impl | Status | Notes |
|---|---|---|---|---|
| Leader | `Alt w` → "tmux" mode (config.kdl) | real `prefix M-w` | ✅ | D3 — WezTerm/Ghostty chord forwards serve both verbatim |
| Mode persistence | per-client modes | `set key-table` (session-scoped) | 🟡 | D2; multi-client-same-session sees shared mode |
| Leader from non-normal modes | unavailable (leader only from Normal) | prefix unavailable in non-root tables | ✅ | R4 verified by construction |
| Mode exit | `esc` → normal (shared_except) | `Escape` → `set key-table root` in every table | ✅ | ESC cancels, never Ctrl+C |
| Locked mode | locked table; only `Alt esc` exits | `key-table locked`; only `M-Escape` exits | ✅ | max passthrough |
| Mode indicator | zj-hud bar mode segment (colors/icons) | status-left `[#{client_key_table}]` plain text | 🟡 | Phase 4 brings the themed bar (D6) |

## Leader chords (Zellij "tmux" mode ↔ tmux prefix table)

| Chord | Zellij | tmux | Status | Notes |
|---|---|---|---|---|
| `v` / `s` splits | NewPane right/down | `split-window -h` / `-v` | ✅ | |
| `z` zoom | ToggleFocusFullscreen | `resize-pane -Z` | ✅ | |
| `f` frame toggle | TogglePaneFrames | `set -w pane-border-status` | 🟡 | different affordance; frames are off-by-default both sides |
| `L` locked / `l` scroll / `o` session / `p` pane / `t` tab | SwitchToMode | `set key-table` / `copy-mode` | ✅ | |
| `q` quit | themed gum confirm (zellij-quit-confirm) | themed `input::confirm` popup (mux-quit-confirm) | ✅ | per-backend kill path; ONE script — the zellij keybind now runs mux-quit-confirm too (Phase 6; zellij-quit-confirm retired) |
| `Y` / `M-y` copy-pwd | context-keys `run copy-pwd {pid}` (flash-free) | `run-shell copy-pwd #{pane_pid}` | ✅ | same script, PID source per backend |
| `,` terminal config | context-keys → edit-terminal-config | same script, tmux branch (focus-or-create window) | ✅ | outer terminal via tmux session env |
| `i`/`u`/`k` alarms | zj-hud alarm pipes (bar renders) | `monitor-silence 30` / `monitor-activity` / clear + `display` | 🟡 | Phase 4 adds flag styling + HS notify (D6) |
| `U`/`G` resume pickers, `c` clipboard | zellijModalRun floats | display-popup via tmux-modal --inject | ✅ | libexec pickers called directly (zellij thins keep zellij glue) |
| leader-again | exits mode | `send-prefix` (raw M-w to app) | 🟡 | closest useful equivalent |

## Root-table keys

| Key | Zellij | tmux | Status | Notes |
|---|---|---|---|---|
| `C-hjkl`/arrows focus | vim-navigator wasm (smart-splits protocol) | `if -F @pane-is-vim∥fzf` → send / select-pane | ✅ | D4/D13; same nvim plugin both sides |
| `C-S-hjkl`/arrows resize | vim-navigator resize | vim-aware `resize-pane 2` | ✅ | |
| `C-j/k` in fzf | context-keys `when fzf: $source` | fzf comm match in the same `if -F` | ✅ | fast lane, no fork |
| `C-j/k` in agents | `when agent,cursor-agent: key down/up` | `is_agent` ps probe → `send-keys Down/Up`, chained before the vim/fzf lane | ✅ | D21; verified with real keystrokes (nested tmux): an `agent` pane receives `ESC[B`/`ESC[A` |
| `Shift+Enter` | context-keys: kitty CSI-u to pi/claude, alt-enter to agents, tm apply route | `extended-keys always`: CSI-u to kitty-negotiating apps; plain apps get `\e[27;2;13~` | 🟡 | plain-app encodings differ (`\e[13;2u` vs xterm form); `extended-keys-format csi-u` is the alignment knob — decide Phase 5 |
| `J/K/H/L`, `Shift+↑↓`, `A`, `S` tm-scrub routes | context-keys over yazi/hunk/diffnav/tm | `if -F` on the `@ctx` pane option → `system-backup-tm route --session '#{@tm_session}'`; `H/L` → `select-pane`; `S` → `send-keys e s` on `tm-diff` | ✅ | D20 stamp vocabulary (`tm` / `tm-explore` / `tm-diff`); routes address the SESSION, not a pid |
| `Alt Enter` fullscreen toggle | context-keys → terminal-toggle-fullscreen | `is_fzf` ps probe → raw key, else `run-shell -b terminal-toggle-fullscreen` | ✅ | same script both backends; the fzf clause keeps the QL "separate window" accept key |
| `C-S-u/g` glyph/gitmoji pickers | zellijModalRun floats | display-popup via tmux-modal --inject (-B, fzf owns the box) | ✅ | insert-without-dismiss works (pick sink tmux branch) |
| `Alt /` search dialog | zj-hud role "search" float | copy-mode `/` incremental (stage 1) | 🟡 | D12 stage 2 hud owns the dialog |
| `Cmd+F` (terminal → mux search) | WezTerm/Ghostty send `\x1b/` | same bytes — `M-/` is the search entry here too | ✅ | D22: no per-backend branch needed, the chord parity of D3 covers it |
| `Cmd+F` (terminal) | `text:\x1b/` → Alt+/ | same bytes → `M-/` | ✅ | D22: both backends bind `M-/` as the search entry, so the terminal needs no per-backend branch |

## Mode tables

| Behavior | Zellij | tmux | Status | Notes |
|---|---|---|---|---|
| tab: h/l/arrows, Tab, 1–0, n, N, x, s | native actions | previous/next-window, last-window, select-window, themed rename popup, new-window, kill-window, synchronize-panes | ✅ | mux-rename retires the command-prompt stopgap |
| tab: `[`/`]` BreakPaneLeft/Right | native | `join-pane -h -t :-1/+1` | 🟡 | multi-pane windows fold differently |
| tab: `T` quick-launch | modal float | popup via tmux-modal → ql_tx dispatch | ✅ | focus-or-create by @ql_id / =name |
| pane: focus/splits/zoom/kill/rename | native actions | select-pane, split-window ±b, resize -Z, kill-pane, select-pane -T stopgap | ✅ | |
| pane: `S` stacked, `p` pin, `e` embed↔float, `t` float toggle | native | none | ❌ | §6 dispositions (stacked unused; popups are modal) |
| pane: `P` quick-launch | modal float | popup via tmux-modal → ql_tx dispatch | ✅ | QL floats are modal popups (accepted inversion) |
| resize table | Resize Increase/Decrease directional | `resize-pane -LDUR 2`, opposite keys shrink | ✅ | |
| move table: hjkl directional | MovePane directional | `swap-pane -U/-D` + `rotate-window` for h/l | 🟡 | tmux has no directional swap |
| session: `d` detach, `w` manager | native + session-manager plugin | detach-client, `choose-tree -Zs` | ✅ | |
| session: `a/c/p/s` about/config/plugins/share | zellij built-in plugins | none | ❌ | zellij-only chrome |
| session: `S` quick-launch workspace | modal float | popup → new-session -d + switch-client | ✅ | @window: separate-OS-window path shared; nested_mux = prefix None + nested table (D14) |

## Scrollback / search / prompts

| Behavior | Zellij | tmux | Status | Notes |
|---|---|---|---|---|
| scroll motion (j/k/d/u/f/b/g/G) | scroll mode | copy-mode-vi (`mode-keys vi`) | ✅ | |
| `V` edit scrollback | EditScrollback | capture-pane → nvim new-window | ✅ | |
| prompt jumps `n`/`p` | zj-prompt-jumper wasm (p10k prefix scan) | copy-mode next/previous-prompt on OSC 133 marks (zsh precmd emitter) | ✅ | emitter benefits both (D11); zellij keeps the wasm |
| `n` after search | Search "down" in search mode | search-aware: `search-again` when `search_present`, else `next-prompt` | 🟡 | one copy-mode vs two zellij modes |
| search option toggles (case/word/wrap) | zj-hud search role + MessagePlugin sync | M-c/M-b/M-p in the dialog and in (SearchMode): case + word rebuild the ERE pattern, wrap sets tmux's per-pane `wrap-search` | ✅ | gated on the Search STATE, not `#{search_present}` — a zero-match filter clears that flag and would kill the chord that undoes it |
| which-key panel | zj-hud role "whichkey" (pages/trail) | `mux-whichkey` popup (pages, trail, icons, colors) driven by the mode stack | 🟡 | Phase 5 as-built: tmux has no PASSIVE overlay, so the panel is a modal popup that dispatches the mode's keys itself while open |

## Session-level behaviors

| Behavior | Zellij | tmux | Status | Notes |
|---|---|---|---|---|
| OSC 52 copy | re-emit to focused client (no copy_command) | `set-clipboard on` re-emit | ✅ | validated Phase 0 incl. SSH |
| OSC 8 links | `osc8_hyperlinks true` | `terminal-features hyperlinks` | ✅ | |
| Images | sixel-only through VTE | native sixel (WezTerm) / kitty placeholders (Ghostty) via preview stack | ✅ | Phase 0 as-built §10 |
| Scrollback size | `scroll_buffer_size 1000000` | `history-limit 1000000` | ✅ | |
| Session serialization | off | no resurrect plugin | ✅ | D17 |
| Cross-mux hygiene | n/a (zellij sets its own env) | scrubs stale `ZELLIJ*`; zshrc guard blocks nested autostart | ✅ | Phase 0 as-built |

## Platform gotchas — Phase 6 (2026-07-26)

| Fact | Consequence |
| --- | --- |
| `send-keys` injects a key straight into the pane — it never traverses the key tables | a bind can only be verified through a REAL client: nested tmux (outer `send-keys` → inner attach). Three "the bind never fires" findings this phase were the harness, not the config |
| a tmux config parse error ABORTS the rest of the source chain, silently | a single-quoted `'#{@tm_session}'` inside a single-quoted if-shell argument killed every later `source-file` (the panel binds vanished). Command commands go in `{ }` blocks, never nested quotes |
| a copy of a SIP-signed binary (`cp /bin/cat`) runs but produces nothing on macOS 26 | fixtures that need a process with a chosen `comm` copy a Homebrew binary (zsh) instead; a symlink does NOT change `comm` |
| `cat > file` is block-buffered when stdout is a file, not a tty | keystroke-capture fixtures use `cat -u`, or the evidence appears only after the process dies |
| a tmux client needs ~2–3s to finish attaching before it routes keys | nested-tmux probes settle before the first send, and use a warm-up key |
| `#{pane_pid}` is the pane's ROOT process (the shell), not the foreground worker | tm routes address the session by path (`@tm_session`); a pid-matched route matches nothing on tmux |
| `run-shell` inherits the SERVER's birth environment (the same rule as `SSH_CONNECTION`) | fixtures export `BKP_*` before starting the scratch server, not into the session env |
| tmux REPORTS a run-shell child that dies by a signal (`'…' terminated by signal 15`) | the tm route's own supersede logic kills the previous route — which under tmux IS tmux's child, so a held scrub key papered the session with the message. The `--session` route forks and hands tmux an immediate exit (2.4s of exposure → 107ms) |
| the zellij resize loop stops as soon as the timeline is ≤ 22 cols, so 22 — not the nominal 21 — is the width it always delivered | the tmux split takes `W-23`; at 21 the footer hint line wraps, because the nerd-font key glyphs measure 2 cells under tmux and 1 under zellij (the VS16 width split, again) |
| chafa's sixel renders under tmux when invoked BARE, but comes back blank with an explicit `-s` box above ~15 rows — and the canvas does not explain it (bare emits 480x480 and renders; `-s 130x21` emits a smaller 420x420 and does not) | the image viewer computes no geometry at all: bare `chafa --align center,center`, which is the invocation measured to work. Its hint lives in the WINDOW NAME, so nothing but the image is ever written to the pane. UNEXPLAINED — the `-s` interaction is worth understanding before any other consumer relies on it |
| a tmux POPUP cannot hold an image — tmux attaches images to a PANE's grid, and a popup is an overlay drawn over it | every image preview renders blank in a popup (the frame appears, "press any key to close" appears, no picture). Images open in a real window on tmux — mux-open's image branch, fzf-tab's Ctrl+O, and yazi's quick-look over SSH. Zellij keeps its float, which IS a pane |
| a bare `%` as a zsh substitution PATTERN (`${s//%/…}`) matches an empty position at the END and appends the replacement — in the system /bin/zsh too, not a build quirk | mux-open's `urldecode` pinned a stray `\x` (an incomplete escape = a NUL byte) onto every path. Invisible on the tab paths, which travel as argv and get truncated harmlessly at the syscall — but the image popup travels as a tmux COMMAND STRING, where tmux cut it at the NUL, left an unterminated quote, and sh exited 2. Bracket the class: `${s//[%]/…}` |
| `pty-frame` reconstructs the child's grid, and its CSI table was missing two of the ten sequences bubbletea actually emits: REP (`CSI Ps b`) and HPA (`CSI Ps ` + backtick) | REP cost the filter box its padding (border drawn straight after the label); HPA — the twin of the CHA it *did* implement — cost every incremental redraw its column, so navigating the file tree shredded the pane. Both pre-existing on both backends. Found by `pipe-pane` on the raw stream and enumerating the finals the child emits vs the ones the emulator handles: capture-pane only ever shows the RESULT |
| a `@ctx` stamp OUTLIVES its session (worker crash, pane reused after teardown) and the route matched but found nothing | a stale stamp silently ATE `J`/`K`/`A` in a plain shell. The timeline clears its stamp on exit (the lens already did), and the route self-heals: unstamp the pane and replay the key. Binds pass `--pane #{pane_id}` and the LITERAL key (`--send J`), because `J` means "scrub older" to the route but a plain `J` to a shell |
| `tm-timeline` sized its rows region `h-5` but wrote only as many rows as the ladder has | a ladder shorter than the pane left the footer floating under the last rung; the region is padded now. Latent under zellij (2 chrome rows), visible under tmux (1) |

## Mode B validation checklist (both backends, per phase)

1. Every leader chord + each mode table entry/exit (Escape, locked M-Escape).
2. vim/fzf pass-through keys inside nvim, fzf, and a plain shell.
3. copy-pwd (both variants) with OSD; alarms set/clear.
4. Scrollback: motion, search, `V`, prompt jumps.
5. Pickers/dialogs once Phase 2 lands: glyph/gitmoji/clipboard/quit/rename.
6. Quick-launch (Phase 3+): pane/tab/workspace incl. nested.
7. OSC 52 local+SSH, OSC 8 click, Shift+Enter per-app behavior.

## Platform gotchas (Mode B, 2026-07-24 — durable facts for later phases)

| Fact | Consequence |
| --- | --- |
| WezTerm folds shift into ctrl+shift letters (`C-S-h` arrives as `C-H`) | every ctrl+shift letter bind needs its uppercase twin |
| `display-popup` never format-expands its shell-command (only `-T`) | no `#{...}` in popup commands; tmux-modal self-resolves origin (popup `TMUX_PANE` is unset ⇒ `display -p` = client's active pane) |
| `display-popup` issued while a popup is open MODIFIES it and IGNORES `-w/-h/-d` | chain popups via `run-shell -b -d 0.2` (server-deferred, survives popup pty teardown) |
| `display-popup` `%` sizes against full client height; zellij floats against the viewport (rows−2, floored) | tmux-popup shim converts to absolute cells |
| foreground `run-shell` + `-E` popup deadlocks (popup blocks client, run-shell blocks server) | popup binds go through `run-shell -b` |
| untargeted tmux commands (and `#{session_name}`) resolve most-recently-used — unstable right after `new-session -d` | anchor on `MUX_MODAL_TARGET_PANE` (a pane id is a valid target-session) |
| the tmux server's process env is its birth env (ssh-born ⇒ `SSH_CONNECTION` forever; `TERM_PROGRAM=tmux`) | host/ssh + terminal-brand truth lives in the SESSION env (`update-environment`) |
| `split-window`/`display-popup` default cwd = session start dir; zellij panes inherit the focused pane's cwd | QL resolves origin `#{pane_current_path}` when the target has no explicit cwd |
| zsh (macOS wcwidth) counts VS16 emoji 1 cell, tmux renders 2; zellij agrees with zsh | tmux inject paths strip U+FE0F; manual VS16 pastes under tmux still corrupt ZLE (no fix available) |
| `@pane-is-vim` can't gate nav keys (smart-splits lazy-loads on those keys); `pane_current_command` = pgroup leader (widget fzf ⇒ "zsh") | root nav uses the vim-tmux-navigator ps probe; `@pane-is-vim` gates only the resize chords |
| p10k instant prompt redirects stdout during zshrc (load-time `-t 1` fails); transient prompt erases+rewrites marked lines | OSC 133 comes from p10k itself (`POWERLEVEL9K_TERM_SHELL_INTEGRATION`), not a bare precmd hook |

## Platform gotchas — Mode B session 2 + Phase 5 (2026-07-24)

| Fact | Consequence |
| --- | --- |
| `#{client_prefix}` flips do not redraw the status line | the leader is a key-table switch (`prefix None` + root `M-w switch-client -T prefix`) — table changes DO redraw |
| `search-*-incremental` are no-ops outside the command-prompt machinery | the search dialog drives plain `search-backward` re-searches from a coordinate anchor |
| tmux search is SMART-CASE (any uppercase → sensitive) | case-sensitive mode on all-lowercase terms injects a matching-neutral `[A]{0}` atom |
| `jump-to-*` are the t/T adjacent variants; `jump-*` are f/F on-char | text-object macros use `jump-backward`/`jump-forward` |
| `set-mark` paints the marked line (any style override clobbers cell colors) | search anchors are cursor COORDINATES (`scroll_position` + `copy_cursor_x/y`), restored before every re-search |
| the outer terminal keeps its last DECSCUSR forever (survives tmux restart); tmux emits nothing for default→default | cursor-shape restore writes `ESC[0 q` to the CLIENT tty (gated on `cursor_shape=default`) |
| `display-popup -y` positions the BOTTOM edge | search-dialog anchor math |
| C-c reaches a popup dialog as SIGINT, not a byte | popup input loops trap INT (an uncaught INT skips EXIT traps → stale pane options) |
| copy-mode text objects are an engine gap (fixed `send -X` vocabulary; no plugin can extend it) | i/a pseudo-objects macro select-word + jump pairs; V→nvim is full fidelity |
| `display-menu` items accept `{ }` command blocks; a leading-`-` (disabled) first item needs `--` to end option parsing | the generated which-key menus |
| `list-keys -T <table>` may render nothing for sparse custom tables (binds ARE registered) | assert via the global listing (extends the Phase 1 locked-table row) |

## Which-key panel (Phase 5) — mechanism + ledger rows

| Fact | Consequence |
| --- | --- |
| tmux has no passive overlay primitive: popups are modal (they take the keyboard the panel documents) and popup-in-popup mutates the outer one | the panel renders into STATUS LINES (`status 2..5`), the only passive surface |
| the status stack caps at 5 lines | panel gets 4 rows incl. borders (footer hints ride inside the bottom border rather than their own row + rule); panes shrink while it shows; pagination covers the overflow |
| a `#()` command runs server-side with NO client — `display -p '#{client_*}'` is empty there | the bar renderer passes its own format-expanded state into `mux-whichkey sync` as arguments |
| `set -gu` on an array INDEX deletes the entry instead of restoring the built-in default; `show` never reports a default once touched | the real `status-format[0]` is read once from a pristine throwaway server (`-L … -f /dev/null`) and cached |
| `status 1` is not a valid value (`on`/`off`/2..5 only), and reads back as `on` | height math normalizes both ways |
| a re-executed `local -a` does NOT clear an array that already exists in the scope (zsh) | explicit `arr=()` per loop iteration — page 2 inherited page 1's rows without it |

## Which-key panel v2 — the real port (Phase 5 + 5.2)

| Fact | Consequence |
| --- | --- |
| a tmux popup swallows ALL key input — key tables do not fire while one is open (measured with a real client) | the panel IS the mode dispatcher while open: it reads the key, looks it up in keymap.yaml and runs that binding's command; `M-.` hands the same bindings back to the key tables |
| a popup opened over a popup mutates the outer one | dialog bindings close the panel first and fire via `run-shell -b -d 0.3` |
| a bare `;` in a tmux CONFIG file is a command separator | every generated bind wraps its command in a `{ … }` block, or multi-command binds execute themselves at load |
| the status stack caps at 5 lines | the panel cannot live there (it is vertical and tall) — hence the popup |
| `,` is a real binding, so a comma-separated key list loses it | keys are pipe-separated in whichkey.data |
| a `j:…:` join-flag argument is literal — a parameter inside renders as text | the breadcrumb joins by hand |

### The panel's dispatch — two orthogonal questions per key

Answered together in `_decide` (and printable without a tty via
`mux-whichkey dispatch <table> <key>`, which is what the spec drives).

| Question | Values | Comes from |
| --- | --- | --- |
| **who runs it** | `run` (the panel sources the cmd) · `defer` (…after the popup closes) · `forward` (the PANE owns the key) · `defer-forward` · `ignore` | a non-empty `cmd` vs an empty one; `dialog` defers |
| **what becomes of the mode** | `push:<state>` · `sticky` · `clear` | `to` + `sticky` in keymap.yaml |

| Fact | Consequence |
| --- | --- |
| a key sent to the PANE reaches its copy-mode binding while the panel's popup is still open (measured) | entries with no cmd are forwarded, so `j` (scroll-down in Scroll, cursor-down in Copy — one tmux table, two states) keeps its single conditional binding in copy-mode-vi instead of being duplicated into the YAML |
| an entry that neither switches nor sticks ENDS the mode — the panel's default | the copy tables were 42 entries with no cmd and no disposition: pressing `j` in the Scroll panel ran nothing AND ended Scroll, while the same key worked with the panel hidden |
| `C-u`/`C-d` are both the panel's paging keys and the copy tables' half-page scroll | paging only claims them when there is more than one page (the same condition that shows the paging hint); otherwise they fall through to the binding |
| the label colour IS the disposition | pink ends the mode, blue enters another, green stays in this one |
| a `$(…)` command substitution FORKS, and the panel's helpers ran per key, per entry and per row — ~150 forks a frame | the hot helpers answer in `REPLY`; a frame went 70ms → 30ms and the panel 250ms → 130ms end to end |
| `$(_paint …)` also swallowed the globals `_paint` sets — a subshell's assignments die with it | `PAGE`/`PAGES` never reached the panel loop, so C-d/C-u could never turn a page; `_paint` answers in `REPLY` and the caller reads them (`mux-whichkey pages` pins it) |

## The mode stack (Phase 5 refactor, 2026-07-25)

`@mux_stack` = `"command:1 scroll:1 search:0"` (state:visible, bottom→top) is
the single source of truth; the key table, the pane's copy-mode and the popup
are derived views. One API (`lib/mux/stack.zsh`, exposed to key bindings by
`mux-stack`), so the panel path and the hidden-panel path run identical logic.

| Fact | Consequence |
| --- | --- |
| a backgrounded child (`cmd &`) of a `run-shell` keeps that run-shell alive as long as it holds the pipe — with a popup on the end of it, the run-shell never returns | `sync` hands the panel launch to the SERVER (`tmux run-shell -b "…"`) and forks nothing |
| zsh runs `TRAPEXIT` in every `$(…)` COMMAND SUBSTITUTION as well as at exit | the panel driver un-claimed itself on its first substitution — no exit trap; the claim is a PID (`@mux_wk_driver`) that anyone can test with `kill -0`, which also self-heals a driver killed with its popup |
| `switch-client -T prefix` fails with "no current client" from a `run-shell -b` (client-less) and from inside a popup (no pane of its own) | every client-scoped command names the client: `switch-client -c "$(list-clients -F '#{client_tty}' \| head -1)"` |
| `set key-table X` is a SESSION option and works client-less; `#{client_key_table}` needs a client | the stack sets the session option, and specs that assert the armed table attach a real client (nested tmux) |
| `show -gv @foo` on an option removed with `set -gu` ERRORS ("invalid option") rather than printing empty | flags that are polled get an explicit `0`, never `set -gu` |
| tmux ties "the current match" to the CURSOR, and scrolling drags the cursor across the buffer (it is pinned to a screen row) | the search keeps its OWN position (`@search_mpos`): n/N restore it, search from there, and save where they landed, so reading the buffer never changes which match comes next. The cursor-driven highlight is muted by every scroll key and restored on a jump — the mute goes FIRST in the binding, because the movement is what repaints |
| tmux exposes NO match index — the whole search vocabulary is count/present/partial/timed_out/match/string | ` X / N ` is ours: X counted once per re-search over the region below the cursor (~15ms, flat), then ±1 with wrap as n/N step |
| `set-mark` CLEARS the search (`search_present` 1 → 0, every highlight gone) | the mark cannot anchor a current-match indicator |
| a style option may reference another by format (`#{E:copy-mode-match-style}`), the way `copy-mode-position-style` defaults to `#{E:mode-style}` | the scroll keys mute the current-match colour with a pure tmux command — no shell forked on a held key, no hex outside the theme |
| match styles are resolved when the SEARCH runs, not on every repaint | un-muting after `search-again` leaves the new match painted with the muted style; unmute BEFORE searching |
| `wrap-search` is a real per-pane option (3.7b) that `search-again`/`search-reverse` honour | the wrap chord sets it, not just the indicator glyph — flipping the glyph alone left n/N coming round the buffer (Mode B) |
| a search that matches NOTHING clears `#{search_present}` — tmux keeps no "there is a term" flag of its own | the mode PILL names the top of the stack (tmux state only detects a stale entry), and the M-c/M-b/M-p toggles gate on the Search STATE: gating them on `search_present` killed the very chord that would undo a zero-match filter |
| tmux has no search-cancel, and an empty `search-forward` keeps the old term | leaving a Search entry exits and re-enters copy-mode and restores the viewport from `#{scroll_position}` — the stack owns that teardown, so `/`, Backspace and the panel cannot disagree |
| a popup cannot resize itself (geometry flags are ignored once one exists) | one DRIVER process owns the popup for the whole stack: the panel performs a stack operation and exits, the driver re-reads the stack and opens the next correctly sized popup |

## Platform gotchas — Phase 6 (consumer rewire, 2026-07-26)

| Fact | Consequence |
| --- | --- |
| a tmux config ERROR (ours: `unbind -T tab C-d` before anything created the `tab` table) leaves the client in a message overlay, and the first keypresses are consumed DISMISSING those messages | not cosmetic after all — a fresh server swallowed its first ~10 keys. The generated block binds `M-.` into each table BEFORE unbinding, so the table exists and the load is silent |
| `send-keys` injects into the PANE, bypassing key tables entirely | a bind can never be tested with plain `send-keys`. `send-keys -K -c <client-tty>` looks the key up in the client's key table (it needs a real client, so the nested-tmux attach still earns its keep); pass-through has no `-K` answer — it falls out of the table and reaches nothing |
| `cat > file` in a probe pane is BLOCK-buffered — bytes sit in libc until exit | key-capture harnesses read empty files and "prove" a key was swallowed. `zsh -c 'while read -k 1 c; do print -n -- "$c" >> f; done'` flushes per key |
| a tmux command string is re-parsed, so an outer `'…'` is ended by an inner `'#{@tm_session}'` | route binds use `{ }` command blocks; the shim's popup args are quoted with zsh `(qq)` (single quotes survive the parser, `(q)`'s backslash escapes do not) |
| `display-popup` from our own client dies when the caller exits (yazi runs quick-look as a task that returns immediately) | `mux::popup` hands every popup to the SERVER via `run-shell -b` |
| `#{pane_pid}` is the pane's root shell, never the worker inside it | tm routes address the session by path (`@tm_session`), not by pid — a pid-matched route silently never fires |
| zellij `run` cannot size the pane it creates; tmux `split-window -l` can | the 30-iteration resize-convergence loop in the tm launcher is now zellij-only |
