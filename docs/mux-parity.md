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
| Mode persistence | per-client modes | `set key-table` (session-scoped) | 🟡 | D2; multi-client-same-session sees shared mode. The PANEL is per-client: every binding hands `#{client_tty}` down so the popup, its geometry and the armed prefix table follow the client that pressed the key |
| Leader from non-normal modes | unavailable (leader only from Normal) | prefix unavailable in non-root tables | ✅ | R4 verified by construction |
| Mode exit | `esc` → normal (shared_except) | `Escape` → `set key-table root` in every table | ✅ | ESC cancels, never Ctrl+C |
| Locked mode | locked table; only `Alt esc` exits | `key-table locked`; only `M-Escape` exits | ✅ | max passthrough |
| Mode indicator | zj-hud bar mode segment (colors/icons) | status-left `[#{client_key_table}]` plain text | 🟡 | Phase 4 brings the themed bar (D6) |

## Leader chords (Zellij "tmux" mode ↔ tmux prefix table)

| Chord | Zellij | tmux | Status | Notes |
|---|---|---|---|---|
| `v` / `s` splits | NewPane right/down | `split-window -h` / `-v` `-c "#{pane_current_path}"` | ✅ | tmux defaults a new pane to the SESSION start dir where zellij inherits the focused pane's cwd — every creation site passes the cwd, including the stock `"`/`%` prefix splits |
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
| tab: h/l/arrows, Tab, 1–0, n, N, x, s | native actions | previous/next-window, last-window, select-window, themed rename popup, `new-window -c "#{pane_current_path}"`, kill-window, synchronize-panes | ✅ | mux-rename retires the command-prompt stopgap; the new tab inherits the pane's cwd (zellij parity) |
| tab: `[`/`]` BreakPaneLeft/Right | native | `join-pane -h -t :-1/+1` | 🟡 | multi-pane windows fold differently |
| tab: `T` quick-launch | modal float | popup via tmux-modal → ql_tx dispatch | ✅ | focus-or-create by @ql_id / =name |
| pane: focus/splits/zoom/kill/rename | native actions | select-pane, split-window ±b, resize -Z, kill-pane, select-pane -T stopgap | ✅ | |
| pane: `S` stacked, `p` pin, `e` embed↔float, `t` float toggle | native | none | ❌ | §6 dispositions (stacked unused; popups are modal) |
| pane: `P` quick-launch | modal float | popup via tmux-modal → ql_tx dispatch | ✅ | QL floats are modal popups (accepted inversion) |
| resize table | Resize Increase/Decrease directional | `resize-pane -LDUR 2`, opposite keys shrink | ✅ | |
| move table: hjkl directional | MovePane directional | `swap-pane -U/-D` + `rotate-window` for h/l | 🟡 | tmux has no directional swap |
| session: `d` detach, `w` manager | native + session-manager plugin | detach-client, `choose-tree -Zs` | ✅ | |
| session: `a/c/p/s` about/config/plugins/share | zellij built-in plugins | none | ❌ | zellij-only chrome |
| session: `S` quick-launch workspace | modal float | popup → new-session -d + switch-client | ✅ | @window: separate-OS-window path shared (nested included — the window attaches an outer session, it does not run the ssh bare); nested_mux = prefix None + status off + nested table (D14), which binds the picker chord itself so ⌘⇧S stays local |

## Scrollback / search / prompts

| Behavior | Zellij | tmux | Status | Notes |
|---|---|---|---|---|
| scroll motion (j/k/d/u/f/b/g/G) | scroll mode | copy-mode-vi (`mode-keys vi`) | ✅ | |
| `V` edit scrollback | EditScrollback | capture-pane → nvim new-window | ✅ | |
| prompt jumps `n`/`p` | zj-prompt-jumper wasm (p10k prefix scan) | copy-mode next/previous-prompt on OSC 133 marks (zsh precmd emitter) | ✅ | emitter benefits both (D11); zellij keeps the wasm |
| `n` after search | Search "down" in search mode | search-aware: `search-again` when `search_present`, else `next-prompt` | 🟡 | one copy-mode vs two zellij modes |
| search option toggles (case/word/wrap) | zj-hud search role + MessagePlugin sync | M-c/M-b/M-p in the dialog and in (SearchMode): case + word rebuild the ERE pattern, wrap sets tmux's per-pane `wrap-search` | ✅ | gated on the Search STATE, not `#{search_present}` — a zero-match filter clears that flag and would kill the chord that undoes it |
| which-key panel | zj-hud role "whichkey" (pages/trail) | `mux-whichkey` popup (pages, trail, icons, colors) driven by the mode stack | 🟡 | Phase 5 as-built: tmux has no PASSIVE overlay, so the panel is a modal popup that dispatches the mode's keys itself while open |

## Tab titles (zj-hud compose_body ↔ tmux window pill)

| Behavior | Zellij impl | tmux impl | Status | Notes |
|---|---|---|---|---|
| user-renamed tab | tab icon + name | `@win_icon`/󰓩 + `#W` (automatic-rename off) | ✅ | |
| app's own title (agents' session + progress) | `pane_osc_title(...)` beats the process name | OSC 0/2 → `#{pane_title}` → `automatic-rename-format` → `#W` | ✅ | tmux re-evaluates the format as the title changes and fires window-renamed, so progress repaints without shortening status-interval |
| per-process glyph | `icons::process_icon` | generated `#{?}` chain from `.muxTabIcons` | ✅ | ported 1:1; one list feeds the tmux side, Phase 8 merges the two |
| shell → cwd | home/dir icon + pretty cwd | same | ✅ | |
| project-aware path abbreviation | `abbreviated_project_path` | `mux-tab-path`, pushed onto `@win_path` | ✅ | segments above the project root shrink to an initial, then collapse to `…`; the root and the tail stay whole |
| zoom / sync / alarm icons | extra_icons | `win_extras` | ✅ | Phase 4 |

## The compact dialog (zj-hud search/rename roles ↔ lib/mux/dialog.zsh)

Both floating dialogs are ONE object with a different accent, glyph and
payload — as they are in the plugin, which draws each with the same
`render_field`. `lib/mux/dialog.zsh` owns the geometry, the frame, the field
and the anchor; `mux-search` adds its toggle reserve, `mux-rename` adds
nothing but the rename itself.

## Rename dialog (zj-hud `role "rename"` ↔ mux-rename)

| Behavior | Zellij impl | tmux impl | Status | Notes |
|---|---|---|---|---|
| geometry | floating pane, 40×3, right-inset, pinned | `display-popup -w 40 -h 3 -x (cw-41) -y (ch-2)` | ✅ | the plugin's PANE_WIDTH/PANE_HEIGHT/RIGHT_INSET; `-y` is the BOTTOM edge |
| chrome | rename-coloured `┃` rule, md_rename glyph, half-block field | same glyphs, same columns (GLYPH_COL 2 / INPUT_COL 5) | ✅ | colours from the theme JSON (`dialog.warning` = the plugin's RENAME_RGB), never literals |
| prefill | current tab/pane title in the field | `#{window_name}` / `#{pane_title}` of the ORIGIN pane | ✅ | a popup owns no pane, so `display -p` answers for the client's active pane |
| apply / cancel | Enter renames, Esc leaves it | `rename-window` / `select-pane -T`; ESC and C-c abandon | ✅ | ESC cancels — never conflated with Ctrl+C |
| mode pill | zj-hud rename role lights the bar | `@renaming` read by tmux-status-right | ✅ | cleared on every exit path, including SIGINT |
| what can be renamed | tab, pane | window, pane, SESSION | 🟢 tmux-ahead | `n` in the session table; zellij's role has no session arm |
| Alt+r in the session dialog | — | fills the field from `mux-random-session-name` | 🟢 tmux-ahead | the generator is called with NO arguments (its `--apply*` modes are never used here); the rename still only happens on Enter |
| rename as a MODE | zj-hud role lights the bar | `@renaming` carries the KIND → ribbon shows the Rename pill + that kind's key hints (`⌥r random` only for a session) | ✅ | NOT a mode-stack entry: the stack's driver owns exactly one popup, and a stackable rename had it closing the dialog it had just opened |

## Session-level behaviors

| Behavior | Zellij | tmux | Status | Notes |
|---|---|---|---|---|
| OSC 52 copy | re-emit to focused client (no copy_command) | `set-clipboard on` re-emit | ✅ | validated Phase 0 incl. SSH |
| OSC 8 links | `osc8_hyperlinks true` | `terminal-features hyperlinks` | ✅ | |
| Images | sixel-only through VTE | sixel (WezTerm) / kitty (Ghostty) via preview stack | ✅ | Phase 0 as-built §10; the Ghostty half was ASPIRATIONAL until 2026-07-27 — nothing set a format, chafa auto-detected sixel through tmux, and Ghostty rendered nothing. term-quick-view now picks `-f kitty --passthrough tmux` off `#{client_termname}` |
| Scrollback size | `scroll_buffer_size 1000000` | `history-limit 1000000` | ✅ | |
| Session serialization | off | no resurrect plugin | ✅ | D17 |
| Autostart "Main" reuse | absent→create, idle→attach, has-client→anonymous | same three ways | ✅ | Phase 7; `.zshrc`, both branches asserted in `tests/mux_autostart_spec.sh` |
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
| the limit is `input-buffer-size` — a SERVER option (`show -s`, not `show -g`, which is why it looks absent), default 1 MiB, RAISABLE at runtime. tmux.conf sets 16 MiB; the renderers ask the server for the value rather than hard-coding it | tmux ingests a sixel image as ONE DCS string and DISCARDS the whole thing past that limit — a blank pane, no error, nothing in the log | captured with `pipe-pane` in the real terminal: a 774KB stream renders, a 2.45MB one does not. NOTHING about the image predicts it (255-colour photos and 13-colour line art land on both sides, 800px-wide canvases both render and blank) because chafa renders at the terminal's TRUE cell resolution — the stream size is the variable, not any property of the file. The image viewer renders to a file, checks its size, and shrinks the CELL box until it fits |
| a pane's TTY WINSIZE is still 80x24 when a command spawned by `new-window` starts — `tput`/`stty` report the default, not the pane | anything sizing itself from the tty renders ~40% small in a 130x33 window, on every render, silently. Ask tmux (`display -p '#{pane_width} #{pane_height}'`), which is right immediately; keep tput as the non-mux fallback. A settle-loop on `stty size` does NOT help — it settles on the stale value |
| chafa centres VERTICALLY by emitting newlines, and a newline resets the column to 1 | manual left padding printed before chafa is silently discarded for any image tall enough to need vertical centring — a width-constrained image came out flush left while square ones looked fine. Padding has to come from BOUNDING the image (-s) and letting chafa centre it; `--margin-*` reserve only the right and bottom |
| measuring a renderer headlessly measures a different renderer | every chafa figure taken outside the real terminal (canvas, palette, bytes) was 3-10x off, because chafa falls back to 80x25 char-art assumptions with no tty to probe. Correlation tables built that way sent this investigation down four dead ends; `pipe-pane` on the real pane settled it in one capture |
| quick look (images, PDFs, documents, fonts) | `term-quick-view` in a tab | `term-quick-view` in a tab | ✅ | one implementation, one singleton tab per backend; zellij closes-and-reopens where tmux respawns in place (no verb to swap a tab's command), so its tab moves to the end |
| a tmux POPUP cannot hold an image — tmux attaches images to a PANE's grid, and a popup is an overlay drawn over it. RE-VERIFIED after the DCS size cap below, with a stream small enough to render in a pane: still blank in a popup, so this is a real limitation and not the size limit wearing a disguise | every image preview renders blank in a popup (the frame appears, "press any key to close" appears, no picture). Images open in a real window on tmux — mux-open's image branch, fzf-tab's Ctrl+O, and yazi's quick-look over SSH. Zellij keeps its float, which IS a pane |
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
| `#{client_tty}` DOES expand in a `run-shell`, backgrounded or not, and names the client that pressed the key even with several attached (measured; a comment in stack.zsh claimed the opposite) | the panel stops guessing with `list-clients \| head -1`, which opened it in whichever terminal attached FIRST — press the leader in WezTerm, watch the panel appear in the Ghostty window |
| `#(shell-command)` is NOT evaluated inside `window-status-format` — the same `#()` runs from `status-right` and never from the pill (measured) | anything the pill needs from a script has to be PUSHED onto a window option (`@win_path`), from the moments the answer changes: the shell's chpwd hook and tmux's `pane-focus-in` |
| tmux SEEDS `#{pane_title}` with the hostname, and its automatic-rename samples the pane's PROCESS — a command started via `$SHELL -c` can leave the window named after the shell (stock tmux names a `node -e …` window "zsh" permanently) | the title guards reject the hostname; the OSC title bypasses process sampling altogether |
| a `display-popup` command's STDIN is not the keyboard — a `cat` in a popup receives nothing; zsh's `read -k` reads /dev/tty, which is | dialogs must read the terminal, never fd 0. Reading fd 0 made the rename dialog deaf to every key including ESC, while its piped specs passed (a pipe is not a tty) |
| the which-key panel runs its commands with `source-file` from inside a POPUP, where tmux has no current pane — so `#{pane_current_path}` expands EMPTY and a new tab silently landed in the session's start dir (the identical key-table bind inherited correctly) | the panel resolves that one format itself before sourcing (`display -p` from a popup does answer for the client's active pane); a blanket expansion is wrong, since other commands carry `#W` / `%%` that tmux must still see |

## Platform gotchas — Phase 6 Mode B session 2 (2026-07-27)

| Fact | Consequence |
| --- | --- |
| `extended-keys always` does NOT mean "send every key as CSI-u" — it means "use CSI-u where there is no OTHER way to send the key". Measured by feeding a real client all three encodings WezTerm can emit for Ctrl+Alt+A (legacy `\e^A`, xterm modifyOtherKeys `CSI 27;7;97~`, kitty `CSI 97;7u`): tmux decodes each and re-emits the SAME legacy `\e^A` to the pane | a chord with a legacy encoding needs no CSI-u twin in `keybindings.sh`, on either backend. The "the key must be arriving as CSI-u under tmux" theory is the obvious one and it is wrong; measure with `send-keys -H <raw bytes>` into a nested client before touching any bindkey |
| `display-popup` returns 1 when NO client is attached, and the message surfaces as `'tmux' display-popup … returned 1` in the pane | a headless probe (`new-session -d`, no attach) makes every popup look broken. Any popup probe must attach a real client FIRST and only then trigger the code under test — an earlier run "proved" the ai-playbook float was still failing when it was the harness racing |
| `capture-pane` reads the pane GRID, so it cannot see a popup at all (same root as "a popup cannot hold an image") | popup rendering is verified from the OUTER pane of a nested tmux, never from `capture-pane` on the session running the code |
| ai-playbook's mux integration is config-driven but STATIC: one preset (zellij, hardcoded `zellij action …`), opt-in via `[mux] backend`, and explicitly NO `$ZELLIJ` auto-detect (its ADR-0007) | a single config file cannot serve a zellij pane and a tmux pane. `~/.config/mux/scripts/mux-playbook` is pointed at by all five templates and resolves the backend per call; `backend = "mux"` is just the on-switch, since any name other than `zellij` simply requires all templates overridden |
| ai-playbook runs each mux template with `cmd.Run()` and WAITS for it | every adapter action must return promptly. The shim already does (tmux popups leave via `run-shell -b`, splits return once the pane exists), which is why the adapter is a dispatcher and not an implementation |
| `mux::dump_screen` was never parity-equal: zellij returned the VIEWPORT, tmux the whole scrollback — and the spec table baked the asymmetry in | it takes `--full` now and both backends agree in both modes. It had no consumers, so nothing had caught it; the first consumer (ai-playbook's scrollback capture) wanted the viewport |
| `zellij list-sessions` / `zellij_attached_sessions` keep answering under tmux — with ZELLIJ's sessions, which outlive the switch as resurrectable ones | quick-launch's workspace list showed stale zellij sessions (`Main`, `quadratic-bee`) while tmux held `main`/`QMK Firmware`, so the `(other window)` tag could never clear. A zellij call that "still works" off-backend is the dangerous kind: it returns a plausible answer instead of failing |
| `display-popup -E` exits with its COMMAND's status, and `run-shell` paints any non-zero one over the client as `'…' returned N` | 130 is the clean-cancel convention (pick-common; ESC and Ctrl+C both land there), so dismissing a modal left an error overlay quoting the whole popup command. `_mux_tx_popup` now appends `\|\| [ $? -eq 130 ]` to the run-shell line — exactly 130 is swallowed, every other status still reports. zellij needs none of this: closing a float reports nothing |
| in `mux::popup` geometry a bare integer is CELLS, so `70 60` is a 70x60 CELL popup — which simply fails (exit 1) in a client shorter than 60 rows | a probe that means percentages must write `70% 60%`. Two "the percent branch is broken" findings were this, not the branch |

## Platform gotchas — MEH direct bindings (2026-07-27)

| Fact | Consequence |
| --- | --- |
| `extended-keys always` means "use CSI-u where there is NO OTHER WAY to send the key", not "always send CSI-u". Ctrl+P and Ctrl+Shift+P are both the byte `0x10`, and tmux normalises EVERY extended encoding back to it — legacy, `CSI 27;7;112~`, `CSI 27;8;112~`, `CSI 27;7;80~`, `CSI 27;8;80~`, `CSI 112;7u`, `CSI 112;8u` all reach a pane as `\e^P` | MEH can never be a zsh `bindkey`, and `cat -v` inside tmux can never show the difference. The binding must live in tmux's key TABLE, which DOES distinguish it |
| the two terminals disagree about where Shift goes, and tmux believes both: WezTerm folds it into the CODEPOINT (`CSI 27;7;80~` → `C-M-P`), Ghostty sets the shift bit AND shifts the codepoint (`CSI 27;8;80~` → `C-M-S-P`), the kitty form shifts neither (`CSI 112;8u` → `C-M-S-p`) | one logical chord = THREE binds. The fan-out is per-TERMINAL, not per-mux — both dialects arrive at the same tmux server. Ghostty also sends plain legacy `^[^P` for Ctrl+Alt+P and only escalates when Shift is involved |
| `send-keys C-M-P`, `send-keys C-M-p` and `send-keys C-M-S-P` all emit the identical `\e^P` | a guarded MEH bind can NEVER fall through: an `if` whose else-branch is `send-keys C-M-P` fires ai-playbook-pick (bound to `\e^P` in zsh) from inside nvim. MEH binds are "act, or do nothing" — the opposite of the C-h nav binds, which pass through by design |
| tmux has exactly three modifier bits and no extension point. kitty's super(8) is ALIASED to Meta (`CSI 112;9u` reaches the pane as `\ep`, i.e. plain Alt+p); hyper(16) and meta(32) are SILENTLY DROPPED and fire the unmodified key. `Super-`/`Cmd-`/`Command-`/`D-`/`Hyper-` are all "unknown key" to the bind parser (`s-` is just `S-`, shift) | there is no "custom modifier". A terminal forwarding Cmd as super does not merely go undetected — it COLLIDES with the `⌥w` leader. Cmd must be remapped terminal-side to something tmux can name |
| tmux binds arbitrary Unicode codepoints, PUA included, with modifiers composing (`bind -n <U+E000>`, `C-<U+E000>`), and they survive a `source-file`. But an UNBOUND private-use codepoint LEAKS into the pane as a glyph (`CSI 57345;1u` delivered `ee 80 81`) | a viable Cmd transport, but it needs the terminal and tmux generated from one source or a stray chord types an invisible character into the buffer. Not needed in the end: the terminal can synthesise the MEH sequence instead, which is readable ASCII |
| tmux knows F1–F12 only — `F13`…`F24` are rejected | the usual "park it on a spare high F-key" escape hatch does not exist here |
| MEH+digit binds as shifted PUNCTUATION (`C-M-!` … `C-M-)`), which is layout-dependent. All ten survive a generated `source-file`, with tmux self-quoting `"C-M-#"`, `"C-M-$"`, `"C-M-%"` on read-back | fine when the TERMINAL synthesises the bytes (deterministic regardless of keyboard), dangerous when the user presses the physical chord on a non-US layout |
| a tmux POPUP needs an attached client — `display-popup` returns 1 when there is none, surfacing as `'tmux' display-popup … returned 1` | a headless probe (`new-session -d`, no attach) makes every popup look broken. Attach a real client FIRST, then trigger. `capture-pane` also cannot see an overlay, so popup rendering is read from the OUTER pane of a nested tmux |
| tmux QUOTES a key name containing `#`, `$` or `%` when listing it — `bind -n C-M-#` reads back as `bind-key -T root "C-M-#"` | a count/assert that greps `-T root +C-M-` silently undercounts by exactly those keys. Patterns over `list-keys` output need `"?`. The binds themselves register and fire fine unquoted in a config file |
| Shift does not fold a DIGIT to a digit — it folds it to the layout's shifted PUNCTUATION, so MEH+1 is `C-M-!`, not `C-M-1` (the kitty form, which shifts neither bit nor codepoint, does stay `C-M-S-1`) | the tab jumps are bound on `!@#$%^&*()`, a US-layout mapping. Safe ONLY because the terminal synthesises the bytes for ⌘N — deterministic whatever the keyboard does. A design that depended on the physical chord would be layout-fragile |
| a `bind -n` ROOT bind DOES still fire while the pane is in copy-mode | one bind can serve both entry and repeat for a scroll chord — but it must test `#{pane_in_mode}` and push the mode stack ONLY on entry, or three presses stack three `scroll` entries and the panel desyncs |
| `bind -n C-M-{` is a SYNTAX ERROR from a config file, and per the Phase-6 row a config error aborts the rest of the source chain | `{`/`}` are tmux's own command-block delimiters, so brace punctuation is unbindable — `[`/`]` were ruled out for the prompt jumps on this basis. `!@#$%^&*()<>` are all fine |
| arrows carry their modifiers in a NUMERIC field (`CSI 1;8A`), so Shift has no codepoint to fold into | MEH+Up/Down needs only ONE tmux spelling (`C-M-S-Up`), unlike MEH+letter which needs three. Both terminals send the identical bytes |
| `%hidden` names are expanded at PARSE time and `send -X` is normalised to `send-keys -X` in `list-keys` output | assertions over `list-keys` must match the probe's CONTENT, not the `$var` name, and the long-form command spelling. Three specs were written against the source spelling and failed |
| WezTerm ships `SHIFT\|ALT\|CTRL Up/DownArrow -> AdjustPaneSize`, so the physical MEH+↑/↓ chord is SWALLOWED before it can reach the mux (Ghostty has no such default — its ctrl+alt+shift arrows are free) | MEH+arrow needs an explicit WezTerm bind, not just a tmux one. The ⌘↑/⌘↓ path was unaffected, which is why it worked while the physical chord did not — two paths to one tmux bind can fail independently |
| `previous-prompt` / `next-prompt` move the CURSOR, and do not scroll while the target mark is already on screen | walking prompts from the bottom moved the cursor PROMPT-20 → 19 → 18 with `scroll_position` stuck at 0 — the view never moved and the jump looked broken. Anchoring to the viewport edge first (`send -X top-line` / `bottom-line`, then the jump) skips the prompts already visible, so every press moves the view |
| WezTerm re-evaluates its config automatically; GHOSTTY DOES NOT — a running instance keeps the config it started with until `cmd+r` (reload_config) or a relaunch | after any `chezmoi apply` touching `~/.config/ghostty/config`, a running Ghostty is still on the OLD bindings, and the stale behaviour reads exactly like a code bug. Cost an investigation: ⌘⇧↑ "needed three presses" in Ghostty while WezTerm was fine — the window was still replaying `⌥w l p`, whose plain `previous-prompt` walks the visible screen without scrolling. Reload Ghostty before concluding anything about a keybind change |
| the OSD glyph DB (`~/.local/share/fonts/nerd-font/symbols.db`) keys nerd-font symbols as `nf-<set>-<name>`, and an unknown name resolves to NO ICON silently (only an `hs.printf` nobody reads) | `glyph:cod-folder` and `glyph:md-bell_*` had been iconless since they were written — the correct names are `nf-cod-folder`, `nf-md-bell_ring`, … The DB also carries non-nerd sets under bare names (`fa-clipboard-list`, `usr-wezterm`), so "no prefix" is not universally wrong and a blanket rewrite would break those. Query the DB before trusting a glyph name |
| a tmux client reached over SSH makes `show-environment SSH_CONNECTION` return `SSH_CONNECTION=…`; a LOCAL session returns `-SSH_CONNECTION` (the leading `-` means explicitly unset) | any "is this client remote?" probe must match the `SSH_CONNECTION=*` PREFIX, not merely non-empty output. And a probe tmux server born from an ssh-attached shell INHERITS the variable, so it simulates a REMOTE client — scrub it (`env -u SSH_CONNECTION …`) to reproduce a local one. Cost two contradictory readings of the copy-pwd OSD fix |
| `show-messages` logs COMMANDS, not `display-message` text | "no message was shown" cannot be concluded from it. Status-line output is only observable from the OUTER pane of a nested tmux with a real client attached |
| a `#!/usr/bin/env zsh` script re-reads `/etc/zshenv`, whose `path_helper` REBUILDS PATH | stripping PATH in the invocation cannot hide a binary from the script — `command -v hs` kept resolving through a deliberately minimal PATH. Use `env -i` when a probe needs a genuinely absent tool |
| tmux's three window alerts are NOT one category: activity/silence are ALARMS the user arms by hand (the leader's "alarm on updated"/"alarm on idle" set `monitor-activity`/`monitor-silence`), while the bell is unarmed — `monitor-bell` is on out of the box and any program can ring it | they want opposite defaults. The alarms notify because you asked to be told; the bell does not, because it is already reported twice without an OSD (the terminal rings it, and the window's status entry takes `window-status-bell-style`). Gating them together — one `@alert_osd` switch — silences the alarms you deliberately set, which is the wrong half |
| tmux's STOCK `DoubleClick1Pane`/`TripleClick1Pane` contain `run-shell -d 0.3` between `select-word` and `copy-pipe-and-cancel`. It is NOT dead weight — it is the gesture's only feedback: the selection highlight is on screen for exactly as long as the pause | deleting it makes the copy land SILENTLY, which reads as "double-click does nothing" even though the word is on the clipboard (verified: the buffer fills either way). Shorten it, do not remove it — 0.12 keeps a visible flash at under half the latency. Measuring the commands by hand proves nothing here; only real SGR mouse bytes into a live client exercise the streak + mouse-position path |
| the bar's mode pill is resolved from `pane_in_mode` + `@visual` DIRECTLY, not from `@mux_stack` — `mux_stack::reconcile` only ever DROPS copy states, it never pushes one | "why does it say Scroll?" is not answerable from the stack. Any path that enters copy-mode without stamping `@visual` reads as Scroll on the bar, including tmux's own built-in mouse bindings |
| a pane option can gate a HOOK, not just a bind: `set-hook pane-mode-changed 'if -F "#{@mouse_select}" "" { … }'` | the transient copy-mode of a mouse word-select fired pane-mode-changed TWICE and spawned four zsh scripts (~40ms each) for a mode nobody is in. The same flag folds into the bar's in_copy argument (`#{&&:#{?pane_in_mode,1,0},#{?#{@mouse_select},0,1}}`) so the pill stays quiet — one option, both problems, no script changes |
| tmux HOLDS a double-click ~300ms before firing `DoubleClick1Pane`, waiting to see whether a triple-click follows — measured 17ms for a single click vs 328ms for a double, with a `touch` stamp fired from inside the binding | that is the lag before the selection highlight appears, and it is BEFORE any of our commands run. There is no option for it: the complete tmux mouse surface is `mouse` and `focus-follows-mouse`. The only escape is taking double-click away from tmux entirely, which WezTerm can do (`mouse_reporting = true` mouse_bindings) and Ghostty CANNOT — it binds keys only, no mouse events |
| a `#()` status command re-runs whenever any format it interpolates changes, so adding a pane option to `status-right` puts a script spawn on every change of that option | folding `@mouse_select` into the bar's `in_copy` argument made the flag itself a status trigger. Reverted: the pill now shows COPY via `@visual 1` instead, and `@mouse_select` survives only as the pane-mode-changed gate |
| a MOUSE selection enters copy-mode without ever pushing a stack entry, and `mux_stack::reconcile` early-returned when it found no copy entries — BEFORE the code that clears the pane's copy-mode flags | `@visual` leaked set after every drag-select, so the NEXT Scroll entry read as Copy. The flags are cleared as soon as the pane is known not to be in copy-mode, ahead of the no-entries return: past `_in_copy` they are stale whatever the stack says |
| stock `MouseDrag1Pane` is a bare `copy-mode -M` — no `@visual` stamp — so DRAGGING out a selection put the bar in Scroll | drag-select stamps `@visual 1` (the resolver spells Copy that way), while `WheelUpPane` (`copy-mode -e`) is deliberately left alone: scrolling IS scrolling. Three mouse paths into copy-mode, two different correct answers |
| `quick-launch-zellij` resolved the dispatcher as `${0:A:h}/quick-launch` — a SIBLING — but Phase 6.1 moved the neutral entry points to `~/.config/mux/scripts/` and left only the backend-private adapters behind | the zellij quick-launch pickers have been dead since Phase 6.1, and nothing caught it because every phase after that was validated on tmux. The three sibling adapters (`pick-{clipboard,gitmoji,glyph}-zellij`) use absolute `~/.local/libexec/…` paths and were unaffected — quick-launch was the only one whose target moved |
| a live session with no entry in the targets file was visible to `list-sessions` but UNREACHABLE from the workspace picker, on both backends | the picker now synthesises `{id, name}` = the session name for those, sorted after the defined live workspaces and before the not-yet-created ones, and `ql_get_element` resolves an unknown id the same way when it names a live session. The existence probe has to be backend-aware: `ql_session_exists` is zellij-only (`$ZJ`), its tmux twin is `ql_tx_session_exists`, and the lookup runs BEFORE the dispatcher's backend branch |
| an apostrophe inside a comment in the picker's jq program CLOSES the single-quoted shell string | `ql_get_element's` in a jq comment turned into a shell parse error at a line 20 further down. jq comments live inside the shell quoting, so they follow the shell's rules, not jq's |
| `term-quick-view` sized itself from `tput` under zellij: the pane query was written `if [[ -n "$TMUX" ]] … fi` with no other arm, so only tmux got a real answer | zellij has no client-size query at all, hence `mux::terminal_size`/`_mux_zj_terminal_size` deriving the tab's extent from its non-floating panes. Without that branch the chrome laid itself out for the unsettled 80x24 inside a much larger tab — the same failure the tmux winsize row describes, on the other backend |
| the 1MB stream ceiling in `term-quick-view` is TMUX'S `input-buffer-size` and nothing else's, but it was applied unconditionally | under zellij a 2.2MB render was shrunk to 70% and the picture came out visibly small inside a correctly-sized frame. The debug log is what separated this from the sizing bug it looked like: `pane=130x29 box=118x21` were both RIGHT while `SHRINKING: 2285652 > 1000000` explained the picture. The cap is now `_max=0` (no ceiling) unless `$TMUX` is set |
| ANSI cursor columns are 1-BASED, so `\e[2;${_padx}H` leaves `_padx-1` cells before the text | the quick view's title sat one column left of the frame it lines up with, on BOTH backends, for as long as the chrome has existed. The right-hand side was correct because it computes an END column and already carried the `+1` — an asymmetry that hid the bug until someone counted cells |
| chafa probes the TERMINAL for cell pixel geometry, and tmux and zellij answer differently | the same image lands a half-row taller under zellij, so the vertical compensation (`top = bottom - 1`, "the newline squares it up") is a per-backend constant tuned against tmux's answer, not a universal one. LOGGED, not fixed — cosmetic, and only on the backend being migrated away from |
| `zellij action dump-screen` takes its target as `--path <PATH>` and prints to STDOUT when omitted — it is NOT a positional. The shim passed a mktemp'd path positionally, written against an older CLI | `mux::dump_screen` returned NOTHING on zellij, both viewport and `--full`, and had done so for as long as the verb existed. Every dump_screen spec was tmux-only, which is exactly how it survived: the tmux stub ignores its arguments, so the tmux tests passed while the zellij call was being rejected. Dumping to stdout also retires the temp file |
| the shell Claude Code runs in can INHERIT `ZELLIJ`/`ZELLIJ_SESSION_NAME` from wherever the session was started | `mux::backend` then reports `zellij` in what looks like a bare shell, so any "outside a mux" baseline taken there is wrong. Check `ZELLIJ`/`TMUX` before trusting a control run |
| ZELLIJ parses the KITTY key encoding (`CSI <codepoint>;<mods>u`) but NOT xterm modifyOtherKeys (`CSI 27;<mods>;<cp>~`) — fed the latter it hands the raw bytes to the shell, where ZLE beeps and swallows them | that is why every ⌘ chord was dead on zellij after the MEH work: the terminals were synthesising modifyOtherKeys. The kitty form serves BOTH — tmux resolves it to `C-M-S-<key>`, a spelling it already binds (14/14 verified). Proof zellij PARSES rather than forwards: fed `CSI 112;8u` it emitted legacy `\e^P` downstream, i.e. it decoded the key and re-encoded it, where modifyOtherKeys came back byte-identical |
| in the kitty encoding the codepoint is the UNSHIFTED character, so MEH+digit is a digit (`49`) and not the layout's shifted punctuation (`33`/`!`) | switching encodings deleted the US-layout dependency the digit binds carried, for free |
| zellij accepts three-modifier binds (`bind "Ctrl Alt Shift p"`), and `shared_except "locked"` is its equivalent of tmux's ROOT table | validate with `zellij --config <file> setup --check` — it reports `[CONFIG FILE]: Well defined.` or points at the exact line. A `MessagePlugin` child block must be MULTI-LINE; written inline (`{ MessagePlugin "x" { name "y" } }`) it fails to deserialize |
| zellij's prompt-jumper plugin has to be messaged from SCROLL mode, the way the leader path (`⌥w l p`) reaches it | messaged from normal mode the first press did nothing visible and only the second jumped — a two-tap that looked like a debounce bug. The bind switches mode first, exactly as tmux's twin enters copy-mode |
| macOS claims `⌘⌥⇧C` for Window → Move & Resize → Center on a machine whose keyboard has no Globe key, where a laptop keyboard gets `Ctrl+Globe+C` | menu shortcuts fire BEFORE the app's key handling (the same precedence the Ghostty `performable:` rows describe), so the chord never reached the terminal at all. Fixed in System Settings → Keyboard Shortcuts → App Shortcuts, not in this repo |
| `mux-open` runs in WezTerm's GUI environment, where there is no `$ZELLIJ`/`$TMUX` — it resolves the session itself and passed `--session` to its nvim branch but NOT to `term-quick-view` | zellij REFUSES an untargeted `action new-tab` ("Please specify the session name"), so CMD+click never opened the quick view there while opening files and directories worked fine. tmux hid the identical gap: an untargeted command picks the most-recently-used session, so it worked by luck and would have opened the view in the WRONG session with two of them about. The session travels as `MUX_SESSION`, alongside the existing `MUX_BACKEND` |
| `mux::available` re-derived the backend from `$ZELLIJ`/`$TMUX` while `mux::backend` honours the `MUX_BACKEND` pin — two functions guarding the same decision, disagreeing | a caller OUTSIDE any session (mux-open, from WezTerm's GUI) pins the backend and dispatch obeys, but availability said "no mux", so `term-quick-view` took its inline arm and painted into a terminal nobody was looking at. Broken on BOTH backends, which is why the CMD+click quick view opened nothing on zellij and — despite the Phase 6 claim — was never really working on tmux either |
| **Mode B over SCREEN SHARING is not a valid test of a keybinding**: both machines run this config, the LOCAL Hammerspoon sees the keystroke first, swallows it, and the remote never gets it | cost five rounds of debugging a clipboard paste that was never broken — ⇧⌘v opened the LAPTOP's picker while the mac-mini logged nothing, and the paste arrived at the remote shell as a bare "v". `keysBelongElsewhere()` now yields the whole keyboard (eventtap + leader hotkey) whenever a screen-sharing client is frontmost. When a key "does nothing" on a remote machine, check WHICH machine is claiming it before touching any config |

## Phase 7 — the default flip (2026-07-27)

tmux is now what a bare terminal launches. The knob lives in two halves that
must agree: chezmoi's `.muxBackend` (`home/.chezmoidata/mux.yaml`), which
`.zshrc` bakes in, and `mux::default_backend`'s fallback in
`home/dot_local/lib/mux.zsh`, which answers the same question for callers that
are not the login shell. `mux.zsh` cannot be a template — 17 specs `Include` it
raw — hence the duplication, and hence the test that fails when they drift.

**Reverting is a one-liner, no chezmoi edit and no rebuild:**

```sh
print -r -- zellij > ~/.config/mux/backend   # new terminals launch Zellij again
```

The loose file wins over the baked default on that machine only. Nothing about
this strands a running session: dispatch *inside* a session is runtime
detection off `$TMUX`/`$ZELLIJ`, so a live Zellij keeps behaving like Zellij
while new windows come up as tmux, and `zj attach Main` still reaches it.

| Gotcha | Consequence |
|---|---|
| `tmux new -A -s Main` — the obvious one-liner, and what D17 sketched — is NOT equivalent to the Zellij dance it replaces | `-A` collapses the has-a-client case into "attach", so a second window joins Main and MIRRORS it instead of getting its own session. The three states have to be probed separately (`has-session` → `list-clients` → attach/anonymous/create) for ⌘N to keep meaning what it means on Zellij |
| tmux needs no EXITED sweep, Zellij does | tmux destroys a session when its last process exits, so `has-session` is the whole liveness test; Zellij keeps a dead record that must be `delete-session -f`'d before a fresh Main can take the name |
| `-t Main` PREFIX-matches in tmux; `-t=Main` is exact | without the `=`, a session called "Main2" answers for "Main". Session names are case-sensitive, so a lowercase `main` is a different session and does not collide |
| in zsh, `*` in a pattern substitution matches ACROSS NEWLINES | `${block//for _tmux in *; do/...}`, rewriting a binary list to point at a test stub, silently ate the entire loop body up to the next `; do` — the test then exercised nothing and still "passed" the parse. Rewrite line-scoped. This is a testing-harness trap, and it cost a full debug cycle |
| a spec that pins a value by `sed`-ing for its literal (`_mux_backend="zellij"`) breaks the moment the default flips | three Zellij regression tests failed on the flip for that reason and looked like real breakage. Match the alternation (`(zellij|tmux)`) so the fence survives the thing it is fencing |
| `XDG_CONFIG_HOME=/scratch zsh -c '...'` does NOT isolate config: `.zshenv` runs first and `environment.sh` resets the variable to the real `~/.config` | a "the loose pin overrides the baked default" check quietly read the REAL `~/.config/mux/backend` and reported the baked value — passing by luck exactly when the two agreed. Use `zsh -f`, or set the variable as the first line of the script TEXT so it lands after the rc files. Any test isolating via an XDG var has this hole |

## Click-to-open — ⌥+click (2026-07-27)

Opening the thing under the pointer moved OUT of the terminal and INTO tmux.
WezTerm resolved it in an `open-uri` Lua hook; tmux stores OSC 8 hyperlinks
itself and exposes the one under the pointer as `#{mouse_hyperlink}`, so one
root-table binding now serves both terminals — and knows exactly which pane
was clicked, which the Lua hook had to infer.

Ghostty forced this: it has no scripting hook of any kind. `link` (regex →
action) is a stubbed config key — `error.NotImplemented`, "TODO: This can't
currently be set!" — unimplemented in every release, no timeline, and a
collaborator has called arbitrary script-running out of scope. Nothing in
`+list-actions` runs a command.

Ghostty's own link handling is switched OFF (`mouse-shift-capture = always`)
so there is exactly one way to open a link rather than two half-working ones.
WezTerm keeps its ⌘+click, which still works there and is the only path on
zellij.

| Behavior | Zellij | tmux | Status | Notes |
|---|---|---|---|---|
| Click to open a link | WezTerm `open-uri` Lua only | `M-MouseDown1Pane` → `mux-open` via `#{mouse_hyperlink}` | 🟡 | tmux works on BOTH terminals; zellij has no scriptable mouse binding and no hyperlink format, so Ghostty+zellij cannot do this at all |
| Hover cue | terminal-native | terminal-native | 🟡 | WezTerm underlines on plain hover; Ghostty's is off by choice (it required ⌘⇧ and only ever opened the wrong app) |

| Gotcha | Consequence |
|---|---|
| the SGR mouse protocol encodes only Shift(+4), Meta(+8) and Ctrl(+16) — there is NO Cmd bit — and tmux's modifier vocabulary is `C-`/`S-`/`M-` with no Super | ⌘+click can never reach tmux, on any terminal. WezTerm's ⌘+click works only because WezTerm resolves it internally and never forwards it. Of the three modifiers that do travel, ⌃ is macOS's secondary-click and ⇧ is the mouse-capture bypass, which leaves ⌥ as the only free one. Note this does NOT generalise from the MEH work: those ⌘ chords reach tmux because the terminal REWRITES them (`keybind = cmd+shift+p=text:\x1b[112;8u`), and a click cannot be rewritten that way because a `text:` action carries no coordinates |
| tmux has no `MouseMove` event — the complete list is Wheel/Down/Up/Drag/DragEnd/Second/Double/TripleClick | hover is not a bindable thing in tmux, so a hover effect cannot be built there at any price. It also has no command that restyles content cells; copy-mode selection is its only in-content highlight. Hover cues are the terminal's job, always |
| Ghostty's `link-url = false` does NOT disable OSC 8 hyperlinks — MEASURED, hover and click both survived it | it governs the regex URL MATCHER only; explicit OSC 8 links take a separate path with no config of its own. The only lever that reaches them is `mouse-shift-capture`, because Ghostty suppresses its link handling entirely while an app captures the mouse, and ⇧ is the bypass that re-enables it |
| `mouse-shift-capture = always` forwards ⇧+mouse to tmux, and tmux ships NO shift-modified mouse bindings in either the root or copy-mode-vi table | every ⇧ gesture goes inert at once — click-to-focus, drag-select, double/triple-click, wheel-scroll, and the copy-mode-vi drag-END that performs the copy. Accepted deliberately here (one selection engine), but if it ever needs undoing, emit `S-` twins from shared template variables in `keymap-base.conf.tmpl` — hand-duplicating those command strings is how they drift |
| `mux::backend_for_pid` wants the mux CLIENT process; a pane's `#{pane_pid}` is its SHELL, whose parent is the server | it answers `none` for a pane pid, so a tmux-side caller cannot reuse the pid contract WezTerm's GUI hook uses. `mux-open` now takes `MUX_BACKEND`+`MUX_SESSION` from the environment and skips the probes — but only when BOTH are set, since a session with no backend is not an answer |
| `mailto:a@b` is a valid URI with no double slash | a `*://*` glob for "is this a link" silently drops it. Match the scheme (`^[a-zA-Z][a-zA-Z0-9+.-]*:`) instead. Caught by a test, not by review |
| chezmoi source files carry their executable bit in the `executable_` PREFIX, so the file in the repo is mode 644 | a spec that runs one directly gets status 126 and every example fails at once, which reads as a broken script rather than a broken harness. Invoke as `zsh <path>` |
| `mux-open` exports its OWN `PATH` before doing anything, to survive a GUI environment | a test that stubs a binary by prepending to `PATH` is silently overridden and runs the REAL command — stubbing `open` that way launches a browser instead of failing. Point `HOME` at a scratch dir and put stubs in `$HOME/.local/bin`, which is first in the PATH the script sets |

## Click-to-open, round 2 — plain URLs and Ghostty images (2026-07-27)

Two gaps that only surfaced under real use, both from the same root: the first
version assumed the terminal's job and tmux's job were interchangeable.

| Gotcha | Consequence |
|---|---|
| `#{mouse_hyperlink}` is populated ONLY for OSC 8 links. URL-shaped TEXT (`echo https://example.com`) is not a link to tmux — nothing linkifies it | ⌥+click did nothing on a printed URL while WezTerm's ⌘+click opened it, because WezTerm regex-matches URLs itself (`config.hyperlink_rules`). Moving the gesture into tmux is a DOWNGRADE on WezTerm unless the fallback is built. `mux-click` scans `#{mouse_line}` for a URL containing `#{mouse_x}` |
| `#{mouse_word}` cannot stand in for that scan: `word-separators` here is `" !\"#$%&'()*+,-./:;<=>?@[]^\\\`{|}~"`, which includes `:` and `/` | the "word" under `https://google.com` is `https`. Loosening the option to keep URLs whole would break double-click word-select in code, which is used far more often — so the line+column route is the cheaper trade |
| GHOSTTY DOES NOT SUPPORT SIXEL AND NEVER WILL — a stated decision by its maintainer, not a missing feature. Its Kitty graphics implementation is among the most complete outside Kitty itself | chafa was called with no `--format`, so it auto-detected: kitty when it can see `xterm-ghostty`, sixel through tmux (tmux advertises sixel), and Ghostty drew nothing. The `TERM_QUICK_VIEW_ARGS` hook had existed unused the whole time — the fix was wiring, not machinery |
| inside a pane `$TERM` is TMUX'S (`tmux-256color`) and says nothing about what will finally draw the pixels | the graphics protocol must be chosen from `#{client_termname}` (the attached client's terminal), not the environment. Same class of error as sizing from `tput` instead of asking the mux |
| zsh sets `$0` to the FUNCTION NAME inside a function (`FUNCTION_ARGZERO`, on by default), so `${0:A:h}` there is the CALLER'S CWD, not the script's directory | a sibling-script lookup written inside a helper function resolved to `$PWD/mux-open` and failed from a binding whose CWD is arbitrary — i.e. a click that silently does nothing. Resolve the script directory at top level and close over it |
| `${var%%[.,;:!?]##}` needs `extended_glob`, which is OFF in a plain script | without it `##` is literal, the trim silently does nothing, and a URL at the end of a sentence keeps its full stop. Silent because a slightly-wrong URL still "works" often enough to pass a casual look. The trim must also survive `a.tar.gz` — strip trailing punctuation, never all dots |

## Click-to-open, round 3 — what real use found (2026-07-27)

Three defects that every existing test passed straight through. All three were
in the seams: tmux→sh quoting, the key-table guard, and the physical modifier.

| Gotcha | Consequence |
|---|---|
| `'#{q:mouse_line}'` — `q:` escapes with BACKSLASHES for UNQUOTED use, and inside single quotes a backslash is literal while `\'` ENDS the string | `eza` quotes filenames containing spaces, so a real `ls` line carries single quotes and the command sh received was malformed: exit 2, click does nothing. It failed for exactly the files whose names have spaces, which made it look like a PDF/Office/graphics problem and sent the diagnosis chasing the kitty protocol. THE ERROR TEXT NAMED THE CAUSE — read the failing command string before theorising |
| the obvious fix (drop the quotes, keep `#{q:…}`) is also broken: an EMPTY value expands to NOTHING rather than an empty word | a click with no hyperlink shifted every later argument by one. Pass click values as unquoted `#{q:…}` ENVIRONMENT assignments instead — `FOO=` stays valid when empty, and `q:` keeps a hostile value one word. Verified against `$HOME`, backticks, quotes, `;`, `&`, `\|` |
| `#{pane_in_mode}` is TRUE in copy/scroll mode, so copying the drag-bind's guard verbatim swallowed the click there | scrolling back to find a filename and clicking it is a MAIN use of the gesture. The guard for click-to-open is `#{mouse_any_flag}` ALONE — an application capturing the mouse should take the event, a pane merely in copy-mode should not. Confirmed by synthesising the click both ways: old guard fires nothing in copy mode, new guard resolves the hyperlink in both |
| `#{mouse_x}` is ZERO-based — an SGR report of column 3 arrives as 2 | measured, not assumed. The single-URL path deliberately ignores the column so an off-by-one cannot produce a dead click, which is indistinguishable from an unbound key |
| a GUI app COLD-STARTED while OPTION is held reads it as a safe-mode request — Firefox pops "Open in Troubleshoot Mode?" instead of the page | ⌥ is the click modifier, so every ⌥+click on a URL hit it. `mux-open` waits for ⌥ to come up before calling `open` (`hs -c 'hs.eventtap.checkKeyboardModifiers().alt'`, ~9ms a query, bounded ~1.4s then opens anyway). Only the browser path is affected — the file branches open tabs inside tmux and launch nothing |
| a mouse event CAN be synthesised: the nested-tmux probe plus `send-keys -H` writing raw SGR bytes (`\e[<8;COL;ROWM`, where 8 = button0 + meta) into the inner client, which parses them as a real click | this is the only kind of test that sees these bugs. Tests that call the helper script directly pass while the gesture is completely broken, because the defects live in the binding and the quoting around it. `tests/mux_click_spec.sh` now drives real clicks in both normal and copy mode |

## Mouse word vs WORD select (2026-07-27)

| Behavior | Zellij | tmux | Status | Notes |
|---|---|---|---|---|
| double-click select | native word select | `select-word` under tmux.conf's `word-separators` (`viw`) | ✅ | |
| ⇧+double-click select | none | same `select-word` with `word-separators` narrowed to a space (`viW`) | 🟡 | tmux-only; needs the terminal to FORWARD shift rather than keep it as its bypass |

| Gotcha | Consequence |
|---|---|
| word vs WORD is not two commands — `select-word` reads `word-separators`, so narrowing that option to a single space for the duration turns the SAME command into `viW`. `foo-bar_baz.txt/qux` comes back whole instead of `bar_baz` | the alternative (`previous-space` + `begin-selection` + `next-space-end`) mis-handles a cursor already sitting on the first character, the way vim's `B` does. Restore with `setw -u`, never by restating the list — the global in tmux.conf stays the single source of truth |
| the narrowed option must be UNSET again on the way out, and nothing shouts if it is not | a leaked value silently turns every later PLAIN double-click into a WORD select: the new gesture looks perfect while the old one quietly breaks. Mutation-checked — dropping the restore leaves `word-separators` as `" "` on the window |
| `word-separators` is a WINDOW option, so it is narrowed for sibling panes too during the ~0.3s highlight | accepted: only a CONCURRENT double-click in another pane of the same window could observe it |
| ⌥ cannot carry a double-click gesture here — the FIRST click of a double fires `MouseDown1Pane`, and `M-MouseDown1Pane` opens the link under the pointer | ⌥+double-click on a filename would open it AND select it. ⇧ is free precisely because `S-MouseDown1Pane` is unbound (the inert-shift tradeoff), so nothing fires on the way in |
| ⇧ only reaches tmux if the terminal stops using it as the mouse-reporting bypass | Ghostty: `mouse-shift-capture = always` (bypass lost outright). WezTerm: `bypass_mouse_reporting_modifiers = 'CTRL'` — parked rather than disabled, so WezTerm keeps a native-selection escape hatch on ⌃+drag |
| a double-click can be SYNTHESISED: two rapid press/release pairs of raw SGR bytes through the nested-tmux probe, with the modifier in the button code (0 plain, 4 shift, 8 meta) | `tests/mux_select_spec.sh` drives both gestures for real and asserts the paste buffer, which is the only level at which a swallowed click or a leaked option is visible |

## The mnemonic rebinding (2026-07-28)

Why rename ever lived on `n`, and what it cost to move it. Full map in
`docs/superpowers/specs/2026-07-28-keymap-rebinding-design.md`.

| Gotcha | Consequence |
|---|---|
| retiring a key in the PREFIX table does not silence it — that table is tmux's own, so the key reverts to tmux's DEFAULT | `o` carried Session mode; left alone it would have started cycling panes (`select-pane -t :.+`) for anyone with ten months of muscle memory. Needs an explicit `unbind -T prefix o`. The custom mode tables have no defaults beneath them and need no such care |
| the which-key panel reads keys from TWO places in `keymap.yaml` — the entries, and `which_key.groups`, which lists keys by name for the panel's layout | updating the entries alone left the panel still dispatching `s` to the old split while the tmux table had already moved on. The panel is a separate process reading the DEPLOYED `whichkey.data`, so a scratch server with fresh binds still dispatches from stale data — which is what a verification run caught |
| `zellij setup --check` validates syntax and input modes but NOT action names — it accepts `TotallyBogusAction` without complaint | the only honest oracle is booting Zellij with the config (inside a scratch tmux pane). That is how `NewSession` turned out to be "Unsupported action" while `RenameSession` parses — a distinction no amount of reading the config would have settled |
| a spec that asserts two strings appear in one listing does NOT pin which one belongs to which key | the MEH test held `C-M-P` and `menu workspace` in the same output; swapping the two pickers kept every string present and the test green. Per-chord assertions are the only kind that can fail |
| a session whose `key-table` is `nested` never falls back to the ROOT table (measured: CSI-u MEH-s into a real nested client fired the root bind before the switch and nothing after it) | every chord the terminal sends unconditionally has to be bound in the `nested` table too, or it reaches the remote. WezTerm's Lua can branch on `nested-session-check` and substitute `C-M-Space`; Ghostty has no scripting, so ⌘⇧S opened the REMOTE's workspace picker there for the whole migration. A per-terminal split cannot fix a per-terminal blind spot — the key table can |

## The running server vs the deployed config (2026-07-28)

Chasing "the statusbar is not updating for any mode anymore" through a config
that turned out to be correct the whole time. What the hunt actually
established, in the order it stopped being a suspect:

| Gotcha | Consequence |
|---|---|
| a tmux server holds its config in MEMORY — `chezmoi apply` rewrites `~/.config/tmux/*.conf`, and a server started before that keeps the old key tables, hooks and `status-right` until something says `source-file` | the drift is silent and reads as a bug in the file you just edited: the bar still paints, the keys still do *something*. `run_onchange_after_58-reload-tmux.sh` now re-sources into every running server, walking the socket dir (`-L` servers included) rather than assuming the default socket |
| the mode pill is repainted by tmux ITSELF when the key table moves; an OPTION change earns no redraw | `@renaming` had to ask for its own `refresh-client -S` on the way in, or the pill waits for the next `status-interval` tick (10s) with the dialog already on screen. The exit path had one; the entry path did not |
| `send-keys -K -c <tty>` does NOT reliably traverse the key tables — the same sequence that leaves `client_key_table` stuck at `prefix` under `send-keys` walks Command → Tab → Rename perfectly when the bytes arrive as real input | cost a false diagnosis ("the `t` bind never fires"). Drive a nested client's terminal instead: `tmux -L outer send-keys -t host M-w` types into the pane that IS the inner client's tty |
| `set key-table X` (session option) and `switch-client -T X` (client) are BOTH in play here and are not the same knob — the leader arms the client, every mode bind moves the session default | reading only `client_key_table` while the option moved, or the reverse, makes a working chain look broken |
| a nested attach refuses while `$TMUX` is set, even for a DIFFERENT socket | `unset TMUX; tmux attach -t …`; and a half-typed line means the keys you send land in the shell instead of the client — check the pane before believing the bar |
| the renderer tolerates a short argv (11/13/14/15 args all render), so an appended argument is NOT what breaks a stale server | ruled out early; the arg list has grown 11 → 15 across the phase and stayed backward-compatible by appending only |
| **a `#()` job is not merely SLOW when it is slow — tmux will not start another while one is in flight, so the status line stops being re-expanded between runs.** A 4-11s accessibility probe in the renderer meant a mode began AND ended inside one render: `Alt+w` lit no pill at all, and the bar looked frozen rather than laggy | the render path may ask nothing that blocks. Both terminals now read a MIRROR file: WezTerm pushes its own from `wezterm.lua`, Ghostty's is filled by `mux-fullscreen-probe` off the `client-resized` hook. Renderer 5,500ms → 26ms; `tests/tmux_status_right_spec.sh` pins both the absence of blocking calls and a sub-second render |
| the give-away was that the ribbon repainted on a ~3.5s heartbeat and NOTHING — not a key-table change, not `refresh-client -S` — could make it repaint sooner | `refresh-client -S` forces a status REDRAW, not a job re-run: with a job in flight the redraw reuses the stale cached output. "Explicit refresh does nothing, but it updates on its own every few seconds" is the signature of a slow `#()`, and timing the renderer directly is the one-line diagnosis |
| an untrustworthy probe answer must not overwrite the mirror | the accessibility call returns `NOT_RUNNING` for a plainly-running Ghostty when the asker lacks the Accessibility grant. Writing `false` there silently disables the fullscreen segments and reads as a rendering bug — so only `WINDOWED`/`*_FULLSCREEN` are believed |
| probing bindings against the server the user is SITTING IN is how a working setup gets broken | a malformed `\;` chain left the live leader damaged and produced the very report being investigated. Scratch socket (`-L probe`) for experiments; a throwaway session + nested client when the LIVE server itself must be verified |

## Blink Shell — the third terminal (2026-07-29)

The iPad client is a mux CONSUMER like WezTerm and Ghostty, and it had been
carrying pre-MEH chords through two rebindings without anything noticing.
Bringing it current turned up facts about the chord layer that outlive it.
Map in `docs/superpowers/specs/2026-07-28-blink-keymap-design.md`; the file
itself is `assets/blink-shell/blink-kb.json` (hand-authored, so committed —
the directory's `.gitignore` excludes only the generated font/theme artifacts).

**Three layers, and only the middle one is Phase 8's.** `keymap.yaml` owns the
MODE TABLES; `keymap-base.conf` owns the root binds ("the root table has always
been ours"); and the terminal chord layer — `⌘⇧S` → `CSI 115;8u` — is
hand-written three times over, in `ghostty/config`, `wezterm.lua` and now
`blink-kb.json`. Phase 8 generates the two MUX config planes and touches none
of that, so waiting for it to fix terminal-chord drift is waiting for the
wrong thing.

| Gotcha | Consequence |
|---|---|
| **hiding the cursor and restoring it are two different sequences, and only one is universally supported.** `hide()` paints `cursor-colour` the canvas bg, which tmux emits as `OSC 12`; unsetting the option makes tmux emit `Cr` — `OSC 112`, reset cursor colour. Both measured off a scratch server through a pty. hterm implements the first and ignores the second | the cursor never came back — not in that pane, not in that session, not until the terminal restarted. Copy/visual was hit identically: a block cursor painted the background, in the one state whose point is showing a cursor. `show()` now repaints `roles.ui.cursor` outright rather than trusting a reset to land. Not a Blink special case — it restores through the SAME `OSC 12` that demonstrably hides the cursor there, so it cannot fail for a reason that would not also break hiding |
| the fix has a twin five lines below it: `shape_reset` already injects DECSCUSR 0 because tmux's shape reset does not reach the outer terminal either | the pattern is "tmux is correct AND the terminal still has to be told explicitly" — worth reaching for whenever a cursor attribute is restored rather than set. Both now share one `to_clients` helper, which APPENDS: identical on a tty, and it lets the colour and the shape both land when one call follows the other |
| `#{cursor_colour}` reports `none` when nothing in the pane drives `OSC 12`, and the app's value when something does — even while the pane OPTION is set to something else | that is the guard that keeps the repaint from painting over nvim's per-mode cursors, and the exact analogue of `shape_reset`'s `#{cursor_shape} == default` test. Verify the theme sets no GLOBAL `cursor-colour`, or the guard reads a hex instead of `none` and the repaint silently never fires |
| Blink maps Option to Escape — which is what makes `⌥w`, `⌥/`, `⌥.` and `⌥Enter` work with no binding at all | the same setting means it can never produce a MEH chord physically, so on Blink EVERY MEH action is Cmd-only. A root bind with no `⌘` chord is simply unreachable there, which is why the clipboard picker (`MEH-v`, unbound in both desktop terminals because the physical chord covers it) needed one. `C-M-Space`, the hand-typed nested hatch, is unreachable for the same reason |
| Blink folds Ctrl+Shift+letter down to the plain control byte. The evidence was already in the file: the glyph and gitmoji pickers were bound to explicit `CSI 117;6u` / `CSI 103;6u` by hand, which would be redundant if the native encoding carried shift | the resize row was not DEAD, it was WRONG — `⌃⇧J` arrived as `C-j` and moved focus instead of resizing. A chord that silently does something else is worse than one that does nothing, and it cannot be found by reading the terminal's config |
| Blink is `text:`-only — no scripting, no way to ask "is this pane nested?" | it mirrors GHOSTTY, not WezTerm: send unconditional bytes and let the outer session's `nested` table make the distinction (the row above, 2026-07-28). WezTerm's two Lua-branching chords are inexpressible, so `⌘⌥⇧S` forwards the leader `⌥w s S` — which must NOT be MEH-s, since identical bytes are eaten by the `nested` table before reaching the inner mux |
| `⌘,` means "open THIS terminal's config", and on Blink the settings UI *is* the config — there is no file | forwarding it as `⌥w ,` would open the remote's `~/.ssh/config` (`edit-terminal-config` resolves `ENV_TYPE=SSH` for any Blink session) and cost the only route into Blink's own settings. Left native; a ledger divergence from both desktop terminals, not an oversight |
| a chord table can be verified STRUCTURALLY without the device: decode every hex to its sequence, map each `CSI <cp>;<mod>u` to the tmux key name it will arrive as, and grep the RENDERED `keymap-base.conf` for that bind | caught the whole stale set before import (35 sequences, 0 missing) and is the cheap half of a drift detector — the terminal chord layer has no generator, so nothing else notices when a rebinding lands. It cannot catch what the TERMINAL does with a chord, which is where both real bugs lived |
| **two Blink shortcuts cannot send the same bytes. The second one is stored but never activates** — first occurrence in the file wins, and there is no error, no warning, and nothing missing from the config to look at | `⌘⇧K`/`⌘⇧J` (the WezTerm letter twins of `⌘⇧↑`/`⌘⇧↓`, deliberately identical actions) simply did not appear in Blink's shortcut list, while the file that defined them looked perfect. Measured by re-import and re-export: all 60 entries came back intact, so the drop is at ACTIVATION, not at import or storage — which is why reading the exported JSON confirms nothing about what is live |
| the fix is to spell the SAME key two ways. tmux binds three encodings of every MEH chord (see the MEH block in `keymap-base.conf`), so the arrows keep kitty `CSI <cp>;8u` and the letter twins take modifyOtherKeys `CSI 27;8;<cp>~` | different bytes, same `C-M-S-b`/`C-M-S-f` — verified by writing both forms into a real tmux client through a pty and watching the bind fire, not inferred from the comment. Any terminal that gives one mux action two chords needs this; it is the price of the letter/arrow twins existing at all |
| `stringInput` is NOT what makes an entry work — it is just what Blink writes when a shortcut is entered through the string-sequence path rather than the hex one | 39 of 41 hex entries on a working device have no `stringInput` at all. It looked causal because hand-adding a shortcut fixed it, but the hand-added entry worked by being the ONLY claimant of those bytes at that moment. A correlation that survives one test and dies on the second |
| one entry (`⌃⇧J`) went missing from an export with unique bytes and no collision, and came back on re-import | UNEXPLAINED. Left as a ledger row rather than folded into the dedup rule above — the rule accounts for every other case exactly, and a rule stretched to cover its one counter-example stops being predictive |
