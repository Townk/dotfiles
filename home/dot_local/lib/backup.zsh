# backup.zsh — bkp:: module: the system-backup (Terminal Time Machine) silo.
# This file is intended to be sourced; it does not run on its own.
#
# Phase 1 ships the thinning engine (bkp::thin), the pure retention planner
# from the design spec §5. Later phases add manifest resolution, capture,
# and reconcile helpers.

# Logging and the shared stdlib come from the shared base. Source it relative
# to THIS file so it resolves both at ~/.local/lib (production) and at the
# repo path (the ShellSpec suite sources us directly).
_bkp_self="${(%):-%x}"
source "$(dirname "$_bkp_self")/common.zsh"
# The freshness heartbeat + prompt banner (bkp::drift::*). Standalone so the
# prompt can source it alone; here the workers get bkp::drift::stamp.
source "$(dirname "$_bkp_self")/backup-drift.zsh"
unset _bkp_self

zmodload zsh/datetime
zmodload zsh/system
# -F … b:zstat loads only the zstat builtin — a plain `zmodload zsh/stat`
# would shadow the system `stat` command for every sourcing script.
zmodload -F zsh/stat b:zstat

# Default retention ladder (spec §5). One tier per line:
#   <grid> <min_age_seconds> <max_age_seconds|->
# A snapshot belongs to the first tier whose half-open band [min, max)
# contains its age; `-` means unbounded. The published per-tier counts
# (48/24/4/2/7/8/12) are emergent — band width divided by grid interval —
# not enforced explicitly.
BKP_THIN_DEFAULT_POLICY='
  30m    0         86400
  1h     86400     172800
  6h     172800    259200
  12h    259200    345600
  day    345600    950400
  week   950400    5788800
  month  5788800   37324800
  year   37324800  -
'

# bkp::thin::cell <grid> <epoch>
# The wall-clock grid cell containing <epoch>, in LOCAL time (TZ-sensitive by
# design: "the 06:00 snapshot" means 06:00 on the user's wall clock). Sets
# REPLY to a cell id unique within the grid; ids from different grids may
# collide, so callers must namespace by tier. Weekly cells are ISO weeks
# (%G%V), which anchors them on Monday.
bkp::thin::cell() {
  local grid="$1" epoch="$2" stamp
  strftime -s stamp '%Y %m %d %H %M %G %V' "$epoch"
  local -a f=(${(z)stamp})
  local Y="$f[1]" m="$f[2]" d="$f[3]" H="$f[4]" M="$f[5]" G="$f[6]" V="$f[7]"
  case "$grid" in
    30m)   REPLY="$Y$m$d$H.$(( 10#$M / 30 ))" ;;
    1h)    REPLY="$Y$m$d$H" ;;
    6h)    REPLY="$Y$m$d.$(( 10#$H / 6 ))" ;;
    12h)   REPLY="$Y$m$d.$(( 10#$H / 12 ))" ;;
    day)   REPLY="$Y$m$d" ;;
    week)  REPLY="$G$V" ;;
    month) REPLY="$Y$m" ;;
    year)  REPLY="$Y" ;;
    *)
      log_error "bkp::thin::cell: unknown grid '$grid'"
      return 2
      ;;
  esac
}

# bkp::thin <now_epoch> [<policy>]
# The retention planner (spec §5). Pure: no restic, no clock reads, no
# filesystem — fully driven by its arguments and stdin.
#
#   stdin:  one snapshot per line:  <id><TAB><unix_epoch>
#   stdout: one line per snapshot:  keep<TAB><id>  |  drop<TAB><id>
#           (input order preserved)
#   policy: BKP_THIN_DEFAULT_POLICY format; defaults to the §5 ladder.
#
# Every snapshot is assigned the first tier whose age band contains it, then
# quantized to that tier's wall-clock grid cell; the newest snapshot in each
# (tier, cell) survives, and the newest snapshot overall always survives
# (keep_last=1). Deterministic and idempotent for a fixed <now>: re-running
# on its own keep-set changes nothing.
bkp::thin() {
  local now="${1:-}" policy="${2:-$BKP_THIN_DEFAULT_POLICY}"
  [[ "$now" == <-> ]] || {
    log_error "bkp::thin: <now> must be a unix epoch, got '$now'"
    return 2
  }

  # Parse the policy table. ${(z)} tokenization (not pattern-trimming, which
  # would need extendedglob) handles indentation and blank lines.
  local -a t_grid=() t_min=() t_max=()
  local line
  local -a f
  while IFS= read -r line; do
    f=(${(z)line})
    (( ${#f} )) || continue
    [[ "$f[1]" == '#'* ]] && continue
    if (( ${#f} != 3 )) || [[ "$f[2]" != <-> ]] ||
      [[ "$f[3]" != <-> && "$f[3]" != - ]]; then
      log_error "bkp::thin: bad policy line: '$line'"
      return 2
    fi
    t_grid+=("$f[1]") t_min+=("$f[2]") t_max+=("$f[3]")
  done <<<"$policy"
  (( ${#t_grid} )) || {
    log_error "bkp::thin: empty policy"
    return 2
  }

  # Read the snapshot list.
  local -a s_id=() s_epoch=()
  local id epoch
  while IFS=$'\t' read -r id epoch; do
    [[ -z "$id$epoch" ]] && continue
    if [[ -z "$id" || "$epoch" != <-> ]]; then
      log_error "bkp::thin: bad snapshot line (want <id><TAB><epoch>): '$id'"
      return 2
    fi
    s_id+=("$id") s_epoch+=("$epoch")
  done
  (( ${#s_id} )) || return 0

  # keep_last=1 — the newest snapshot always survives.
  local i newest=1
  for (( i = 2; i <= ${#s_id}; i++ )); do
    (( s_epoch[i] > s_epoch[newest] )) && newest=$i
  done

  # Newest snapshot per (tier, wall-clock cell).
  local -A best=()   # "tier:cell" -> index of the newest snapshot in that cell
  local age t key REPLY
  for (( i = 1; i <= ${#s_id}; i++ )); do
    age=$(( now - s_epoch[i] ))
    (( age < 0 )) && age=0   # clock skew: a future snapshot is "brand new"
    for (( t = 1; t <= ${#t_grid}; t++ )); do
      (( age >= t_min[t] )) || continue
      [[ "$t_max[t]" == - ]] || (( age < t_max[t] )) || continue
      break
    done
    (( t <= ${#t_grid} )) || {
      log_error "bkp::thin: no tier covers age ${age}s — policy must be exhaustive"
      return 2
    }
    bkp::thin::cell "$t_grid[t]" "$s_epoch[i]" || return 2
    key="$t:$REPLY"
    if [[ -z "${best[$key]:-}" ]] || (( s_epoch[i] > s_epoch[best[$key]] )); then
      best[$key]=$i
    fi
  done

  local -A keep=()
  keep[$newest]=1
  for key in ${(k)best}; do
    keep[$best[$key]]=1
  done

  for (( i = 1; i <= ${#s_id}; i++ )); do
    if (( ${keep[$i]:-0} )); then
      print -r -- "keep"$'\t'"$s_id[i]"
    else
      print -r -- "drop"$'\t'"$s_id[i]"
    fi
  done
}

# ── Manifest ─────────────────────────────────────────────────────────────────

BKP_MANIFEST="${BKP_MANIFEST:-$HOME/.config/backup/manifest.toml}"

# bkp::manifest::json <file>
# The manifest as JSON on stdout (house parse: yq TOML->JSON once, jq after).
bkp::manifest::json() {
  local file="$1"
  [[ -f "$file" ]] || {
    log_error "bkp: manifest not found: $file"
    return 2
  }
  yq -p toml -o json '.' "$file" 2>/dev/null || {
    log_error "bkp: unparseable manifest: $file"
    return 2
  }
}

# bkp::manifest::roots <file>
# One root per line: <path>\t<bundle_unpushed>\t<untracked_warn_size>.
# A bare-string root takes the built-in defaults (bundle_unpushed=true,
# untracked_warn_size=50m); a table overrides per root. ~ expands to $HOME.
bkp::manifest::roots() {
  local json
  json=$(bkp::manifest::json "$1") || return 2
  jq -r --arg home "$HOME" '
    (.roots // [])[]
    | (if type == "string" then {path: .} else . end)
    | [ (.path | sub("^~"; $home)),
        # NB: not `// true` — the // operator treats an explicit false as absent.
        ((.bundle_unpushed != false) | tostring),
        (.untracked_warn_size // "50m") ]
    | @tsv' <<<"$json"
}

# bkp::manifest::deny <file> — the deny globs, one per line, ~ expanded.
bkp::manifest::deny() {
  local json
  json=$(bkp::manifest::json "$1") || return 2
  jq -r --arg home "$HOME" '(.deny // [])[] | sub("^~"; $home)' <<<"$json"
}

# bkp::manifest::chezmoi_excluded <file>
# Predicate: true unless the manifest sets exclude_chezmoi_managed = false.
bkp::manifest::chezmoi_excluded() {
  local json
  json=$(bkp::manifest::json "$1") || return 2
  jq -e '.exclude_chezmoi_managed != false' <<<"$json" >/dev/null
}

# bkp::duration <spec>
# "30m"/"24h"/"7d"/"2w" -> seconds, in REPLY. Sizes ("50m" megabytes) are a
# different beast — this is time only.
bkp::duration() {
  local spec="$1" n="${1%?}"
  if [[ "$n" != <-> ]]; then
    log_error "bkp: bad duration '$spec' (want <n>m|h|d|w)"
    return 2
  fi
  case "$spec" in
    *m) REPLY=$(( n * 60 )) ;;
    *h) REPLY=$(( n * 3600 )) ;;
    *d) REPLY=$(( n * 86400 )) ;;
    *w) REPLY=$(( n * 604800 )) ;;
    *)
      log_error "bkp: bad duration '$spec' (want <n>m|h|d|w)"
      return 2
      ;;
  esac
}

# bkp::thin::grid_for <interval>
# Map a [policy] tier interval keyword onto a wall-clock grid (REPLY). The
# thinning engine is grid-based, so only grid-shaped intervals are legal.
bkp::thin::grid_for() {
  case "$1" in
    30m)               REPLY=30m ;;
    60m | 1h)          REPLY=1h ;;
    6h)                REPLY=6h ;;
    12h)               REPLY=12h ;;
    24h | 1d | daily)  REPLY=day ;;
    7d | 1w | weekly)  REPLY=week ;;
    monthly)           REPLY=month ;;
    yearly)            REPLY=year ;;
    *)
      log_error "bkp: unsupported tier interval '$1' (grids: 30m 60m 6h 12h 24h 7d monthly yearly)"
      return 2
      ;;
  esac
}

# bkp::manifest::thin_policy <file>
# [policy].tiers -> a bkp::thin policy table. Windows are cumulative age
# bands; a terminal unbounded yearly tier is always appended so the policy is
# exhaustive. No [policy].tiers -> the default §5 ladder.
bkp::manifest::thin_policy() {
  local json
  json=$(bkp::manifest::json "$1") || return 2
  local rows
  rows=$(jq -r '(.policy.tiers // [])[] | [.interval, .window] | @tsv' <<<"$json")
  if [[ -z "$rows" ]]; then
    print -r -- "$BKP_THIN_DEFAULT_POLICY"
    return 0
  fi
  local row interval window grid min=0 max REPLY
  for row in ${(f)rows}; do
    interval="${row%%$'\t'*}" window="${row##*$'\t'}"
    bkp::thin::grid_for "$interval" || return 2
    grid="$REPLY"
    bkp::duration "$window" || return 2
    max=$(( min + REPLY ))
    print -r -- "$grid $min $max"
    min=$max
  done
  print -r -- "year $min -"
}

# ── External seams (stubbed in tests) ────────────────────────────────────────

# bkp::chezmoi::managed — absolute paths of every chezmoi-managed FILE.
# Files only: a managed directory (e.g. ~/.config) still holds unmanaged
# children, so subtraction must be file-grained; a fully-managed subtree
# prunes wholesale because every file in it is listed.
bkp::chezmoi::managed() {
  chezmoi managed --include=files --path-style=absolute
}

# bkp::git::is_repo <dir> — does <dir> head a USABLE git work tree?
# The `.git` gate alone is not enough: vendored release tarballs (e.g.
# lua-language-server's meta/3rd/*) ship submodule gitfiles whose gitdir does
# not exist in the extracted tree. Those are plain dirs, not repos — the
# rev-parse check (only run when a .git exists, so it stays off the hot path)
# sends them down the ordinary walk instead of the repo path.
bkp::git::is_repo() {
  [[ -e "$1/.git" ]] || return 1
  git -C "$1" rev-parse --git-dir >/dev/null 2>&1
}

# bkp::git::ls <repo>
# Absolute paths of the repo's capturable working tree: tracked + untracked
# minus everything git's FULL ignore resolution drops (repo .gitignore(s),
# .git/info/exclude, and the machine-global core.excludesFile). Restricted to
# files present on disk — `ls-files --cached` also lists tracked files whose
# uncommitted deletion hasn't landed in the index; feeding those phantoms to
# restic makes the whole backup exit 3.
bkp::git::ls() {
  local repo="$1" out
  out=$(git -C "$repo" ls-files --cached --others --exclude-standard 2>/dev/null) || return 1
  local f
  for f in ${(f)out}; do
    [[ -e "$repo/$f" || -h "$repo/$f" ]] && print -r -- "$repo/$f"
  done
  return 0
}

# ── The sweep ────────────────────────────────────────────────────────────────

# bkp::manifest::denied <path>
# Predicate against the _bkp_deny globs (dynamic scope from the sweep).
# Three shapes per pattern: exact/glob match, prefix subsumption (a denied
# dir denies its contents), and dir-with-trailing-slash (so "**/Cache/**"
# prunes the Cache dir itself, not just files under it).
bkp::manifest::denied() {
  local p="$1" pat
  for pat in "${_bkp_deny[@]}"; do
    [[ "$p" == ${~pat} || "$p" == ${~pat}/* || "$p/" == ${~pat} ]] && return 0
  done
  return 1
}

# bkp::fs::device <path> — REPLY = st_dev of <path>, empty on failure.
# A seam so tests can fake mountpoints without mounting anything.
bkp::fs::device() {
  local -a _st
  REPLY=""
  zstat -A _st +device -- "$1" 2>/dev/null && REPLY=$_st[1]
  return 0
}

# bkp::manifest::walk <node>
# Recursive sweep worker. Emits F\t<file> / R\t<repo>\t<bundle>\t<warn>.
# Reads _bkp_deny, _bkp_managed, _bkp_bundle, _bkp_warn, _bkp_root_dev from
# the caller's scope. Inside a git repo, enumeration is delegated to git
# (full ignore resolution); on git failure it degrades to a plain walk that
# skips .git — over-capture, never under-capture.
bkp::manifest::walk() {
  local node="$1" entry
  bkp::manifest::denied "$node" && return 0
  if [[ -h "$node" || -f "$node" ]]; then
    [[ -n "${_bkp_managed[$node]:-}" ]] || print -r -- "F"$'\t'"$node"
    return 0
  fi
  [[ -d "$node" ]] || return 0
  # Never cross a filesystem boundary: anything MOUNTED inside a root (a
  # scrub session's restic FUSE mount, a network volume) is not this
  # machine's state — and descending into a repo mount reads the whole
  # repository back through FUSE (the sweep once wedged for 22 hours in
  # exactly that).
  if [[ -n "${_bkp_root_dev:-}" ]]; then
    local REPLY
    bkp::fs::device "$node"
    if [[ -n "$REPLY" && "$REPLY" != "$_bkp_root_dev" ]]; then
      log_warn "bkp: skipping $node — mounted filesystem inside a capture root"
      return 0
    fi
  fi
  if [[ -e "$node/.git" ]]; then
    if bkp::git::is_repo "$node"; then
      print -r -- "R"$'\t'"$node"$'\t'"$_bkp_bundle"$'\t'"$_bkp_warn"
      local git_out f
      if git_out=$(bkp::git::ls "$node"); then
        for f in ${(f)git_out}; do
          bkp::manifest::denied "$f" && continue
          [[ -n "${_bkp_managed[$f]:-}" ]] && continue
          print -r -- "F"$'\t'"$f"
        done
      else
        log_warn "bkp: git enumeration failed in $node — over-capturing (ignore rules skipped)"
        for entry in "$node"/*(DN); do
          [[ "$entry" == "$node/.git" ]] && continue
          bkp::manifest::walk "$entry"
        done
      fi
      return 0
    elif [[ -d "$node/.git" ]]; then
      # A real .git dir that git can't use (corrupt repo, broken git binary):
      # capture the tree but never the pack store.
      log_warn "bkp: unusable git repo at $node — over-capturing (ignore rules skipped)"
      for entry in "$node"/*(DN); do
        [[ "$entry" == "$node/.git" ]] && continue
        bkp::manifest::walk "$entry"
      done
      return 0
    fi
    # Broken gitFILE (vendored tarballs ship submodule gitfiles pointing at
    # nonexistent gitdirs): not a repo at all — quiet plain walk below.
  fi
  for entry in "$node"/*(DN); do
    bkp::manifest::walk "$entry"
  done
}

# bkp::manifest::sweep <manifest>
# Resolve the manifest into a mixed F/R stream (spec §2):
#   capture = roots − deny − chezmoi-managed − per-repo gitignored
# Missing roots are skipped (spec §11); chezmoi filter failure over-captures.
bkp::manifest::sweep() {
  local manifest="$1"
  bkp::manifest::json "$manifest" >/dev/null || return 2

  local -a _bkp_deny=()
  local deny_out
  deny_out=$(bkp::manifest::deny "$manifest") || return 2
  [[ -n "$deny_out" ]] && _bkp_deny=(${(f)deny_out})
  # The backup's own state dir is ALWAYS denied, in code: the repo must
  # never capture itself, and scrub sessions mount the repository via
  # FUSE under sessions/. WIP bundles still ride along — capture::run
  # re-appends $BKP_WIP_DIR explicitly after the sweep.
  _bkp_deny+=("$BKP_STATE_DIR")

  local -A _bkp_managed=()
  if bkp::manifest::chezmoi_excluded "$manifest"; then
    local managed_out mline
    if managed_out=$(bkp::chezmoi::managed 2>/dev/null); then
      for mline in ${(f)managed_out}; do
        _bkp_managed[$mline]=1
      done
    else
      log_warn "bkp: chezmoi filter unavailable — over-capturing managed files"
    fi
  fi

  local root _bkp_bundle _bkp_warn _bkp_root_dev REPLY
  while IFS=$'\t' read -r root _bkp_bundle _bkp_warn; do
    [[ -e "$root" || -h "$root" ]] || continue
    bkp::fs::device "$root"
    _bkp_root_dev="$REPLY"
    bkp::manifest::walk "$root"
  done < <(bkp::manifest::roots "$manifest")
}

# bkp::manifest::scoped_files <manifest> <scope>
# The CAPTURABLE files under one scope dir, per the sweep's exact rules
# (deny globs + always-denied state dir + chezmoi-managed + per-repo
# gitignore + no filesystem crossing). This is what "the backup owns"
# inside <scope> — the diff lens compares live against snapshots through
# this filter so exclusions don't render as phantom additions.
bkp::manifest::scoped_files() {
  local manifest="$1" scope="$2"
  bkp::manifest::json "$manifest" >/dev/null || return 2

  local -a _bkp_deny=()
  local deny_out
  deny_out=$(bkp::manifest::deny "$manifest") || return 2
  [[ -n "$deny_out" ]] && _bkp_deny=(${(f)deny_out})
  _bkp_deny+=("$BKP_STATE_DIR")

  local -A _bkp_managed=()
  if bkp::manifest::chezmoi_excluded "$manifest"; then
    local managed_out mline
    if managed_out=$(bkp::chezmoi::managed 2>/dev/null); then
      for mline in ${(f)managed_out}; do
        _bkp_managed[$mline]=1
      done
    else
      log_warn "bkp: chezmoi filter unavailable — over-capturing managed files"
    fi
  fi

  local _bkp_bundle="" _bkp_warn="" _bkp_root_dev REPLY
  bkp::fs::device "$scope"
  _bkp_root_dev="$REPLY"
  bkp::manifest::walk "$scope" | awk -F'\t' '$1 == "F" { print $2 }'
}

# bkp::manifest::files <manifest> — the resolved --files-from list.
bkp::manifest::files() {
  setopt local_options pipe_fail
  bkp::manifest::sweep "$1" | awk -F'\t' '$1 == "F" { print $2 }'
}

# bkp::manifest::repos <manifest>
# The bundle plan: <repo>\t<bundle_unpushed>\t<untracked_warn_size> per repo
# the sweep entered. Capture (Phase 3) decides what to do with the flags.
bkp::manifest::repos() {
  setopt local_options pipe_fail
  bkp::manifest::sweep "$1" | awk -F'\t' '$1 == "R" { print $2 "\t" $3 "\t" $4 }'
}

# ── Capture + Storage ────────────────────────────────────────────────────────

BKP_CONFIG="${BKP_CONFIG:-$HOME/.config/backup/config.toml}"

# bkp::config::json [<file>]
# The local-only deployment config as JSON (staging + targets + secret).
bkp::config::json() {
  local file="${1:-$BKP_CONFIG}"
  [[ -f "$file" ]] || {
    log_error "bkp: config not found: $file (copy config.toml.example and edit)"
    return 2
  }
  yq -p toml -o json '.' "$file" 2>/dev/null || {
    log_error "bkp: unparseable config: $file"
    return 2
  }
}

# bkp::config::staging_path [<file>] — the staging repo path, ~ expanded.
bkp::config::staging_path() {
  local json val
  json=$(bkp::config::json "$@") || return 2
  # capture-then-print: jq -e still writes "null" to stdout on a missing key
  val=$(jq -er --arg home "$HOME" '.staging.path | sub("^~"; $home)' <<<"$json" 2>/dev/null) || {
    log_error "bkp: config missing [staging].path"
    return 2
  }
  print -r -- "$val"
}

# bkp::config::password_command [<file>]
# The command that resolves the repo passphrase (1Password via
# system-secrets) — the command string only, never the secret itself.
bkp::config::password_command() {
  local json val
  json=$(bkp::config::json "$@") || return 2
  val=$(jq -er '.staging.password_command' <<<"$json" 2>/dev/null) || {
    log_error "bkp: config missing [staging].password_command"
    return 2
  }
  print -r -- "$val"
}

# bkp::time::epoch <rfc3339>
# RFC3339 -> unix epoch, in REPLY. Pure integer arithmetic (civil-days
# algorithm) — no strptime, so no platform/TZ variance. Fractional seconds
# and Z / ±hh:mm / ±hhmm offsets accepted.
bkp::time::epoch() {
  local ts="$1"
  local d="${ts%%T*}" rest="${ts#*T}" time="" off="" sign=""
  if [[ "$rest" == "$ts" || "$d" != <->-<->-<-> ]]; then
    log_error "bkp: bad timestamp '$ts'"
    return 2
  fi
  case "$rest" in
    *Z)  time="${rest%Z}" ;;
    *+*) time="${rest%+*}" off="${rest##*+}" sign='-' ;;  # east of UTC: subtract
    *-*) time="${rest%-*}" off="${rest##*-}" sign='+' ;;  # west of UTC: add
    *)   time="$rest" ;;
  esac
  time="${time%%.*}"
  local -a T=(${(s.:.)time}) D=(${(s:-:)d})
  if (( ${#T} != 3 )) || [[ "$T[1]$T[2]$T[3]" != <-> ]]; then
    log_error "bkp: bad timestamp '$ts'"
    return 2
  fi
  local y=$(( 10#$D[1] )) m=$(( 10#$D[2] )) dd=$(( 10#$D[3] ))
  local offsec=0
  if [[ -n "$off" ]]; then
    off="${off//:/}"
    offsec=$(( 10#${off[1,2]} * 3600 + 10#${off[3,4]:-0} * 60 ))
  fi
  local era yoe doy doe days
  (( m <= 2 )) && (( y-- ))
  (( era = y / 400 ))
  (( yoe = y - era * 400 ))
  (( doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + dd - 1 ))
  (( doe = yoe * 365 + yoe / 4 - yoe / 100 + doy ))
  (( days = era * 146097 + doe - 719468 ))
  REPLY=$(( days * 86400 + 10#$T[1] * 3600 + 10#$T[2] * 60 + 10#$T[3] ))
  [[ "$sign" == '-' ]] && REPLY=$(( REPLY - offsec ))
  [[ "$sign" == '+' ]] && REPLY=$(( REPLY + offsec ))
  return 0
}

# bkp::restic::parse_snapshots
# `restic snapshots --json` on stdin -> "<id>\t<epoch>" per line (the
# bkp::thin input format). A null/empty snapshot list is fine (empty output).
bkp::restic::parse_snapshots() {
  local rows
  rows=$(jq -r '(. // [])[] | [.id, .time] | @tsv' 2>/dev/null) || {
    log_error "bkp: unparseable snapshot list"
    return 2
  }
  [[ -z "$rows" ]] && return 0
  local row REPLY
  for row in ${(f)rows}; do
    bkp::time::epoch "${row##*$'\t'}" || return 2
    print -r -- "${row%%$'\t'*}"$'\t'"$REPLY"
  done
}

# bkp::restic::parse_snapshots_tree
# Like parse_snapshots, but keeps the root tree id: "<id>\t<epoch>\t<tree>".
# A snapshot with no tree field yields an empty 3rd column so the scrub
# dedup fails open (never collapses a snapshot of unknown content).
bkp::restic::parse_snapshots_tree() {
  local rows
  rows=$(jq -r '(. // [])[] | [.id, .time, (.tree // "")] | @tsv' 2>/dev/null) || {
    log_error "bkp: unparseable snapshot list"
    return 2
  }
  [[ -z "$rows" ]] && return 0
  local row id time tree mid REPLY
  for row in ${(f)rows}; do
    id="${row%%$'\t'*}"
    tree="${row##*$'\t'}"
    mid="${row#*$'\t'}"; time="${mid%$'\t'*}"
    bkp::time::epoch "$time" || return 2
    print -r -- "$id"$'\t'"$REPLY"$'\t'"$tree"
  done
}

# --- snapshot addressing (spec 2026-07-04 §4) ---------------------------

# bkp::snap::ladder [<config>]
# Capture snapshots newest-first as <full-id>\t<epoch>. bkp-undo snapshots
# are restore plumbing, not points on the time ladder — excluded.
bkp::snap::ladder() {
  local staging
  staging=$(bkp::config::staging_path "$@") || return 2
  bkp::restic "$staging" snapshots --json |
    jq '[(. // [])[] | select(((.tags // []) | index("bkp-undo")) | not)]' |
    bkp::restic::parse_snapshots | sort -t$'\t' -k2,2 -rn
}

# bkp::snap::tree_sig <dir>
# REPLY = a cksum over "<size> <mtime> <relpath>" of every regular file under
# <dir> (files only — dir mtimes are noisy and not rsync-comparable). Paths
# are <dir>-relative so a mounted rung's anchor subtree and the live tree
# sign identically when their content matches. A missing/empty <dir> yields
# the stable empty signature. size+mtime is the same notion of change the
# live-diff prescreen (bkp::changeset::live_view) uses, so two rungs sign
# alike exactly when the diff lens would show them alike.
bkp::snap::tree_sig() {
  local dir="$1" out
  if [[ -d "$dir" ]]; then
    # find -exec stat + : one stat process for the whole subtree; strip the
    # "./" that `find .` prefixes so the relpath matches live_sig's.
    out=$( cd "$dir" && find . -type f -exec stat -f '%z %m %N' {} + 2>/dev/null |
      sed 's# \./# #' | sort | cksum )
  else
    out=$(print -n | cksum)
  fi
  REPLY="${out%% *}"
}

# bkp::snap::live_sig <scope> [<manifest>]
# REPLY = tree_sig's signature for the CAPTURE-FILTERED live tree under
# <scope> — the same file set (bkp::manifest::scoped_files) and "<size>
# <mtime> <relpath>" format the mounted rungs are signed with, so a rung
# equals live exactly when the diff lens would render it empty. Filtering
# matters: snapshots only hold capturable files, so an unfiltered live walk
# would never match. If the file set is uncomputable the signature is made
# unique so no rung is wrongly dropped as "identical to live".
bkp::snap::live_sig() {
  local scope="$1" manifest="${2:-$BKP_MANIFEST}" files out
  files=$(bkp::manifest::scoped_files "$manifest" "$scope") || { REPLY="live-uncomputable"; return 0 }
  out=$(
    for f in ${(f)files}; do
      [[ -n "$f" ]] || continue
      st=$(stat -f '%z %m' "$f" 2>/dev/null) || continue
      print -r -- "$st ${f#$scope/}"
    done | sort | cksum
  )
  REPLY="${out%% *}"
}

# bkp::snap::ladder_scrub <scope> [<mnt-ids>]
# The scrub ladder: bkp::snap::ladder with runs of unchanged snapshots
# collapsed, so a snapshot that adds nothing over its older neighbour is not
# its own rung. The OLDEST of each unchanged run survives (the rung sits at
# the change boundary). Output is the same "<id>\t<epoch>" newest-first shape
# ladder consumers expect. Two tiers:
#   1. whole-tree — drop a snapshot whose root tree equals its older
#      neighbour's (the entire backup is unchanged). Free, from the one
#      snapshots call; a snapshot with no tree id is never collapsed here.
#   2. scope-aware — when <scope> is a directory anchor AND the session repo
#      is mounted at <mnt-ids> (…/mnt/ids), also drop a snapshot whose subtree
#      UNDER <scope> is unchanged from its older neighbour (something changed
#      elsewhere in the backup, but not here), AND drop any snapshot whose
#      subtree equals the LIVE tree — those render as an empty diff, since the
#      lens diffs each rung against live. Signatures come from walking the
#      one session-long mount (index loaded once), not a restic call per
#      snapshot. Skipped without a mount ("/" anchor, a file anchor, or the
#      FUSE-less fallback), where tier 1 still applies.
bkp::snap::ladder_scrub() {
  local scope="${1:-}" mnt_ids="${2:-}" staging rows
  staging=$(bkp::config::staging_path) || return 2
  rows=$(bkp::restic "$staging" snapshots --json |
    jq '[(. // [])[] | select(((.tags // []) | index("bkp-undo")) | not)]' |
    bkp::restic::parse_snapshots_tree | sort -t$'\t' -k2,2 -rn) || return 2
  [[ -n "$rows" ]] || return 0
  # Tier 1: collapse adjacent identical root trees.
  local -a lines=("${(@f)rows}") kept=()
  local i n=${#lines} line tree next_tree
  for (( i = 1; i <= n; i++ )); do
    line="${lines[i]}"
    tree="${line##*$'\t'}"
    if (( i < n )) && [[ -n "$tree" ]]; then
      next_tree="${lines[i+1]##*$'\t'}"
      [[ "$tree" == "$next_tree" ]] && continue
    fi
    kept+=("$line")   # still <id>\t<epoch>\t<tree>
  done
  # Tier 2: collapse adjacent identical anchored subtrees + drop == live.
  if [[ -n "$scope" && "$scope" != "/" && -d "$scope" && -n "$mnt_ids" && -d "$mnt_ids" ]]; then
    local -a sigs=() scoped=()
    local REPLY f st id sid m=${#kept} live_sig
    for line in "${kept[@]}"; do
      id="${line%%$'\t'*}" sid="${id[1,8]}"
      bkp::snap::tree_sig "$mnt_ids/$sid$scope"
      sigs+=("$REPLY")
    done
    bkp::snap::live_sig "$scope"; live_sig="$REPLY"
    for (( i = 1; i <= m; i++ )); do
      (( i < m )) && [[ "${sigs[i]}" == "${sigs[i+1]}" ]] && continue   # unchanged from older rung
      [[ "${sigs[i]}" == "$live_sig" ]] && continue                     # identical to live -> empty diff
      scoped+=("${kept[i]}")
    done
    # A dir static across all of history AND equal to live drops every rung.
    # Keep the oldest so the session still opens (the lens renders its empty
    # state gracefully) instead of failing as "no snapshots yet".
    (( ${#scoped} )) || scoped=("${kept[-1]}")
    kept=("${scoped[@]}")
  fi
  for line in "${kept[@]}"; do
    print -r -- "${line%$'\t'*}"   # strip the tree column -> <id>\t<epoch>
  done
}

# bkp::snap::expand <prefix> <ladder> — REPLY = full id for a hex prefix.
bkp::snap::expand() {
  local prefix="$1" ladder="$2" line
  for line in ${(f)ladder}; do
    if [[ "${line%%$'\t'*}" == "$prefix"* ]]; then
      REPLY="${line%%$'\t'*}"
      return 0
    fi
  done
  log_error "bkp: no snapshot matching '$prefix'"
  return 2
}

# bkp::snap::resolve_since <when> [<config>]
# REPLY = full id of the newest snapshot at or before <when>.
# <when>: yesterday | <N><m|h|d|w> | YYYY-MM-DD | snapshot id (8-64 hex).
bkp::snap::resolve_since() {
  local when="$1"; shift
  local ladder cutoff
  ladder=$(bkp::snap::ladder "$@") || return 2
  [[ -n "$ladder" ]] || { log_error "bkp: no snapshots yet"; return 2 }
  if [[ "$when" == yesterday ]]; then
    cutoff=$(( EPOCHSECONDS - 86400 ))
  elif [[ "$when" =~ '^[0-9]+[mhdw]$' ]]; then
    bkp::duration "$when" || return 2
    cutoff=$(( EPOCHSECONDS - REPLY ))
  elif [[ "$when" =~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' ]]; then
    strftime -r -s cutoff '%Y-%m-%d' "$when" 2>/dev/null || {
      log_error "bkp: unparseable date: $when"
      return 2
    }
  elif [[ "$when" =~ '^[0-9a-f]{8,64}$' ]]; then
    bkp::snap::expand "$when" "$ladder"
    return $?
  else
    log_error "bkp: cannot parse '$when' (yesterday | 3h/2d/1w | YYYY-MM-DD | snapshot id)"
    return 2
  fi
  local line id epoch oldest=""
  for line in ${(f)ladder}; do
    id="${line%%$'\t'*}" epoch="${line##*$'\t'}"
    oldest="$id"
    if (( epoch <= cutoff )); then
      REPLY="$id"
      return 0
    fi
  done
  log_error "bkp: no snapshot at or before '$when' — oldest is ${oldest[1,8]}"
  return 2
}

# --- changeset synthesis (spec 2026-07-04 §3) ---------------------------

# bkp::changeset::guard <workdir> <max-bytes>
# Replace files above the size threshold (either side) with a small stub so
# the patch stays light. The stub carries size + cksum so two changed
# oversized versions still differ; every skip is logged — never silent.
bkp::changeset::guard() {
  local work="$1" max="$2" f
  local -a st
  for f in "$work"/{a,b}/**/*(.NoN); do
    zstat -A st +size -- "$f" 2>/dev/null || continue
    (( st[1] > max )) || continue
    local sum
    sum=$(cksum "$f")
    log_warn "bkp: changes: ${f#$work/[ab]} is ${st[1]} bytes — over the size threshold, content skipped"
    print -r -- "[tm] content skipped (over changes.size_threshold): ${st[1]} bytes, cksum ${sum%% *}" > "$f"
  done
  return 0
}

# bkp::changeset::patch <snapA> <snapB> [<scope>]
# Git-style patch between two snapshots, scoped to <scope> (default /).
# Only changed files are materialized (restic diff → include-file restore
# of each side), then `git diff --no-index` from a workdir whose subdirs
# are literally named a and b — with --src-prefix=/--dst-prefix= the dir
# names become the conventional a/ b/ labels, already live-relative.
bkp::changeset::patch() {
  setopt local_options pipe_fail
  local a="$1" b="$2" scope="${3:-/}"
  local staging thresh work
  staging=$(bkp::config::staging_path) || return 2
  thresh=$(bkp::config::change_size_threshold) || return 2
  work=$(mktemp -d "${TMPDIR:-/tmp}/bkp-changes.XXXXXX") || return 1
  {
    bkp::restic "$staging" diff --json "$a" "$b" |
      jq -r --arg s "${scope%/}/" 'select(.message_type == "change")
        | select(.modifier != "U")
        | select(.path | endswith("/") | not)
        | select(($s == "/") or (.path | startswith($s)) or (.path == ($s | rtrimstr("/"))))
        | .path' > "$work/include" || return 1
    [[ -s "$work/include" ]] || return 0
    mkdir -p "$work/a" "$work/b"
    bkp::restic "$staging" restore "$a" --target "$work/a" \
      --include-file "$work/include" --quiet || return 1
    bkp::restic "$staging" restore "$b" --target "$work/b" \
      --include-file "$work/include" --quiet || return 1
    bkp::changeset::guard "$work" "$thresh"
    local rc=0
    ( cd "$work" &&
      git -c core.quotePath=false diff --no-index \
        --src-prefix= --dst-prefix= -- a b ) || rc=$?
    (( rc <= 1 )) || return 1
    return 0
  } always {
    rm -rf "$work"
  }
}

# bkp::changeset::relabel <past-root> [<view-root> <live-root>]
# Rewrite --no-index header labels: strip the mount rung root from the
# left side — and, when the live side was diffed through a cleaned view
# (hardlink farm without sockets/fifos), map the view root back to the
# real live root — so both labels are live-absolute. Literal string
# replace on header lines only (paths may contain regex metacharacters).
bkp::changeset::relabel() {
  local past="${1#/}" view="${2:-}" live="${3:-}"
  view="${view#/}" live="${live#/}"
  awk -v past="$past" -v view="$view" -v live="$live" '
    function fix(s, from, to,  i) {
      i = index(s, from)
      if (i) s = substr(s, 1, i - 1) to substr(s, i + length(from))
      return s
    }
    /^(diff --git |--- |\+\+\+ |Binary files )/ {
      if (view != "") {
        $0 = fix($0, "a/" view "/", "a/" live "/")
        $0 = fix($0, "b/" view "/", "b/" live "/")
      }
      $0 = fix($0, "a/" past "/", "a/")
      $0 = fix($0, "b/" past "/", "b/")
    }
    { print }
  '
}

# bkp::changeset::live_view <scope> <dest> [<manifest>]
# Build (or reuse) the capture-filtered live view at <dest>: the scope
# swept through the capture rules (deny + chezmoi-managed + gitignored),
# survivors hardlinked under <dest>/tree via rsync --files-from +
# --link-dest (near-free). A <dest>/.ready stamp marks a complete build;
# callers rm -rf <dest> to invalidate (e.g. after an apply). The stamp
# lives OUTSIDE tree/ so it can never appear in a diff.
bkp::changeset::live_view() {
  local scope="$1" dest="$2" manifest="${3:-$BKP_MANIFEST}"
  [[ -e "$dest/.ready" ]] && return 0
  rm -rf "$dest"
  # Pathology cap: a huge scope (~/.local/share…) means a whole-tree
  # walk — the 200-rsync incident. Count with an early-exit pipe and
  # refuse, loudly, before the capture-rule sweep even starts.
  local cap="${BKP_TM_LIVEVIEW_MAX_FILES:-50000}" nfiles
  nfiles=$(find "$scope" -not -type d 2>/dev/null | head -n $(( cap + 1 )) | wc -l | tr -d ' ')
  if (( nfiles > cap )); then
    log_error "bkp: $scope holds over $cap files — too large for live-diff synthesis (BKP_TM_LIVEVIEW_MAX_FILES raises the cap)"
    return 1
  fi
  local files
  files=$(bkp::manifest::scoped_files "$manifest" "$scope") || return 1
  local -a live_files=()
  [[ -n "$files" ]] && live_files=(${(f)files})
  mkdir -p "$dest/tree"
  if (( ${#live_files} )); then
    print -rl -- "${live_files[@]#$scope/}" |
      rsync -lpt --files-from=- --link-dest="$scope" "$scope/" "$dest/tree/" 2>/dev/null
    local rrc=$?
    # 23/24 = partial transfer / files vanished mid-copy — routine on
    # a live tree (files churn under us); the view is still a usable
    # copy of everything that held still. Anything else is fatal.
    if (( rrc != 0 && rrc != 23 && rrc != 24 )); then
      rm -rf "$dest"
      log_error "bkp: could not build a clean live view for $scope (rsync rc=$rrc)"
      return 1
    fi
  fi
  touch "$dest/.ready"
}

# bkp::changeset::patch_live <mount-rung-root> <scope> [<manifest>]
# Patch of the mounted snapshot rung vs the live filesystem, scoped. The
# live side is FILTERED through the capture rules (bkp::changeset::
# live_view): snapshots only ever contain capturable files, so a raw
# dir-vs-dir diff drowns real changes in "added" noise for everything
# capture deliberately skips. A file scope is diffed directly (an
# explicitly anchored file is shown regardless of capture rules).
#
# Perf: within a session the live side never changes between rungs —
# BKP_LIVEVIEW_REUSE names a persistent view dir that is built once and
# reused (invalidated by rm -rf, e.g. after an apply). And instead of
# content-reading every captured file through FUSE, an rsync dry-run
# prescreens by size+mtime (the same unchanged-heuristic restic itself
# uses for incremental backups) and only the candidates get a real
# content diff — per-rung cost tracks CHANGES, not tree size.
# BKP_LIVEVIEW_DIR overrides the throwaway view parent when REUSE is
# unset.
bkp::changeset::patch_live() {
  setopt local_options pipe_fail
  local rung="$1" scope="$2" manifest="${3:-$BKP_MANIFEST}"
  if [[ ! -d "$scope" ]]; then
    local frc=0 fout
    fout=$(git -c core.quotePath=false diff --no-index -- "$rung$scope" "$scope" 2>/dev/null) || frc=$?
    (( frc <= 1 )) || {
      log_error "bkp: git diff failed for $scope"
      return 1
    }
    [[ -n "$fout" ]] || return 0
    print -r -- "$fout" | bkp::changeset::relabel "$rung"
    return 0
  fi
  local view own=0
  if [[ -n "${BKP_LIVEVIEW_REUSE:-}" ]]; then
    view="$BKP_LIVEVIEW_REUSE"
  else
    view=$(mktemp -d "${BKP_LIVEVIEW_DIR:-${TMPDIR:-/tmp}}/bkp-liveview.XXXXXX") || return 1
    rm -rf "$view"   # live_view owns the dest layout
    own=1
  fi
  {
    bkp::changeset::live_view "$scope" "$view" "$manifest" || return 1
    local vtree="$view/tree" past="$rung$scope"
    # Prescreen: rsync dry-run compares size+mtime only (no content
    # reads) and names what differs; --delete surfaces live-deleted
    # files. FUSE getattrs are ~10x cheaper than reads.
    local -a cands=()
    if [[ -d "$past" ]]; then
      local plist prc=0
      plist=$(rsync -rlptn --delete --out-format="%o|%n"         "$vtree/" "$past/" 2>/dev/null) || prc=$?
      if (( prc != 0 && prc != 23 && prc != 24 )); then
        log_error "bkp: prescreen failed for $scope (rsync rc=$prc)"
        return 1
      fi
      local line op rel
      for line in ${(f)plist}; do
        op="${line%%|*}" rel="${line#*|}"
        [[ "$op" == send || "$op" == del. ]] || continue
        # directories are creation/deletion NOISE here; their files
        # arrive as their own entries
        [[ -d "$vtree/$rel" && ! -h "$vtree/$rel" ]] && continue
        [[ -d "$past/$rel" && ! -h "$past/$rel" ]] && continue
        cands+=("${rel%/}")
      done
    else
      # Nothing captured under the scope in that snapshot: every view
      # file is an addition since then. ^/ = anything but a directory —
      # the view holds only files and symlinks, and glob qualifiers AND
      # together, so (.@) would match nothing at all.
      local f
      for f in "$vtree"/**/*(DN^/); do
        cands+=("${f#$vtree/}")
      done
    fi
    (( ${#cands} )) || return 0
    # Degenerate rungs (near-everything changed): one whole-tree diff
    # beats thousands of per-file forks. The threshold is a knob so the
    # spec suite can force either path and pin them to each other.
    local rc=0 out
    if (( ${#cands} > ${BKP_TM_PRESCREEN_MAX:-400} )); then
      # A rung that never captured the scope has no $past to diff
      # against — stand in an empty tree so everything renders added.
      local base="$past"
      [[ -d "$base" ]] || { base=$(mktemp -d) || return 1 }
      out=$(git -c core.quotePath=false diff --no-index -- "$base" "$vtree" 2>/dev/null) || rc=$?
      [[ "$base" == "$past" ]] || rmdir "$base" 2>/dev/null
      (( rc <= 1 )) || {
        log_error "bkp: git diff failed for $scope"
        return 1
      }
      [[ -n "$out" ]] || return 0
      print -r -- "$out" | bkp::changeset::relabel "$rung" "$vtree" "$scope"
      return 0
    fi
    # NB: rel is already local above — re-`local`ing an existing local
    # makes zsh PRINT its value (typeset semantics), polluting the patch.
    # (o) sorts candidates: same file order as a whole-tree git diff,
    # so both paths emit byte-identical patches (pinned by the spec).
    local a b piece
    for rel in "${(o)cands[@]}"; do
      a="$past/$rel" b="$vtree/$rel"
      [[ -e "$a" || -h "$a" ]] || a=/dev/null
      [[ -e "$b" || -h "$b" ]] || b=/dev/null
      rc=0
      piece=$(git -c core.quotePath=false diff --no-index -- "$a" "$b" 2>/dev/null) || rc=$?
      (( rc <= 1 )) || continue
      # -z||print, NOT -n&&print: a candidate whose content held still
      # (mtime-only churn) yields an empty piece, and if it lands LAST
      # the &&-form exits the loop with status 1 — under pipe_fail that
      # fails the whole synthesis and the refresh throws a good patch
      # away. Exactly what blanked the lens on real rungs.
      [[ -z "$piece" ]] || print -r -- "$piece"
    done | bkp::changeset::relabel "$rung" "$vtree" "$scope"
  } always {
    (( own )) && rm -rf "$view" || :
  }
}

BKP_STATE_DIR="${BKP_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/terminal-backup}"
BKP_WIP_DIR="${BKP_WIP_DIR:-$BKP_STATE_DIR/wip}"
# Wall-clock ceiling for a single scheduled capture's `restic backup`. Kept
# well below the 30-min (1800s) schedule cadence so a wedged run self-aborts
# with room to spare and the NEXT launchd tick starts clean — a hang dies in
# ~5min, not ~20, so a burst of wedges can't chew a whole cycle before the
# heartbeat recovers. A normal capture of tens of thousands of local files
# finishes in seconds; this only ever trips on a genuine hang.
BKP_CAPTURE_TIMEOUT="${BKP_CAPTURE_TIMEOUT:-300}"

# bkp::size_bytes <spec> — "50m"/"2g"/"512k"/plain-bytes -> bytes in REPLY.
bkp::size_bytes() {
  local spec="${(L)1}" n="${1%?}"
  if [[ "$spec" == <-> ]]; then
    REPLY=$(( 10#$spec ))
    return 0
  fi
  if [[ "$n" != <-> ]]; then
    log_error "bkp: bad size '$1' (want <n>[k|m|g])"
    return 2
  fi
  case "$spec" in
    *k) REPLY=$(( 10#$n * 1024 )) ;;
    *m) REPLY=$(( 10#$n * 1048576 )) ;;
    *g) REPLY=$(( 10#$n * 1073741824 )) ;;
    *)
      log_error "bkp: bad size '$1' (want <n>[k|m|g])"
      return 2
      ;;
  esac
}

# bkp::project::id <repo>
# Stable sidecar basename: <dirname>-<12 hex of the path>. Hashing via git
# itself — git is guaranteed present wherever bundles are being made.
bkp::project::id() {
  local hash
  hash=$(print -rn -- "$1" | git hash-object --stdin 2>/dev/null) || return 1
  REPLY="${1:t}-${hash[1,12]}"
}

# bkp::project::meta <repo>
# Reconstruction metadata (spec §2 D): drives restore-project
# (clone origin -> fetch bundle -> overlay tree -> re-apply stashes).
bkp::project::meta() {
  local repo="$1" branch head
  branch=$(git -C "$repo" symbolic-ref --short -q HEAD 2>/dev/null) || branch=""   # detached
  head=$(git -C "$repo" rev-parse -q --verify HEAD 2>/dev/null) || head=""  # unborn
  jq -n \
    --arg path "$repo" --arg branch "$branch" --arg head "$head" \
    --arg remotes "$(git -C "$repo" remote -v 2>/dev/null)" \
    --arg status "$(git -C "$repo" status --porcelain 2>/dev/null)" \
    --arg stashes "$(git -C "$repo" stash list 2>/dev/null)" \
    '{path: $path, branch: $branch, head: $head,
      remotes: ($remotes | split("\n") | map(select(length > 0))),
      status:  ($status  | split("\n") | map(select(length > 0))),
      stashes: ($stashes | split("\n") | map(select(length > 0)))}'
}

# bkp::project::bundle <repo> <out>
# Local-only history: branches + tags (+ the latest stash) minus everything
# any remote already holds. Nothing unpushed -> no bundle (rc 0, stale file
# removed). Older stash entries (stash@{1}+) are reflog-only: enumerated in
# meta.json but not bundled — documented v1 caveat (spec §2 D).
bkp::project::bundle() {
  local repo="$1" out="$2"
  local -a refs=(--branches --tags)
  git -C "$repo" rev-parse -q --verify refs/stash >/dev/null 2>&1 && refs+=(refs/stash)
  local count
  count=$(git -C "$repo" rev-list --count "${refs[@]}" --not --remotes 2>/dev/null) || {
    log_warn "bkp: cannot enumerate history in $repo — skipping bundle"
    return 1
  }
  if (( count == 0 )); then
    rm -f "$out"
    return 0
  fi
  git -C "$repo" bundle create "$out" "${refs[@]}" --not --remotes 2>/dev/null || {
    log_warn "bkp: bundle failed in $repo"
    return 1
  }
}

# bkp::project::warn_large <repo> <size-spec>
# The "about to haul in a 2 GB blob?" tripwire (spec §2 D): flag untracked
# non-ignored files over the per-root guard. Logged, never silent, never fatal.
bkp::project::warn_large() {
  local repo="$1" REPLY
  bkp::size_bytes "$2" || return 2
  local limit=$REPLY f size
  git -C "$repo" ls-files --others --exclude-standard 2>/dev/null |
    while IFS= read -r f; do
      size=$(zstat +size "$repo/$f" 2>/dev/null) || continue
      (( size > limit )) &&
        log_warn "bkp: large untracked file in $repo: $f ($size bytes > $2)"
    done
  return 0
}

# bkp::lock <name> [<timeout>]
# Run-lock, held until the process exits (zsystem flock keeps the fd).
# Default is non-blocking: rc 1 when busy — tick callers coalesce (skip
# the run), never queue. A timeout (seconds) waits that long for the
# holder to finish instead — for callers that must eventually run, like
# the nightly prune.
bkp::lock() {
  local lockfile="$BKP_STATE_DIR/$1.lock"
  mkdir -p "$BKP_STATE_DIR"
  : >> "$lockfile"
  zsystem flock -t "${2:-0}" "$lockfile" 2>/dev/null
}

# bkp::project::sidecar <repo> <bundle_unpushed> <warn_size>
# One repo's history layer: meta.json always, bundle when enabled. Sidecar
# problems warn but never block the file capture (rc 0).
bkp::project::sidecar() {
  local repo="$1" bundle="$2" warn="$3" REPLY
  bkp::project::id "$repo" || {
    log_warn "bkp: cannot id repo $repo — skipping sidecar"
    return 0
  }
  local id="$REPLY"
  mkdir -p "$BKP_WIP_DIR"
  bkp::project::meta "$repo" > "$BKP_WIP_DIR/$id.meta.json"
  if [[ "$bundle" == true ]]; then
    bkp::project::bundle "$repo" "$BKP_WIP_DIR/$id.bundle" || :
  fi
  bkp::project::warn_large "$repo" "$warn" || :
  return 0
}

# bkp::config::targets [<file>]
# TSV per replication target: name\tpath\trole (role: mirror|master,
# default mirror). Path is ~-expanded. Invalid entries are a config error.
bkp::config::targets() {
  local json
  json=$(bkp::config::json "$@") || return 2
  jq -r --arg home "$HOME" '
    (.target // [])[]
    | if (.name == null or .path == null) then error("missing name/path")
      elif ((.role // "mirror") | IN("mirror", "master") | not) then error("bad role")
      else . end
    | [ .name, (.path | sub("^~"; $home)), (.role // "mirror") ]
    | @tsv' <<<"$json" 2>/dev/null || {
    log_error "bkp: invalid [[target]] (need name + path, role mirror|master)"
    return 2
  }
}

# bkp::config::change_size_threshold [<file>]
# [changes].size_threshold (spec 2026-07-04 §3) as bytes on stdout —
# files larger than this are stubbed out of synthesized changeset patches.
bkp::config::change_size_threshold() {
  local json val REPLY
  json=$(bkp::config::json "$@") || return 2
  val=$(jq -er '.changes.size_threshold' <<<"$json" 2>/dev/null) || val="5m"
  bkp::size_bytes "$val" || return 2
  print -r -- "$REPLY"
}

# bkp::target::present <path>
# Present = parent dir exists AND is writable (spec §8). The repo dir itself
# may not exist yet — first reconcile creates it.
bkp::target::present() {
  local parent="${1:h}"
  [[ -d "$parent" && -w "$parent" ]]
}

# bkp::project::restore <repo-path>
# Reconstruct a repo from its sidecar (spec §7): the working-tree FILES are
# assumed already on disk (a restic restore put them back); this rebuilds the
# .git side around them — init + origin fetch, bundle fetch for unpushed
# refs, HEAD/branch/index alignment (mixed reset: the on-disk tree is never
# touched), and stash re-registration. Refuses on an existing .git.
bkp::project::restore() {
  local repo="$1" REPLY
  bkp::project::id "$repo" || return 1
  local meta="$BKP_WIP_DIR/$REPLY.meta.json" bundle="$BKP_WIP_DIR/$REPLY.bundle"
  [[ -f "$meta" ]] || {
    log_error "bkp: no sidecar meta for $repo ($meta)"
    return 2
  }
  if [[ -e "$repo/.git" ]]; then
    log_error "bkp: $repo already has a .git — refusing to reconstruct over it"
    return 3
  fi
  local branch head origin
  branch=$(jq -r '.branch // empty' "$meta")
  head=$(jq -r '.head // empty' "$meta")
  origin=$(jq -r '.remotes[]?
    | select(startswith("origin\t")) | select(endswith("(fetch)"))
    | split("\t")[1] | sub(" \\(fetch\\)$"; "")' "$meta" | head -1)

  mkdir -p "$repo"
  git -C "$repo" init -q || return 1
  if [[ -n "$origin" ]]; then
    git -C "$repo" remote add origin "$origin"
    git -C "$repo" fetch -q origin 2>/dev/null ||
      log_warn "bkp: origin unreachable ($origin) — continuing from the bundle alone"
  fi
  if [[ -f "$bundle" ]]; then
    # --update-head-ok: the fresh init's HEAD already names the branch being
    # fetched; the mixed reset below re-aligns the index right after.
    git -C "$repo" fetch -q --update-head-ok "$bundle" \
      'refs/heads/*:refs/heads/*' 'refs/tags/*:refs/tags/*' 2>/dev/null ||
      log_warn "bkp: bundle fetch failed (missing prerequisites?) — unpushed refs not recovered"
  fi
  [[ -n "$branch" ]] && git -C "$repo" symbolic-ref HEAD "refs/heads/$branch"
  if [[ -n "$head" ]] && git -C "$repo" cat-file -e "$head" 2>/dev/null; then
    git -C "$repo" update-ref "refs/heads/${branch:-main}" "$head" 2>/dev/null || :
    git -C "$repo" reset -q "$head" 2>/dev/null || :
  fi
  if [[ -f "$bundle" ]]; then
    local stash_sha
    stash_sha=$(git -C "$repo" bundle list-heads "$bundle" 2>/dev/null |
      awk '$2 == "refs/stash" {print $1}')
    if [[ -n "$stash_sha" ]]; then
      git -C "$repo" fetch -q "$bundle" refs/stash 2>/dev/null || :
      git -C "$repo" stash store -m "restored by system-backup" "$stash_sha" 2>/dev/null ||
        log_warn "bkp: could not re-register stash $stash_sha"
    fi
  fi
  log_ok "bkp: reconstructed $repo (branch ${branch:-<detached>}, head ${head[1,8]:-none})"
}

# bkp::restic <repo> <args…>
# THE storage seam — every restic invocation goes through here (tests stub
# this function). Repo + passphrase-command via env; the passphrase itself is
# resolved by restic at exec time and never appears in argv or logs.
#
# Optional wall-clock guard: when BKP_RESTIC_TIMEOUT is a positive integer and
# a coreutils `timeout` (or `gtimeout`) is on PATH, the restic run is bounded so
# a wedged process (observed hanging for hours at 0% CPU, ignoring SIGTERM, and
# blocking the whole capture schedule) self-aborts. -k escalates to SIGKILL
# after BKP_RESTIC_KILL_AFTER seconds precisely because a hung restic ignores
# SIGTERM; the timeout binary then exits 124 (TERM) or 137 (KILL), both of which
# read as failure to callers. With no timeout binary the seam degrades to an
# unguarded run so a coreutils-less host still backs up. Callers opt in per
# invocation (capture scopes it to its `backup`) — it is never applied globally,
# so a legitimately long `copy`/`prune`/`restore` is not truncated.
bkp::restic() {
  local repo="$1"; shift
  local pwcmd
  pwcmd=$(bkp::config::password_command) || return 2
  local -a guard=()
  if [[ "${BKP_RESTIC_TIMEOUT:-0}" == <1-> ]]; then
    local tbin
    tbin=$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null)
    [[ -n "$tbin" ]] && guard=("$tbin" -k "${BKP_RESTIC_KILL_AFTER:-30}" "$BKP_RESTIC_TIMEOUT")
  fi
  RESTIC_REPOSITORY="$repo" RESTIC_PASSWORD_COMMAND="$pwcmd" "${guard[@]}" restic "$@"
}

# bkp::capture::ensure_repo <repo>
# First-run init. Encrypted by construction: restic init with a passphrase
# from password_command — there is no unencrypted path through here.
bkp::capture::ensure_repo() {
  local repo="$1"
  bkp::restic "$repo" cat config >/dev/null 2>&1 && return 0
  log_info "bkp: initializing restic repo at $repo"
  mkdir -p "$repo"
  bkp::restic "$repo" init
}

# bkp::capture::thin <repo> <manifest>
# Post-capture retention: snapshots -> pure bkp::thin plan -> restic forget.
# Cheap ref removal only — repack/reclaim is the daily `prune` job (spec §5).
#
# bkp-undo safety-net snapshots (pre-restore captures, spec §7) are excluded
# from the ladder — a one-path undo snapshot must never win a wall-clock cell
# and displace a full capture. They expire on their own clock instead:
# forgotten once older than 7 days.
bkp::capture::thin() {
  local repo="$1" manifest="$2"
  local policy json snaps undo plan
  policy=$(bkp::manifest::thin_policy "$manifest") || return 2
  json=$(bkp::restic "$repo" snapshots --json) || return 2
  snaps=$(print -r -- "$json" |
    jq '[(. // [])[] | select(((.tags // []) | index("bkp-undo")) | not)]' 2>/dev/null |
    bkp::restic::parse_snapshots) || return 2
  undo=$(print -r -- "$json" |
    jq '[(. // [])[] | select((.tags // []) | index("bkp-undo"))]' 2>/dev/null |
    bkp::restic::parse_snapshots) || return 2
  local line
  local -a drop=()
  if [[ -n "$undo" ]]; then
    for line in ${(f)undo}; do
      (( EPOCHSECONDS - ${line##*$'\t'} > 604800 )) && drop+=("${line%%$'\t'*}")
    done
  fi
  if [[ -n "$snaps" ]]; then
    plan=$(print -r -- "$snaps" | bkp::thin "$EPOCHSECONDS" "$policy") || return 2
    for line in ${(f)plan}; do
      [[ "$line" == drop$'\t'* ]] && drop+=("${line#drop$'\t'}")
    done
  fi
  (( ${#drop} )) || return 0
  # --quiet is load-bearing: forget's removed-snapshot table includes a Paths
  # column, and our snapshots record every files-from entry (tens of
  # thousands of paths) — without it each drop dumps them all.
  bkp::restic "$repo" forget --quiet "${drop[@]}" || return 1
  log_info "bkp: retention dropped ${#drop} snapshot(s)"
}

# bkp::restic::snapshot_keys <repo>
# "<raw-id>\t<identity>" per snapshot, identity = original // id. restic
# copy gives copies new ids but stamps `original` — identity comparison is
# what keeps reconcile idempotent (spec §4).
bkp::restic::snapshot_keys() {
  setopt local_options pipe_fail
  bkp::restic "$1" snapshots --json |
    jq -r '(. // [])[] | [.id, (.original // .id)] | @tsv' 2>/dev/null || {
    log_error "bkp: cannot list snapshots in $1"
    return 2
  }
}

# bkp::reconcile::plan <staging_tsv> <target_tsv>
# Pure planner (spec §12 test 7). Inputs are snapshot_keys lines. Emits the
# copy plan converging both repos toward the union:
#   push\t<raw-id>   copy staging -> target
#   pull\t<raw-id>   copy target  -> staging
bkp::reconcile::plan() {
  local -A s_key=() t_key=()
  local line
  for line in ${(f)1}; do s_key[${line##*$'\t'}]="${line%%$'\t'*}"; done
  for line in ${(f)2}; do t_key[${line##*$'\t'}]="${line%%$'\t'*}"; done
  local key
  for key in ${(ko)s_key}; do
    [[ -z "${t_key[$key]:-}" ]] && print -r -- "push"$'\t'"$s_key[$key]"
  done
  for key in ${(ko)t_key}; do
    [[ -z "${s_key[$key]:-}" ]] && print -r -- "pull"$'\t'"$t_key[$key]"
  done
  return 0
}

# bkp::ux::interactive — is a human watching this run?
# BKP_PROGRESS=1/0 overrides (test seam / user escape hatch); default is
# "stderr is a terminal", which is false under launchd.
bkp::ux::interactive() {
  case "${BKP_PROGRESS:-}" in
    1) return 0 ;;
    0) return 1 ;;
  esac
  [[ -t 2 ]]
}

# bkp::spin <title> <outfile> -- <cmd...>
# Run <cmd> with its stdout redirected to <outfile>, animating the shared
# spinner while it works — but ONLY when a human is watching
# (bkp::ux::interactive), so scheduled/piped runs stay silent. Returns <cmd>'s
# exit status. Use it to keep an otherwise-silent long restic op — one we run
# --quiet to suppress its output flood — from looking frozen.
#
# Stdout only: <outfile> is DATA here (the sweep's capture set is parsed
# downstream), so restic's stderr must not be folded into it.
bkp::spin() {
  local title="$1" outfile="$2"; shift 2
  [[ "${1:-}" == -- ]] && shift
  local prog=0
  bkp::ux::interactive && prog=1
  SPIN_PROGRESS="$prog" spin::run "$title" "$outfile" -- "$@"
}

# bkp::capture::run [<manifest>] [<config>]
# One capture tick (spec §4): lock -> ensure staging -> ONE sweep (repo plan
# + file list share the pass) -> git sidecars -> restic backup -> thin.
# Sidecar files are appended to the file list explicitly, so fresh bundles
# ride this very snapshot no matter where BKP_WIP_DIR lives.
#
# Scheduled ticks (launchd) no-op when the last successful capture is still
# inside BKP_CAPTURE_CADENCE — wake/calendar near-misses stay cheap. Set
# BKP_CAPTURE_FORCE=1 (system-backup now) to bypass. When a run proceeds
# while already overdue, a `catchup` heartbeat stamp keeps the prompt banner
# quiet until success or failure.
bkp::capture::run() {
  local manifest="${1:-$BKP_MANIFEST}"
  local BKP_CONFIG="${2:-$BKP_CONFIG}"   # dynamic scope: bkp::restic sees it
  bkp::lock capture || {
    log_info "bkp: capture already running — coalescing"
    return 0
  }

  local hb epoch age=0 overdue=1
  if hb=$(bkp::drift::last capture); then
    epoch="${hb%% *}"
    age=$(( EPOCHSECONDS - epoch ))
    (( age < 0 )) && age=0
    # Slack: the completion stamp lands D seconds (capture duration) AFTER its
    # slot, so a scheduled tick exactly one cadence later sees age = cadence-D
    # and would wrongly no-op — halving the effective cadence. 3/4 of a cadence
    # is comfortably past any real capture duration but well short of the next
    # slot, so a just-finished capture won't double-fire yet a due tick proceeds.
    (( age < BKP_CAPTURE_CADENCE * 3 / 4 )) && overdue=0
  fi
  if (( ! overdue && ! ${BKP_CAPTURE_FORCE:-0} )); then
    log_info "bkp: last capture ${age}s ago (< ${BKP_CAPTURE_CADENCE}s cadence) — skipping"
    return 0
  fi

  local staging
  staging=$(bkp::config::staging_path) || return 2
  bkp::capture::ensure_repo "$staging" || return 1

  # About to do real work while the prompt would otherwise nag: announce
  # catch-up so the banner stays quiet for BKP_CATCHUP_GRACE seconds.
  (( overdue )) && bkp::drift::stamp catchup 0

  local sweep_file files_from run_rc=0
  sweep_file=$(mktemp "${TMPDIR:-/tmp}/bkp-sweep.XXXXXX") || return 1
  files_from=$(mktemp "${TMPDIR:-/tmp}/bkp-files.XXXXXX") || return 1
  {
    # The sweep is the silent minute — narrate it, with a spinner on top
    # when a human is watching and gum is around.
    log_info "bkp: resolving capture set"
    local sweep_rc=0
    bkp::spin "resolving capture set…" "$sweep_file" -- \
      bkp::manifest::sweep "$manifest" || sweep_rc=$?
    if (( sweep_rc )); then
      run_rc=2
      return 2
    fi

    local repo bundle warn nrepos=0
    while IFS=$'\t' read -r repo bundle warn; do
      [[ -z "$repo" ]] && continue
      nrepos=$(( nrepos + 1 ))
      bkp::project::sidecar "$repo" "$bundle" "$warn"
    done < <(awk -F'\t' '$1 == "R" { print $2 "\t" $3 "\t" $4 }' "$sweep_file")

    # File list = swept files minus (possibly stale) wip entries, plus the
    # wip dir as it stands after the sidecars above were (re)written.
    awk -F'\t' -v wip="$BKP_WIP_DIR/" \
      '$1 == "F" && index($2, wip) != 1 { print $2 }' "$sweep_file" > "$files_from"
    local wf
    for wf in "$BKP_WIP_DIR"/*(N.); do
      print -r -- "$wf" >> "$files_from"
    done

    local nfiles
    nfiles=$(( $(wc -l < "$files_from") ))
    log_info "bkp: capturing $nfiles files ($nrepos git repos) -> $staging"

    bkp::restic "$staging" unlock >/dev/null 2>&1 || :   # stale-lock recovery
    # -verbatim is load-bearing: plain --files-from glob-expands every line,
    # so a captured file named "[.md" (tldr pages ship one) aborts the whole
    # backup with Go's "syntax error in pattern". Our list is literal paths.
    # Interactive runs keep restic's native progress display; scheduled runs
    # stay --quiet for the log.
    local -a quiet=(--quiet)
    bkp::ux::interactive && quiet=()
    local backup_rc=0
    # Bound this run so a wedged restic can't stall the whole schedule (see
    # bkp::restic). Scoped to the capture backup only — reconcile/prune/restore
    # keep their unbounded seam.
    BKP_RESTIC_TIMEOUT=$BKP_CAPTURE_TIMEOUT \
      bkp::restic "$staging" backup --files-from-verbatim "$files_from" "${quiet[@]}" || backup_rc=$?
    if (( backup_rc == 3 )); then
      # rc 3 = snapshot CREATED, some sources unreadable (deleted between
      # sweep and read, or permission-denied). A partial snapshot beats none.
      log_warn "bkp: some source files were unreadable — snapshot created without them"
    elif (( backup_rc == 124 || backup_rc == 137 )); then
      # timeout(1) fired: restic exceeded BKP_CAPTURE_TIMEOUT and was killed.
      # Return failure so this run's heartbeat stays stale and the next tick
      # starts clean instead of stacking behind a hang.
      log_error "bkp: capture exceeded ${BKP_CAPTURE_TIMEOUT}s wall-clock — restic killed (wedged run?)"
      run_rc=1
      return 1
    elif (( backup_rc != 0 )); then
      run_rc=1
      return 1
    fi
  } always {
    rm -f "$sweep_file" "$files_from"
    # Failed catch-up: drop the silence marker so the banner can nag again.
    (( run_rc )) && bkp::drift::clear catchup
  }
  # The snapshot exists now — stamp capture fresh BEFORE retention, so a
  # thin failure (retention only) never masks a successful capture.
  bkp::drift::stamp capture 0
  bkp::drift::clear catchup
  log_info "bkp: applying retention"
  bkp::capture::thin "$staging" "$manifest"
}

# ── Reconcile ────────────────────────────────────────────────────────────────

# bkp::restic::copy <src> <dst> <ids…>
# restic copy through the seam. Both repos share one passphrase (spec §8) —
# required, since copy needs credentials for both ends. --quiet suppresses
# copy's per-snapshot "snapshot X of [paths…]" header, which would echo the
# tens of thousands of files-from paths our snapshots record; reconcile logs
# its own pushed/pulled summary instead.
bkp::restic::copy() {
  local src="$1" dst="$2"; shift 2
  local pwcmd
  pwcmd=$(bkp::config::password_command) || return 2
  # Always --quiet: copy's per-snapshot "snapshot X of [paths…]" header echoes
  # every files-from path our snapshots record. Interactive feedback comes from
  # a spinner at the call site instead (bkp::reconcile::one).
  bkp::restic "$dst" copy --from-repo "$src" --from-password-command "$pwcmd" --quiet "$@"
}

# bkp::reconcile::ensure_target <staging> <target>
# First contact with a target: init sharing staging's chunker params so
# `restic copy` preserves dedup and stays idempotent across re-copies (§4).
bkp::reconcile::ensure_target() {
  local staging="$1" target="$2"
  bkp::restic "$target" cat config >/dev/null 2>&1 && return 0
  local pwcmd
  pwcmd=$(bkp::config::password_command) || return 2
  log_info "bkp: initializing target repo at $target"
  mkdir -p "$target"
  bkp::restic "$target" init --from-repo "$staging" \
    --from-password-command "$pwcmd" --copy-chunker-params
}

# bkp::reconcile::one <staging> <name> <path> <role> <manifest>
# Converge one present target toward the union, then apply retention to
# mirrors. A master keeps everything: no forget, ever (deepest archive).
bkp::reconcile::one() {
  local staging="$1" name="$2" tpath="$3" role="$4" manifest="$5"
  bkp::reconcile::ensure_target "$staging" "$tpath" || return 1
  local s_keys t_keys plan
  s_keys=$(bkp::restic::snapshot_keys "$staging") || return 1
  t_keys=$(bkp::restic::snapshot_keys "$tpath") || return 1
  plan=$(bkp::reconcile::plan "$s_keys" "$t_keys")
  local line
  local -a push=() pull=()
  for line in ${(f)plan}; do
    case "$line" in
      push$'\t'*) push+=("${line#push$'\t'}") ;;
      pull$'\t'*) pull+=("${line#pull$'\t'}") ;;
    esac
  done
  # Gate the pull through the LOCAL retention plan (spec §4/§5). Union
  # convergence alone repopulates staging forever: a snapshot capture::thin
  # just dropped still lives on the target, so a naive pull drags it straight
  # back (paired "retention dropped N" + "pulled 1"); and a master holds the
  # whole archive by design, so its pull = every snapshot staging lacks. So:
  # never pull from a master, and otherwise pull only the target-only
  # snapshots the ladder would keep — the ones bkp::thin retains when they sit
  # alongside staging's current set. Push and convergence are untouched.
  if (( ${#pull} )); then
    if [[ "$role" == master ]]; then
      pull=()
    else
      local policy s_pairs t_pairs pl id
      policy=$(bkp::manifest::thin_policy "$manifest") || return 1
      s_pairs=$(bkp::restic "$staging" snapshots --json | bkp::restic::parse_snapshots) || return 1
      t_pairs=$(bkp::restic "$tpath" snapshots --json | bkp::restic::parse_snapshots) || return 1
      local -A t_epoch=()
      for line in ${(f)t_pairs}; do t_epoch[${line%%$'\t'*}]="${line##*$'\t'}"; done
      local -a thin_lines=()
      [[ -n "$s_pairs" ]] && thin_lines=(${(f)s_pairs})
      for id in "${pull[@]}"; do
        [[ -n "${t_epoch[$id]:-}" ]] && thin_lines+=("$id"$'\t'"${t_epoch[$id]}")
      done
      local -A keep=()
      if (( ${#thin_lines} )); then
        pl=$(printf '%s\n' "${thin_lines[@]}" | bkp::thin "$EPOCHSECONDS" "$policy") || return 1
        for line in ${(f)pl}; do
          [[ "$line" == keep$'\t'* ]] && keep[${line#keep$'\t'}]=1
        done
      fi
      local -a filtered=()
      for id in "${pull[@]}"; do
        [[ -n "${keep[$id]:-}" ]] && filtered+=("$id")
      done
      pull=("${filtered[@]}")
    fi
  fi
  if (( ${#push} )); then
    bkp::spin "target '$name': pushing ${#push} snapshot(s)…" /dev/null -- \
      bkp::restic::copy "$staging" "$tpath" "${push[@]}" || return 1
  fi
  if (( ${#pull} )); then
    bkp::spin "target '$name': pulling ${#pull} snapshot(s)…" /dev/null -- \
      bkp::restic::copy "$tpath" "$staging" "${pull[@]}" || return 1
  fi
  if [[ "$role" != master ]]; then
    bkp::capture::thin "$tpath" "$manifest" || return 1
  fi
  log_ok "bkp: target '$name' reconciled (${#push} pushed, ${#pull} pulled)"
}

# bkp::reconcile::run [<manifest>] [<config>]
# One reconcile pass (spec §4): every configured target that is present gets
# converged; absent targets are skipped silently and retried next pass.
bkp::reconcile::run() {
  local manifest="${1:-$BKP_MANIFEST}"
  local BKP_CONFIG="${2:-$BKP_CONFIG}"   # dynamic scope, like capture::run
  bkp::lock reconcile || {
    log_info "bkp: reconcile already running — coalescing"
    return 0
  }
  local staging targets
  staging=$(bkp::config::staging_path) || return 2
  targets=$(bkp::config::targets) || return 2
  [[ -z "$targets" ]] && return 0   # staging-only setup: nothing to do
    # NB: "tpath", not "path" — a lowercase `local path` would shadow zsh's
  # special $path array (tied to $PATH) and wipe command lookup in-scope.
  local name tpath role rc=0
  while IFS=$'\t' read -r name tpath role; do
    [[ -z "$name" ]] && continue
    if ! bkp::target::present "$tpath"; then
      log_info "bkp: target '$name' absent — skipped"
      continue
    fi
    bkp::reconcile::one "$staging" "$name" "$tpath" "$role" "$manifest" || rc=1
  done <<<"$targets"
  bkp::drift::stamp reconcile "$rc"
  return $rc
}

# ── UX helpers ───────────────────────────────────────────────────────────────

# bkp::thin::tier_of <now> <epoch> [<policy>]
# REPLY = grid name of the tier whose age band contains the snapshot — the
# tier label shown by `system-backup list`.
bkp::thin::tier_of() {
  local now="$1" epoch="$2" policy="${3:-$BKP_THIN_DEFAULT_POLICY}"
  local age=$(( now - epoch ))
  (( age < 0 )) && age=0
  local line
  local -a f
  while IFS= read -r line; do
    f=(${(z)line})
    (( ${#f} == 3 )) || continue
    [[ "$f[1]" == '#'* ]] && continue
    (( age >= f[2] )) || continue
    [[ "$f[3]" == - ]] || (( age < f[3] )) || continue
    REPLY="$f[1]"
    return 0
  done <<<"$policy"
  REPLY="?"
  return 1
}

# bkp::ux::age <seconds> — human age in REPLY: 5m / 2h / 3d.
bkp::ux::age() {
  local s=$1
  if (( s < 3600 )); then
    REPLY="$(( s / 60 ))m"
  elif (( s < 172800 )); then
    REPLY="$(( s / 3600 ))h"
  else
    REPLY="$(( s / 86400 ))d"
  fi
}

# bkp::ux::list [<manifest>] [<config>]
# Snapshot rows: <id8>\t<local time>\t<age>\t<tier>.
bkp::ux::list() {
  local manifest="${1:-$BKP_MANIFEST}"
  local BKP_CONFIG="${2:-$BKP_CONFIG}"
  local staging policy snaps
  staging=$(bkp::config::staging_path) || return 2
  policy=$(bkp::manifest::thin_policy "$manifest") || return 2
  snaps=$(bkp::restic "$staging" snapshots --json | bkp::restic::parse_snapshots) || return 2
  [[ -z "$snaps" ]] && return 0
  local line id epoch tier when REPLY now="$EPOCHSECONDS"
  for line in ${(f)snaps}; do
    id="${line%%$'\t'*}" epoch="${line##*$'\t'}"
    bkp::thin::tier_of "$now" "$epoch" "$policy" || :
    tier="$REPLY"
    bkp::ux::age $(( now - epoch ))
    strftime -s when '%Y-%m-%d %H:%M' "$epoch"
    print -r -- "${id[1,8]}"$'\t'"$when"$'\t'"$REPLY"$'\t'"$tier"
  done
}

# bkp::ux::targets [<config>] — presence table: ●/○ name role path.
bkp::ux::targets() {
  local BKP_CONFIG="${1:-$BKP_CONFIG}"
  local targets
  targets=$(bkp::config::targets) || return 2
  [[ -z "$targets" ]] && {
    log_info "bkp: no targets configured"
    return 0
  }
  local name tpath role dot
  while IFS=$'\t' read -r name tpath role; do
    [[ -z "$name" ]] && continue
    if bkp::target::present "$tpath"; then dot="●"; else dot="○"; fi
    print -r -- "$dot"$'\t'"$name"$'\t'"$role"$'\t'"$tpath"
  done <<<"$targets"
}

# bkp::ux::_dirsize <path> — REPLY = human on-disk footprint (du -sh) of the
# repo dir, or "—" when it does not exist yet. This is the true stored size
# (packs + index), and du is effectively free even on a fat repo.
bkp::ux::_dirsize() {
  REPLY="—"
  [[ -d "$1" ]] || return 0
  local out
  out=$(du -sh "$1" 2>/dev/null) || return 0
  REPLY="${out%%$'\t'*}"
}

# bkp::ux::_diskfree <path> — REPLY = human free space (df avail) on the
# volume holding the nearest EXISTING ancestor of <path>, or "—". An absent
# target's repo dir need not exist, so we walk up to a real mountpoint.
bkp::ux::_diskfree() {
  local p="$1" prev=""
  while [[ -n "$p" && ! -e "$p" && "$p" != "$prev" ]]; do
    prev="$p"; p="${p:h}"
  done
  [[ -e "$p" ]] || { REPLY="—"; return 0; }
  local avail
  avail=$(df -h "$p" 2>/dev/null | awk 'NR==2{print $4; exit}') || avail=""
  REPLY="${avail:-—}"
}

# bkp::ux::status [<manifest>] [<config>] — glanceable health + size summary.
# Fast path only: heartbeat freshness (no restic), snapshot span, and each
# copy's on-disk size (du) + volume headroom (df). Logical size / dedup ratio
# scan the repo, so they belong in a --full view or a capture-stamped cache,
# not here.
bkp::ux::status() {
  local manifest="${1:-$BKP_MANIFEST}"
  local BKP_CONFIG="${2:-$BKP_CONFIG}"
  local staging snaps REPLY
  staging=$(bkp::config::staging_path) || return 2
  snaps=$(bkp::restic "$staging" snapshots --json | bkp::restic::parse_snapshots) || return 2

  print -r -- "Terminal Time Machine"
  print

  # ── freshness: heartbeat only, so this stays a single-file read ──
  local now="$EPOCHSECONDS" cad hb epoch rc verdict glyph
  if   (( BKP_CAPTURE_CADENCE < 3600 ));  then cad="$(( BKP_CAPTURE_CADENCE / 60 ))m"
  elif (( BKP_CAPTURE_CADENCE < 86400 )); then cad="$(( BKP_CAPTURE_CADENCE / 3600 ))h"
  else                                         cad="$(( BKP_CAPTURE_CADENCE / 86400 ))d"
  fi
  if hb=$(bkp::drift::last capture); then
    epoch="${hb%% *}"; rc="${hb##* }"
    bkp::ux::age $(( now - epoch ))
    verdict=$(bkp::drift::assess "$now" "$epoch" "$rc" "$BKP_CAPTURE_CADENCE")
    if   [[ -z "$verdict" ]];            then glyph="✓"
    elif [[ "$verdict" == crit$'\t'* ]]; then glyph="✗"
    else                                      glyph="⚠"
    fi
    printf '  %-11s%s %-9s%s\n' capture "$glyph" "$REPLY ago" "every $cad"
  else
    printf '  %-11s%s\n' capture "— never captured"
  fi
  if hb=$(bkp::drift::last reconcile); then
    epoch="${hb%% *}"; rc="${hb##* }"
    bkp::ux::age $(( now - epoch ))
    if (( rc == 0 )); then glyph="✓"; else glyph="✗"; fi
    printf '  %-11s%s %-9s%s\n' reconcile "$glyph" "$REPLY ago" \
      "$( (( rc == 0 )) || print -n 'last pass failed' )"
  fi

  # ── snapshot span: count + how far back a restore can reach ──
  local count=0 newest=0 oldest=0 line e
  for line in ${(f)snaps}; do
    [[ -n "$line" ]] || continue
    # NB: not `(( count++ ))` — post-increment from 0 evaluates to 0, which
    # is exit status 1, and the dispatcher's errexit would kill us here.
    count=$(( count + 1 ))
    e="${line##*$'\t'}"
    (( e > newest )) && newest=$e
    (( oldest == 0 || e < oldest )) && oldest=$e
  done
  if (( count )); then
    bkp::ux::age $(( now - oldest ))
    local span="$REPLY" od nd
    strftime -s od '%Y-%m-%d' "$oldest"
    strftime -s nd '%Y-%m-%d' "$newest"
    printf '  %-11s%-9s%s back · %s → %s\n' snapshots "$count" "$span" "$od" "$nd"
  else
    printf '  %-11s%s\n' snapshots "none yet"
  fi
  print

  # ── copies: staging + every configured target, with size + headroom ──
  printf '  %s %-9s %-7s %8s   %s\n' ' ' copy role 'on disk' free
  bkp::ux::_dirsize "$staging"; local ssize="$REPLY"
  bkp::ux::_diskfree "$staging"; local sfree="$REPLY"
  printf '  %s %-9s %-7s %8s   %s\n' '●' staging local "$ssize" "$sfree"
  local targets name tpath role dot dsz dfr
  targets=$(bkp::config::targets) || return 2
  if [[ -n "$targets" ]]; then
    while IFS=$'\t' read -r name tpath role; do
      [[ -z "$name" ]] && continue
      if bkp::target::present "$tpath"; then
        dot="●"
        bkp::ux::_dirsize "$tpath"; dsz="$REPLY"
        bkp::ux::_diskfree "$tpath"; dfr="$REPLY"
      else
        dot="○"; dsz="—"; dfr="—"
      fi
      printf '  %s %-9s %-7s %8s   %s\n' "$dot" "$name" "$role" "$dsz" "$dfr"
    done <<<"$targets"
  fi
}

# bkp::ux::verify [<config>] — restic check on staging + every present,
# initialized target. rc 1 when any check fails.
bkp::ux::verify() {
  local BKP_CONFIG="${1:-$BKP_CONFIG}"
  local staging targets rc=0
  staging=$(bkp::config::staging_path) || return 2
  targets=$(bkp::config::targets) || return 2
  log_info "bkp: checking staging"
  bkp::restic "$staging" check || rc=1
  local name tpath role
  while IFS=$'\t' read -r name tpath role; do
    [[ -z "$name" ]] && continue
    bkp::target::present "$tpath" || continue
    bkp::restic "$tpath" cat config >/dev/null 2>&1 || continue
    log_info "bkp: checking target '$name'"
    bkp::restic "$tpath" check || rc=1
  done <<<"$targets"
  return $rc
}

# bkp::ux::has_fuse — is a FUSE provider available for `restic mount`?
# BKP_HAS_FUSE=0/1 overrides (test seam / user escape hatch).
bkp::ux::has_fuse() {
  case "${BKP_HAS_FUSE:-}" in
    1) return 0 ;;
    0) return 1 ;;
  esac
  [[ -e /Library/Filesystems/macfuse.fs ||
     -e "/Library/Application Support/fuse-t" ||
     -e /dev/fuse ]]
}

# bkp::mount <repo> <mountpoint>
# Transient `restic mount` for browse: background the mount, wait for the
# FUSE tree to appear, REPLY = mount pid. Caller must bkp::umount.
# The wrapper ignores HUP: closing a zellij pane HUPs the whole pty, and
# a FUSE server that dies WITH the pane leaves the teardown racing a
# corpse — the mount-table entry wedges and rm -rf leaves mnt behind.
# HUP-immune, restic outlives the pane just long enough for the
# teardown's unmount to detach a live mount (restic then exits itself).
bkp::mount() {
  local repo="$1" mp="$2"
  mkdir -p "$mp"
  ( trap '' HUP; bkp::restic "$repo" mount "$mp" ) >/dev/null 2>&1 &
  local pid=$! i
  for (( i = 0; i < 100; i++ )); do
    if [[ -d "$mp/snapshots" ]]; then
      REPLY=$pid
      return 0
    fi
    kill -0 $pid 2>/dev/null || break
    sleep 0.1
  done
  pkill -P $pid 2>/dev/null
  kill $pid 2>/dev/null
  log_error "bkp: restic mount did not come up at $mp"
  return 1
}

# bkp::mounted <mountpoint> — true while the mount-TABLE entry exists.
# The table, not the tree: with a dead FUSE server the tree goes
# inaccessible ([[ -d … ]] false) while the entry stays wedged in place.
bkp::mounted() { mount | grep -qF " on $1 (" }

# bkp::umount <pid> <mountpoint> — end a transient mount, best-effort.
# Clean unmount FIRST — restic exits on its own when the mount detaches.
# Killing is the fallback, and it must hit the whole tree: <pid> is the
# backgrounded wrapper and restic is its CHILD; a killed wrapper leaves
# restic serving the mount, and the eventual forced unmount can wedge the
# vnode (uninterruptible D-state for anything touching the path).
# Every wait probes the mount table (bkp::mounted) — the old tree probe
# declared victory on dead-server wedges and left the entry mounted.
bkp::umount() {
  local pid="$1" mp="$2" i
  umount "$mp" 2>/dev/null || :
  for (( i = 0; i < 20; i++ )); do
    bkp::mounted "$mp" || return 0
    sleep 0.1
  done
  pkill -P "$pid" 2>/dev/null
  kill "$pid" 2>/dev/null
  for (( i = 0; i < 20; i++ )); do
    bkp::mounted "$mp" || return 0
    umount "$mp" 2>/dev/null || :
    sleep 0.1
  done
  diskutil unmount force "$mp" >/dev/null 2>&1 || :
  for (( i = 0; i < 10; i++ )); do
    bkp::mounted "$mp" || return 0
    sleep 0.1
  done
  return 1
}

# bkp::ux::browse_fzf <repo> <path>
# FUSE-less fallback: pick a version of <path> across snapshots and restore
# it AS A COPY next to the live file (<path>.<snapid>) — in-place restores go
# through the undoable `restore` verb, never through the picker.
bkp::ux::browse_fzf() {
  local repo="$1" p="$2"
  local sel
  sel=$(bkp::restic "$repo" find --json -- "$p" 2>/dev/null |
    jq -r '.[]? | (.snapshot[0:8]) as $s | .matches[]? | [$s, .path] | @tsv' 2>/dev/null |
    fzf --with-nth=1 --prompt="versions of ${p:t}> ") || return 1
  [[ -n "$sel" ]] || return 0
  local snap="${sel%%$'\t'*}"
  bkp::restic "$repo" dump "$snap" "${sel##*$'\t'}" > "$p.$snap" || return 1
  log_ok "bkp: restored copy -> $p.$snap"
}

# bkp::ux::diff <path> <snapA> [<snapB>]
# File diff across snapshots (spec §7): dump A (and B; default = the live
# file) and view via hunk, falling back to plain unified diff.
bkp::ux::diff() {
  local p="${1:-}" a="${2:-}" b="${3:-}"
  if [[ -z "$p" || -z "$a" ]]; then
    log_error "bkp: diff needs <path> <snapshotA> [<snapshotB>]"
    return 2
  fi
  if [[ -d "$p" ]]; then
    log_error "bkp: '$p' is a directory — use \`system-backup changes [--since <when>] [<snapA> [<snapB>]] $p\`"
    return 2
  fi
  local staging
  staging=$(bkp::config::staging_path) || return 2
  local ta tb=""
  ta=$(mktemp "${TMPDIR:-/tmp}/bkp-diff.XXXXXX") || return 1
  {
    bkp::restic "$staging" dump "$a" "$p" > "$ta" || return 1
    local right="$p"
    if [[ -n "$b" ]]; then
      tb=$(mktemp "${TMPDIR:-/tmp}/bkp-diff.XXXXXX") || return 1
      bkp::restic "$staging" dump "$b" "$p" > "$tb" || return 1
      right="$tb"
    fi
    # Either viewer: rc 1 means "files differ", which is not a failure here.
    if command -v hunk >/dev/null 2>&1; then
      hunk diff "$ta" "$right" || (( $? == 1 ))
    else
      diff -u "$ta" "$right" || (( $? == 1 ))
    fi
  } always {
    rm -f "$ta" ${tb:+"$tb"}
  }
}

# bkp::ux::changes <snapA> <snapB> [<scope>]
# Render a synthesized changeset: hunk tree-view when available and
# interactive, else the raw patch through the pager.
bkp::ux::changes() {
  local a="$1" b="$2" scope="${3:-/}"
  local patch
  patch=$(mktemp "${TMPDIR:-/tmp}/bkp-changes.XXXXXX") || return 1
  {
    bkp::changeset::patch "$a" "$b" "$scope" > "$patch" || return $?
    if [[ ! -s "$patch" ]]; then
      log_ok "bkp: no changes between ${a[1,8]} and ${b[1,8]}${${scope:#/}:+ under $scope}"
      return 0
    fi
    if command -v hunk >/dev/null 2>&1 && [[ -t 1 ]]; then
      hunk patch "$patch" || (( $? == 1 ))
    else
      ${=PAGER:-less} "$patch"
    fi
  } always {
    rm -f "$patch"
  }
}

# bkp::ux::changes_cmd <since> <a> <b> <scope>
# Argument resolution for the changes verb (spec §4): --since resolves to
# "rung at/before <when> vs latest"; bare = previous vs latest; explicit
# ids are prefix-expanded. B defaults to the LATEST SNAPSHOT, not live —
# the footer states the as-of time.
bkp::ux::changes_cmd() {
  local since="$1" a="$2" b="$3" scope="${4:-/}"
  local ladder REPLY
  ladder=$(bkp::snap::ladder) || return 2
  [[ -n "$ladder" ]] || { log_error "bkp: no snapshots yet"; return 2 }
  local -a lines=("${(f)ladder}")
  local latest="${lines[1]%%$'\t'*}"
  if [[ -n "$since" ]]; then
    [[ -z "$a" ]] || { log_error "bkp: --since and explicit snapshots are mutually exclusive"; return 2 }
    bkp::snap::resolve_since "$since" || return 2
    a="$REPLY" b="$latest"
  elif [[ -z "$a" ]]; then
    (( ${#lines} >= 2 )) || { log_error "bkp: only one snapshot so far — nothing to compare"; return 2 }
    a="${lines[2]%%$'\t'*}" b="$latest"
  else
    bkp::snap::expand "$a" "$ladder" || return 2
    a="$REPLY"
    if [[ -n "$b" ]]; then
      bkp::snap::expand "$b" "$ladder" || return 2
      b="$REPLY"
    else
      b="$latest"
    fi
  fi
  if [[ "$a" == "$b" ]]; then
    log_ok "bkp: nothing to compare — both sides are ${a[1,8]}"
    return 0
  fi
  bkp::ux::changes "$a" "$b" "$scope" || return $?
  local line epoch="" when
  for line in "${lines[@]}"; do
    [[ "${line%%$'\t'*}" == "$b" ]] && epoch="${line##*$'\t'}"
  done
  if [[ -n "$epoch" ]]; then
    strftime -s when '%Y-%m-%d %H:%M' "$epoch"
    log_info "bkp: as of $when (snapshot ${b[1,8]}) — run \`system-backup now\` first for up-to-the-second"
  fi
}

# bkp::restic::glob_escape <path>
# restic hands --include values to Go's filepath.Match, so a concrete live path
# that contains a glob metacharacter (\ * ? [) is read as a PATTERN, not a
# filename. A real captured path like .../chat/[id]/+page.svelte becomes a
# character class that matches ZERO files while restic still exits 0 — a silent
# no-op restore. Escape each metacharacter with a leading backslash so the path
# matches itself literally (a ] is only special inside a class, so it is left
# alone). Backslash is escaped first so we never re-escape our own escapes.
# Result in REPLY.
bkp::restic::glob_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\*/\\*}"
  s="${s//\?/\\?}"
  s="${s//\[/\\[}"
  REPLY="$s"
}

# bkp::restic::restore_count — read `restic restore --json` on stdin and print
# the summary's files_restored (0 when the summary omits it, which is exactly
# how restic reports a restore that matched nothing). Lets callers tell a real
# restore from restic's "Restored 0 files/dirs, rc 0" no-op.
bkp::restic::restore_count() {
  jq -rs '[.[] | select(.message_type == "summary")] | last | .files_restored // 0' 2>/dev/null
}

# bkp::restore::undo_snapshot <path…>
# The pre-restore safety net (spec §7): capture the live state of the paths
# about to be overwritten, tagged bkp-undo, so a bad restore is one
# `system-backup undo` away. Excluded from the thin ladder (see thin).
bkp::restore::undo_snapshot() {
  local staging
  staging=$(bkp::config::staging_path) || return 2
  bkp::restic "$staging" backup --tag bkp-undo --quiet "$@"
}

# bkp::restore::paths <snapshot> [--force] <path…>
# Undoable in-place restore: refuses to overwrite existing paths without
# --force (rc 3); with it, the live state is snapshotted first, then the
# requested paths are restored from <snapshot>.
bkp::restore::paths() {
  local snap="${1:-}"; shift 2>/dev/null || :
  local force=0
  [[ "${1:-}" == --force ]] && { force=1; shift }
  if [[ -z "$snap" ]] || (( $# == 0 )); then
    log_error "bkp: restore needs a snapshot id and at least one path"
    return 2
  fi
  local staging
  staging=$(bkp::config::staging_path) || return 2
  local p
  local -a live=()
  for p in "$@"; do
    [[ -e "$p" || -h "$p" ]] && live+=("$p")
  done
  if (( ${#live} && ! force )); then
    log_error "bkp: refusing to overwrite ${#live} existing path(s) — pass --force (an undo snapshot is taken first)"
    return 3
  fi
  if (( ${#live} )); then
    bkp::restore::undo_snapshot "${live[@]}" || return 1
  fi
  local -a includes=()
  local esc
  for p in "$@"; do
    bkp::restic::glob_escape "$p"; esc="$REPLY"
    includes+=(--include "$esc")
  done
  # --json (not --quiet): restore's plain header echoes the snapshot's recorded
  # paths — tens of thousands of files-from entries for capture snapshots — and
  # --json both silences that and lets us read files_restored. restic exits 0
  # even when an --include matches nothing, so the count is the only proof the
  # restore was real.
  local json restored
  json=$(bkp::restic "$staging" restore "$snap" --target / "${includes[@]}" --json) || return 1
  restored=$(print -r -- "$json" | bkp::restic::restore_count)
  if (( restored <= 0 )); then
    log_error "bkp: restore matched no files in snapshot ${snap[1,8]} — nothing restored (paths absent from that snapshot?)"
    return 1
  fi
  log_ok "bkp: restored $# path(s) from snapshot ${snap[1,8]} (undo with \`system-backup undo\`)"
}

# bkp::restore::undo
# Revert the last restore: restore the newest bkp-undo snapshot in place,
# then forget it — stacked undos peel one restore at a time. The restore is
# restricted to the snapshot's own recorded paths: a bare `--target /` would
# make restic recreate parent nodes like /var, which is a symlink on macOS
# (it fatals trying to replace it).
bkp::restore::undo() {
  local staging
  staging=$(bkp::config::staging_path) || return 2
  local sel
  sel=$(bkp::restic "$staging" snapshots --json --tag bkp-undo |
    jq -r '[(. // [])[] | select((.tags // []) | index("bkp-undo"))]
           | sort_by(.time) | last // empty
           | [.id, ((.paths // []) | join("\u001f"))] | @tsv' 2>/dev/null)
  [[ -n "$sel" ]] || {
    log_error "bkp: nothing to undo"
    return 1
  }
  local id="${sel%%$'\t'*}" joined="${sel#*$'\t'}"
  local -a includes=()
  local p esc
  for p in "${(@ps:\x1f:)joined}"; do
    [[ -n "$p" ]] || continue
    bkp::restic::glob_escape "$p"; esc="$REPLY"
    includes+=(--include "$esc")
  done
  # Gate the forget on an actual restore: restic exits 0 even when the includes
  # match nothing (e.g. a bracketed path read as a glob). Forgetting the undo
  # snapshot after a 0-file no-op would delete the ONLY record of the content
  # the earlier restore overwrote — so preserve it and fail instead.
  local json restored
  json=$(bkp::restic "$staging" restore "$id" --target / "${includes[@]}" --json) || return 1
  restored=$(print -r -- "$json" | bkp::restic::restore_count)
  if (( restored <= 0 )); then
    log_error "bkp: undo restored no files from snapshot ${id[1,8]} — keeping it (safety net preserved, not forgotten)"
    return 1
  fi
  bkp::restic "$staging" forget --quiet "$id" || return 1
  log_ok "bkp: undid the last restore ($(( ${#includes} / 2 )) path(s))"
}

# bkp::tick [<manifest>] [<config>]
# One scheduled tick (spec §6): capture, then reconcile-after-capture. The
# two phases hold distinct locks, so in-process chaining is safe; each still
# coalesces independently against concurrent runs.
bkp::tick() {
  bkp::capture::run "$@" || return $?
  bkp::reconcile::run "$@"
}

# bkp::reconcile::prune [<config>]
# The expensive daily repack (spec §5): staging + present, initialized,
# non-master targets. Prune is restic-EXCLUSIVE — it cannot share the
# staging repo with a capture, and the nightly calendar slot lands inside
# a 30-minute capture tick more often than not (it failed two nights
# straight racing the 03:14 capture). So it WAITS for the in-flight tick
# on BOTH locks, in the tick's own acquisition order (capture, then
# reconcile) so the two can never deadlock. Holding the capture lock
# coalesces capture ticks away for the repack's duration; they resume on
# the next tick.
bkp::reconcile::prune() {
  local BKP_CONFIG="${1:-$BKP_CONFIG}"
  local lock_wait="${BKP_PRUNE_LOCK_WAIT:-900}"
  bkp::lock capture "$lock_wait" || {
    log_error "bkp: capture still running after ${lock_wait}s — prune aborted"
    return 1
  }
  bkp::lock reconcile "$lock_wait" || {
    log_error "bkp: reconcile still running after ${lock_wait}s — prune aborted"
    return 1
  }
  local staging targets rc=0
  staging=$(bkp::config::staging_path) || return 2
  targets=$(bkp::config::targets) || return 2
  bkp::restic "$staging" prune --quiet || rc=1
  local name tpath role
  while IFS=$'\t' read -r name tpath role; do
    [[ -z "$name" ]] && continue
    [[ "$role" == master ]] && continue
    bkp::target::present "$tpath" || continue
    bkp::restic "$tpath" cat config >/dev/null 2>&1 || continue
    bkp::restic "$tpath" prune --quiet || rc=1
  done <<<"$targets"
  bkp::drift::stamp prune "$rc"
  return $rc
}

# bkp::reclaim::run [<manifest>] [<config>] [--dry-run]
# Retroactively enforce the manifest deny list on EXISTING snapshots. A deny
# change only shapes FUTURE captures; this rewrites every snapshot in each
# repo to drop the now-denied paths (restic rewrite), then prunes the freed
# packs. Applies to staging AND every present, initialized target — master
# included: a rewrite keeps every snapshot, it only trims paths, so the
# deepest archive stays complete while shedding what should never have been
# in it. Mirrors MUST be reclaimed here, not via reconcile: reconcile keys
# snapshots on `.original`, which rewrite preserves, so a staging-only
# rewrite is invisible to a mirror. Restic-exclusive like the nightly prune,
# so it serializes behind capture+reconcile in the same acquisition order.
#   --dry-run: `rewrite --dry-run` per repo, no forget, no prune.
bkp::reclaim::run() {
  local manifest="$BKP_MANIFEST" cfg="$BKP_CONFIG" dry=0 pos=0
  while (( $# )); do
    case "$1" in
      --dry-run) dry=1 ;;
      --*) log_error "bkp: reclaim: unknown flag '$1'"; return 2 ;;
      *)
        case $pos in
          0) manifest="$1" ;;
          1) cfg="$1" ;;
          *) log_error "bkp: reclaim: too many arguments"; return 2 ;;
        esac
        pos=$(( pos + 1 ))
        ;;
    esac
    shift
  done
  local BKP_CONFIG="$cfg"

  # Excludes = the manifest deny globs (~-expanded) plus the always-denied
  # state dir (capture appends this too — never re-ingest our own repo).
  local -a excludes=() rewrite_args=()
  local deny_out
  deny_out=$(bkp::manifest::deny "$manifest") || return 2
  [[ -n "$deny_out" ]] && excludes=(${(f)deny_out})
  excludes+=("$BKP_STATE_DIR")
  local pat
  for pat in "${excludes[@]}"; do rewrite_args+=(--exclude "$pat"); done

  local staging targets rc=0
  staging=$(bkp::config::staging_path) || return 2
  targets=$(bkp::config::targets) || return 2

  # A rewrite cannot share a repo with a capture — wait the tick out on both
  # locks, in the tick's own order (capture then reconcile) so they can never
  # deadlock. A preview writes nothing, so it needs no lock.
  if (( ! dry )); then
    local lock_wait="${BKP_PRUNE_LOCK_WAIT:-900}"
    bkp::lock capture "$lock_wait" || {
      log_error "bkp: capture still running after ${lock_wait}s — reclaim aborted"
      return 1
    }
    bkp::lock reconcile "$lock_wait" || {
      log_error "bkp: reconcile still running after ${lock_wait}s — reclaim aborted"
      return 1
    }
  fi

  # staging first, then every present, initialized target (master included).
  local -a repos=("staging"$'\t'"$staging")
  local name tpath role
  while IFS=$'\t' read -r name tpath role; do
    [[ -z "$name" ]] && continue
    bkp::target::present "$tpath" || continue
    bkp::restic "$tpath" cat config >/dev/null 2>&1 || continue
    repos+=("$name"$'\t'"$tpath")
  done <<<"$targets"

  local entry rname rpath before after tmp n REPLY
  local -a pq
  for entry in "${repos[@]}"; do
    rname="${entry%%$'\t'*}" rpath="${entry##*$'\t'}"
    if (( dry )); then
      # restic rewrite spews the full file list per snapshot to stdout — send
      # it to a temp file so the flood never hits the terminal (stderr still
      # flows, so real errors surface), and spin so a big/cloud repo doesn't
      # look frozen while it reads. Report only the count.
      tmp=$(mktemp "${TMPDIR:-/tmp}/bkp-reclaim.XXXXXX") || return 1
      bkp::spin "reclaim ($rname): previewing…" "$tmp" -- \
        bkp::restic "$rpath" rewrite --dry-run "${rewrite_args[@]}" || rc=1
      n=$(grep -c 'would save new snapshot' "$tmp") || n=0
      rm -f "$tmp"
      log_info "bkp: reclaim ($rname) — $n snapshot(s) would change"
    else
      bkp::ux::_dirsize "$rpath"; before="$REPLY"
      log_info "bkp: reclaim ($rname) — rewrite + prune ($before on disk)"
      # rewrite MUST stay -q (its per-file flood is unusable), so spin over
      # it. prune has a usable native progress bar — show it interactively,
      # stay --quiet when scheduled/piped.
      if bkp::spin "reclaim ($rname): rewriting…" /dev/null -- \
           bkp::restic "$rpath" rewrite -q --forget "${rewrite_args[@]}"; then
        pq=(--quiet); bkp::ux::interactive && pq=()
        bkp::restic "$rpath" prune "${pq[@]}" || rc=1
      else
        rc=1; continue
      fi
      bkp::ux::_dirsize "$rpath"; after="$REPLY"
      log_ok "bkp: reclaim ($rname) — $before → $after"
    fi
  done
  (( dry )) || bkp::drift::stamp prune "$rc"
  return $rc
}
