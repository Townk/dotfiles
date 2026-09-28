#!/usr/bin/env zsh
# share/ssh.zsh — the ssh backend: copy files to one of YOUR OWN boxes over an
# ssh hop (the Phase 4 dev-shell experiment). SOURCED by share.zsh, never
# executed.
#
# Not a sharing mechanism in the croc/rclone sense: no link, no expiry, no
# third party. The pasteable line is the remote path(s), for the human to
# paste into a shell on that box. That is why it is only ever reached through
# an explicit `--to` and can never be a profile default.
#
# THE ONE RULE: nothing variable ever reaches the remote command line. ssh
# joins its command arguments into ONE string that the remote login shell
# parses, so any filename or directory interpolated there is code. Both
# remote commands below are compile-time constants; the directory and file
# names travel on STDIN as newline-terminated header lines (share::send has
# already refused a newline in any path), followed by the file's bytes. There
# is therefore nothing to quote, and nothing a hostile name can inject.
#
# Why ssh + cat and not scp or rsync:
#  * scp in legacy mode (-O, still what older servers speak) hands remote paths
#    to the remote shell — the CVE-2020-15778 class. SFTP-mode scp does not,
#    but which one runs depends on the client version, and scp cannot create
#    the per-share directory anyway, so a second ssh call is needed regardless.
#  * rsync also passes remote paths through the remote shell unless told not
#    to (-s/--protect-args), macOS now ships openrsync with a different flag
#    surface, and it needs rsync installed on the far end.
#  * ssh + cat needs only a POSIX sh, mkdir and cat on the remote, which every
#    dev-shell has. The costs — no resume, no delta, one connection per file —
#    are acceptable for handing a few files to yourself.

# Remote side of a copy. Reads the directory and the name, creates the
# directory, writes the file without clobbering, and prints the directory's
# physical absolute path (the receipt needs it; a relative `dir` resolves
# against the remote $HOME, where ssh starts). umask 077: this may be a
# shared box, and the files are nobody else's business.
SHARE_SSH_RECV_SCRIPT='umask 077; set -C; IFS= read -r d || exit 3; IFS= read -r n || exit 3; mkdir -p -- "$d" && cd -- "$d" && cat >"./$n" && pwd -P'

# Remote side of a revoke. Reads the directory, then one name per line, and
# removes exactly those names inside it. The directory itself goes only if it
# is then empty: something added after the send is not ours to delete. A
# directory that is already gone means there is nothing left to remove.
SHARE_SSH_RM_SCRIPT='IFS= read -r d || exit 3; cd -- "$d" 2>/dev/null || exit 0; d=$(pwd -P); s=0; while IFS= read -r n; do rm -f -- "./$n" || s=1; done; cd / && rmdir -- "$d" 2>/dev/null; exit $s'

# share::_ssh_run <target> <script> — run a constant script on <target>,
# stdin passed through. -T: no tty, so the byte stream is not mangled.
# -e none: no escape character inside file data. BatchMode: never prompt — a
# backgrounded send has no terminal, and a prompt there hangs a job forever.
# The script is wrapped in `sh -c '…'` so the remote login shell only has to
# parse one single-quoted word, whatever that shell is.
share::_ssh_run() {
  local target="$1" script="$2"
  ssh -T -e none -o BatchMode=yes -- "$target" "sh -c '$script'"
}

# share::ssh_reject_store_remote <endpoint> — an ssh endpoint speaks only to
# its `target`; a `store` or `remote` key alongside it is a configuration
# error, not a fallback, because share::destination_host's echo would then
# name the store's or remote's host while the bytes actually go to `target`.
# Called from both share::destination_host (the pre-send echo) and
# share::ssh_check_endpoint (this backend's own resolution), so no ssh path
# can ever echo or use the wrong host.
share::ssh_reject_store_remote() {
  local ep="$1" store remote
  local -a bad=()
  store="$(share::field "$ep" store)"
  remote="$(share::field "$ep" remote)"
  [[ -n "$store" ]] && bad+=(store)
  [[ -n "$remote" ]] && bad+=(remote)
  if (( ${#bad[@]} )); then
    log_error "share: ssh endpoint $ep sets ${(j:, :)bad} — an ssh endpoint only ever uses target"
    return 1
  fi
  return 0
}

# share::ssh_check_endpoint <endpoint> — the config an ssh endpoint needs.
share::ssh_check_endpoint() {
  local ep="$1" target dir
  share::ssh_reject_store_remote "$ep" || return 1
  target="$(share::field "$ep" target)" || return 1
  if [[ -z "$target" ]]; then
    log_error "share: ssh endpoint $ep has no target — set target = \"user@host\""
    return 1
  fi
  # A leading `-` would be read by ssh as an option (-oProxyCommand=… runs a
  # local command); `--` already guards that, but refusing says why.
  if [[ "$target" == -* || "$target" == *[[:space:]]* ]]; then
    log_error "share: ssh endpoint $ep has an invalid target: ${(V)target}"
    return 1
  fi
  dir="$(share::field "$ep" dir)" || return 1
  if [[ -z "$dir" ]]; then
    log_error "share: ssh endpoint $ep has no dir — set dir = \"~/incoming\""
    return 1
  fi
  if [[ "$dir" == *$'\n'* || "$dir" == '~'[^/]* ]]; then
    log_error "share: ssh endpoint $ep has an unsupported dir: ${(V)dir} (use ~/…, a relative or an absolute path)"
    return 1
  fi
  if [[ "$(share::field "$ep" web false)" == true ]]; then
    log_error "share: ssh endpoint $ep sets web = true — the ssh backend makes no web links"
    return 1
  fi
  if [[ -n "$(share::field "$ep" default_for)" ]]; then
    log_error "share: ssh endpoint $ep claims default_for — an ssh endpoint is only ever used through an explicit --to"
    return 1
  fi
}

# share::ssh_preflight <endpoint> <to-given 0|1> [<flag>…] -- <path…>
#
# Everything that can be refused is refused HERE, before any byte moves. The
# flags are the options the caller saw that this backend cannot honour; both
# share::send and share::send_background pass them, so a backgrounded send is
# refused at the prompt rather than as a failure toast minutes later.
share::ssh_preflight() {
  local ep="$1" to_given="$2"; shift 2
  if (( ! to_given )); then
    log_error "share: $ep is an ssh endpoint, which is never chosen implicitly — pass --to $ep"
    return 1
  fi
  share::ssh_check_endpoint "$ep" || return 1
  while (( $# )); do
    case "$1" in
      --) shift; break ;;
      --live)
        log_error "share: the ssh backend has no live mode — it copies the file to $ep and is done"
        return 1 ;;
      --qr)
        log_error "share: --qr does not apply to the ssh backend — its line is a path on your own box"
        return 1 ;;
      --expiration | --downloads)
        log_error "share: $1 does not apply to the ssh backend — the copy stays until share revoke"
        return 1 ;;
    esac
    shift
  done

  # Regular files only: a directory would need a recursive protocol, and a
  # file's basename is then never `.` or `..`. Names must be unique because
  # every file lands in the same per-share directory.
  # An array searched with (Ie), not an assoc: a hostile name holding `]`
  # or `(` is not something to feed a subscript.
  local p
  local -a seen=()
  for p in "$@"; do
    if [[ ! -f "$p" || ! -r "$p" ]]; then
      log_error "share: the ssh backend sends readable regular files only: $p"
      return 1
    fi
    if (( ${seen[(Ie)${p:t}]} )); then
      log_error "share: two files share the same name (${p:t}) — they would land in one directory"
      return 1
    fi
    seen+=("${p:t}")
  done
}

# share::ssh_remote_dir <endpoint> — `dir` plus a per-send stamp, so two sends
# of one filename never collide and a revoke never touches another share. A
# leading `~/` is stripped rather than expanded: a relative path already
# resolves against the remote $HOME, and a `~` inside a variable is never
# expanded by the remote shell anyway.
share::ssh_remote_dir() {
  zmodload zsh/datetime 2>/dev/null
  local dir
  dir="$(share::field "$1" dir)" || return 1
  case "$dir" in
    '~')   dir=. ;;
    '~/'*) dir="${dir#'~/'}"; [[ -n "$dir" ]] || dir=. ;;
  esac
  printf '%s/%s\n' "${dir%/}" "${EPOCHREALTIME/./}-$$"
}

# share::_ssh_remove <target> <dir> <name…>
share::_ssh_remove() {
  local target="$1" dir="$2"; shift 2
  { print -r -- "$dir"; print -rl -- "$@"; } \
    | share::_ssh_run "$target" "$SHARE_SSH_RM_SCRIPT" >/dev/null
}

# share::ssh_send <endpoint> <path…> — copy, record, print the pasteable line.
share::ssh_send() {
  setopt localoptions pipefail
  local endpoint="$1"; shift
  local target label rdir
  target="$(share::field "$endpoint" target)" || return 1
  label="$(share::label "$@")" || return 1
  rdir="$(share::ssh_remote_dir "$endpoint")" || return 1

  local -i n=$# i=0
  local src name out absdir=""
  local -a names=()
  for src in "$@"; do
    (( i += 1 ))
    name="${src:t}"
    names+=("$name")
    share::_progress $(( (i - 1) * 100 / n )) "copying $i/$n: $name"
    # pipefail: a local read error must fail the copy rather than let ssh
    # succeed on a truncated stream.
    out="$( { print -r -- "$rdir"; print -r -- "$name"; cat -- "$src"; } \
      | share::_ssh_run "$target" "$SHARE_SSH_RECV_SCRIPT")" || {
      log_error "share: ssh copy failed for $name ($target)"
      # Whatever already landed has no receipt, so nobody could revoke it.
      share::_ssh_remove "$target" "${absdir:-$rdir}" "${names[@]}" 2>/dev/null \
        || log_warn "share: could not clean up $target:${absdir:-$rdir}"
      return 1
    }
    # The last line: a chatty remote rc file may print before it.
    [[ -n "$absdir" ]] || absdir="${out##*$'\n'}"
  done
  if [[ "$absdir" != /* ]]; then
    log_error "share: $target did not report where the files landed (got: ${(V)absdir})"
    share::_ssh_remove "$target" "$rdir" "${names[@]}" 2>/dev/null
    return 1
  fi
  share::_progress 100 "copied"

  # The receipt carries its own target and directory, so a revoke still
  # reaches the right box after the manifest changes. Names ride jq's stdin:
  # one may start with `-`.
  local ref
  ref="$(print -rl -- "${names[@]}" \
    | jq -Rnc --arg t "$target" --arg d "$absdir" '{target:$t, dir:$d, names:[inputs]}')" || return 1

  # Shell-quoted, space-separated: pasted into a shell on that box, each path
  # arrives as one argument, whatever characters it holds.
  local -a paths=("${(@)names/#/$absdir/}")
  local line="${(j: :)${(@q-)paths}}"

  local id; id="$(share::gen_id)"
  share::ledger_add "$id" ssh "$endpoint" "$label" "$ref" "$line" 0
  print -r -- "$line"
}

# share::ssh_revoke <ref-json> — remove exactly the recorded names.
share::ssh_revoke() {
  local ref="$1" target dir name
  target="$(printf '%s' "$ref" | jq -r '.target // ""')"
  dir="$(printf '%s' "$ref" | jq -r '.dir // ""')"
  local -a names
  names=("${(@f)$(printf '%s' "$ref" | jq -r '.names[]?')}")
  # The receipt is local state, but it decides what gets deleted on another
  # machine: check it as if it were input.
  if [[ -z "$target" || "$target" == -* || "$dir" != /* || -z "${names[*]}" ]]; then
    log_error "share: refusing a malformed ssh receipt"
    return 1
  fi
  for name in "${names[@]}"; do
    if [[ -z "$name" || "$name" == */* || "$name" == . || "$name" == .. ]]; then
      log_error "share: refusing to remove ${(V)name} — not a plain file name"
      return 1
    fi
  done
  share::_ssh_remove "$target" "$dir" "${names[@]}" || {
    log_error "share: could not remove the copies on $target — receipt kept"
    return 1
  }
}

# share::ssh_status_row <endpoint> → "ssh\t<target>:<dir>\t<state>"
# `ssh -G` resolves the target through ~/.ssh/config OFFLINE (an alias, a
# custom port), then only the TCP port is probed: authenticating would mean a
# prompt, or a second factor, just to print a table.
share::ssh_status_row() {
  local name="$1" target dir cfg host port
  target="$(share::field "$name" target)"
  dir="$(share::field "$name" dir)"
  cfg="$(ssh -G -- "$target" 2>/dev/null)"
  host="$(printf '%s\n' "$cfg" | awk '$1 == "hostname" { print $2; exit }')"
  port="$(printf '%s\n' "$cfg" | awk '$1 == "port" { print $2; exit }')"
  [[ -n "$host" ]] || host="${target##*@}"
  [[ -n "$port" ]] || port=22
  if share::_probe_tcp "$host" "$port"; then
    printf 'ssh\t%s:%s\tsshd reachable (auth not checked)\n' "$target" "$dir"
  elif (( $? == 2 )); then
    printf 'ssh\t%s:%s\tcannot probe (no nc)\n' "$target" "$dir"
  else
    printf 'ssh\t%s:%s\tNOT REACHABLE\n' "$target" "$dir"
  fi
}
