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
| `q` quit | themed gum confirm (zellij-quit-confirm) | themed `input::confirm` popup (mux-quit-confirm) | ✅ | per-backend kill path; zellij keybind re-points at mux-quit-confirm in Phase 6 |
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
| `C-j/k` in agents | `when agent,cursor-agent: key down/up` | — | ⏳ tmux | Phase 6 context routes |
| `Shift+Enter` | context-keys: kitty CSI-u to pi/claude, alt-enter to agents, tm apply route | `extended-keys always`: CSI-u to kitty-negotiating apps; plain apps get `\e[27;2;13~` | 🟡 | plain-app encodings differ (`\e[13;2u` vs xterm form); `extended-keys-format csi-u` is the alignment knob — decide Phase 5 |
| `J/K/H/L`, `Shift+↑↓`, `A`, `S` tm-scrub routes | context-keys over yazi/hunk/diffnav/tm | NOT BOUND (would intercept bare capitals; no tmux tm consumer yet) | ⏳ tmux | Phase 6.4 binds against `@ctx` (wrapper already stamps) |
| `Alt Enter` fullscreen toggle | context-keys → terminal-toggle-fullscreen | — | ⏳ tmux | Phase 6.1 |
| `C-S-u/g` glyph/gitmoji pickers | zellijModalRun floats | display-popup via tmux-modal --inject (-B, fzf owns the box) | ✅ | insert-without-dismiss works (pick sink tmux branch) |
| `Alt /` search dialog | zj-hud role "search" float | copy-mode `/` incremental (stage 1) | 🟡 | D12 stage 2 hud owns the dialog |

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
| search option toggles (case/word/wrap) | zj-hud search role + MessagePlugin sync | — | ⏳ tmux | D12 stage 2 |
| which-key panel | zj-hud role "whichkey" (pages/trail) | — | ⏳ tmux | Phase 5 (menus → hud) |

## Session-level behaviors

| Behavior | Zellij | tmux | Status | Notes |
|---|---|---|---|---|
| OSC 52 copy | re-emit to focused client (no copy_command) | `set-clipboard on` re-emit | ✅ | validated Phase 0 incl. SSH |
| OSC 8 links | `osc8_hyperlinks true` | `terminal-features hyperlinks` | ✅ | |
| Images | sixel-only through VTE | native sixel (WezTerm) / kitty placeholders (Ghostty) via preview stack | ✅ | Phase 0 as-built §10 |
| Scrollback size | `scroll_buffer_size 1000000` | `history-limit 1000000` | ✅ | |
| Session serialization | off | no resurrect plugin | ✅ | D17 |
| Cross-mux hygiene | n/a (zellij sets its own env) | scrubs stale `ZELLIJ*`; zshrc guard blocks nested autostart | ✅ | Phase 0 as-built |

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
