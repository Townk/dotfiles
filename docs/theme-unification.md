# Theme Unification — chezmoi dotfiles repo

A **single source of truth** for color across every app, CLI, and shell in this
repo: one switchable, role-based schema in `home/.chezmoidata/theme.yaml`, with
thin per-format projections (and per-app generated themes) that each consumer
reads. Status: **implemented**. Editing one key — `theme.active` — and running
`chezmoi apply` re-colors *every* terminal surface; switching to a light palette
also flips each app's light/dark mode.

The schema (full detail in §4.1):

- **`theme.active`** names the palette to render — the only switch.
- **`theme.palettes.<name>`** — the switchable palette files. Each fills the SAME
  named vocabulary (the 26 Catppuccin slots + `white`) plus `meta.appearance`
  (`dark`/`light`) and the bespoke per-theme sets (`ansi_bright`, `alternate_bg`
  washes, `tags`, `tab`, `dialog`, `diff`, `pi`, `find_highlight`). Ships with
  `catppuccin-mocha` (dark) and `catppuccin-latte` (light).
- **`theme.roles`** — the shared semantic map (CONSTANT across palettes): every
  value is a vocabulary slot resolved against the active palette. Generators read
  THESE roles (`ui`, `state`, `action`, `mode`, `diff`, `ansi`, `syntax`), never
  raw slot names, so a switch re-colors everything.
- **No app is pinned to a built-in/vendored theme.** ghostty, wezterm, bottom,
  zellij, bat, yazi, delta, glow, pi, tealdeer all render a `system`/generated
  theme produced from `theme.yaml`; nvim renders a `chezmoi-system` colorscheme
  that **vendors catppuccin/nvim's highlight-group definitions** (MIT) and feeds
  them OUR palette via injected `C`/`O`/`U` globals — catppuccin's full coverage
  (~937 groups: editor + treesitter + LSP + plugins) with NO catppuccin runtime
  dependency, and still theme-agnostic (a custom-named palette drives it).
- **Runtime override layer:** a loose, host-pushed `~/.config/theme/override.toml`
  lets a session use different colors (e.g. match the WezTerm SSH tint) without
  re-applying chezmoi — resolved at session start (§4.8).
- **Guardrail:** `make lint` (`tests/lint-theme.sh`) fails on any raw hex outside
  `theme.yaml`, and `make test` runs it before the suite (§7).

> How the apps that ship **their own copy** of the palette (`bat`, `ghostty`,
> `bottom`, the yazi flavor, nvim's plugin) are made to follow `theme.yaml` is in
> **§4.4**. Switching is covered in §4.1; the role taxonomy in §4.1.1.

---

## 1. Why

The Catppuccin Mocha palette (and a couple of stray *other* palettes) is
hardcoded independently in **15+ files** across six languages (zsh, Lua, KDL,
JSON, TOML, Python, JS). A palette tweak is a 15-file edit, and the values have
**already drifted**:

- `home/dot_pi/agent/themes/catppuccin-mocha.json` is wrong in several slots:
  `mauve #cba0f3` (canonical `#cba6f7`), `sapphire #74c7ff` (canonical
  `#74c7ec`), `overlay0 #9399b2` (that's *overlay2*'s value), `overlay2
  #89dceb` (that's *sky*'s value).
- `home/dot_local/libexec/executable_ics-view` has `OVERLAY0 = (108, 114, 134)`
  while `common.zsh` uses `#6c7086` = `(108, 112, 134)`.
- `home/dot_config/zellij/layouts/default.kdl.tmpl` mixes case (`#F9E2AF` vs
  `#f9e2af`, `#89B4FA` vs `#89b4fa`) and mixes palettes (see §3).

There is already a *partial* unification for the zsh/dialog family
(`common.zsh` `C_HEX_*`, `theme-common.zsh` `THEME_*`, `pick.jq`,
`tint-palette.toml`). This design **generalizes that pattern** to the whole
repo rather than inventing a new one.

---

## 2. Inventory — every color-definition site today

Grouped by how color is declared. "Mechanism" is what would change.

### 2.1 Existing partial sources of truth (zsh/dialog/picker only)

| File | Defines | Mechanism |
|---|---|---|
| `home/dot_local/lib/common.zsh` | `C_HEX_*` (subset of Mocha), `C_*` SGR, `C_HEX_TAB_*` | zsh vars, tty-gated |
| `home/dot_local/lib/theme-common.zsh` | `THEME_*` semantic tokens, `theme::args`, `theme::sgr_fg` | composes from `C_*` |
| `home/dot_config/zsh/themes.sh` | `JQ_COLORS` (jq/yq/xq) | env var, raw SGR |
| `home/dot_local/lib/pick.jq` | `c_glyph/c_key/c_auto/c_code/c_desc` | jq defs, raw SGR |
| `home/dot_config/wezterm/tint-palette.toml` | per-machine bg tint washes | flat TOML; read by `wezterm.lua` + `system-onboard` |

### 2.2 Hardcoded Catppuccin Mocha, duplicated

| Area | File(s) | How |
|---|---|---|
| Terminals | `wezterm/wezterm.lua` (`tab_bar` literals + named scheme), `ghostty/config` (`theme =`), `assets/blink-shell/catppuccin-mocha-custom.js` (16-color) | literals / name |
| Multiplexer | `zellij/themes/catppuccin-mocha-dialog.kdl` (full theme, RGB triples), `zellij/config.kdl.tmpl` (`theme "…"`), `zellij/layouts/default.kdl.tmpl` (status-bar/which-key, 82 literals) | literals / name |
| Pickers | `pick-common.zsh` (fzf `--color`), `libexec/pick-glyph`, `libexec/pick-gitmoji` (via `pick.jq`) | literals |
| File viewers | `libexec/{ics,sqlite,disk-image}-view` — each redefines its own `class CTP` (full Mocha as RGB tuples) | literals ×3 |
| fzf | `zsh/completion.sh` `FZF_DEFAULT_OPTS` | literals |
| CLIs (name only) | `bat/config`, `yazi/{package,theme}.toml` flavor, `bottom/bottom.toml` base, `ghostty/config` | named theme |
| CLI overrides | `bottom/bottom.toml` `[styles.*]` (24 literals), `tealdeer/config.toml.tmpl` (RGB styles) | literals |
| CLI theme file | `glow/catppuccin-mocha.json` (44 colors; selected by path in `bin/preview`) | committed theme |
| AI agent | `dot_pi/agent/themes/catppuccin-mocha.json` (32) + `modify_settings.json.tmpl` theme key | committed theme |

### 2.3 Extension palettes layered on Mocha (legitimately separate)

| Set | File | Notes |
|---|---|---|
| Tab bar | `C_HEX_TAB_*` (`common.zsh`), `wezterm.lua` `tab_bar` | sourced from zj-hud bar colors |
| Tint washes | `wezterm/tint-palette.toml` | per-machine bg tint over base |
| Tool-result tints | `dot_pi/.../catppuccin-mocha.json` (`toolSuccessBg #1e2e1e`, `toolErrorBg #321e1e`) | tinted base |
| Diff | `git/config.tmpl` `[delta]` (`#053f1f`, `#2bfa84`, `#00703e`, `#3e151d`, `#ff878a`, …) | custom diff greens/reds |
| Tags | `yazi/init.lua` mactag (`#ee7b70`, `#f5bd5c`, …) | macOS Finder-style tags |
| Custom accents | pi `earthMaroon #D77757`; zellij scroll `#7b5bd6` | one-off |

### 2.4 NOT Catppuccin today — must be migrated (decision: migrate)

| Palette | Where |
|---|---|
| **One Dark** (`#98c379` `#61afef` `#c678dd` `#e06c75` `#abb2bf` `#5c6370` `#56b6c2` `#d19a66`) | `zsh/functions.d/_lib.sh` (p10k color vars), `nvim/lua/lualine/themes/doom-modeline.lua` + components (fallbacks), `completion.sh` warnings, `dot_zshrc` separator, and **mixed into** `zellij/layouts/default.kdl.tmpl` (resize `#c678dd`, search `#61afef`, prompt/session/tmux `#e06c75`, rename `#e5bf7b`, scroll `#7b5bd6`) |
| **Custom softened pastel** (`#B3E1A7` `#E590A8` `#93B3F4` `#F5E3B5` `#FFB056` `#A5E0D5` `#60B9E3` `#9ad3da` `#a0cff5`) | `zsh/p10k.zsh` prompt foregrounds |

### 2.5 Out of scope (decorative, not "theme")

Hammerspoon Stream Deck icon gradients (`streamdeck/presets.lua`, `renderer.lua`),
`hammerspoon/Assets/icons/svg/*`, `custom-builds/colorscripts/`, nerd-font
`custom-icons/*.svg`. These are brand/art assets, not theme tokens.

---

## 3. Canonical palette (the values to author once)

Standard Catppuccin Mocha — the content of `theme.palettes.catppuccin-mocha` (the
default `active` palette). `theme.palettes.catppuccin-latte` mirrors this shape
with the light flavor's values.

| Token | Hex | RGB |
|---|---|---|
| rosewater | `#f5e0dc` | 245 224 220 |
| flamingo | `#f2cdcd` | 242 205 205 |
| pink | `#f5c2e7` | 245 194 231 |
| mauve | `#cba6f7` | 203 166 247 |
| red | `#f38ba8` | 243 139 168 |
| maroon | `#eba0ac` | 235 160 172 |
| peach | `#fab387` | 250 179 135 |
| yellow | `#f9e2af` | 249 226 175 |
| green | `#a6e3a1` | 166 227 161 |
| teal | `#94e2d5` | 148 226 213 |
| sky | `#89dceb` | 137 220 235 |
| sapphire | `#74c7ec` | 116 199 236 |
| blue | `#89b4fa` | 137 180 250 |
| lavender | `#b4befe` | 180 190 254 |
| text | `#cdd6f4` | 205 214 244 |
| subtext1 | `#bac2de` | 186 194 222 |
| subtext0 | `#a6adc8` | 166 173 200 |
| overlay2 | `#9399b2` | 147 153 178 |
| overlay1 | `#7f849c` | 127 132 156 |
| overlay0 | `#6c7086` | 108 112 134 |
| surface2 | `#585b70` | 88 91 112 |
| surface1 | `#45475a` | 69 71 90 |
| surface0 | `#313244` | 49 50 68 |
| base | `#1e1e2e` | 30 30 46 |
| mantle | `#181825` | 24 24 37 |
| crust | `#11111b` | 17 17 27 |

---

## 4. Design

**One theme identity — `system`.** Every app references a single,
flavor-independent theme *name* — `system` — instead of `catppuccin-mocha`. The
name means "whatever this machine's chezmoi config defines," so changing flavor
or tweaking a color never renames anything; only `theme.yaml` changes
(`ghostty theme = system`, `wezterm color_scheme = "system"`, `bat --theme=system`,
`zellij theme "system"`, the generated yazi `theme.toml`, zj-hud/ai-playbook
config). nvim follows the same idea with its own generated colorscheme,
`chezmoi-system` (§4.4) — no vendored plugin. `system` is the recommended
identifier; `chezmoi` or a
personal handle work equally well — it's a one-line change in the templates.

### 4.1 Source of truth: `home/.chezmoidata/theme.yaml`

chezmoi `data` files are visible to **every** `*.tmpl` in the repo — the natural
home for a global palette. Two halves: per-theme **palettes** (switchable) and a
shared **role map** (constant).

```yaml
theme:
  active: catppuccin-mocha          # <- the ONLY switch

  palettes:
    catppuccin-mocha:
      meta: { name: "Catppuccin Mocha", appearance: dark }
      # named vocabulary = the 26 Catppuccin slots + white (all hex, no '#')
      rosewater: "f5e0dc"  ...  mauve: "cba6f7"  ...  base: "1e1e2e"  white: "ffffff"
      # bespoke per-theme sets:
      ansi_bright:  { red: "f37799", green: "89d88b", ... }   # terminal slots 9-14
      alternate_bg: { cyan: "1c232f", blue: "1d1f33", ... }   # SSH/window tint washes
      tags:         { red: "ee7b70", ... }                    # yazi mactag (Finder tags)
      tab:          { bg: "282c41", fg: "9b9fc1", ... }       # zj-hud tab chrome
      dialog:       { danger: "ff5555", warning: "e5bf7b" }   # loud dialog variants
      diff:         { plus_bg: "053f1f", minus_bg: "3e151d", ... }  # delta git-diff
      pi:           { thinking: "d77757", tool_success_bg: "1e2e1e", ... }
      find_highlight: "3e5767"
    catppuccin-latte:
      meta: { name: "Catppuccin Latte", appearance: light }
      base: "eff1f5"  text: "4c4f69"  ...  white: "11111b"    # light flavor
      # ... same bespoke sets, light-appropriate values ...

  # Shared semantic map — CONSTANT across palettes; every value is a vocabulary
  # slot resolved against the ACTIVE palette. Generators read THESE.
  roles:
    ui:     { bg: base, surface: surface0, fg: text, accent: mauve,
              border: surface2, border_focus: blue, border_inactive: surface1,
              hint: overlay1, input_fg: text, placeholder: overlay0,
              cursor: rosewater, selection: surface2, link: blue, key: white, ... }
    state:  { error: red, warning: yellow, success: green, info: sapphire, hint: teal }
    action: { primary: mauve, run: green, confirm: green, stop: red,
              caution: peach, attention: yellow, info: sapphire, neutral: overlay1 }
    mode:   { normal: green, locked: peach, pane: blue, tab: green, resize: mauve,
              move: yellow, search: blue, scroll: lavender, rename: yellow,
              session: red, prompt: red, tmux: red }
    diff:   { added: green, removed: red, changed: peach }
    ansi:   { black: surface1, red: red, ..., bright_white: subtext0 }
    syntax: { keyword: mauve, string: green, comment: overlay2, function: blue, ... }
```

**Switching mechanism:** templates resolve the active palette once —
`{{ $p := index .theme.palettes .theme.active }}` — then resolve roles against it
(`{{ index $p $r.ui.accent }}`). Switch = edit `theme.active` + `chezmoi apply`.
Because every palette fills the same vocabulary, slot refs (`$p.mauve`) and role
refs both follow the switch.

Notes:
- Store hex **without** `#` so templates can emit `#{{ . }}`, `0x{{ . }}`, or
  split to `R G B` (the `.chezmoitemplates/hex2rgb.tmpl` helper) as each syntax
  needs.
- `alternate_bg` (the SSH/window tint washes) is **per-theme + appearance-aware**:
  a dark theme keeps them near a dark base, a light theme makes them light. The
  per-machine layer (`terminal-location.zsh` / onboard color) only selects WHICH
  name a box uses; the active theme supplies the color, and `tint-palette.toml` is
  generated from it (§4.3).

#### 4.1.1 Role taxonomy (the app-facing contract)

Roles are grouped by axis so a generator picks the right one:

- **`ui`** — chrome: backgrounds (`bg`/`bg_dim`/`bg_deep`/`surface`/`surface_hi`),
  foregrounds (`fg`/`fg_dim`/`muted`/`overlay`), `accent`, borders (`border`
  resting, `border_focus` active/selected, `border_inactive` unfocused), inputs
  (`input_fg`, `placeholder` = also the zsh-autosuggestion ghost, `hint` = the
  keybind-hint line), `cursor`/`cursor_text`, `selection`, `link`, `separator`,
  `key`, `title`.
- **`state`** — status text: `error`/`warning`/`success`/`info`/`hint`.
- **`action`** — button INTENTS (one hue each). Apps map their buttons to an
  intent; the theme never names per-app actions. `run`/`confirm` share green
  by default (both positive) but stay separate for later per-theme split.
  Exported via `palette.json` (`roles.action`) for TUIs (e.g. ai-playbook).
- **`mode`** — input-state indicators (zellij modes, p10k vi-mode), NOT actions.
- **`diff`** — semantic add/remove/change (editors/pi); delta's full diff
  highlight (wash bgs, line numbers) lives in the per-theme `palette.diff`.
- **`ansi`** — canonical 16-color; ghostty/wezterm keep their own near-identical
  built-in mappings (slot-based), so this is for any new consumer.
- **`syntax`** — the canonical code-token map for the generated `.tmTheme`
  (bat/yazi-preview/delta) and nvim.

### 4.2 Migration map for the non-Mocha surfaces (§2.4 → Mocha by role)

Decision was **migrate**. Map by semantic role, not by closest hex:

| Old (One Dark / pastel) | Role | → Mocha |
|---|---|---|
| `#98c379` / `#B3E1A7` | green / ok | `green #a6e3a1` |
| `#e06c75` / `#E590A8` | red / error | `red #f38ba8` |
| `#61afef` / `#93B3F4` | blue / dir | `blue #89b4fa` |
| `#c678dd` | magenta / resize | `mauve #cba6f7` |
| `#7b5bd6` | scroll accent | `mauve #cba6f7` (or `lavender`) |
| `#e5bf7b` / `#e5c07b` / `#F5E3B5` | yellow | `yellow #f9e2af` |
| `#d19a66` / `#FFB056` | orange / pipe | `peach #fab387` |
| `#56b6c2` / `#A5E0D5` / `#9ad3da` | cyan / teal | `teal #94e2d5` |
| `#60B9E3` / `#a0cff5` | sky / anchor | `sapphire #74c7ec` (or `sky`) |
| `#abb2bf` | fg / loading | `text #cdd6f4` or `subtext1` |
| `#5c6370` | gray / untracked | `overlay0 #6c7086` |
| `#282c34` | bg fallback | `base #1e1e2e` |

These mappings are the *recommended* defaults; each is a one-line tweak in
`theme.yaml`'s `semantic`/consumer mapping if a slot looks off after applying.

### 4.3 The bridge: thin generated `palette.*` modules

Because consumers span six languages, render **one tiny projection per format**.
Each is mechanical (just re-emits `theme.yaml`). Proposed location:
`~/.config/theme/` (source: `home/dot_config/theme/palette.*.tmpl`).

| Bridge | Emits | Consumed by |
|---|---|---|
| `palette.zsh` | `C_HEX_*`, `C_*` SGR, `THEME_*` tokens | `common.zsh`, `theme-common.zsh`, `pick-common.zsh`, `completion.sh`, `_lib.sh`, `dot_zshrc` |
| `palette.lua` | a `{ palette=…, semantic=…, extended=… }` table | `wezterm.lua`, `yazi/init.lua`, hammerspoon, nvim lualine |
| `palette.json` | nested objects (hex with `#`) | the 3 Python viewers (`json.load`), and `pick.jq` via `--argjson` |

`palette.toml` is **not** needed: the only TOML consumers (`bottom`, the tint
file) become templates that read `theme.yaml` directly (§4.5).

Minimizing bridge count is deliberate — JSON already serves Python *and* jq.

### 4.4 The named-theme trap — "flavor switch" vs. "custom palette"

The apps that read a **built-in/named theme** (`bat --theme="Catppuccin Mocha"`,
`ghostty theme = Catppuccin Mocha`, the yazi flavor dep, `bottom theme=`, and
nvim's `catppuccin/nvim` plugin) each ship **their own copy** of the palette and
ignore `theme.yaml`. So "one place to change the theme" only holds if we deal
with them explicitly. Two different operations hide behind "change the theme":

**(A) Switch among published Catppuccin flavors** (Mocha → Macchiato). The
named-theme apps don't need replacing — just drive every name from one
`theme.flavor` key: `bat --theme="Catppuccin {{ flavor | title }}"`,
`ghostty theme = catppuccin-{{ flavor }}`, yazi `[flavor] dark =
"catppuccin-{{ flavor }}"`, nvim `flavour = "{{ flavor }}"`,
`bottom theme = "catppuccin-{{ flavor }}"`. One key, one `chezmoi apply`.
**Caveat:** this stays consistent only while `theme.yaml`'s palette is
byte-identical to the upstream flavor — otherwise the bespoke apps (which read
`theme.yaml`) and the named apps (which read their bundled copy) drift apart.
Flavor-by-name therefore **forbids per-color tweaks**.

**(B) Use a custom/tuned palette** (a tweaked Mocha, custom accents, or a
non-published scheme). A built-in *name* can't express "my mocha" — "Catppuccin
Mocha" always means upstream's exact values. To make the named apps honor a tweak
you must **generate each app's own theme artifact from `theme.yaml` and point the
app at the generated one**, replacing the built-in name.

This repo is **already in case (B)**: it has custom tab colors, `earthMaroon`,
the tint washes, and (per the chosen decisions) migrated prompt colors + drift
fixes. So the unification must *generate artifacts*, not lean on names. Consumers
split into three tiers:

- **Tier 1 — UI palettes** (bg/fg/16-ANSI/accent). Fully generatable; each has a
  verified custom-load path:
  - **ghostty** → generate `~/.config/ghostty/themes/mocha`
    (`background`/`foreground`/`cursor-color`/`selection-*`/`palette = N=#hex`);
    set `theme = mocha`.
  - **wezterm** → generate `~/.config/wezterm/colors/mocha.toml` (`[colors]`
    `ansi`/`brights`/bg/fg/cursor/selection); set `color_scheme = "mocha"` (or
    feed `config.color_schemes` from `palette.lua`).
  - **bottom** → drop `theme=`; it already supports a full `[styles]` hex block —
    complete it from `theme.yaml`.
  - **nvim** → a `chezmoi-system` colorscheme (`nvim/colors/chezmoi-system.lua`)
    that **vendors catppuccin/nvim's group definitions** (MIT, under
    `nvim/lua/chezmoi_theme/ctp/`: `groups/{editor,syntax,treesitter,lsp,
    semantic_tokens}` + the integrations for the plugins this config uses) and
    invokes them with OUR palette injected as the `C`/`O`/`U` globals — exactly
    how catppuccin's own compiler calls them. Result: catppuccin's full coverage
    (~937 highlight groups) with NO catppuccin runtime dependency (the plugin is
    `enabled = false`), and still theme-agnostic — `C` is built from the active
    palette's 26 slots, so a custom-named `theme.yaml` drives nvim too. Two
    vendored files were minimally patched to drop their `require("catppuccin"…)`
    (see inline notes). (Earlier passes used catppuccin `color_overrides`, then a
    hand-rolled scheme; both were replaced — the first pinned to the plugin, the
    second under-covered plugins.)
  - **yazi UI** → drop the flavor dep; UI colors in a generated `theme.toml`
    (user `theme.toml` overrides flavors, so the generated one wins).
  - zellij dialog theme, pi, glow, fzf, the viewers, pick — already custom files
    (§4.5).
- **Tier 2 — syntax-highlighting themes** (TextMate `.tmTheme`: maps *language
  scopes* → colors, not just 26 names): **bat**, **yazi code preview** (syntect),
  and **delta**'s `syntax` coloring (it borrows bat's theme). A faithful
  `.tmTheme` is a real artifact, not a 26-line projection. Pick one:
  1. **Generate** a `.tmTheme` from `theme.yaml` via a template — Catppuccin's
     **Whiskers** tool exists for exactly this.
  2. **Vendor** the official Catppuccin `.tmTheme` and regenerate/swap it on
     `theme.flavor` change (loses per-color tweaks in *code* highlighting only).
  3. **Accept upstream-by-name** for syntax highlighting only (bat keeps
     `--theme="Catppuccin Mocha"`); every other surface still follows
     `theme.yaml`. Per-token tweaks rarely matter inside a code block.
  bat also needs `bat cache --build` after the theme changes (§5).

Add a `theme.flavor` key regardless: it's the selector for (A), the chooser for a
Tier-2 vendored tmTheme, and it documents intent.

**Existing engines (alternative to hand-rolling):** Catppuccin **Whiskers** (one
source palette + `.tera` templates → ports) and base16 / tinted-theming
**`flavours`** both implement "one scheme → many app themes." They cover popular
apps but **not** the bespoke ones here (zellij dialog, pi, the Python viewers,
`pick.jq`), so they'd sit *under* the `theme.yaml` + `palette.*` approach, not
replace it. Recommendation: hand-rolled chezmoi templates for uniformity,
optionally Whiskers for the Tier-2 `.tmTheme`.

### 4.5 Consumption matrix (post-unification)

| Consumer | After unification | File action |
|---|---|---|
| `common.zsh` | `source ~/.config/theme/palette.zsh` (drop literal `C_HEX_*`/`C_*`) | edit |
| `theme-common.zsh` | unchanged logic (builds `THEME_*` from `C_*`) | none |
| `themes.sh` (`JQ_COLORS`) | `themes.sh.tmpl`, build SGR string from `.theme.palette` | → `.tmpl` |
| `pick.jq` | picker passes `--argjson palette palette.json`; defs read `$palette` | edit |
| `pick-common.zsh` / `completion.sh` fzf | build `--color`/`FZF_DEFAULT_OPTS` from `C_HEX_*` | edit |
| `_lib.sh`, `p10k.zsh` | reference `C_HEX_*` (migrated to Mocha by §4.2) | edit |
| `dot_zshrc` separator | `%F{$C_HEX_OVERLAY0}` | edit |
| `wezterm.lua` | generate `colors/system.toml` (or `color_schemes` via `palette.lua`); `color_scheme = "system"`; `tab_bar` from `palette.lua` | edit + generate |
| `tint-palette.toml` | generated from `.theme.extended.tints` | → `.tmpl` |
| `ghostty/config` | generate `themes/system` (`palette = N=#hex` + bg/fg/cursor/selection) from `.theme`; `theme = system` | edit + generate |
| `zellij/config.kdl.tmpl` | `theme "system"` → the generated dialog theme below | edit |
| `zellij/themes/system.kdl` | `.kdl.tmpl`; the `system` theme, `R G B` from `.theme.palette` (split hex); renamed from `catppuccin-mocha-dialog.kdl` | → `.tmpl` (rename) |
| `zellij/layouts/default.kdl.tmpl` | replace 82 literals with `.theme` lookups (migrate One-Dark ones) | edit |
| `bottom/bottom.toml` | `.tmpl`; **drop `theme=`**, define every `[styles.*]` from `.theme.palette` | → `.tmpl` |
| `glow/catppuccin-mocha.json` | `.tmpl` from `.theme.palette` | → `.tmpl` |
| `tealdeer/config.toml.tmpl` | already `.tmpl`; RGB from `.theme.palette` | edit |
| `git/config.tmpl` `[delta]` | already `.tmpl`; diff hexes from `.theme.extended.diff` | edit |
| `dot_pi/.../catppuccin-mocha.json` | `.tmpl` `vars` block from `.theme.palette` (**fixes drift**); keep role map | → `.tmpl` |
| `libexec/{ics,sqlite,disk-image}-view` | read `~/.config/theme/palette.json` at startup; delete the 3 `CTP` classes | edit ×3 |
| `yazi/init.lua` mactag | read `palette.lua` `.extended.tags` | edit |
| `nvim` core.lua + `colors/chezmoi-system.lua` + `lua/chezmoi_theme/ctp/` | `chezmoi-system` colorscheme: vendored catppuccin group defs (MIT) fed our `palette.lua` via injected `C`/`O`/`U`; `catppuccin/nvim` disabled; `colorscheme = "chezmoi-system"` | edit + vendor |
| `nvim` lualine `doom-modeline.lua` | migrate One-Dark fallbacks to Mocha (or read `palette.lua`) | edit |
| `yazi` flavor | **drop the flavor dep**; UI colors in generated `theme.toml`. Code preview → Tier 2 | edit |
| `bat` · delta `syntax` · yazi code-preview | **Tier 2** (`.tmTheme`): generate/vendor a `.tmTheme` + `bat cache --build` — see §4.4 | generate/vendor |
| `ai-playbook input` | `--theme-*` flags via `theme::args`/`AI_THEME_ARGS` | ✅ already wired |
| `ai-playbook ui` (pager) | needs `--theme-*` flags first (§4.7), then pass from `ai-assist-render` | upstream fix |
| `zj-hud` | mode/tab/which-key chrome = config keys (§4.7, done); **bar background follows the live `Style`** (§4.8) so the runtime override reaches it | upstream fix + edit |
| `zj-prompt-jumper`, `zj-context-keys` | no color output | none |

### 4.6 Special case: Blink Shell

`assets/blink-shell/catppuccin-mocha-custom.js` lives **outside** the chezmoi
source root (`home/`), served by `assets/blink-shell/serve-blink-assets.sh`, so
it can't read chezmoi data at apply time. Options: (a) keep it a manual mirror
with a comment pointing at `theme.yaml`; (b) have the serve script render it from
`theme.yaml` via `chezmoi execute-template`. Recommend (b) if Blink is in active
use, else (a).

---

### 4.7 Custom binaries: color-config readiness (prerequisite gaps)

Four binaries in this config are ours. The unification can only drive their
colors if they accept color *config*; where they hardcode, that must be fixed in
the binary **first** — a prerequisite, and an upstream commit in the binary's own
repo, not part of the chezmoi work. Audit result:

| Binary | Color surface | Status | Gap to close first |
|---|---|---|---|
| **ai-playbook** `input` | dialog/form widget | ✅ **Ready** — 15 `--theme-*` flags (`input/theme.go`), already driven by `theme::args`/`AI_THEME_ARGS` | — |
| **ai-playbook** `ui` (pager) | ai-assist output, markdown, code (chroma) | ❌ **Hardcoded** — ~30 consts in `ui/theme.go` + a baked chroma style; no flags; `AI_THEME_ARGS` is wired only into the `input` shims | Add `--theme-*` flags (mirror `input/theme.go`) or a shared `--theme-file` both subcommands read; pass them from `ai-assist-render`. (Also fixes a drift: `colSubtext = "#9399b2"` is mislabeled — that's overlay2.) |
| **zj-hud** | status bar + tabs + which-key | ✅ **Fixed (committed, unreleased)** — chrome configurable + bar bg follows `Style`; defaults unchanged; fmt clean, 302 tests, wasm builds; verified live on the dev-shell | Now accepts `tabs { bg fg active_bg active_fg }`, top-level `bar_bg` + `hint_glyph_on`, and `which_key { key label switch border footer }` (`dim` still tracks the live `Style`). **Bar background now follows the live `Style`** (§4.8); `bar_bg` is an optional hard override (`Option<Color>`). Remaining: release the plugin; wire accents from the templated layout. |
| **zj-prompt-jumper** | none (only *strips* ANSI to find prompts) | ✅ **N/A** | — |
| **zj-context-keys** | none (headless key/command router) | ✅ **N/A** | — |

**zj-hud is done** (config keys implemented locally + tested; pending commit /
release + layout wiring). The one **remaining** prerequisite is ai-playbook's
`ui` renderer (requested in that repo). Until it lands, the pager keeps its
current hardcoded Mocha values (consistent today, but it would not follow a
`theme.yaml` tweak). The other two binaries need nothing.

> Sources are local and **outside** this chezmoi repo:
> `~/Projects/langs/go/ai-playbook` and
> `~/Projects/apps/zellij/{zj-hud,zj-prompt-jumper,zj-context-keys}`. The fixes
> are commits there; the chezmoi side only *passes* the colors once the binaries
> accept them. The ai-playbook ask is written up in that repo at
> `THEME-UI-REQUEST.md` (handed to its own agent team); the zj-hud fix is being
> implemented by a dispatched agent.

### 4.8 Runtime override layer (per-machine, host-pushed)

A separate need surfaced from the WezTerm SSH **tint** work: tinting only
recolors the terminal's *background* (the color shown where nothing paints —
i.e. `NO_COLOR`/default bg). TUIs that **paint** their own background (fzf
pickers, the zj-hud status bar, dialogs) keep the un-tinted base and sit as
un-tinted islands on a tinted terminal. The fix is a **runtime override**: a file
that says "for this session, use these colors instead," so painted backgrounds
match the session's tint.

This cannot be baked at `chezmoi apply` time — a file dropped later must take
effect without re-applying. So the palette becomes two layers resolved at
**session start**: `effective = canonical (theme.yaml) ⊕ override (loose file)`.

**Override file (loose, never in chezmoi):** `~/.config/theme/override.toml`,
flat `token = "#hex"` (mirrors `tint-palette.toml`); any token, `base` the common
one:

```toml
base = "#1c232f"   # this session's tint; any token may be overridden
```

**Host-owned, target-keyed, pushed on connect.** The file is authored on the
**host**, not the remote, and `rsync`'d to the remote on connection via
`sync-remote-assets` (`private_dot_ssh/config.example`: a single `Match host …
exec` pre-connect hook with a `_SYNCREMOTE` sentinel + `; false`) — the same
entry point that mirrors the glyph DB. Its `theme` step looks up the target's
tint in the host's color map (the same `lib/terminal-location.zsh` /
`tint-palette.toml` source WezTerm uses) and rsyncs a generated `override.toml`
to `<target>:~/.config/theme/`. Consequence (as intended): a remote's colors
reflect **the host you connected from** — two hosts with different color maps
push different overrides to the same box.

**Resolver `theme-apply`** runs early in shell init, *before* the Zellij attach
(and is re-runnable on demand). It merges canonical ⊕ override and emits the
**effective** outputs:
- the runtime palette projections (`palette.zsh/json/lua`), or each `palette.*`
  overlays the override inline at load;
- the effective Zellij theme `~/.config/zellij/themes/system.kdl` (Zellij can't
  merge, so the file is rewritten with the effective backgrounds).

**Who honors it (and how):**
- **Free** — fzf, zsh dialogs, ai-playbook, pickers, viewers: built from the
  runtime palette, so an overridden `base` flows through automatically (e.g. fzf
  `--color=bg:` = `C_HEX_BASE`).
- **zj-hud** — its **background follows the live Zellij `Style`**
  (`text_unselected.background`), not static layout KDL. The resolver writes the
  effective theme; Zellij hands it to the plugin as `Style`; the bar paints the
  effective background. (This is the §4.7 redirect; accent/tab/which-key keys
  stay canonical config.)
- **Not needed** — WezTerm/Ghostty: they are the local *source* of the tint.
- **Optional** — bottom/glow/bat read their own static config; covering them
  means the resolver also regenerates those files (heavier; defer).

**Timing:** session start (next attach picks it up). Live mid-session (drop file
→ recolor a running session) is a later extension: re-run `theme-apply` + a
Zellij theme reload so the plugin re-reads `Style`.

This reuses three existing pieces — the `tint-palette.toml` color source, the
`Match exec` + `rsync` + sentinel transport, and the per-machine color map — so
it adds a `theme-apply` resolver and a `sync-remote-assets` theme step, not a
new paradigm.

## 5. Sharp edges / risks

1. **Tests vs templating.** `tests/common_palette_spec.sh` and
   `theme-common_spec.sh` do `Include home/dot_local/lib/common.zsh` and assert
   `$C_HEX_MAUVE` etc. If `common.zsh` starts sourcing
   `~/.config/theme/palette.zsh` (an *applied* artifact), the spec must provide
   it. Resolution: a spec helper renders `theme.yaml` → palette via
   `chezmoi execute-template` into a temp file and sources it; the existing
   value assertions then become the **drift guardrail** for the whole repo. Keep
   `common.zsh` itself non-templated so it stays editable without `{{ }}`.
2. **KDL needs decimal RGB**, not hex — the dialog-theme template must split each
   hex into `R G B`. Store nothing extra; split in-template (`printf`/`mod`),
   or add a `palette_rgb` mirror in `theme.yaml` if the template math is ugly.
3. **Sourcing order in zsh.** `palette.zsh` must be sourced before `p10k.zsh`,
   `_lib.sh`, and `completion.sh` reference `C_HEX_*`. `common.zsh` is already
   the early bottom-of-stack include, so route palette through it.
4. **p10k is compiled** (`run_onchange_after_22-compile-p10k`). Referencing
   `$C_HEX_*` vars in `p10k.zsh` is fine (runtime expansion), but confirm the
   compile step re-fires after the edit.
5. **Migration is a visual change.** The prompt/statusline will look different
   (truer Mocha, less pastel). That's the intent — call it out so it's not a
   surprise on first `chezmoi apply`.
6. **Don't over-templatize hot files.** `p10k.zsh`/`common.zsh` are large and
   user-tuned; prefer "reference a sourced var" over converting the whole file
   to `.tmpl`.
7. **Tier-2 syntax themes need a rebuild step.** `bat` caches compiled themes;
   after the `.tmTheme` changes, `bat cache --build` must run — wire a
   `run_onchange` keyed on the tmTheme hash, alongside the existing numbered
   hooks. yazi's code preview and `delta`'s `syntax` coloring ride the same
   `.tmTheme`. This is the cost that makes Tier 2 heavier than Tier 1.

---

## 6. Phasing

> **Status: complete.** The switchable role-based schema is implemented end to
> end and proven: flipping `theme.active` to `catppuccin-latte` re-renders every
> generated surface to the light palette (verified via `chezmoi cat`), and
> `meta.appearance` is exported so nvim flips light/dark too. A custom-named
> palette (`NorthernLights`) was verified to drive nvim's `chezmoi-system`
> colorscheme with zero Catppuccin dependency. `make test` (185 examples) and
> `make lint` (no raw hex outside `theme.yaml`) are green.
>
> Delivered across the waves below: the role-based `theme.yaml` (active +
> palettes + roles); the `palette.{zsh,json,lua}` bridges emitting roles; every
> generated app theme (ghostty/wezterm/bottom/glow/pi/tealdeer + the zellij base
> theme + bar modes/which-key + delta diff + JQ_COLORS + tints); the Tier-2
> `.tmTheme` for bat (+ `bat cache --build`), yazi (UI `theme.toml` + syntect
> preview, flavor dropped), and delta `syntax-theme = system`; nvim via a
> `chezmoi-system` colorscheme that vendors catppuccin's group definitions (MIT)
> and feeds them our palette (~937 groups, catppuccin plugin disabled,
> theme-agnostic); the non-Mocha
> prompt/statusline migration; the runtime override layer (`theme-apply` +
> `sync-remote-assets`'s theme step); a second (`catppuccin-latte`) palette;
> and the lint.

1. **Prerequisite — close custom-binary color gaps (§4.7).** zj-hud config keys
   **+ bar-bg-follows-`Style`** + configurable which-key bg — **done, released
   v0.1.3** (302 tests; chezmoi manifest bumped). ai-playbook `ui`
   `--theme-*`/`--theme-file` — **requested** in that repo. The other two
   binaries need nothing.
2. **Foundation** — **done.** `theme.yaml` (palette + semantic + extended) +
   generated `~/.config/theme/palette.zsh`; `common.zsh` sources it (path
   overridable via `THEME_PALETTE_FILE`); the spec helper renders it
   hermetically; `make test` green (185 examples, 0 failures). `theme-common.zsh`
   already composes from `common.zsh`, so it needed no change. (`theme.flavor`
   deferred to the flavor-switch work.)
3. **Foreign-format bridges + worst offenders.** Add `palette.lua`,
   `palette.json`; retarget the 3 Python viewers, `pick.jq`, the pi theme
   (fixes drift), `glow`.
4. **Templatize already-renderable configs.** `tint-palette`, zellij theme +
   layout, `delta`, `tealdeer`.
5. **Replace named themes with the generated `system` theme (Tier 1, §4.4).**
   ghostty `themes/system`; wezterm `colors/system.toml`; `bottom` full `[styles]`
   (drop `theme=`); nvim `chezmoi-system` colorscheme (catppuccin disabled); yazi
   `theme.toml` (drop flavor dep).
   Then choose the Tier-2 `.tmTheme` strategy (bat/yazi-preview/delta) + wire
   `bat cache --build`.
6. **Migrate the non-Mocha surfaces (§4.2).** `p10k.zsh`, `_lib.sh`, lualine
   fallbacks, `completion.sh` warnings, `dot_zshrc`, the One-Dark colors in the
   zellij bar.
7. **Runtime override layer (§4.8) — done.** `theme-apply` resolver (effective
   palette + effective `system.kdl`: block renamed to `system`, each overridden
   token's RGB substituted, stamped staleness check) running before the Zellij
   attach; loose `override.toml`; `sync-remote-assets`'s theme step (host-side,
   reusing `terminal-location.zsh` + `tint-palette.toml`) + the ssh
   `Match host … exec` hook documented in `config.example`; zj-hud
   bg-from-`Style` (from step 1).
8. **Cleanup.** Blink decision (§4.6); add a lint (§7); document the new silo.

Each phase is independently shippable and leaves the repo working.

---

## 7. Guardrail: "no raw hex outside the source" — implemented

`tests/lint-theme.sh` (run by `make lint`, and by `make test` before the suite)
greps `home/` for `#[0-9a-fA-F]{6}` and fails if any appear outside an allowlist.
`theme.yaml` stores hex WITHOUT a leading `#`, so it never matches. The allowlist
exempts only: decorative/non-theme assets (`**/Assets/**`, `*.svg`, `*.css`,
`**/hammerspoon/**`, the `notify` swatch); runtime FALLBACKS that load a palette
bridge and fall back to literals only if it is missing (nvim `**/lualine/**`, the
3 Python viewers, `wezterm.lua`, `yazi/init.lua`); and a few comment/example
mentions (`theme-apply`, `ghostty/config`, `lib/zellij.zsh`, `ai-commit`).
Adding a file to the allowlist requires a real reason — never to
hide a color that belongs in `theme.yaml`. This makes drift structurally hard.

---

## 8. Silo-map entry (new owner)

Theming currently has **no owner** in `docs/chezmoi-silo-map.md`. Add a `theme`
silo:

- **Owner area:** `home/.chezmoidata/theme.yaml`, `home/dot_config/theme/palette.*.tmpl`.
- **Public contract:** the `theme.palette` / `theme.semantic` / `theme.extended`
  keys, and the emitted symbols per bridge (`C_HEX_*`, `C_*`, `THEME_*` in
  `palette.zsh`; the `palette.lua` table shape; the `palette.json` schema).
- **Consumed by:** terminal-mux, shell, pick, preview, neovim, pi, yazi, system
  (delta/tint), ai-harnesses (`theme::args`).
- **Coordination:** like `common.zsh`, it's a read-mostly cross-silo dependency
  — a schema change ripples; additive changes are safe.
- **Concurrency:** `⚠` with any silo that hardcodes color today (until that
  silo is migrated to read a bridge).

---

## 9. Future (not in scope now)

- **Multi-flavor**: the same `theme.yaml` shape supports Latte/Frappé/Macchiato
  by swapping `palette` — gate by `chezmoi` profile or a `theme.flavor` key.
- **Light/dark auto**: pair with terminals' `theme_light`/`theme_dark`.
- **Per-profile accents**: e.g. a different `semantic.accent` on work vs personal.
