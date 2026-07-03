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

BKP_STATE_DIR="${BKP_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/terminal-backup}"
BKP_WIP_DIR="${BKP_WIP_DIR:-$BKP_STATE_DIR/wip}"

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
  branch=$(git -C "$repo" symbolic-ref --short -q HEAD) || branch=""   # detached
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

# bkp::lock <name>
# Non-blocking run-lock, held until the process exits (zsystem flock keeps
# the fd). rc 1 when busy — callers coalesce (skip the tick), never queue.
bkp::lock() {
  local lockfile="$BKP_STATE_DIR/$1.lock"
  mkdir -p "$BKP_STATE_DIR"
  : >> "$lockfile"
  zsystem flock -t 0 "$lockfile" 2>/dev/null
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

# bkp::target::present <path>
# Present = parent dir exists AND is writable (spec §8). The repo dir itself
# may not exist yet — first reconcile creates it.
bkp::target::present() {
  local parent="${1:h}"
  [[ -d "$parent" && -w "$parent" ]]
}

# bkp::restic <repo> <args…>
# THE storage seam — every restic invocation goes through here (tests stub
# this function). Repo + passphrase-command via env; the passphrase itself is
# resolved by restic at exec time and never appears in argv or logs.
bkp::restic() {
  local repo="$1"; shift
  local pwcmd
  pwcmd=$(bkp::config::password_command) || return 2
  RESTIC_REPOSITORY="$repo" RESTIC_PASSWORD_COMMAND="$pwcmd" restic "$@"
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
bkp::capture::thin() {
  local repo="$1" manifest="$2"
  local policy snaps plan
  policy=$(bkp::manifest::thin_policy "$manifest") || return 2
  snaps=$(bkp::restic "$repo" snapshots --json | bkp::restic::parse_snapshots) || return 2
  [[ -z "$snaps" ]] && return 0
  plan=$(print -r -- "$snaps" | bkp::thin "$EPOCHSECONDS" "$policy") || return 2
  local line
  local -a drop=()
  for line in ${(f)plan}; do
    [[ "$line" == drop$'\t'* ]] && drop+=("${line#drop$'\t'}")
  done
  (( ${#drop} )) || return 0
  bkp::restic "$repo" forget "${drop[@]}"
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

# bkp::capture::run [<manifest>] [<config>]
# One capture tick (spec §4): lock -> ensure staging -> git sidecars ->
# resolve manifest -> restic backup -> thin. Sidecars are written FIRST so
# the sweep captures them (BKP_WIP_DIR lives under a manifest root).
bkp::capture::run() {
  local manifest="${1:-$BKP_MANIFEST}"
  local BKP_CONFIG="${2:-$BKP_CONFIG}"   # dynamic scope: bkp::restic sees it
  bkp::lock capture || {
    log_info "bkp: capture already running — coalescing"
    return 0
  }
  local staging
  staging=$(bkp::config::staging_path) || return 2
  bkp::capture::ensure_repo "$staging" || return 1

  local repo bundle warn
  while IFS=$'\t' read -r repo bundle warn; do
    [[ -z "$repo" ]] && continue
    bkp::project::sidecar "$repo" "$bundle" "$warn"
  done < <(bkp::manifest::repos "$manifest")

  local files_from
  files_from=$(mktemp "${TMPDIR:-/tmp}/bkp-files.XXXXXX") || return 1
  {
    bkp::manifest::files "$manifest" > "$files_from" || return 2
    bkp::restic "$staging" unlock >/dev/null 2>&1 || :   # stale-lock recovery
    bkp::restic "$staging" backup --files-from "$files_from" --quiet || return 1
  } always {
    rm -f "$files_from"
  }
  bkp::capture::thin "$staging" "$manifest"
}

# ── Reconcile ────────────────────────────────────────────────────────────────

# bkp::restic::copy <src> <dst> <ids…>
# restic copy through the seam. Both repos share one passphrase (spec §8) —
# required, since copy needs credentials for both ends.
bkp::restic::copy() {
  local src="$1" dst="$2"; shift 2
  local pwcmd
  pwcmd=$(bkp::config::password_command) || return 2
  bkp::restic "$dst" copy --from-repo "$src" --from-password-command "$pwcmd" "$@"
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
  if (( ${#push} )); then
    bkp::restic::copy "$staging" "$tpath" "${push[@]}" || return 1
  fi
  if (( ${#pull} )); then
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
  return $rc
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
# non-master targets. Exclusive restic op — a lock conflict with a running
# capture fails loudly; the next daily run retries.
bkp::reconcile::prune() {
  local BKP_CONFIG="${1:-$BKP_CONFIG}"
  bkp::lock reconcile || {
    log_info "bkp: reconcile busy — prune skipped"
    return 0
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
  return $rc
}
