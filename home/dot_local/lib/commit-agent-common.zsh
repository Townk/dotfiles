#!/usr/bin/env zsh
# commit-agent-common.zsh — shared engine for the AI-driven commit harnesses
# (ai-commit-pi, ai-commit-cursor) behind the `ai-commit` dispatcher. They
# differ in how they invoke their agent and whether they cache the plan;
# everything from the plan onward — the thinking spinner, the plan summary, the
# dry-run dump, and the stage/commit loop — was duplicated and now lives here.
#
# SOURCED, never executed. Pulls in the base (C_*, log_*, die) and the prompt
# module (prompt::confirm), so a front-end only needs to source THIS file.

# Source the base + prompt module relative to THIS file.
_cagent_self="${(%):-%x}"
source "$(dirname "$_cagent_self")/common.zsh"
source "$(dirname "$_cagent_self")/prompt-common.zsh"
unset _cagent_self

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
# is called with the NEXT index (commit-cursor uses it to shrink its plan
# cache; commit-ai passes the no-op `:`).
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
