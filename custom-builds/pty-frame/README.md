# custom-builds / pty-frame

`pty-frame` draws a titled box and runs a child TUI (in practice **fzf**) inside
it, compositing the child's output into the frame. It's how the borderless
zellij picker modals (glyph / gitmoji / `zj::pick`) get the exact dialog layout:

```
╭───────────────── Glyph Picker ─────────────────╮   outer border + label   (pty-frame)
│                                                │   blank                   (pty-frame)
│ ▓▓▓ Glyph Picker                               │   ▓▓▓ title               (pty-frame)
│ ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ │   rule                    (pty-frame)
│ ╭────────────────────────────────────────────╮ │  input box               (fzf)
│ │ > query                              12/120 │ │
│ ╰────────────────────────────────────────────╯ │
│                                                │   input→list blank        (fzf --header)
│ ▌ item one                                     │   list                    (fzf)
│ ▌ item two                                     │
│                                                │   blank                   (fzf --footer)
│   ↵ open · esc cancel                          │   hints                   (fzf --footer)
╰────────────────────────────────────────────────╯
```

## Why this exists

fzf has exactly **one** header region. Putting the `▓▓▓` title block *above* the
input consumes it, leaving nothing for the blank line *below* the input — so fzf
alone can't render the spec above. And a shell script can't draw the box around
fzf either: fzf clears its **full-width** region, erasing any borders we'd draw on
its rows (verified — `--no-border --margin` still wipes col 1 / col W).

The fix is to give fzf a **smaller terminal**. `pty-frame` runs fzf in a sub-pty
sized to the inner area, so fzf's clears can't reach the frame columns. Because
*pty-frame* draws the `▓▓▓` block (not fzf's `--header`), fzf's single header is
freed to become the input→list blank. This is the same trick a terminal
multiplexer uses to draw borders around panes.

## Usage

```
pty-frame [chrome flags] -- CHILD [args...]
```

- Reads the list to filter on **stdin**, passes it to the child.
- Relays the child's **stdout** (the selection) verbatim, and propagates its exit
  code (so fzf's `130` cancel still reaches the caller).
- Draws its UI to `/dev/tty`; keystrokes are forwarded from the real tty to the
  child's sub-pty. Answers the child's cursor-position report; redraws on
  `SIGWINCH`.

Chrome flags: `--title`, `--label`, `--bg`, `--fg`, `--border-color`,
`--title-color`, `--rule-color` (all colors are `#rrggbb`).

The caller (`~/.local/lib/pick-common.zsh`) builds the fzf args so the child is
borderless and fills the sub-pty inline:

```
… | pty-frame --title "Glyph Picker" --bg "#181825" … -- \
      fzf --no-border --height=100% --input-border --header=' ' \
          --no-separator --footer-border=none --footer=$'\n<hints>' …
```

If `pty-frame` isn't on disk, `pick-common.zsh` falls back to the
fzf-owns-the-whole-box layout (no input→list blank), so pickers always work.

## Build / install

```sh
make install      # go build → ~/.local/libexec/pty-frame
```

`custom-builds/` is outside chezmoi's `home/` source dir, so chezmoi never
deploys it. The build is driven on `chezmoi apply` by
`home/.chezmoiscripts/run_onchange_after_55-build-pty-frame.sh.tmpl`, which
re-fires whenever `main.go` / `go.mod` change (and skips cleanly if Go is
absent). The single source file (`main.go`) holds the arg parsing, the chrome
renderer, the sub-pty spawn, and a minimal VT emulator (just the `CUP`/`SGR`/
`EL`/`ED`/text fzf emits) that turns the child's output into a colored cell grid.
