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
if [ -n "${BASH_SOURCE:-}" ]; then
  _cagent_self="${BASH_SOURCE[0]}"
else
  _cagent_self="${(%):-%x}"
fi
source "$(dirname "$_cagent_self")/common.sh"
source "$(dirname "$_cagent_self")/prompt-common.zsh"
unset _cagent_self

# cagent::spinner <pid>
# Braille spinner with elapsed seconds while <pid> runs, so the user knows the
# model is still thinking. No-op when stderr isn't a TTY (piped/non-interactive).
cagent::spinner() {
  local pid="$1"
  [[ -t 2 ]] || return 0
  local spinner=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  local start=$SECONDS s=1 elapsed
  while kill -0 "$pid" 2>/dev/null; do
    elapsed=$((SECONDS - start))
    print -nu2 -- "\r  ${C_BLU}${spinner[s]}${C_RES} ${elapsed}s  "
    sleep 0.1
    s=$(( s % 10 + 1 ))
  done
  print -nu2 -- "\r\e[K"
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
  [[ ${#files[@]} -gt 0 ]] || { log_warn "commit $((idx + 1)) has no files; skipping"; return 1; }
  git add -- "${files[@]}"
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
    jq -r ".commits[$i].message" "$plan_file" > "$msg_file"

    print -P -- "${C_BLU}── commit $((i + 1)) of ${commit_count} ──${C_RES}"

    cagent::stage_commit "$plan_file" "$i" \
      || { cagent::unstage_all; die "failed to stage files for commit $((i + 1))"; }

    if [[ "$no_commit" -eq 1 ]]; then
      "${EDITOR:-vi}" "$msg_file"

      # Re-empty check: if the editor leaves a blank file, abort that commit.
      if ! grep -q '[^[:space:]]' "$msg_file"; then
        log_warn "empty commit message; aborting"
        cagent::unstage_all
        return 0
      fi

      if prompt::confirm "Create this commit?"; then
        git commit --quiet -F "$msg_file" \
          || { cagent::unstage_all; die "git commit failed"; }
        "$post_hook" $((i + 1))
        log_ok "committed: $(git log -1 --pretty=%s)"
      else
        cagent::unstage_all
        log_info "aborted at commit $((i + 1)); no further commits will be created"
        return 0
      fi
    else
      git commit --quiet -F "$msg_file" \
        || { cagent::unstage_all; die "git commit failed"; }
      "$post_hook" $((i + 1))
      log_ok "committed: $(git log -1 --pretty=%s)"
    fi

    i=$((i + 1))
  done

  print -P -- "\n${C_GRN}Done.${C_RES} Created ${commit_count} commit(s)."
}
