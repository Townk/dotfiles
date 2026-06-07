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

- `build-zsh.sh` keeps a **shallow clone** of upstream zsh under `build/zsh`
  (gitignored), regenerates `configure` (autoconf), builds, and installs to
  `~/.local/opt/zsh`, then symlinks `~/.local/bin/zsh` to it. It is idempotent:
  a no-op fast path when the installed binary already matches the clone's
  commit.
- `home/run_onchange_after_zsh-nounicode9.sh.tmpl` runs the builder on
  `chezmoi apply` for **macOS** with the **work** or **personal** profile,
  re-firing when `build-zsh.sh` changes (its SHA is baked into the rendered
  hook).
- **Source / updates.** The clone tracks `ZSH_REF` (default `master` — i.e.
  development zsh; set `ZSH_REF=zsh-5.9.1` to pin a release). Update on demand:

  ```bash
  ZSH_UPDATE=1 bash build-zsh.sh   # shallow fetch latest ZSH_REF + rebuild
  ```

  (`git pull` is avoided in-script — shallow clones backfill history and stall;
  the builder uses `git fetch --depth 1` + `git reset --hard`.)
- **Login shell.** The builder also makes this zsh the login shell
  (`ensure_login_shell`): z4h does **not** auto-switch — its candidate search
  only runs when the *starting* zsh is older than 5.8 or can't load its
  modules, so a healthy 5.x login shell is kept and z4h re-execs *that same
  binary*. Registering it (`/etc/shells` + `chsh`) prompts for a password, so
  the builder only does it with a tty (e.g. interactive `chezmoi apply` during
  bootstrap). Non-interactively it prints the one-liner instead:

  ```bash
  echo "$HOME/.local/bin/zsh" | sudo tee -a /etc/shells
  chsh -s "$HOME/.local/bin/zsh"
  ```

  It's idempotent — a no-op once the login shell already points here.

## Build recipe notes

See the header of `build-zsh.sh`. The non-obvious bits: regenerate `configure`
with `autoconf` (a git clone, unlike a release tarball, ships none); relax
clang's implicit-int / implicit-function-declaration errors (else configure
silently disables dynamic modules that z4h requires); and pass
`--with-tcsetpgrp` (the runtime probe needs a controlling tty the hook lacks).

### Dependencies

This repo's convention is to source tools from `mise`; brew is used only when
there's no mise equivalent. The build's two non-toolchain deps have none, so
both are declared in `home/dot_config/packages/Brewfile.tmpl`:

- `autoconf` — regenerates `configure` from the git clone (not in mise's
  registry / no asdf/aqua/ubi backend);
- `pcre2` — the PCRE2 library the `zsh/pcre` module links against (a C library,
  not a runtime mise manages).

`clang`/`make` come from the Xcode Command Line Tools, and `git`/`make` are
already in the Brewfile. There is intentionally **no `mise.toml`** here —
nothing in the build is mise-installable.

Compiled with `-O3 -mcpu=native`. On AArch64, **`-mcpu` is the single correct
knob** — it sets both the instruction-set extensions and the scheduling model
for a specific core. `-mcpu=native` detects this Mac's actual chip (M-series),
so a per-machine build is tuned to that machine. Do **not** use
`-march=native -mcpu=apple-m1`: on AArch64 `-march` only selects the
architecture level (not microarchitecture tuning), and `-mcpu=apple-m1` pins
codegen to the M1 core — wrong for a newer chip and contradictory with
`native`. (For a shell the perf delta is negligible regardless; this just
avoids leaving correctness on the floor.)

## Optional modules

All optional modules that don't need an external library build by default
(`zpty`, `mathfunc`, `attr`, `net/tcp`, `net/socket`, `zprof`, `zftp`, `stat`,
`mapfile`, …). The two that need libraries:

- `zsh/pcre` — built when `pcre2-config` is present (`--enable-pcre`). zsh
  master uses **PCRE2** (legacy PCRE1 was dropped upstream in 2023), so it
  links against Homebrew's `pcre2` — a runtime dependency that only matters
  when you `zmodload zsh/pcre`.
- `zsh/db/gdbm` — needs `gdbm`; not enabled (niche: persistent hashes via
  `ztie`). Add `gdbm` + `--enable-gdbm` if ever wanted.
