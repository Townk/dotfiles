# Non-unicode9 zsh

A from-source zsh built **without** `--enable-unicode9`, so the line editor
(ZLE) takes emoji display widths from macOS's `wcwidth()` instead of zsh's
frozen Unicode 9.0 (2016) tables.

## The problem

Every stock zsh on macOS — Apple's `/bin/zsh`, Homebrew, and z4h's bundled
binary — is compiled with `--enable-unicode9`. That makes zsh ignore the OS and
use its own Unicode 9.0 width tables. Emoji added after 2016 are unknown to
those tables, so zsh assigns them width 0 and ZLE prints a placeholder escape
instead of the glyph:

| code point | emoji | macOS `wcwidth()` | unicode9 zsh | this build |
| --- | --- | --- | --- | --- |
| U+1F3A8 (Unicode 6) | 🎨 | 2 | 2 | 2 |
| U+1F9EE (Unicode 11) | 🧮 | 2 | **0 → `<0001f9ee>`** | 2 |
| U+1FAC0 (Unicode 13) | 🫀 | 2 | **0 → `<0001fac0>`** | 2 |
| U+1FAE0 (Unicode 14) | 🫠 | 2 | **0** | 2 |

macOS's `wcwidth()` is correct (returns 2), so omitting `--enable-unicode9`
fixes it. This is purely a ZLE *display* issue — the bytes on the command line
were always correct.

(Unrelated: emoji that are `base + U+FE0F` — e.g. `♻️` rendered as `♻<fe0f>` —
are a *combining* problem fixed separately by `setopt COMBINING_CHARS` in
`~/.zshrc`.)

## How it's wired

- `build-zsh.sh` downloads, verifies, configures, builds, and installs zsh to
  `~/.local/opt/zsh-nounicode9/<ver>` and symlinks `~/.local/bin/zsh` to it. It
  is idempotent (fast no-op when the correct binary is already installed).
- `home/run_onchange_after_zsh-nounicode9.sh.tmpl` runs the builder on
  `chezmoi apply`, re-firing when `build-zsh.sh` changes (its SHA is baked into
  the rendered hook).
- **A one-time `chsh` is required** to make the terminal *start* this zsh:

  ```bash
  echo "$HOME/.local/bin/zsh" | sudo tee -a /etc/shells
  chsh -s "$HOME/.local/bin/zsh"
  ```

  z4h does **not** auto-switch on its own: its candidate search
  (`exec-zsh-i`) only runs when the *starting* zsh is older than 5.8 or can't
  load its modules. A healthy 5.9.x login shell is kept as-is, and z4h re-execs
  into *that same binary* — so the login shell itself must be the new zsh.
  (This `chsh` is per-machine and not chezmoi-managed; only the binary is.)

## Build recipe notes

See the header of `build-zsh.sh`. The non-obvious bits: relax clang's
implicit-int / implicit-function-declaration errors (else configure silently
disables dynamic modules that z4h requires), and pass `--with-tcsetpgrp` (the
runtime probe needs a controlling tty the hook lacks).

## Optional modules

All optional modules that don't need an external library build by default
(`zpty`, `mathfunc`, `attr`, `net/tcp`, `net/socket`, `zprof`, `zftp`, `stat`,
`mapfile`, …). The two that need libraries:

- `zsh/pcre` — built when `pcre2-config` is present (`--enable-pcre`). zsh 5.9.1
  uses **PCRE2** (legacy PCRE1 was dropped upstream in 2023), so it links
  against Homebrew's `pcre2` — a runtime dependency that only matters when you
  `zmodload zsh/pcre`.
- `zsh/db/gdbm` — needs `gdbm`; not enabled (niche: persistent hashes via
  `ztie`). Add `gdbm` + `--enable-gdbm` if ever wanted.
