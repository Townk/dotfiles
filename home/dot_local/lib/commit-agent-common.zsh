#!/usr/bin/env zsh
# commit-agent-common.zsh — shared engine for the AI-driven commit harnesses
# (ai-commit-claude, ai-commit-cursor, ai-commit-pi) behind the `ai-commit`
# dispatcher. The workers differ only in how they build their prompt and
# invoke their agent; everything else — argument parsing, pre-flight, the
# fingerprint-bound plan cache, the plan summary, the dry-run dump, and the
# stage/commit loop — lives here so the three can never drift again (the pi
# worker shipped for months without the cache subsystem its siblings had).
#
# SOURCED, never executed. Pulls in the base (C_*, log_*, die) and the prompt
# module (prompt::confirm), so a front-end only needs to source THIS file.
#
# Worker contract (zsh dynamic scope — the cagent:: helpers read and set the
# caller's conventionally-named globals rather than threading a dozen args):
#   usage            function printing the worker's help (parse_args calls it)
#   cagent::worker_flag  OPTIONAL hook for worker-specific flags — called with
#                    the remaining argv on an unrecognized `-…`; consume by
#                    setting REPLY=<arg count> and returning 0, or return
#                    non-zero for "not mine" (parse_args then dies).
#   parse_args sets: include_untracked dry_run no_commit force_refresh
#                    verbose extra_guidance
#   preflight sets:  repo_root cache_file use_cached_plan have_modified
#                    have_untracked
#   cache trio read: cache_file plan_file include_untracked commit_count

# Source the base + prompt module relative to THIS file.
_cagent_self="${(%):-%x}"
source "$(dirname "$_cagent_self")/common.zsh"
source "$(dirname "$_cagent_self")/prompt-common.zsh"
unset _cagent_self

# cagent::parse_args "$@"
# The universal worker CLI (every flag here is part of the cross-harness
# contract the `ai-commit` dispatcher forwards verbatim). Worker-specific
# flags ride the cagent::worker_flag hook — see the header contract. `-m` is
# universal but the model DEFAULT is per-worker: initialize `model` before
# calling.
cagent::parse_args() {
  include_untracked=0
  dry_run=0
  no_commit=0
  force_refresh=0
  verbose=0
  extra_guidance=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -u | --untracked)
        include_untracked=1
        shift
        ;;
      -d | --dry-run)
        dry_run=1
        shift
        ;;
      -n | --no-commit)
        no_commit=1
        shift
        ;;
      -f | --force-refresh | --replan)
        force_refresh=1
        shift
        ;;
      -m | --model)
        [[ $# -ge 2 ]] || die "--model needs a value"
        model="$2"
        shift 2
        ;;
      -v | --verbose)
        verbose=1
        shift
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      --)
        shift
        extra_guidance=("$@")
        break
        ;;
      -*)
        if typeset -f cagent::worker_flag >/dev/null && cagent::worker_flag "$@"; then
          shift "$REPLY"
        else
          usage >&2
          die "unknown flag: $1"
        fi
        ;;
      *)
        extra_guidance=("$@")
        break
        ;;
    esac
  done

  [[ "$dry_run" -eq 1 && "$no_commit" -eq 1 ]] &&
    die "--dry-run and --no-commit are mutually exclusive"
  return 0
}

# cagent::preflight <worker-name>
# Everything between arg parsing and prompt building: tool checks, repo-root
# cd, the per-worker plan-cache resolution + freshness gate, the staged-changes
# refusal, and change detection with the two clean/untracked-only early exits.
# <worker-name> keys the cache path (.git/<worker-name>-plan.json — unchanged
# from the pre-consolidation per-worker paths, so existing caches stay valid).
cagent::preflight() {
  local _cagent_worker="$1"
  command -v git >/dev/null 2>&1 || die "git not on PATH"
  command -v jq >/dev/null 2>&1 || die "jq is required to parse the agent's plan"

  repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" ||
    die "not inside a git repository"
  builtin cd "$repo_root" || die "could not cd to repository root: $repo_root"

  cache_file="$(git rev-parse --git-path "${_cagent_worker}-plan.json")" ||
    die "could not resolve git cache path"
  cache_file="${cache_file:a}"
  use_cached_plan=0
  if [[ -s "$cache_file" && "$force_refresh" -eq 0 ]]; then
    # A cache is only honoured when its stored fingerprint still matches the
    # current tree + scope (bug #4a); a stale cache is discarded so we re-plan
    # rather than staging bytes the plan was never generated for.
    if cagent::cache_is_fresh "$cache_file" "$include_untracked"; then
      use_cached_plan=1
    else
      log_info "cached commit plan is stale (working tree or scope changed); re-planning"
      rm -f "$cache_file"
    fi
  fi

  # Refuse pre-existing staged changes — keeps dry-run / no-commit / default
  # modes from getting tangled with whatever the user had half-staged. The
  # user can `git reset` (to unstage) or `git commit` (to commit them) first.
  if ! git diff --cached --quiet; then
    die "you already have staged changes; \`git reset\` to unstage (or commit them) first"
  fi

  have_modified=0
  git diff --quiet || have_modified=1

  have_untracked=0
  [[ -n "$(git ls-files --others --exclude-standard)" ]] && have_untracked=1

  if [[ "$have_modified" -eq 0 && "$have_untracked" -eq 0 ]]; then
    [[ -e "$cache_file" ]] && rm -f "$cache_file"
    log_ok "nothing to commit, working tree clean"
    exit 0
  fi
  if [[ "$have_modified" -eq 0 && "$include_untracked" -eq 0 && "$use_cached_plan" -eq 0 ]]; then
    log_warn "only untracked files present; pass -u/--untracked to include them"
    exit 0
  fi
  return 0
}

# cagent::save_plan_cache — persist the current plan, fingerprint-stamped.
cagent::save_plan_cache() {
  local tmp_cache fp
  mkdir -p "${cache_file:h}"
  # Bind the cache to the state it was generated for (bug #4a): stamp the
  # current fingerprint into the cached plan so a later run can detect a
  # drifted tree/scope and re-plan.
  fp="$(cagent::plan_fingerprint "$include_untracked")"
  tmp_cache="${cache_file}.$$"
  jq --arg fp "$fp" '. + {fingerprint: $fp}' "$plan_file" >"$tmp_cache"
  mv "$tmp_cache" "$cache_file"
  log_ok "saved commit plan cache: $cache_file"
}

cagent::clear_plan_cache() {
  # `[[ -e ]] && rm` returns non-zero when the cache is already gone (e.g. it
  # was discarded as stale on load), which trips the script's `set -e` if this
  # is the last command in a caller. Force a zero return.
  [[ -e "$cache_file" ]] && rm -f "$cache_file"
  return 0
}

# cagent::save_remaining_plan_cache <next_idx> — the execute_plan post-commit
# hook: shrink the cache to the not-yet-landed groups (or clear it when done).
cagent::save_remaining_plan_cache() {
  local next_idx="$1"
  local remaining=$((commit_count - next_idx))
  local tmp_cache fp

  if [[ "$remaining" -le 0 ]]; then
    cagent::clear_plan_cache
    return 0
  fi

  mkdir -p "${cache_file:h}"
  # A commit just landed, so the tree changed: re-stamp the fingerprint for
  # the NOW-current state so the remaining-plan cache is re-verified against
  # the post-commit tree on the next run (bug #4a).
  fp="$(cagent::plan_fingerprint "$include_untracked")"
  tmp_cache="${cache_file}.$$"
  jq --argjson start "$next_idx" --arg fp "$fp" \
    '{fingerprint: $fp, commits: .commits[$start:]}' "$plan_file" >"$tmp_cache"
  mv "$tmp_cache" "$cache_file"
  log_info "updated commit plan cache with ${remaining} remaining commit(s)"
}

# cagent::validate_plan <plan_file>
# The shared plan-shape contract every worker enforces before staging:
# `.commits` is a non-empty array AND every group carries a non-empty `files`
# array and a non-empty `message` string. Rejecting a message-less group here
# is what stops `.commits[i].message` from resolving to null and committing a
# real commit with the literal subject "null". Returns non-zero for any
# violation (and swallows jq's diagnostic — callers print their own).
cagent::validate_plan() {
  local plan_file="$1"
  jq -e '
    .commits | type == "array" and length > 0 and
    all(.[]; (.files | type == "array" and length > 0) and
             (.message | type == "string" and length > 0))
  ' "$plan_file" >/dev/null 2>&1
}

# cagent::plan_fingerprint <include_untracked>
# A content-sensitive digest of the exact git state a plan was generated for,
# used to bind the plan cache to that state (bug #4a). It folds together, into
# a single stable hash:
#   * HEAD (so a landed commit invalidates a cached "remaining" plan),
#   * the scope flag in effect (tracked-only vs +untracked), and
#   * the CONTENT of every in-scope change — the full `git diff HEAD` of
#     tracked modifications, plus the path list and per-file blob hash of
#     untracked files when they are in scope.
# Editing a planned file changes its diff/blob hash, so the fingerprint
# changes and the cache is rejected. `emulate -L zsh` keeps the caller's
# `set -e`/`pipefail` from aborting mid-helper on an expected non-zero probe.
cagent::plan_fingerprint() {
  emulate -L zsh
  local include_untracked="${1:-0}"
  local head
  head="$(git rev-parse HEAD 2>/dev/null)" || head=""
  {
    print -r -- "head=$head"
    print -r -- "scope_untracked=$include_untracked"
    print -r -- "--- tracked ---"
    # HEAD vs working tree (the index equals HEAD — the workers refuse
    # pre-existing staged changes). Falls back to `git diff` in a repo with
    # no commits yet.
    git --no-pager -c core.quotepath=false diff --no-color --no-ext-diff HEAD 2>/dev/null ||
      git --no-pager -c core.quotepath=false diff --no-color --no-ext-diff 2>/dev/null
    if [[ "$include_untracked" -eq 1 ]]; then
      print -r -- "--- untracked ---"
      git ls-files --others --exclude-standard 2>/dev/null
      git ls-files --others --exclude-standard -z 2>/dev/null |
        xargs -0 git hash-object 2>/dev/null
    fi
  } | git hash-object --stdin 2>/dev/null
}

# cagent::cache_is_fresh <cache_file> <include_untracked>
# The load-time guard: a cached plan is only honoured when its stored
# `fingerprint` still equals the fingerprint recomputed against the CURRENT
# tree + scope. A missing/empty cache, a cache with no stored fingerprint
# (legacy/bare), or a fingerprint mismatch all return non-zero so the caller
# re-plans instead of staging stale bytes.
cagent::cache_is_fresh() {
  emulate -L zsh
  local cache_file="$1" include_untracked="${2:-0}"
  [[ -s "$cache_file" ]] || return 1
  local stored current
  stored="$(jq -r '.fingerprint // empty' "$cache_file" 2>/dev/null)"
  [[ -n "$stored" ]] || return 1
  current="$(cagent::plan_fingerprint "$include_untracked")"
  [[ "$stored" == "$current" ]]
}

# cagent::print_plan_summary <plan_file> <commit_count>
# The "Planned N commit(s)" header + one subject/file-list block per commit.
cagent::print_plan_summary() {
  local plan_file="$1" commit_count="$2"
  print -P -- "\n${C_BWH}Planned ${commit_count} commit(s)${C_RES}\n"
  jq -r '
    .commits | to_entries[] |
    "── #\(.key + 1) ──\n" +
    (.value.message | split("\n")[0]) + "\n" +
    (.value.files | map("  " + .) | join("\n")) + "\n"
  ' "$plan_file"
}

# cagent::print_dry_run <plan_file>
# Full plan dump (files + complete message per commit) for --dry-run.
cagent::print_dry_run() {
  local plan_file="$1"
  print -P -- "${C_DIM}(dry run — no commits created)${C_RES}\n"
  jq -r '
    .commits | to_entries[] |
    "──────────── commit #\(.key + 1) ────────────\n" +
    "Files (\(.value.files | length)):\n" +
    (.value.files | map("  " + .) | join("\n")) + "\n\n" +
    "Message:\n" +
    .value.message + "\n"
  ' "$plan_file"
}

# cagent::unstage_all — reset the index (best-effort) after an aborted commit.
cagent::unstage_all() { git reset --quiet 2>/dev/null || true; }

# cagent::stage_commit <plan_file> <idx>
# Stage exactly the files of commit group <idx>. Returns non-zero (and warns)
# for an empty group. Empty array elements (a zero-file group splits to one "")
# are dropped before the length guard so `git add -- ""` can't happen.
cagent::stage_commit() {
  local plan_file="$1" idx="$2"
  local files
  files=("${(@f)$(jq -r ".commits[$idx].files[]" "$plan_file")}")
  files=(${files:#})
  [[ ${#files[@]} -gt 0 ]] || {
    log_warn "commit $((idx + 1)) has no files; skipping"
    return 1
  }
  # `--` stops OPTION parsing but does NOT disable pathspec MAGIC, so a
  # model-emitted `:(top,glob)**`, `:(exclude)…`, etc. would expand beyond the
  # named files (bug #4b). `--literal-pathspecs` treats every plan path as a
  # literal filename, neutralising all `:(…)` / `:/` magic.
  git --literal-pathspecs add -- "${files[@]}"
}

# cagent::execute_plan <plan_file> <commit_count> <tmpdir> <no_commit> [post_commit_hook]
# Stage + commit each group in turn. With no_commit=1, open $EDITOR on the
# message and prompt::confirm before committing (an empty message or a "no"
# aborts cleanly). After each successful commit, the optional post_commit_hook
# is called with the NEXT index — every worker passes
# cagent::save_remaining_plan_cache so an aborted multi-commit run resumes
# from the surviving groups.
cagent::execute_plan() {
  local plan_file="$1" commit_count="$2" tmpdir="$3" no_commit="$4" post_hook="${5:-:}"
  local i=0 msg_file
  while [[ "$i" -lt "$commit_count" ]]; do
    msg_file="$tmpdir/msg-$i.txt"
    jq -r ".commits[$i].message" "$plan_file" >"$msg_file"

    print -P -- "${C_BLU}── commit $((i + 1)) of ${commit_count} ──${C_RES}"

    cagent::stage_commit "$plan_file" "$i" ||
      {
        cagent::unstage_all
        die "failed to stage files for commit $((i + 1))"
      }

    if [[ "$no_commit" -eq 1 ]]; then
      "${EDITOR:-vi}" "$msg_file"

      # Re-empty check: if the editor leaves a blank file, abort that commit.
      if ! grep -q '[^[:space:]]' "$msg_file"; then
        log_warn "empty commit message; aborting"
        cagent::unstage_all
        return 0
      fi

      if prompt::confirm "Create this commit?"; then
        git commit --quiet -F "$msg_file" ||
          {
            cagent::unstage_all
            die "git commit failed"
          }
        "$post_hook" $((i + 1))
        log_ok "committed: $(git log -1 --pretty=%s)"
      else
        cagent::unstage_all
        log_info "aborted at commit $((i + 1)); no further commits will be created"
        return 0
      fi
    else
      git commit --quiet -F "$msg_file" ||
        {
          cagent::unstage_all
          die "git commit failed"
        }
      "$post_hook" $((i + 1))
      log_ok "committed: $(git log -1 --pretty=%s)"
    fi

    i=$((i + 1))
  done

  print -P -- "\n${C_GRN}Done.${C_RES} Created ${commit_count} commit(s)."
}
