# rip_helper.sh — shared doubles for the rip specs.
#
# Each rip spec `Include`s this at the top of its Describe (or sources it
# there): it must be loaded ONCE per file, outside the examples, because it
# also holds what a file sets up once (rip_lib_load, rip_static_build).

# rip_fake_ffmpeg_pair <dir> — install a fake ffmpeg/ffprobe pair in <dir>
# and point rip.zsh's RIP_FFMPEG_BIN / RIP_FFPROBE_BIN seams at it.
#
# WHY THIS EXISTS. rip::_enrich_audiobooks retags every staged book's audio
# on the way to the push and REFUSES a book whose tags cannot be written and
# read back (design doc 2026-08-26-audiobook-authoritative-tags, S3). That is
# the whole point of the feature — but ~75 push/session examples across the
# rip specs stage a six-byte text file named "*.m4b", which a real ffmpeg
# cannot remux, so every one of them would be refused for reasons that have
# nothing to do with what they are testing.
#
# The pair below is a TEST DOUBLE, not a simulator: the fake ffmpeg copies
# its input to its output byte-for-byte (so every "contents of file … should
# equal" assertion in those examples keeps meaning what it meant) and records
# the -metadata flags it was handed; the fake ffprobe replays exactly those
# as the file's format tags. Sequential by construction — the retag verifies
# the file it just wrote, one at a time — so a single last-write record is
# enough and no path bookkeeping is needed.
#
# Examples that are ABOUT the tags do NOT use this: they build real m4b media
# with the real ffmpeg and point the seams back at the real tools. Where a
# stub appears there, it stubs exactly one failure and never the verification.
rip_fake_ffmpeg_pair() {
  if [ -n "${RIP_STATIC:-}" ]; then
    # The pair is the same two scripts for every example: they were written
    # once (rip_static_build) and only the record of the last tags is the
    # example's own.
    rip_mkdir "$1"
    export RIP_FFMPEG_BIN="$RIP_STATIC/tools/ffmpeg" RIP_FFPROBE_BIN="$RIP_STATIC/tools/ffprobe"
    export RIP_FAKE_TAGS="$1/last-tags"
    return 0
  fi
  _rip_write_ffmpeg_pair "$1"
  chmod +x "$1/ffmpeg" "$1/ffprobe"
  export RIP_FFMPEG_BIN="$1/ffmpeg" RIP_FFPROBE_BIN="$1/ffprobe"
  export RIP_FAKE_TAGS="$1/last-tags"
}
_rip_write_ffmpeg_pair() {
  mkdir -p "$1"
  cat > "$1/ffmpeg" <<'FFMPEG'
#!/bin/sh
# -v error -y -i IN -map … -metadata k=v … -- OUT
in=""; out=""; tags=""
while [ $# -gt 0 ]; do
  case "$1" in
    -i) in="$2"; shift ;;
    -metadata) tags="$tags$2
"; shift ;;
    --) shift; out="$1" ;;
  esac
  shift
done
[ -n "$in" ] && [ -n "$out" ] || exit 1
cp "$in" "$out" || exit 1
printf '%s' "$tags" > "${RIP_FAKE_TAGS:?}"
exit 0
FFMPEG
  cat > "$1/ffprobe" <<'FFPROBE'
#!/bin/sh
# -v error -show_entries format_tags -of json -- FILE
tags="${RIP_FAKE_TAGS:-}"
[ -n "$tags" ] && [ -f "$tags" ] || { printf '{"format":{"tags":{}}}\n'; exit 0; }
printf '{"format":{"tags":'
# jq builds the object so a value containing a quote or a backslash is
# encoded rather than smuggled through.
jq -R -s 'split("\n") | map(select(length > 0)) | map(split("=") | {key: .[0], value: (.[1:] | join("="))}) | from_entries' "$tags"
printf '}}\n'
exit 0
FFPROBE
}

# rip_stub_remote_hops <bin_dir> — install a silent, successful stand-in for
# every helper the default RIP_AB_REMOTE_HOPS shell out to (today only
# rip-abs-authors) in <bin_dir>, which the spec exports as RIP_BIN_DIR.
#
# WHY THIS EXISTS. The hops run after every verified audiobooks push, and at
# their production default they resolve the REAL deployed helpers, i.e. live
# calls against cantina. The suites used to guard against that with an EMPTY
# sandbox bin dir: the shell-out failed with "no such file or directory" and
# the hop's `|| log_warn` swallowed it. That was hermetic, but it wrote the
# failure to stderr in every push example (~20 shellspec warnings) and made
# every example quietly exercise the hop's FAILURE path. A stub that exits 0
# and prints nothing is just as hermetic (it is still a sandbox path, never
# the deployed helper) and lets each example test what it is about.
#
# Examples that are ABOUT the hops (argv logging, a failing hop that must not
# fail the job) overwrite this stub with their own after setup.
#
# Under rip_static_build the stand-in is a symlink to the one shared copy
# (no process to make it). An example that writes its OWN helper there must
# take the link away first, or it would write through it into the copy every
# later example runs: `rip_own "$RIP_BIN_DIR/rip-abs-authors"`, then write.
# rip_static_check (in the specs' cleanup) fails the example that forgot.
rip_stub_remote_hops() {
  if [ -n "${RIP_STATIC:-}" ]; then
    rip_mkdir "$1"
    zf_ln -s "$RIP_STATIC/rip-abs-authors" "$1/rip-abs-authors"
    return 0
  fi
  mkdir -p "$1"
  printf '#!/bin/sh\nexit 0\n' > "$1/rip-abs-authors"
  chmod +x "$1/rip-abs-authors"
}

# --- fixtures made ONCE per spec file -----------------------------------------
#
# Every example used to write the same stubs again (pueue, the ffmpeg/ffprobe
# pair, rip-abs-authors, ...): a heredoc, a chmod and a copy into the exec pool
# each, and a `mktemp -d`, a few `mkdir -p` and an `rm -rf` around them, about
# 25 ms of processes before the example's first line. All of those stubs take
# what differs between examples from the ENVIRONMENT ($JOB_FAKE_LOG,
# $RIP_FAKE_TAGS, $RIP_SANDBOX), so one copy serves the whole file:
#
#   BeforeAll 'rip_static_build'      # $RIP_STATIC, under the file's tmpbase
#   setup() { rip_sandbox; ...; export JOB_PUEUE_BIN="$RIP_STATIC/pueue"; ... }
#   cleanup() { rip_static_check; rip_rmtree "$RIP_SANDBOX"; }
#
# Each copy is run once here, outside any example:
# macOS charges the first exec of a new script inode about 50 ms (see THE EXEC
# POOL in spec_helper.sh).
#
# THE RULE for an example that needs a DIFFERENT pueue / ffmpeg / LibationCli:
# write it under $RIP_SANDBOX as before and POINT THE SEAM AT IT
# (`export JOB_PUEUE_BIN="$RIP_SANDBOX/pueue"`). Never write to "$JOB_PUEUE_BIN"
# or into $RIP_STATIC. rip_static_check enforces both ends: a stub written at
# the old per-example path while the seam still names the shared copy (it
# would never run), and a shared copy that no longer has its bytes.
#
# rip_sandbox [prefix], rip_mkdir <dir>..., rip_rmtree <dir>... do what
# `mktemp -d`, `mkdir -p` and `rm -rf` did, with zsh's own builtins: no
# process. The sandbox is a new 0700 directory under $SHELLSPEC_TMPBASE, named
# for the example's own pid.
zmodload zsh/system 2>/dev/null
zmodload -F zsh/files b:zf_mkdir b:zf_ln b:zf_rm b:zf_chmod 2>/dev/null

rip_mkdir() { zf_mkdir -p -- "$@"; }
rip_rmtree() { zf_rm -rf -- "$@" 2>/dev/null; return 0; }
# rip_own <path>... — take a shared stand-in (a symlink into $RIP_STATIC) out
# of the example's way before writing the example's own file there.
rip_own() { zf_rm -f -- "$@"; }
rip_sandbox() {
  local base="${SHELLSPEC_TMPBASE:?rip_sandbox: no SHELLSPEC_TMPBASE}/${1:-rip}.${sysparams[pid]}"
  local -i n=0
  base=${base//\/\///}   # $TMPDIR ends in a slash on macOS
  RIP_SANDBOX=$base
  until zf_mkdir -m 700 -- "$RIP_SANDBOX" 2>/dev/null; do
    (( ++n < 1000 )) || { echo "rip_sandbox: could not create $base" >&2; return 1; }
    RIP_SANDBOX=$base.$n
  done
  export RIP_SANDBOX
}

# rip_static_put <name> — stdin becomes the read-only executable
# $RIP_STATIC/<name>, and its bytes are remembered for rip_static_check.
typeset -gA _RIP_STATIC_BYTES
rip_static_put() {
  local f="$RIP_STATIC/$1"
  rip_mkdir "${f:h}"
  cat > "$f" || return 1
  command chmod 755 "$f" || return 1
  _RIP_STATIC_BYTES[$1]="$(<$f)"
}
rip_static_build() {
  [ -z "${RIP_STATIC:-}" ] || return 0
  typeset -g RIP_STATIC="${SHELLSPEC_TMPBASE:?rip_static_build: no SHELLSPEC_TMPBASE}/rip-static"
  rip_mkdir "$RIP_STATIC/warm"
  rip_static_put pueue <<'PUEUE'
#!/bin/sh
printf '%s\n' "$*" >> "$JOB_FAKE_LOG"
case "$1" in add) echo "7" ;; esac
exit 0
PUEUE
  rip_static_put rip-abs-authors <<'HOP'
#!/bin/sh
exit 0
HOP
  _rip_write_ffmpeg_pair "$RIP_STATIC/tools.new" || return 1
  rip_static_put tools/ffmpeg < "$RIP_STATIC/tools.new/ffmpeg"
  rip_static_put tools/ffprobe < "$RIP_STATIC/tools.new/ffprobe"
  rip_rmtree "$RIP_STATIC/tools.new"
  rip_static_warm pueue rip-abs-authors tools/ffmpeg tools/ffprobe
}
# The first exec of each, paid here instead of in whichever example is first.
rip_static_warm() {
  local n
  for n in "$@"; do
    JOB_FAKE_LOG=/dev/null RIP_FAKE_TAGS= RIP_SANDBOX="$RIP_STATIC/warm" \
      "$RIP_STATIC/$n" </dev/null >/dev/null 2>&1
  done
  rip_rmtree "$RIP_STATIC/warm"/*(DN)
  return 0
}
# rip_static_check [seam-variable=old-path ...] — for a spec's cleanup. Silent
# when all is well; anything it prints (on stderr, in an AfterEach) fails the
# example. See THE RULE above.
rip_static_check() {
  [ -n "${RIP_STATIC:-}" ] || return 0
  local n pair var
  for n in "${(@k)_RIP_STATIC_BYTES}"; do
    [[ "$(<$RIP_STATIC/$n)" == "${_RIP_STATIC_BYTES[$n]}" ]] && continue
    # Put it back, so only the example that did it fails.
    print -r -- "${_RIP_STATIC_BYTES[$n]}" > "$RIP_STATIC/$n"
    print -u2 -r -- "rip_static_check: this example overwrote the shared $n (write your own under \$RIP_SANDBOX and point the seam at it; rip_own a symlink first)"
  done
  for pair in JOB_PUEUE_BIN="$RIP_SANDBOX/pueue" RIP_FFMPEG_BIN="$RIP_SANDBOX/tools/ffmpeg" \
    RIP_FFPROBE_BIN="$RIP_SANDBOX/tools/ffprobe" "$@"; do
    var=${pair%%\=*}
    [[ "${(P)var}" != "$RIP_STATIC"/* || ! -e "${pair#*=}" ]] ||
      print -u2 -r -- "rip_static_check: this example wrote ${pair#*=} but \$$var still names the shared copy, so it never ran (export $var=\"${pair#*=}\")"
  done
  return 0
}

# --- rip.zsh loaded ONCE per spec file ---------------------------------------
#
# `When run zsh -f -c "source $RIPLIB && rip::fn …"` starts a shell and parses
# rip.zsh (8,000 lines) and common.zsh for every example: about 30 ms each,
# 400 times over the rip specs. Instead a spec says, at the top of its
# Describe:
#
#   rip_lib_load
#
# and an example says:
#
#   When run rip_zsh "source $RIPLIB && rip::fn …"
#
# The code string is the one `zsh -f -c` was given, unchanged. `When run` with
# a function runs it in a SUBSHELL of the spec's shell, which already holds the
# library, so the string's own `source $RIPLIB` returns at the load guard. What
# a process had and the subshell must still have, rip_zsh puts back:
#
#   * `exit`, `return`, `cd`, variables, options, caches (_RIP_SERVER_AUTHORS…)
#     die with the subshell, as they died with the process;
#   * rip.zsh settles its seams from the ENVIRONMENT while it loads
#     (RIP_BIN_DIR="${RIP_BIN_DIR:-$HOME/.local/bin}", and RIP_BD_MENU_BIN from
#     RIP_LIBEXEC_DIR). The spec's shell loaded it before any setup() exported
#     a sandbox, so rip_zsh evaluates those lines again, against what the
#     example exported: a seam the example did not export is unset first, as
#     it was for a fresh process. The lines are READ from rip.zsh
#     (rip_lib_load), not copied here, so a new seam of that form follows;
#   * the UTF-8 LC_CTYPE guard at the top of rip.zsh runs again;
#   * common.zsh's EXIT trap (temp files of common::…) fires when the code
#     ends, as it did when the process ended.
#
# What it canNOT stand in for, so those examples keep `When run zsh -f -c`: a
# process with a different environment at load (`env -u …`, `VAR=x zsh …`,
# positional arguments after the string), a signal sent to the process, a
# library that is not rip.zsh's own (job.zsh still loads in the subshell), and
# anything asserting that a FRESH shell can source the file.
rip_lib_load() {
  typeset -g RIP_HELPER_LIB="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib/rip.zsh"
  typeset -ga _RIP_HELPER_SEAMS
  (( ${#_RIP_HELPER_SEAMS} )) && return 0
  # The guard exports LC_CTYPE; that belongs to each rip_zsh, not to the
  # spec's own shell and the tools its helpers run.
  local had=${+LC_CTYPE} was=${LC_CTYPE-}
  _rip_lib_source || return 1
  if (( had )); then LC_CTYPE=$was; else unset LC_CTYPE; fi
  _rip_lib_seams
}
# No `emulate -L` here: the library's top level must see the shell's options.
_rip_lib_source() { source "$RIP_HELPER_LIB"; }
_rip_lib_seams() {
  emulate -L zsh
  setopt extendedglob
  local line
  for line in "${(@f)$(<$RIP_HELPER_LIB)}"; do
    [[ $line == (#b)([A-Z_]##)'="${'([A-Z_]##)':-'*'}"' && $match[1] == $match[2] ]] &&
      _RIP_HELPER_SEAMS+=("$line")
  done
  (( ${#_RIP_HELPER_SEAMS} ))
}
rip_zsh() {
  local _rz
  for _rz in "${_RIP_HELPER_SEAMS[@]}"; do
    [[ ${(Pt)${_rz%%\=*}} == *export* ]] || unset "${_rz%%\=*}"
  done
  for _rz in "${_RIP_HELPER_SEAMS[@]}"; do eval "$_rz"; done
  case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
    *[Uu][Tt][Ff]-8* | *[Uu][Tt][Ff]8*) ;;
    *) export LC_CTYPE="en_US.UTF-8" ;;
  esac
  unset _rz
  # spec_helper.sh's `chmod` (the exec pool) is the spec's, not the code's.
  unfunction chmod 2>/dev/null
  # In a function an EXIT trap is the function's: it fires when the code ends.
  trap '_common_tmpdir_cleanup' EXIT
  # `zsh -c <code>` has no positional parameters.
  local __rip_zsh_code=$1
  set --
  eval "$__rip_zsh_code"
}
