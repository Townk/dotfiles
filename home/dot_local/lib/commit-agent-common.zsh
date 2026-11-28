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
# A worker is, in order:
#   defaults + --probe            (its own)
#   usage                         (its own text around cagent::usage_options_*)
#   cagent::parse_args "$@"       (+ optional cagent::worker_flag hook)
#   cagent::preflight <name>
#   trap cagent::cleanup EXIT INT TERM   (top level — see cagent::cleanup)
#   cagent::begin <name>
#   cached plan → cagent::load_cached_plan; otherwise
#     prompt="$(cagent::plan_prompt <conventions> <message-ref> <write-lead>)"
#     cagent::log_run_header <fields>; cagent::run_agent <label> <cmd…> "$prompt"
#   cagent::finish "$*" <no-plan hint lines…>
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
#   begin sets:      cagent_worker tmpdir plan_file state_dir log_file
#                    scope_clause extra_block cagent_agent_pid
#   finish sets:     commit_count
#   cache trio read: cache_file plan_file include_untracked commit_count

# Source the base + prompt module relative to THIS file.
_cagent_self="${(%):-%x}"
source "$(dirname "$_cagent_self")/common.zsh"
source "$(dirname "$_cagent_self")/prompt-common.zsh"
unset _cagent_self

# cagent::usage_options_head <agent-noun>
# cagent::usage_options_tail <output-noun>
# The option help every worker shares, split around the slot where a worker
# prints its own `-m` text and extra flags. <agent-noun> is who gets asked to
# re-plan ("Claude"); <output-noun> is whose output --verbose shows ("claude").
cagent::usage_options_head() {
  cat <<EOF
Options:
  -u, --untracked     Also include untracked files in the commits.
  -d, --dry-run       Print the plan (groupings + messages) without
                      staging or committing anything.
  -n, --no-commit     For each planned commit: stage the files, open
                      \$EDITOR with the message, then prompt to commit.
                      Saying No aborts without creating the commit.
  -f, --force-refresh
      --replan        Ignore any cached commit plan and ask $1 to
                      analyze the current working tree again.
EOF
}

cagent::usage_options_tail() {
  cat <<EOF
  -v, --verbose       Show $1 output as it plans.
  -h, --help          Show this help.

Extra positional args (after \`--\`) are passed to the agent as
additional commit guidance — file globs to scope to, scope hints,
JIRA references, etc.
EOF
}

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

# cagent::cleanup — the workers' exit handler: stop a still-running agent and
# drop the scratch dir. Install it from the worker's TOP LEVEL
# (`trap cagent::cleanup EXIT INT TERM`): zsh scopes an EXIT trap set inside a
# function to that function, so the lib cannot install it for the worker. It is
# safe to install before cagent::begin — every variable is read with a default.
cagent::cleanup() {
  if [[ -n "${cagent_agent_pid:-}" ]]; then
    kill "$cagent_agent_pid" 2>/dev/null
  fi
  if [[ -n "${tmpdir:-}" ]]; then
    rm -rf "$tmpdir"
  fi
  return 0
}

# cagent::begin <worker-name>
# Per-run scratch + log locations and the two prompt fragments derived from
# the parsed flags. <worker-name> keys the scratch dir prefix and the state
# dir (${XDG_STATE_HOME:-~/.local/state}/<worker-name>/errors.log).
cagent::begin() {
  cagent_worker="$1"
  cagent_agent_pid=""
  tmpdir="$(mktemp -d -t "${cagent_worker}.XXXXXX")"
  plan_file="$tmpdir/plan.json"

  state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/${cagent_worker}"
  mkdir -p "$state_dir"
  log_file="$state_dir/errors.log"

  scope_clause="modified (tracked) files only"
  [[ "$include_untracked" -eq 1 ]] && scope_clause="modified files AND untracked files"

  extra_block=""
  if [[ ${#extra_guidance[@]} -gt 0 ]]; then
    extra_block=$'\n\nAdditional guidance from the caller:\n'"${extra_guidance[*]}"
  fi
  return 0
}

# cagent::load_cached_plan — reuse the fingerprint-fresh cache as this run's plan.
cagent::load_cached_plan() {
  cp "$cache_file" "$plan_file"
  log_info "Using cached commit plan: $cache_file"
}

# cagent::plan_prompt <conventions> <message-ref> <write-lead>
# Print the planning prompt. This text is BEHAVIOUR — it is what the model is
# told — and it lives here once so the workers cannot drift apart again (the pi
# worker had lost the scope rule and the write-operation ban). A worker
# supplies only what is truly tool-specific:
#   <conventions>  paragraph(s) naming where message conventions come from
#                  (a skill path, "the project's commit skill", plain
#                  Conventional Commits)
#   <message-ref>  appended to "draft a polished message" in step 3, e.g.
#                  " per the commit skill" (empty for none)
#   <write-lead>   how this agent writes a file, e.g. "Use the Write tool to
#                  save the plan" or "Write the plan"
# Reads repo_root plan_file scope_clause extra_block.
cagent::plan_prompt() {
  local conventions="$1" message_ref="$2" write_lead="$3"
  cat <<EOF
You are PLANNING a series of git commits for the repository at:

\`${repo_root}\`

${conventions}

Important: DO NOT execute any \`git add\`, \`git commit\`, \`git push\`,
or other write operation in the repository. The calling script does all git
operations after you finish. You may run read-only git commands and read files
as needed. The only file you may create or modify is the JSON plan file below:

\`${plan_file}\`

Workflow:

1. Inspect the working tree with \`git status\`, \`git diff\`,
   \`git log\`, and per-file reads as needed. Scope: ${scope_clause}.
2. Group the changes into one or more logical commits. Prefer ONE
   commit when changes are coherent; only split when topics are
   clearly independent.
3. For each group, draft a polished message${message_ref}
   (subject + Markdown body sized to the change).
4. ${write_lead} as JSON at the absolute path
   \`${plan_file}\`. Do not just describe the plan in your reply — the
   calling script reads it from disk. The file MUST exist when you
   finish. Shape MUST be EXACTLY:

\`\`\`json
{
  "commits": [
    {
      "files": ["relative/path/one", "relative/path/two"],
      "message": "feat(scope): subject\\n\\n## Changes Description\\n\\n..."
    }
  ]
}
\`\`\`

Rules:
- File paths must be repo-relative, exactly as \`git status --short\` would
  identify them when run from the repository root.
- Every in-scope changed file must appear in exactly one commit's
  \`files\` array. No duplicates, no omissions.
- Do not include files outside the requested scope.
- \`message\` is the full commit message (subject + blank line + body
  when warranted); use JSON \`\\n\` for newlines.
- Do NOT add a \`Co-Authored-By\`, \`Signed-off-by\`, or any AI/agent
  attribution trailer to \`message\`. The repository owner is the sole
  author and sole responsible party for every commit.
- Do NOT stage. Do NOT commit. Do NOT push.
- When you are done, reply with the literal text \`PLAN_WRITTEN\` and
  nothing else.${extra_block}
EOF
}

# cagent::log_run_header <worker-fields>
# Append the per-run separator + settings line to the worker's log. The
# worker passes its own leading fields ("bin=… model=…"); the shared flag
# state follows.
cagent::log_run_header() {
  {
    print -- ""
    print -- "─── $(date '+%Y-%m-%d %H:%M:%S') ─────────────────────────"
    print -- "$1 untracked=$include_untracked dry_run=$dry_run no_commit=$no_commit force_refresh=$force_refresh cache=$cache_file"
  } >>"$log_file"
}

# cagent::run_agent <label> <command> [args…]
# Run the agent with its stdout+stderr always appended to the log (some agent
# TUIs clear the screen on exit, taking their error with them): streamed
# through tee with --verbose, otherwise in the background behind a spinner.
# Dies with "<label> failed (see <log>)" on a non-zero agent.
cagent::run_agent() {
  local label="$1"
  shift
  local rc=0
  if [[ "$verbose" -eq 1 ]]; then
    # `|| rc=…` keeps a non-zero agent from tripping errexit before rc is read,
    # so the diagnostic below is reachable. pipestatus[1] is the agent's status
    # (tee is [2]); reading it in the `||` branch is safe — a bare `|| true`
    # would reset pipestatus and mask the failure as rc=0.
    { "$@" 2>&1 | tee -a "$log_file" } || rc=${pipestatus[1]}
  else
    "$@" >>"$log_file" 2>&1 &
    cagent_agent_pid=$!

    spin::wait "$cagent_agent_pid" "thinking"
    # `|| rc=$?` keeps a non-zero agent from tripping errexit at `wait`, which
    # would abort before the diagnostic below and leave the user with silence.
    wait "$cagent_agent_pid" || rc=$?
    cagent_agent_pid=""
  fi

  [[ "$rc" -eq 0 ]] || die "$label failed (see $log_file)"
  return 0
}

# cagent::finish <original-args> [no-plan hint line…]
# Everything after the plan file should exist: the missing-plan diagnostic,
# shape validation, the summary, the dry-run/no-commit cache save, and the
# dry-run dump or the stage/commit loop. <original-args> is the worker's "$*"
# (echoed in the "regenerate" hint); the hint lines are the worker's own advice
# for an agent that replied without writing the plan.
cagent::finish() {
  local rerun_args="$1"
  shift
  local hint total_files

  if [[ ! -s "$plan_file" ]]; then
    if [[ "$use_cached_plan" -eq 1 ]]; then
      log_warn "the cached commit plan disappeared or is empty: $cache_file"
      log_warn "Regenerate it with:"
      log_warn "  ${cagent_worker} --force-refresh ${rerun_args}"
    else
      for hint in "$@"; do
        log_warn "$hint"
      done
    fi
    die "no plan written (see $log_file)"
  fi

  if ! cagent::validate_plan "$plan_file"; then
    if [[ "$use_cached_plan" -eq 1 ]]; then
      die "cached commit plan is invalid; rerun with --force-refresh (cache: $cache_file)"
    fi
    die "agent produced an invalid plan (see $log_file and $plan_file)"
  fi

  total_files=$(jq '[.commits[].files[]] | length' "$plan_file")
  [[ "$total_files" -gt 0 ]] || die "plan groups have no files"

  commit_count=$(jq -r '.commits | length' "$plan_file")

  cagent::print_plan_summary "$plan_file" "$commit_count"

  if [[ "$dry_run" -eq 1 || "$no_commit" -eq 1 ]]; then
    cagent::save_plan_cache
  fi

  if [[ "$dry_run" -eq 1 ]]; then
    cagent::print_dry_run "$plan_file"
    exit 0
  fi

  cagent::execute_plan "$plan_file" "$commit_count" "$tmpdir" "$no_commit" cagent::save_remaining_plan_cache
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
