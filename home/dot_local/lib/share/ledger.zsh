#!/usr/bin/env zsh
# share/ledger.zsh — the receipt ledger backing `share list` and `share revoke`.
# SOURCED by share.zsh, never executed.
#
# croc writes its own store-receipts.json, but it records nothing about WHICH
# endpoint a transfer used, and the rclone backend leaves no receipt at all. So
# this is the union view. `id` is our key; `ref` is the backend handle (a croc
# transfer id, or an rclone remote path) that revoke dispatches on.
#
# JSONL, appended: a share is a single line written once, so there is no
# read-modify-write race worth locking against. Removal rewrites atomically.

SHARE_LEDGER_FILE="${SHARE_LEDGER_FILE:-}"

share::_ledger_file() {
  printf '%s\n' "${SHARE_LEDGER_FILE:-$SHARE_STATE_DIR/ledger.jsonl}"
}

# share::gen_id — microseconds, matching job::start's id convention: one process
# may record several shares inside the same second.
share::gen_id() {
  zmodload zsh/datetime 2>/dev/null
  printf '%s-%s\n' "${EPOCHREALTIME/./}" "$$"
}

# share::ledger_add <id> <backend> <endpoint> <label> <ref> <url> <expires_epoch>
#
# `ref` and `url` never ride jq's own argv (`--arg`): this file's ledger row
# is exactly what a stored-mode send's URL (key in the fragment) and a
# live-mode send's code phrase look like — a secret. `--arg ref "$5"` puts
# that value on JQ'S command line, and on Linux (a shared corporate box is
# the dev-shell's own description) /proc/<pid>/cmdline is world-readable for
# the lifetime of the process, however brief. Passing both through jq's OWN
# environment instead (`$ENV.ref` / `$ENV.url`, fed by a prefix assignment
# scoped to this one jq invocation) keeps them off argv entirely; `id`,
# `backend`, `endpoint` and `label` carry nothing secret and stay as --arg.
#
# The ledger file itself holds every one of those secrets in cleartext, so
# it is created (and only ever appended to, never widened) under a scoped
# `umask 077` — 0600, readable by nobody but the owner. The subshell keeps
# that umask from leaking into the rest of this process.
share::ledger_add() {
  zmodload zsh/datetime 2>/dev/null
  local file; file="$(share::_ledger_file)"
  (
    umask 077
    mkdir -p -- "${file:h}"
    ref="$5" url="$6" jq -nc \
      --arg id "$1" --arg backend "$2" --arg endpoint "$3" --arg label "$4" \
      --argjson expires "${7:-0}" --argjson created "$EPOCHSECONDS" \
      '{id:$id, backend:$backend, endpoint:$endpoint, label:$label,
        ref:$ENV.ref, url:$ENV.url, expires:$expires, created:$created}' >>"$file"
  )
}

share::ledger_list() {
  local file; file="$(share::_ledger_file)"
  [[ -f "$file" ]] || { printf '[]\n'; return 0; }
  jq -s 'sort_by(.created) | reverse' "$file"
}

share::ledger_get() {
  local file; file="$(share::_ledger_file)"
  [[ -f "$file" ]] || return 1
  jq -se --arg id "$1" 'map(select(.id == $id)) | if length > 0 then .[0] else null end' \
    "$file" | jq -e '. != null' >/dev/null 2>&1 || return 1
  jq -s --arg id "$1" 'map(select(.id == $id)) | .[0]' "$file"
}

# Atomic rewrite: a torn ledger would lose every receipt, not just one.
share::ledger_remove() {
  local file tmp; file="$(share::_ledger_file)"
  [[ -f "$file" ]] || return 0
  tmp="$file.tmp.$$"
  jq -c --arg id "$1" 'select(.id != $id)' "$file" >"$tmp" \
    && mv -f -- "$tmp" "$file"
}

share::ledger_overdue() {
  zmodload zsh/datetime 2>/dev/null
  local file; file="$(share::_ledger_file)"
  [[ -f "$file" ]] || return 0
  jq -r --argjson now "$EPOCHSECONDS" \
    'select(.expires > 0 and .expires < $now) | .id' "$file"
}
