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
unset _bkp_self

zmodload zsh/datetime

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

# bkp::git::is_repo <dir> — does <dir> head a git work tree?
bkp::git::is_repo() {
  [[ -e "$1/.git" ]]
}

# bkp::git::ls <repo>
# Absolute paths of the repo's capturable working tree: tracked + untracked
# minus everything git's FULL ignore resolution drops (repo .gitignore(s),
# .git/info/exclude, and the machine-global core.excludesFile).
bkp::git::ls() {
  local repo="$1" out
  out=$(git -C "$repo" ls-files --cached --others --exclude-standard 2>/dev/null) || return 1
  local f
  for f in ${(f)out}; do
    print -r -- "$repo/$f"
  done
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

# bkp::manifest::walk <node>
# Recursive sweep worker. Emits F\t<file> / R\t<repo>\t<bundle>\t<warn>.
# Reads _bkp_deny, _bkp_managed, _bkp_bundle, _bkp_warn from the caller's
# scope. Inside a git repo, enumeration is delegated to git (full ignore
# resolution); on git failure it degrades to a plain walk that skips .git —
# over-capture, never under-capture.
bkp::manifest::walk() {
  local node="$1" entry
  bkp::manifest::denied "$node" && return 0
  if [[ -h "$node" || -f "$node" ]]; then
    [[ -n "${_bkp_managed[$node]:-}" ]] || print -r -- "F"$'\t'"$node"
    return 0
  fi
  [[ -d "$node" ]] || return 0
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

  local root _bkp_bundle _bkp_warn
  while IFS=$'\t' read -r root _bkp_bundle _bkp_warn; do
    [[ -e "$root" || -h "$root" ]] || continue
    bkp::manifest::walk "$root"
  done < <(bkp::manifest::roots "$manifest")
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
