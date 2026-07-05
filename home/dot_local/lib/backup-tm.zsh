# backup-tm.zsh — tm scrub sessions (spec 2026-07-04): file-based session
# state driving a timeline pane + a lens pane (yazi explore / hunk diff)
# over one session-long restic mount. Sourced by system-backup-tm and the
# browse verb; sources backup.zsh itself.

_bkp_tm_self="${(%):-%x}"
source "$(dirname "$_bkp_tm_self")/backup.zsh"
unset _bkp_tm_self

: ${BKP_TM_SESSIONS:="${BKP_STATE_DIR:-$HOME/.local/state/terminal-backup}/sessions"}

# bkp::tm::session_new <lens> <anchor>
# Create session state (metadata only, instant); prints the session dir.
# The ladder is filled by the timeline pane (bkp::tm::ladder_fill) so the
# invoking prompt never freezes on the restic call.
bkp::tm::session_new() {
  local lens="$1" anchor="$2"
  local s
  mkdir -p "$BKP_TM_SESSIONS"
  s=$(mktemp -d "$BKP_TM_SESSIONS/s.XXXXXX") || return 1
  print -r -- "$lens" > "$s/lens"
  print -r -- "$anchor" > "$s/anchor"
  print -r -- 1 > "$s/rung"
  print -r -- "$s"
}

# bkp::tm::ladder_fill <session>
# Populate the ladder (<id>\t<epoch>\t<tier>, newest first) — the slow
# restic call, deferred out of session_new. Rows carry the tier label so
# the timeline renders without re-deriving policy per frame.
bkp::tm::ladder_fill() {
  local s="$1" ladder policy line id epoch REPLY now="$EPOCHSECONDS"
  ladder=$(bkp::snap::ladder) || return 2
  [[ -n "$ladder" ]] || { log_error "bkp: no snapshots yet — nothing to scrub"; return 2 }
  policy=$(bkp::manifest::thin_policy "$BKP_MANIFEST") || return 2
  {
    for line in ${(f)ladder}; do
      id="${line%%$'\t'*}" epoch="${line##*$'\t'}"
      bkp::thin::tier_of "$now" "$epoch" "$policy" || :
      print -r -- "$id"$'\t'"$epoch"$'\t'"$REPLY"
    done
  } > "$s/ladder"
}

# bkp::tm::rung_line <session> — REPLY = current ladder line (id\tepoch\ttier).
bkp::tm::rung_line() {
  local s="$1" n
  n=$(<"$s/rung")
  local -a lines=("${(@f)$(<"$s/ladder")}")
  (( n >= 1 && n <= ${#lines} )) || return 1
  REPLY="${lines[n]}"
}

# bkp::tm::rung_id <session> — REPLY = full id of the current rung.
bkp::tm::rung_id() {
  bkp::tm::rung_line "$1" || return 1
  REPLY="${REPLY%%$'\t'*}"
}

# bkp::tm::rung_path <session>
# REPLY = mount path of the current rung (restic mount's default ids/
# layout uses SHORT ids).
bkp::tm::rung_path() {
  local s="$1"
  bkp::tm::rung_id "$s" || return 1
  REPLY="$s/mnt/ids/${REPLY[1,8]}"
}

# bkp::tm::rung_root <session>
# REPLY = a root that materializes the current rung at <root><anchor>:
# the live restic mount when present, else a per-rung restore cache
# (FUSE-less diff sessions; cleaned with the session dir).
bkp::tm::rung_root() {
  local s="$1"
  bkp::tm::rung_path "$s" || return 1
  [[ -d "$REPLY" ]] && return 0
  # Two statements, not one: a single `local a=X b=$a` expands both RHSes
  # against the pre-statement environment, so `cache` would never see the
  # `short` this same line just computed.
  local short="${REPLY:t}"
  local cache="$s/rungs/$short"
  if [[ ! -e "$cache/.done" ]]; then
    local staging anchor snap
    staging=$(bkp::config::staging_path) || return 2
    anchor=$(<"$s/anchor")
    bkp::tm::rung_id "$s" || return 1
    snap="$REPLY"
    mkdir -p "$cache"
    bkp::restic "$staging" restore "$snap" --target "$cache" --include "$anchor" --quiet || return 1
    touch "$cache/.done"
  fi
  REPLY="$cache"
}

# bkp::tm::refresh <session>
# Point the lens at the current rung: rewrite current.patch (diff lens —
# hunk --watch reloads) or DDS-cd yazi (explore lens; a failed emit flags
# a respawn for the lens loop).
bkp::tm::refresh() {
  local s="$1" lens anchor REPLY
  # A background synthesis may outlive the session (teardown races it) —
  # never write into a dir that is already winding down.
  [[ -e "$s/closed" || ! -d "$s" ]] && return 0
  lens=$(<"$s/lens") anchor=$(<"$s/anchor")
  if [[ "$lens" == diff ]]; then
    # Only the LATEST rung's synthesis matters: every scrub step spawns
    # an orphaned ctl, and a whole-tree synthesis can run for minutes —
    # unsupervised they pile up into a fork storm (the 200-rsync
    # incident). Supersede the previous synthesis, sweep its dead view,
    # and record ourselves so the teardown can reap us too.
    local prev=""
    [[ -f "$s/refresh.pid" ]] && prev=$(<"$s/refresh.pid")
    if [[ -n "$prev" && "$prev" != "$$" ]]; then
      pkill -P "$prev" 2>/dev/null
      kill "$prev" 2>/dev/null
    fi
    print -r -- $$ > "$s/refresh.pid"
    rm -rf "$s"/bkp-liveview.*(N) 2>/dev/null
    # The live view lands inside the session dir — rm -rf at teardown
    # sweeps it even when its builder died mid-copy.
    local BKP_LIVEVIEW_DIR="$s"
    # FUSE-less fallback: rung_root restores the scoped subtree to a
    # per-rung cache when the mount isn't there.
    bkp::tm::rung_root "$s" || return 1
    local rung="$REPLY"
    # A failed synthesis must not kill the session: hunk renders an empty
    # patch as a graceful "no files" state and --watch refills it on the
    # next scrub step, so degrade to empty instead of erroring out.
    if ! bkp::changeset::patch_live "$rung" "$anchor" > "$s/current.patch.new"; then
      log_warn "bkp: changeset synthesis failed for this rung — showing an empty changeset"
      : > "$s/current.patch.new"
    fi
    mv "$s/current.patch.new" "$s/current.patch"
    [[ -f "$s/refresh.pid" && "$(<"$s/refresh.pid")" == "$$" ]] && rm -f "$s/refresh.pid"
  else
    # Explore still needs the real mount — yazi navigates it live.
    bkp::tm::rung_path "$s" || return 1
    local rung="$REPLY"
    [[ -f "$s/yazi.id" ]] || return 0   # yazi not up yet
    local yid loc="" cwd="" hovered=""
    yid=$(<"$s/yazi.id")
    # yazi.loc (written by the step bindings) carries the anchor-relative
    # location: "<cwd-rel>\t<hovered-rel>". Re-target the new rung there;
    # when the path no longer exists, walk up to the first parent that
    # does — never above the anchor.
    if [[ -f "$s/yazi.loc" ]]; then
      loc=$(<"$s/yazi.loc")
      cwd="${loc%%$'\t'*}"
      hovered="${loc#*$'\t'}"
      [[ "$hovered" == "$loc" ]] && hovered=""
    fi
    local base="$rung$anchor" target="$rung$anchor$cwd"
    while [[ ! -d "$target" && "$target" != "$base" ]]; do
      target="${target:h}"
    done
    [[ -d "$target" ]] || target="$base"
    local hover_abs="$base$hovered" hover_parent=""
    [[ -n "$hovered" ]] && hover_parent="${hover_abs:h}"
    if [[ -n "$hovered" && -e "$hover_abs" && "$hover_parent" == "$target" ]]; then
      ya emit-to "$yid" reveal "$hover_abs" 2>/dev/null || touch "$s/respawn"
    else
      ya emit-to "$yid" cd "$target" 2>/dev/null || touch "$s/respawn"
    fi
  fi
  return 0
}

# bkp::tm::step <session> older|newer
# Move the rung (Down/J = older, Up/K = newer), clamped; refresh the lens.
bkp::tm::step() {
  local s="$1" dir="$2" n total
  n=$(<"$s/rung")
  total=$(wc -l < "$s/ladder")
  case "$dir" in
    older) (( n < total )) && (( n++ )) ;;
    newer) (( n > 1 )) && (( n-- )) ;;
    *) return 2 ;;
  esac
  print -r -- "$n" > "$s/rung"
  bkp::tm::refresh "$s"
}

# bkp::tm::end <session> — signal every session process to wind down.
bkp::tm::end() { touch "$1/closed" }

# bkp::tm::kill_lens <session>
# End the lens pane's process tree: the wrapper's children first (the
# actual yazi/hunk/bx UI — the subshell execs it, so it is a direct
# child), then the wrapper itself. Safe when nothing is running.
bkp::tm::kill_lens() {
  local s="$1" lpid=""
  [[ -f "$s/lens.pid" ]] && lpid=$(<"$s/lens.pid")
  [[ -n "$lpid" ]] || return 0
  pkill -P "$lpid" 2>/dev/null
  kill "$lpid" 2>/dev/null
  return 0
}

# bkp::tm::_sgr <fg|bg> <#rrggbb>
# Truecolor SGR from a palette hex var — emits nothing when stdout isn't
# being styled (C_RES empty), so captured output stays plain.
bkp::tm::_sgr() {
  [[ -n "$C_RES" ]] || return 0
  local h="${2#\#}" mode=38
  [[ "$1" == bg ]] && mode=48
  printf '\e[%d;2;%d;%d;%dm' "$mode" "$(( 0x${h:0:2} ))" "$(( 0x${h:2:2} ))" "$(( 0x${h:4:2} ))"
}

# bkp::tm::timeline_render <session> <height> [<width>] [<focused 0|1>]
# One timeline frame (spec §5.1, UX-session shape): newest at top, every
# rung a two-line stamp (date over time) behind its ● / ┃ glyphs, one
# leading space throughout. Glyph color says where you are: newer-than-
# current red, current green, older yellow. The current rung's two lines
# get a full-width highlight — active-tab background when the timeline
# pane is focused, inactive-tab background otherwise. Windowed to
# <height> rows centered on the current rung with … rows when clipped.
bkp::tm::timeline_render() {
  local s="$1" height="$2" width="${3:-0}" focused="${4:-1}"
  local -a ladder=("${(@f)$(<"$s/ladder")}")
  local cur n=${#ladder}
  cur=$(<"$s/rung")
  local bg
  if (( focused )); then
    bg=$(bkp::tm::_sgr bg "$C_HEX_TAB_ACTIVE_BG")
  else
    bg=$(bkp::tm::_sgr bg "$C_HEX_TAB_BG")
  fi

  local -a rows=() row_rung=()
  local i epoch gc cc date_s time_s r1 r2 pad vis
  for (( i = 1; i <= n; i++ )); do
    epoch="${${ladder[i]#*$'\t'}%%$'\t'*}"
    strftime -s date_s '%a, %b %e %Y' "$epoch"
    date_s="${date_s//  / }"   # %e space-pads single-digit days
    strftime -s time_s '%I:%M %p' "$epoch"
    time_s="${(L)time_s}"
    if (( i < cur )); then gc="$C_RED"
    elif (( i == cur )); then gc="$C_GRN"
    else gc="$C_YEL"
    fi
    # The time row's bar continues the line toward the next rung; the
    # LAST rung has nothing below it — no dangling bar.
    local tg="┃"
    (( i == n )) && tg=" "
    if (( i == cur )) && [[ -n "$bg" ]]; then
      vis=$(( 3 + ${#date_s} ))
      pad=""
      (( width > vis )) && pad="${(l:$(( width - vis )):: :):-}"
      r1="${bg} ${gc}●${C_RES}${bg} ${date_s}${pad}${C_RES}"
      vis=$(( 3 + ${#time_s} ))
      pad=""
      (( width > vis )) && pad="${(l:$(( width - vis )):: :):-}"
      r2="${bg} ${gc}${tg}${C_RES}${bg} ${time_s}${pad}${C_RES}"
    else
      r1=" ${gc}●${C_RES} ${date_s}"
      r2=" ${gc}${tg}${C_RES} ${C_DIM}${time_s}${C_RES}"
    fi
    rows+=("$r1"); row_rung+=($i)
    rows+=("$r2"); row_rung+=($i)
    if (( i < n )); then
      cc="$C_YEL"
      (( i < cur )) && cc="$C_RED"
      rows+=(" ${cc}┃${C_RES}")
      row_rung+=(0)
    fi
  done

  # Window: locate the current rung's first row, center it.
  local total=${#rows} first=1
  if (( total > height )); then
    local cur_row=1 r
    for (( r = 1; r <= total; r++ )); do
      (( row_rung[r] == cur )) && { cur_row=$r; break }
    done
    first=$(( cur_row - height / 2 ))
    (( first < 1 )) && first=1
    (( first + height - 1 > total )) && first=$(( total - height + 1 ))
  fi
  local last=$(( first + height - 1 ))
  (( last > total )) && last=$total
  local out_row
  for (( out_row = first; out_row <= last; out_row++ )); do
    if (( total > height )) && { (( out_row == first && first > 1 )) ||
                                 (( out_row == last && last < total )) }; then
      print -r -- " ${C_DIM}⋮${C_RES}"
    else
      print -r -- "${rows[out_row]}"
    fi
  done
}

# bkp::tm::yazi_overlay <session>
# YAZI_CONFIG_HOME for explore sessions: the user's config (symlinked)
# plus generated scrub bindings. When the user keymap already defines
# `prepend_keymap = [` under [mgr], the bindings are INJECTED at the head
# of that array — TOML forbids re-defining the key as [[mgr.prepend_keymap]]
# afterwards (yazi refuses to boot on the parse error). Without one, the
# table-array form is appended.
#   K / J           timeline newer / older (parent-arrow muscle memory)
#   Shift-Up/Down   same step, native yazi binding (works outside Zellij too)
#   H / L           focus the timeline / the file list (indicator + timeline
#                   highlight trade the active palette); Shift-Left/Right too
#   j / k           scoped by focus: file-list cursor, or scrub when the
#                   timeline holds the focus
#   h / Left        leave — except at the session root, where the focus
#                   moves to the timeline (and once there, h is a no-op)
#   l / Right       enter — except from the timeline, where the focus
#                   returns to the file area
#   a / R           restore selection to the live filesystem (gated apply
#                   flow — snapshots are read-only, so create is meaningless
#                   here and `a` is free)
bkp::tm::yazi_overlay() {
  local s="$1" src="${YAZI_USER_CONFIG:-$HOME/.config/yazi}" ovl="$1/yazi"
  mkdir -p "$ovl"
  # Symlink the WHOLE user config (theme.toml, flavors, init.lua…) — only
  # keymap.toml, init.lua and plugins/ are composed. A hardcoded list here
  # once dropped the theme on the floor.
  local f
  for f in "$src"/*(DN); do
    [[ "${f:t}" == keymap.toml || "${f:t}" == init.lua || "${f:t}" == plugins || "${f:t}" == yazi.toml || "${f:t}" == theme.toml || "${f:t}" == flavors ]] && continue
    ln -sfn "$f" "$ovl/${f:t}"
  done
  # theme.toml: the user's own, untouched — cursor styling lives in the
  # flavor copy's [indicator] section below ([mgr] hovered is gone in
  # yazi 26, and a flavor file beats theme.toml anyway).
  [[ -f "$src/theme.toml" ]] && ln -sfn "$src/theme.toml" "$ovl/theme.toml"
  # flavors/: symlink all, but append an [indicator] section to the active
  # flavor copy — yazi 26 moved cursor-row styling there (mgr hovered is
  # gone; the default is current = reversed). The tab palette drives it:
  # white-on-active-tab for the cursor row, inactive-tab bg for the
  # preview column hover.
  if [[ -d "$src/flavors" && -n "${C_HEX_TAB_ACTIVE_BG:-}" && -n "${C_HEX_TAB_ACTIVE_FG:-}" && -n "${C_HEX_TAB_BG:-}" ]]; then
    local flav
    flav=$(yq -p toml -o json '.' "$src/theme.toml" 2>/dev/null |
      jq -r '.flavor.dark // .flavor.use // empty' 2>/dev/null)
    mkdir -p "$ovl/flavors"
    for f in "$src/flavors"/*(DN); do
      if [[ -n "$flav" && "${f:t}" == "$flav.yazi" && -f "$f/flavor.toml" ]]; then
        mkdir -p "$ovl/flavors/${f:t}"
        local ff
        for ff in "$f"/*(DN); do
          [[ "${ff:t}" == flavor.toml ]] && continue
          ln -sfn "$ff" "$ovl/flavors/${f:t}/${ff:t}"
        done
        {
          cat "$f/flavor.toml"
          print -r -- ""
          print -r -- "[indicator]"
          print -r -- "current = { fg = \"$C_HEX_TAB_ACTIVE_FG\", bg = \"$C_HEX_TAB_ACTIVE_BG\", bold = true }"
          print -r -- "preview = { fg = \"$C_HEX_TAB_FG\", bg = \"$C_HEX_TAB_BG\" }"
        } > "$ovl/flavors/${f:t}/flavor.toml"
      else
        ln -sfn "$f" "$ovl/flavors/${f:t}"
      fi
    done
  elif [[ -d "$src/flavors" ]]; then
    ln -sfn "$src/flavors" "$ovl/flavors"
  fi
  # yazi.toml: user config + a scrub-session ratio — the parent column
  # stays visible because tm-gate's Parent:redraw override renders the
  # snapshot timeline there ("where am I" lives inside yazi now).
  {
    [[ -f "$src/yazi.toml" ]] && cat "$src/yazi.toml"
    if [[ -f "$src/yazi.toml" ]] && grep -q '^\[mgr\]' "$src/yazi.toml"; then
      :
    else
      print -r -- "[mgr]"
    fi
  } > "$ovl/yazi.toml"
  if grep -q '^\[mgr\]' "$ovl/yazi.toml" && ! grep -q '^ratio' "$ovl/yazi.toml"; then
    awk '{ print } /^\[mgr\]/ && !done { print "ratio = [ 2, 4, 4 ]"; done = 1 }' \
      "$ovl/yazi.toml" > "$ovl/yazi.toml.new" && mv "$ovl/yazi.toml.new" "$ovl/yazi.toml"
  fi
  # plugins/: the user's plugins plus the generated session gate.
  mkdir -p "$ovl/plugins"
  if [[ -d "$src/plugins" ]]; then
    for f in "$src/plugins"/*(DN); do
      ln -sfn "$f" "$ovl/plugins/${f:t}"
    done
  fi
  bkp::tm::gate_plugin "$ovl/plugins"
  # init.lua: the user's own, then the gate (env-driven, static content).
  {
    # Load the user init with Header additions captured and removed — the
    # user@host element wastes the narrow session header (tm-gate owns it).
    if [[ -f "$src/init.lua" ]]; then
      cat <<'LUA'
do
	local _add, ids = Header.children_add, {}
	Header.children_add = function(self, fn, order)
		local id = _add(self, fn, order)
		ids[#ids + 1] = id
		return id
	end
LUA
      print -r -- "	dofile(\"$src/init.lua\")"
      cat <<'LUA'
	for _, id in ipairs(ids) do
		pcall(function() Header:children_remove(id) end)
	end
	Header.children_add = _add
end
LUA
    fi
    print -r -- 'require("tm-gate"):setup()'
  } > "$ovl/init.lua"
  local bin='$HOME/.local/bin/system-backup-tm'
  # One row per binding, inline-table form (also reused for the appended
  # form). Step bindings pass yazi's hovered entry ($0) and inherit yazi's
  # cwd — that context is what preserves the selection across rungs.
  local -a rows=(
    "  { on = \"K\", run = 'shell --orphan \"$bin ctl $s newer \\\"\$0\\\"\"', desc = \"tm: newer snapshot\" },"
    "  { on = \"J\", run = 'shell --orphan \"$bin ctl $s older \\\"\$0\\\"\"', desc = \"tm: older snapshot\" },"
    "  { on = \"<S-Up>\", run = 'shell --orphan \"$bin ctl $s newer \\\"\$0\\\"\"', desc = \"tm: newer snapshot\" },"
    "  { on = \"<S-Down>\", run = 'shell --orphan \"$bin ctl $s older \\\"\$0\\\"\"', desc = \"tm: older snapshot\" },"
    "  { on = \"H\", run = \"plugin tm-gate focus\", desc = \"tm: focus the timeline\" },"
    "  { on = \"L\", run = \"plugin tm-gate blur\", desc = \"tm: focus the file list\" },"
    "  { on = \"<S-Left>\", run = \"plugin tm-gate focus\", desc = \"tm: focus the timeline\" },"
    "  { on = \"<S-Right>\", run = \"plugin tm-gate blur\", desc = \"tm: focus the file list\" },"
    "  { on = \"j\", run = \"plugin tm-gate j\", desc = \"tm: down (file list) / older (timeline)\" },"
    "  { on = \"k\", run = \"plugin tm-gate k\", desc = \"tm: up (file list) / newer (timeline)\" },"
    "  { on = \"h\", run = \"plugin tm-gate h\", desc = \"tm: leave; timeline focus at the root\" },"
    "  { on = \"<Left>\", run = \"plugin tm-gate h\", desc = \"tm: leave; timeline focus at the root\" },"
    "  { on = \"l\", run = \"plugin tm-gate l\", desc = \"tm: enter; file focus from the timeline\" },"
    "  { on = \"<Right>\", run = \"plugin tm-gate l\", desc = \"tm: enter; file focus from the timeline\" },"
    "  { on = \"a\", run = 'shell --orphan \"$bin apply $s \\\"\$@\\\"\"', desc = \"tm: restore selection to live filesystem\" },"
    "  { on = \"R\", run = 'shell --orphan \"$bin apply $s \\\"\$@\\\"\"', desc = \"tm: restore selection to live filesystem\" },"
    "  { on = \"<S-Enter>\", run = 'shell --orphan \"$bin apply $s \\\"\$@\\\"\"', desc = \"tm: restore selection to live filesystem\" },"
    "  { on = \"q\", run = [ 'shell --orphan \"$bin ctl $s end\"', \"quit\" ], desc = \"tm: end scrub session\" },"
  )
  print -rl -- "${rows[@]}" > "$ovl/.rows"
  if [[ -f "$src/keymap.toml" ]] &&
     awk '/^\[mgr\]/ { m = 1; next }
          /^\[/ { m = 0 }
          m && /^prepend_keymap = \[/ { found = 1 }
          END { exit !found }' "$src/keymap.toml"; then
    # Inject at the head of the existing [mgr] prepend_keymap array.
    awk -v rf="$ovl/.rows" '
      /^\[mgr\]/ { m = 1 }
      /^\[/ && !/^\[mgr\]/ { m = 0 }
      { print }
      m && !done && /^prepend_keymap = \[/ {
        while ((getline row < rf) > 0) print row
        close(rf)
        done = 1
      }' "$src/keymap.toml" > "$ovl/keymap.toml"
  else
    {
      [[ -f "$src/keymap.toml" ]] && cat "$src/keymap.toml"
      print -r -- ""
      print -r -- "# --- tm scrub session bindings (generated; spec 2026-07-04 §5.2/§6) ---"
      print -r -- "[mgr]"
      print -r -- "prepend_keymap = ["
      print -rl -- "${rows[@]}"
      print -r -- "]"
    } > "$ovl/keymap.toml"
  fi
  rm -f "$ovl/.rows"
  print -r -- "$ovl"
}

# bkp::tm::gate_plugin <plugins-dir>
# Write the tm-gate yazi plugin (static content, env-driven at runtime):
# 1) bounce any cd that leaves <mnt>/ids/<rung><anchor> back to the last
#    good directory (cross-rung cds match the pattern, so scrubbing works);
# 2) replace the header cwd with "\u25cf <age>  <live-relative path>" so the
#    mount plumbing never shows;
# 3) render the snapshot timeline in the parent column (Parent:redraw
#    override) \u2014 rung changes arrive as emit-to cd/reveal, which forces a
#    full redraw, so the timeline repaints for free.
# Reads BKP_TM_MNT/ANCHOR/SESSION + palette colors from env.
bkp::tm::gate_plugin() {
  local dir="$1/tm-gate.yazi"
  mkdir -p "$dir"
  cat > "$dir/main.lua" <<'EOF'
-- tm-gate.yazi — scrub-session navigation gate + header rewrite
-- (generated per session by backup-tm.zsh; configured via BKP_TM_* env).
local M = {}

local function esc(s)
	return (s:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%1"))
end

-- Focus swap (keymap H / L): a visual tiebreaker between the file list
-- and the timeline column. The flag lives in the sync VM's globals so
-- Parent:redraw (sync) and the keybinding entry (async) agree; the
-- file-list cursor follows via th.indicator, which is re-read per
-- render. ya.render() works here because the swap is a real key command
-- inside yazi — the retired external DDS publish path had no such luck.
local set_tl_focus = ya.sync(function(_, v)
	_G.__tm_tl_focus = v
	if th and th.indicator then
		local bg = os.getenv(v and "BKP_TM_INACTIVE_BG" or "BKP_TM_ACTIVE_BG")
		local fg = os.getenv(v and "BKP_TM_TAB_FG" or "BKP_TM_ACTIVE_FG")
		if bg and fg then
			th.indicator.current = ui.Style():fg(fg):bg(bg):bold()
		end
	end
	-- ui.render(), NOT ya.render(): yazi 26 renamed it, and a nil call
	-- here fails the whole sync block — the task lands in the task
	-- manager as failed AND the repaint never happens.
	ui.render()
end)

-- Navigation context for the focus-scoped j/k dispatch below.
local get_nav = ya.sync(function()
	local h = cx.active.current.hovered
	return _G.__tm_tl_focus and true or false,
		tostring(cx.active.current.cwd),
		h and tostring(h.url) or ""
end)

-- Keymap args are POSITIONAL ("plugin tm-gate focus") — yazi 26.5
-- silently drops the old `--args=focus` form (job.args arrives empty).
function M:entry(job)
	local arg = job.args and job.args[1]
	if arg == "focus" then
		set_tl_focus(true)
	elseif arg == "blur" then
		set_tl_focus(false)
	elseif arg == "h" then
		-- Immutable rule: with the timeline focused, h/Left do NOTHING.
		-- In the file area they leave as usual, except at the session
		-- root, where "one more left" hands the focus to the timeline.
		local focused, cwd = get_nav()
		if focused then
			return
		end
		local mnt = os.getenv("BKP_TM_MNT")
		local anchor = os.getenv("BKP_TM_ANCHOR") or ""
		if mnt and cwd:match("^" .. esc(mnt) .. "/ids/[^/]+" .. esc(anchor) .. "$") then
			set_tl_focus(true)
		else
			ya.emit("leave", {})
		end
	elseif arg == "l" then
		-- l/Right from the timeline return to the file area; in the file
		-- area they keep the preset behavior: enter (dirs only) — NOT
		-- open, which would launch the opener on hovered files.
		local focused = get_nav()
		if focused then
			set_tl_focus(false)
		else
			ya.emit("enter", {})
		end
	elseif arg == "j" or arg == "k" then
		-- j/k are scoped by the focused side: file-list cursor when the
		-- list owns focus, snapshot scrub when the timeline does (same
		-- ctl contract as K/J — yazi's cwd + hovered keep the place).
		local focused, cwd, hovered = get_nav()
		if not focused then
			ya.emit("arrow", { arg == "j" and 1 or -1 })
			return
		end
		local sess = os.getenv("BKP_TM_SESSION")
		if not sess then
			return
		end
		local cmd = Command(os.getenv("HOME") .. "/.local/bin/system-backup-tm")
			:arg("ctl")
			:arg(sess)
			:arg(arg == "j" and "older" or "newer")
		if hovered ~= "" then
			cmd = cmd:arg(hovered)
		end
		-- output() waits; spawn() must NOT be used here — the discarded
		-- Child handle is killed on GC, racing the ctl to death.
		pcall(function()
			cmd:cwd(cwd):stdout(Command.PIPED):stderr(Command.PIPED):output()
		end)
	end
end

function M:setup()
	local mnt = os.getenv("BKP_TM_MNT")
	local anchor = os.getenv("BKP_TM_ANCHOR") or ""
	local sess = os.getenv("BKP_TM_SESSION")
	if not mnt then
		return
	end
	local pat = "^" .. esc(mnt) .. "/ids/([^/]+)" .. esc(anchor) .. "(.*)$"

	-- The session ladder, newest first (static for the session): an
	-- ordered array for the timeline plus an id(8) -> epoch map for the
	-- header rewrite.
	local ladder, epochs = {}, {}
	if sess then
		local f = io.open(sess .. "/ladder", "r")
		if f then
			for line in f:lines() do
				local id, epoch = line:match("^(%x+)\t(%d+)")
				if id then
					ladder[#ladder + 1] = { id = id:sub(1, 8), epoch = tonumber(epoch) }
					epochs[id:sub(1, 8)] = tonumber(epoch)
				end
			end
			f:close()
		end
	end

	local function inside(cwd)
		local id, rest = cwd:match(pat)
		if not id then
			return nil
		end
		if rest ~= "" and rest:sub(1, 1) ~= "/" then
			return nil
		end
		return id, rest
	end

	local last_ok = nil
	ps.sub("cd", function()
		local cwd = tostring(cx.active.current.cwd)
		if inside(cwd) then
			last_ok = cwd
		elseif last_ok then
			ya.emit("cd", { last_ok })
		end
	end)

	-- Snapshot timeline in the parent column: the ladder IS "where am I"
	-- for a scrub session, so the parent listing (mount plumbing) is
	-- replaced wholesale. The rung file is re-read on every redraw — rung
	-- changes always arrive as `ya emit-to cd|reveal`, which triggers a
	-- full redraw, so this stays fresh with no other repaint machinery.
	local act_bg = os.getenv("BKP_TM_ACTIVE_BG")
	local act_fg = os.getenv("BKP_TM_ACTIVE_FG")
	local inact_bg = os.getenv("BKP_TM_INACTIVE_BG")
	local dim_fg = os.getenv("BKP_TM_TAB_FG")
	local accent_fg = os.getenv("BKP_TM_ACCENT_FG")
	local key_fg = os.getenv("BKP_TM_KEY_FG")
	local hint_fg = os.getenv("BKP_TM_HINT_FG")
	local sep_fg = os.getenv("BKP_TM_SEP_FG") or os.getenv("BKP_TM_TAB_FG")
	_G.__tm_tl_focus = false -- the file list owns focus at launch

	local function cur_rung()
		local f = sess and io.open(sess .. "/rung", "r")
		if not f then
			return 1
		end
		local n = tonumber(f:read("*l")) or 1
		f:close()
		return n
	end

	local function dim(span)
		return dim_fg and span:fg(dim_fg) or span
	end

	if #ladder > 0 then
		function Parent:redraw()
			local w, h = self._area.w, self._area.h
			local cur = cur_rung()
			local function sep_line()
				local span = ui.Span(" " .. string.rep("━", math.max(1, w - 2)))
				return ui.Line({ sep_fg and span:fg(sep_fg) or span })
			end
			local lines = {}
			local title = ui.Span(" \u{10F1DA} Snapshots")
			lines[#lines + 1] = ui.Line({ accent_fg and title:fg(accent_fg) or title })
			lines[#lines + 1] = sep_line()

			-- Every rung is a two-line date/time stamp behind ● / ┃ glyphs;
			-- glyph color says where you are (newer red, current green,
			-- older yellow); the current rung gets a full-width highlight —
			-- active-tab palette when the timeline holds the focus (H),
			-- inactive-tab palette otherwise.
			local focus = _G.__tm_tl_focus
			local hl_bg = focus and act_bg or inact_bg
			local hl_fg = focus and act_fg or dim_fg
			local rows = {}
			for i, r in ipairs(ladder) do
				-- %e space-pads single-digit days ("Jul  5") — collapse it.
				local date = os.date("%a, %b %e %Y", r.epoch):gsub("%s%s+", " ")
				local clock = string.lower(os.date("%I:%M %p", r.epoch))
				local gc = i < cur and "red" or (i == cur and "green" or "yellow")
				-- The time row's bar continues the line toward the next rung;
				-- the LAST rung has nothing below it — no dangling bar.
				local tg = i < #ladder and "┃" or " "
				if i == cur and hl_bg and hl_fg then
					local pad1 = string.rep(" ", math.max(0, w - 3 - #date))
					local pad2 = string.rep(" ", math.max(0, w - 3 - #clock))
					rows[#rows + 1] = { rung = i, line = ui.Line({
						ui.Span(" "):bg(hl_bg),
						ui.Span("●"):fg(gc):bg(hl_bg),
						ui.Span(" " .. date .. pad1):fg(hl_fg):bg(hl_bg):bold(),
					}) }
					rows[#rows + 1] = { rung = i, line = ui.Line({
						ui.Span(" "):bg(hl_bg),
						ui.Span(tg):fg(gc):bg(hl_bg),
						ui.Span(" " .. clock .. pad2):fg(hl_fg):bg(hl_bg),
					}) }
				else
					rows[#rows + 1] = { rung = i, line = ui.Line({
						ui.Span(" "),
						ui.Span("●"):fg(gc),
						ui.Span(" " .. date),
					}) }
					rows[#rows + 1] = { rung = i, line = ui.Line({
						ui.Span(" "),
						ui.Span(tg):fg(gc),
						dim(ui.Span(" " .. clock)),
					}) }
				end
				if i < #ladder then
					rows[#rows + 1] = { rung = 0, line = ui.Line({
						ui.Span(" "),
						ui.Span("┃"):fg(i < cur and "red" or "yellow"),
					}) }
				end
			end

			-- Window the rows around the current rung; ⋮ marks clipped ends.
			local height = math.max(3, h - 5)
			local first = 1
			if #rows > height then
				local at = 1
				for i, row in ipairs(rows) do
					if row.rung == cur then
						at = i
						break
					end
				end
				first = math.max(1, at - math.floor(height / 2))
				if first + height - 1 > #rows then
					first = #rows - height + 1
				end
			end
			local last = math.min(first + height - 1, #rows)
			for i = first, last do
				if #rows > height and ((i == first and first > 1) or (i == last and last < #rows)) then
					lines[#lines + 1] = ui.Line({ dim(ui.Span(" ⋮")) })
				else
					lines[#lines + 1] = rows[i].line
				end
			end

			local function key(text)
				local span = ui.Span(text)
				return key_fg and span:fg(key_fg) or span
			end
			local function hint(text)
				local span = ui.Span(text)
				return hint_fg and span:fg(hint_fg) or span
			end
			-- Hints display uppercase; the shift glyph only marks actual
			-- Shift chords (K/J) — plain keys (q/a) show bare uppercase.
			lines[#lines + 1] = sep_line()
			lines[#lines + 1] = ui.Line({ key(" 󰘶K"), hint(" newer "), hint("· "), key("󰘶J"), hint(" older") })
			lines[#lines + 1] = ui.Line({ key("  Q"), hint(" quit  "), hint("·  "), key("A"), hint(" apply") })

			return { ui.List(lines):area(self._area) }
		end
		-- The column no longer lists the parent folder — a click or wheel
		-- there must not navigate the mount underneath the timeline.
		function Parent:click() end
		function Parent:scroll() end
	end

	-- Header: hide the mount plumbing, show when + where (live-relative).
	pcall(function()
		Header.cwd = function(_)
			local cwd = tostring(cx.active.current.cwd)
			local id, rest = inside(cwd)
			if not id then
				return ui.Span(" " .. cwd .. " ")
			end
			local label = "snapshot " .. id:sub(1, 8)
			local epoch = epochs[id:sub(1, 8)]
			if epoch then
				local age = os.time() - epoch
				if age < 3600 then
					label = math.floor(age / 60) .. "m ago"
				elseif age < 172800 then
					label = math.floor(age / 3600) .. "h ago"
				else
					label = math.floor(age / 86400) .. "d ago"
				end
			end
			return ui.Span(" \u{25cf} " .. label .. "  " .. anchor .. rest .. " ")
		end
	end)
end

return M
EOF
}

# bkp::tm::lens_cmd <session>
# The lens pane argv, one element per line (caller reads into an array).
# Explore: plain yazi anchored inside the rung — the tm-gate plugin does
# the confinement (navigation bounce + header rewrite); snapshots are
# immutable via the read-only mount, so no sandbox is needed (spec §5.3
# as amended: mistake-prevention, not a security boundary).
# Diff: hunk in watch mode.
bkp::tm::lens_cmd() {
  local s="$1" lens anchor REPLY
  lens=$(<"$s/lens") anchor=$(<"$s/anchor")
  if [[ "$lens" == diff ]]; then
    # hunk needs the file to exist even when the first synthesis failed —
    # an empty patch renders as a graceful "no changes" state.
    [[ -f "$s/current.patch" ]] || : > "$s/current.patch"
    print -rl -- hunk patch "$s/current.patch" --watch
    return 0
  fi
  bkp::tm::rung_path "$s" || return 1
  local rung="$REPLY" ovl yid
  ovl=$(bkp::tm::yazi_overlay "$s") || return 1
  yid=$(<"$s/yazi.id")
  print -rl -- env "YAZI_CONFIG_HOME=$ovl" \
    "BKP_TM_MNT=$s/mnt" "BKP_TM_ANCHOR=$anchor" "BKP_TM_SESSION=$s" \
    "BKP_TM_INACTIVE_BG=${C_HEX_TAB_BG:-}" "BKP_TM_ACTIVE_BG=${C_HEX_TAB_ACTIVE_BG:-}" \
    "BKP_TM_ACTIVE_FG=${C_HEX_TAB_ACTIVE_FG:-}" "BKP_TM_TAB_FG=${C_HEX_TAB_FG:-}" \
    "BKP_TM_ACCENT_FG=${C_ROLE_UI_ACCENT:-}" "BKP_TM_KEY_FG=${C_ROLE_UI_KEY:-}" \
    "BKP_TM_HINT_FG=${C_ROLE_UI_HINT:-}" "BKP_TM_SEP_FG=${C_ROLE_UI_SEPARATOR:-}" \
    yazi --client-id "$yid" "$rung$anchor"
}

: ${BKP_TM_BIN:="$HOME/.local/bin/system-backup-tm"}

# bkp::tm::launch <lens> <anchor>
# Entry point (spec §5): under Zellij the session lives in the CURRENT
# tab. Explore is ONE pane — yazi takes over the invoking pane and the
# timeline renders inside its parent column (tm-gate). Diff splits the
# hunk lens off to the right and the timeline pane takes the invoking
# pane. Either way the shell prompt returns when the session ends, and
# the tab keeps its zj-hud chrome — a fresh layout-string tab loses it.
# Outside Zellij: the sequential fallback.
bkp::tm::launch() {
  local lens="$1" anchor="${2:A}"
  log_info "bkp: preparing scrub session for ${anchor/#$HOME/~}…"
  local s
  s=$(bkp::tm::session_new "$lens" "$anchor") || return $?
  if [[ -n "${ZELLIJ:-}" ]]; then
    # ALL slow prep happens here, before any layout change: spinner per
    # stage (gum), completion line after each, split only when ready.
    local _spin=0
    [[ -t 1 ]] && command -v gum >/dev/null 2>&1 && (( ! ${+functions[gum]} )) && _spin=1
    if (( _spin )); then
      gum spin --spinner dot --title "Reading the snapshot ladder…" -- \
        zsh -c "source '$HOME/.local/lib/backup-tm.zsh'; bkp::tm::ladder_fill '$s'" ||
        { rm -rf "$s"; return 2 }
      log_ok "bkp: snapshot ladder ready"
    else
      bkp::tm::ladder_fill "$s" || { rm -rf "$s"; return 2 }
    fi
    if bkp::ux::has_fuse; then
      if (( _spin )); then
        gum spin --spinner dot --title "Mounting the snapshot repository…" -- \
          zsh -c "source '$HOME/.local/lib/backup-tm.zsh'
                  bkp::mount \"\$(bkp::config::staging_path)\" '$s/mnt' &&
                  print -r -- \$REPLY > '$s/mount.pid'" ||
          { rm -rf "$s"; return 1 }
        log_ok "bkp: repository mounted"
      else
        local staging REPLY
        staging=$(bkp::config::staging_path) || { rm -rf "$s"; return 2 }
        bkp::mount "$staging" "$s/mnt" || { rm -rf "$s"; return 1 }
        print -r -- "$REPLY" > "$s/mount.pid"
      fi
    fi
    touch "$s/ready"
    if [[ "$lens" == explore ]]; then
      # One pane: yazi owns the whole session — the timeline lives in its
      # parent column, so there is no split and no timeline pane. The lens
      # worker tears the session down (unmount + rm) when yazi exits.
      "$BKP_TM_BIN" lens "$s" || return $?
    else
      zellij run --close-on-exit --direction right --name "tm lens" \
        -- "$BKP_TM_BIN" lens "$s" >/dev/null || { rm -rf "$s"; return 1 }
      # The new pane takes focus; grow it leftward so the timeline pane
      # narrows toward its ~26-col design width. Focus STAYS on the lens —
      # scrubbing works from inside it (Shift+arrows), and a focused
      # timeline reads as two active panes with no visual tiebreaker.
      local i
      for i in 1 2 3 4 5; do
        zellij action resize increase left 2>/dev/null || break
      done
      "$BKP_TM_BIN" timeline "$s" || return $?
    fi
  else
    bkp::tm::fallback "$s" || return $?
  fi
}

# bkp::tm::fallback <session>
# No-Zellij sequential mode (spec §5.4): lens full-screen, then a keybar —
# j older / k newer / a apply / q quit — stepping relaunches the lens.
# The dispatcher runs under set -e; this function manages its own return
# codes, so err_exit is disabled for its body — otherwise a lens app dying
# (Ctrl-C) would abort the process before the always-teardown unmounts.
bkp::tm::fallback() {
  setopt local_options no_err_exit
  local s="$1" staging key REPLY
  staging=$(bkp::config::staging_path) || return 2
  print -r -- $$ > "$s/timeline.pid"
  print -r -- $$ > "$s/yazi.id"
  printf '%s⏳ reading the snapshot ladder…%s\n' "$C_DIM" "$C_RES"
  bkp::tm::ladder_fill "$s" || { rm -rf "$s"; return 2 }
  if bkp::ux::has_fuse; then
    printf '%s⏳ mounting snapshot repository…%s\n' "$C_DIM" "$C_RES"
    bkp::mount "$staging" "$s/mnt" || return 1
    print -r -- "$REPLY" > "$s/mount.pid"
  fi
  {
    touch "$s/ready"
    while [[ ! -e "$s/closed" ]]; do
      bkp::tm::refresh "$s" || break
      rm -f "$s/respawn"     # fallback relaunches anyway
      local -a cmd
      cmd=("${(@f)$(bkp::tm::lens_cmd "$s")}") || break
      ( cd "$s" && "${cmd[@]}" ) || :
      bkp::tm::rung_line "$s" || break
      local tier="${REPLY##*$'\t'}" rung=""
      [[ -f "$s/rung" ]] && rung=$(<"$s/rung")
      printf '%s[rung %s · %s]  j older · k newer · a apply · q quit%s ' \
        "$C_DIM" "$rung" "$tier" "$C_RES"
      read -k 1 key || key=q
      printf '\n'
      case "$key" in
        j) bkp::tm::step "$s" older || : ;;
        k) bkp::tm::step "$s" newer || : ;;
        a) "$BKP_TM_BIN" apply "$s" || : ;;
        *) break ;;
      esac
    done
  } always {
    bkp::tm::kill_lens "$s"
    [[ -f "$s/mount.pid" ]] && bkp::umount "$(<"$s/mount.pid")" "$s/mnt"
    rm -rf "$s"
  }
}
