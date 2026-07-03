# Completion system + fzf integration. Sourced (deferred) from ~/.config/zsh/.zshrc on the
# first precmd, so the compinit cost stays off the path to the first prompt.
#
# This file owns what zsh4humans used to set implicitly: fpath for the cloned
# completions, compinit (with a compiled, cached dump), completion zstyles,
# and the fzf shell integration wired to the `preview` script.

plugin_dir="${XDG_DATA_HOME:-$HOME/.local/share}/zsh/plugins"

# Completion search path — set BEFORE compinit so the dump picks these up.
fpath=(
  "$plugin_dir/zsh-completions/src"
  "$plugin_dir/zsh-abbr/completions"
  "$HOME/.local/share/zsh/site-functions"
  $fpath
)

# ── compinit (cached + compiled) ───────────────────────────────────────────
autoload -Uz compinit
ZSH_COMPDUMP="${XDG_CACHE_HOME:-$HOME/.cache}/zsh/zcompdump-${ZSH_VERSION}"
[[ -d "${ZSH_COMPDUMP:h}" ]] || mkdir -p "${ZSH_COMPDUMP:h}"
# Skip the insecure-directory audit (-C) when the dump was refreshed in the
# last 24h; do the full check (which can rebuild the dump) otherwise.
if [[ -n ${ZSH_COMPDUMP}(#qNmh-24) ]]; then
  compinit -C -d "$ZSH_COMPDUMP"
else
  compinit -d "$ZSH_COMPDUMP"
fi
# Compile the dump to wordcode for faster loads next time.
if [[ -s "$ZSH_COMPDUMP" && ( ! -s "$ZSH_COMPDUMP.zwc" || "$ZSH_COMPDUMP" -nt "$ZSH_COMPDUMP.zwc" ) ]]; then
  zcompile -R -- "$ZSH_COMPDUMP" 2>/dev/null
fi

# Replay compdef calls queued by the synchronous-load shim in ~/.config/zsh/.zshrc
# (the real `compdef` is defined by compinit, which only just ran).
if (( ${+_pending_compdefs} )); then
  local _c
  for _c in "${_pending_compdefs[@]}"; do compdef ${=_c}; done
  unset _pending_compdefs
fi

# ── Completion styles ──────────────────────────────────────────────────────
# `menu no`, not `menu select`: fzf-tab (below) replaces the selection menu, and
# its docs require the native menu be off so it can intercept completion.
zstyle ':completion:*' menu no
# Case-insensitive, then partial-word, then substring matching.
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}' 'r:|=*' 'l:|=* r:|=*'
zstyle ':completion:*' list-colors ${(s.:.)LS_COLORS}
zstyle ':completion:*' group-name ''
# No color escapes here: fzf-tab uses this description as the group-header text
# and prints %F{}/%f literally (README: "don't use escape sequences … fzf-tab
# will ignore them"). It colors group headers itself via `group-colors` below.
zstyle ':completion:*:descriptions' format '-- %d --'
zstyle ':completion:*:warnings' format "%F{$C_ROLE_STATE_ERROR}-- no matches --%f"
zstyle ':completion:*' completer _complete _match _approximate
zstyle ':completion:*' use-cache on
zstyle ':completion:*' cache-path "${XDG_CACHE_HOME:-$HOME/.cache}/zsh/zcompcache"
zstyle ':completion:*' verbose yes
# Never offer the current directory when completing `cd` — i.e. no pointless
# `cd ../<this-dir>`. `pwd` drops the cwd from path completion. `cd` is aliased
# to the `super-cd` function, so that — not `cd` — is the completion command.
zstyle ':completion:*:super-cd:*' ignore-parents pwd

# ── fzf ────────────────────────────────────────────────────────────────────
export FZF_DEFAULT_COMMAND="fd --type f"

# Catppuccin Mocha palette + layout + previews + key bindings. fzf parses this
# value with its own quote/newline-aware tokenizer, so single-quoted tokens
# (the ones containing spaces) are preserved as single arguments.
# fzf colors come from the single-source palette (generated from theme.yaml).
source "${THEME_PALETTE_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/theme/chezmoi-system.zsh}"
export FZF_DEFAULT_OPTS="
--color=bg:${C_ROLE_UI_BG} --color=bg+:${C_ROLE_UI_SURFACE}
--color=fg:${C_ROLE_UI_FG} --color=fg+:regular:${C_ROLE_UI_FG}
--color=hl:${C_ROLE_STATE_ERROR} --color=hl+:regular:${C_ROLE_STATE_ERROR}
--color=prompt:${C_ROLE_UI_ACCENT} --color=pointer:${C_ROLE_UI_CURSOR} --color=marker:${C_HEX_LAVENDER}
--color=info:${C_ROLE_UI_ACCENT} --color=gutter:${C_ROLE_UI_BG} --color=header:${C_ROLE_STATE_ERROR}
--color=spinner:${C_ROLE_UI_CURSOR} --color=border:${C_ROLE_UI_BORDER}
--filepath-word --border --height=~40% --layout=reverse --info=inline-right
--exit-0 --select-1 --padding=0,2,0,0
--prompt '    ' --pointer ➔ --marker ✔
--preview-window=right:60%,border-line,noinfo
--preview 'preview {}'
--bind ctrl-space:toggle-preview
--bind ctrl-j:down --bind ctrl-k:up
--bind shift-up:preview-up --bind shift-down:preview-down
--bind alt-up:preview-page-up --bind alt-down:preview-page-down
--bind alt-page-up:preview-page-up --bind alt-page-down:preview-page-down
--bind alt-home:preview-top --bind alt-end:preview-bottom
--bind 'ctrl-f:change-preview(FZF_PREVIEW_FULL=1 preview {})'
--bind 'ctrl-alt-f:change-preview(preview {})'
"

# fzf shell integration: completion (the `**<TAB>` fuzzy trigger) + key
# bindings (Ctrl+T paste files, Alt+C cd). `command` bypasses any `fzf` alias.
if command -v fzf >/dev/null; then
  source <(command fzf --zsh)
fi

# Generators for the `**` fuzzy trigger — use fd (respects .gitignore).
_fzf_compgen_path() { fd --hidden --follow --exclude .git . "$1" }
_fzf_compgen_dir()  { fd --type d --hidden --follow --exclude .git . "$1" }

# ── fzf-tab ────────────────────────────────────────────────────────────────
# Restores zsh4humans' headline feature: TAB opens an fzf menu of completions
# instead of zsh's native menu. Sourced AFTER compinit and AFTER `fzf --zsh`
# (so fzf-tab wins the TAB binding — which also retires fzf's `**` trigger) and
# BEFORE the deferred zsh-autosuggestions / zsh-syntax-highlighting (which wrap
# ZLE widgets). CTRL-T / CTRL-R / ALT-C stay on their own keys, untouched.
if [[ -r "$plugin_dir/fzf-tab/fzf-tab.plugin.zsh" ]]; then
  source "$plugin_dir/fzf-tab/fzf-tab.plugin.zsh"

  # The menu inherits all of its chrome — rounded border, the search-glyph
  # prompt, inline-right count, always-visible preview — from FZF_DEFAULT_OPTS,
  # so every fzf surface matches. `use-fzf-default-opts` is what pulls that in.
  zstyle ':fzf-tab:*' use-fzf-default-opts yes

  # Color the group-header row. fzf-tab draws these itself (it ignores %F{} in
  # the descriptions format — see the format zstyle above), defaulting to a
  # fixed rainbow of ANSI + 256-colors that ignores our palette. Pin every group
  # to the theme's warning accent instead, converted from the palette hex to a
  # truecolor escape, so headers keep the single amber the native format had.
  # group-colors indexes per group, so seed enough copies to cover any menu.
  local _wh=${C_ROLE_STATE_WARNING#\#}
  local _hdr=$'\x1b['"38;2;$((16#${_wh[1,2]}));$((16#${_wh[3,4]}));$((16#${_wh[5,6]}))m"
  local -a _hdrs=(); local _i
  for _i in {1..24}; do _hdrs+=$_hdr; done
  zstyle ':fzf-tab:*' group-colors $_hdrs
  unset _wh _hdr _hdrs _i

  # Drop fzf-tab's "·" bullet prefix — the rich renderer prepends a type glyph
  # in its place (see fzf-tab-rich.zsh, wired below).
  zstyle ':fzf-tab:*' prefix ''

  # Hide the textual group-header legend (e.g. "-- external command --  -- shell
  # function --"): the per-row type glyph now conveys the group. Use `quiet`, NOT
  # `none` — `none` rewrites _ftb_groups entries to "__hide__N" before our render
  # runs, which would starve ftb_rich::classify of the real group names and make
  # every non-file candidate fall back to the generic glyph. `quiet` suppresses
  # the header row while keeping _ftb_groups intact for the classifier.
  zstyle ':fzf-tab:*' show-group quiet

  # Rich candidates: prepend a colored, per-type glyph to each fzf-tab row.
  # Lives only in fzf-tab's render path, so the native zsh menu is unaffected.
  # fzf-tab lazily autoloads its lib funcs, so force -ftb-generate-complist's
  # real body in before capturing it (a bare capture would grab the stub).
  if [[ -r "$HOME/.local/lib/fzf-tab-rich.zsh" ]]; then
    source "$HOME/.local/lib/fzf-tab-rich.zsh"
    # Wrap once. `autoload +X` does NOT overwrite an already-defined function,
    # so on a re-source the capture below would grab the wrapper itself as
    # -orig and the wrapper would recurse into itself (FUNCNEST crash). Guard
    # on -orig not yet existing so a re-source is a no-op.
    if (( ! ${+functions[-ftb-generate-complist-orig]} )); then
      autoload +X -Uz -- -ftb-generate-complist
      functions[-ftb-generate-complist-orig]=$functions[-ftb-generate-complist]
      -ftb-generate-complist() {
        -ftb-generate-complist-orig
        (( ${FZF_TAB_RICH:-1} )) || return
        ftb_rich::render
      }
    fi
  fi

  # fzf-flags is appended LAST on fzf-tab's own fzf command line (after its
  # internally computed --height), so it's where we override two things:
  #
  #   --height=~40%  fzf-tab sizes the menu as `#candidates + fzf-pad(2) +
  #                  headers` rows, budgeting only ~2 rows of chrome. But
  #                  use-fzf-default-opts pulls in `--border`, which costs 2
  #                  *more* rows (top+bottom) the formula never accounts for —
  #                  so small menus get clipped (e.g. 5 items shown as 3). The
  #                  README flags this exact `--border` breakage (Aloxaf/
  #                  fzf-tab#455). `~40%` hands sizing back to fzf: it shrinks
  #                  to fit the content (chrome included) and grows only up to
  #                  40% of the pane — matching the other fzf surfaces.
  #   ctrl-space     fzf-tab's defaults (-ftb-fzf) rebind it to multi-select
  #                  *after* FZF_DEFAULT_OPTS; reclaim it for preview-toggle.
  #   preview-window fzf merges repeated --preview-window flags, and fzf-flags is
  #                  appended last, so `hidden` starts the completion preview
  #                  collapsed while keeping the inherited right:60% geometry.
  #                  ctrl-space reveals it on demand. Scoped to the TAB menu only
  #                  — Ctrl-T/Ctrl-R/Alt-C keep their preview on by default.
  zstyle ':fzf-tab:*' fzf-flags --height=~40% --preview-window=hidden --bind=ctrl-space:toggle-preview

  # TAB descends into the highlighted directory and re-opens the menu — the
  # equivalent of z4h's `tab:repeat` (fzf-tab's continuous-trigger, default '/').
  # See the `_fzf-tab-apply` override below, which makes this descend-only: on a
  # file or empty dir, TAB finishes instead of re-completing the next argument.
  zstyle ':fzf-tab:*' continuous-trigger 'tab'

  # Preview only when the candidate resolves to a real path (directories for
  # `cd`, files for file arguments). Non-path completions — git refs, options,
  # PIDs — resolve to nothing and get no preview, per the "cd/files only" scope.
  zstyle ':fzf-tab:complete:*:*' fzf-preview \
    '[[ -d $realpath || -f $realpath ]] && preview $realpath'

  # CTRL-O: pop the highlighted file into a full-size floating Zellij pane for a
  # larger image view — an escape hatch from cramped inline previews.
  # fzf-tab's raw fzf row keeps the display key in field 2. The helper resolves
  # it through fzf-tab's live compcap file to recover the real path, then opens
  # images with the existing zellij-preview-image wrapper (renders at pane size,
  # waits for a key) and --close-on-exit reaps the pane. `execute-silent` keeps
  # the menu open and never tears fzf down, so there's no Sixel-teardown to fight.
  zstyle ':fzf-tab:*' fzf-bindings \
    'ctrl-o:execute-silent($HOME/.local/bin/fzf-tab-preview-open --fzf-tab-desc {2})'

  # Make the `tab` continuous-trigger descend-only (z4h `tab:repeat` semantics).
  # Out of the box, continuous-trigger means "accept then re-complete" with no
  # file/dir distinction: accepting a *file* finishes its word, so zsh advances
  # to the next argument and the menu stays open (e.g. `mv ~/Downloads/<file>`
  # would jump to completing the destination). We want TAB to descend into a
  # real directory but *finish* on a file or empty dir.
  #
  # fzf-tab sets `_ftb_continue` whenever the trigger is pressed; the loop in
  # `fzf-tab-complete` honors it after `_fzf-tab-apply` inserts the choice. Wrap
  # apply to cancel that pending continue unless the accepted candidate is a
  # real directory. `realdir`+`word` is how fzf-tab itself derives `$realpath`
  # for previews (see lib/-ftb-preview.tpl); non-path completions (git refs,
  # options, PIDs) have no `realdir`, so they finish too.
  functions[-ftb-apply-orig]=$functions[_fzf-tab-apply]
  _fzf-tab-apply() {
    -ftb-apply-orig "$@"
    local r=$?
    if (( _ftb_continue )) && (( $#_ftb_choices == 1 )); then
      local bs=$'\2' choice=$_ftb_choices[1]
      local match=${_ftb_compcap[(r)${(b)choice}$bs*]}
      [[ -z $match ]] && match=${_ftb_compcap[(r)${(b)${(q)choice}}$bs*]}
      local -A v=("${(@0)${match#*$bs}}")
      [[ -n ${v[realdir]-} && -d ${v[realdir]}${(Q)v[word]} ]] || _ftb_continue=0
    fi
    return r
  }

fi

unset plugin_dir
