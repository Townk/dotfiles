#!/usr/bin/env zsh
# make test-changed: run only the specs the diff against master can reach.
#
#   tests/test-changed.sh                 diff against master, then run
#   tests/test-changed.sh select FILE...  print the selection for FILE... only
#
# A spec is selected when it changed itself, or when it textually references
# a changed file: a home/dot_local/lib/**/*.zsh library (by its source path
# dot_local/lib/<rel> or its rendered path .local/lib/<rel>), or a non-spec
# helper under tests/ (tests/<name>). The reference is textual only — a spec
# that reaches a library through a script that sources it is NOT selected;
# `make test` is still the lane to trust before landing.
#
# Changes to the Makefile, .shellspec, or tests/spec_helper.sh touch every
# spec, so the selection cannot be trusted and the full `test` lane runs
# instead. So does a missing master to diff against.
#
# `select` prints one spec path per line and exits 0 (an empty selection is
# still 0), or prints the fallback reason and exits 3. TEST_CHANGED_ROOT
# points it at another tree (the spec drives it against a fixture).
setopt err_return no_unset extended_glob

root=${TEST_CHANGED_ROOT:-${0:A:h:h}}
base=${TEST_CHANGED_BASE:-master}

# select FILE... — the spec selection for a list of repo-relative changed paths.
select_specs() {
  local file spec rel
  local -a hits patterns
  local -A picked
  for file in "$@"; do
    case $file in
      Makefile|.shellspec|tests/spec_helper.sh)
        print -r -- "$file changed; every spec depends on it"
        return 3 ;;
    esac
  done
  for file in "$@"; do
    case $file in
      tests/*/*) ;;
      tests/*_spec.sh) [[ -f $root/$file ]] && picked[$file]=1 ;;
      tests/*) patterns+=("${file//./\\.}") ;;
      home/dot_local/lib/*.zsh)
        rel=${file#home/dot_local/lib/}
        patterns+=("(dot_local|\\.local)/lib/${rel//./\\.}") ;;
    esac
  done
  if (( $#patterns )); then
    for spec in $root/tests/*_spec.sh(N); do
      grep -qE -- "${(j:|:)patterns}" $spec && picked[tests/${spec:t}]=1
    done
  fi
  (( $#picked )) && print -rl -- ${(ko)picked}
  return 0
}

# Every path that differs from where this branch left master: committed,
# staged, unstaged, and untracked. Run from $root.
changed_files() {
  local fork
  fork=$(git merge-base "$base" HEAD 2>/dev/null) || return 1
  git diff --name-only "$fork" --
  git ls-files --others --exclude-standard
}

main() {
  local -a files specs
  local reason out rc=0
  if [[ ${1-} == select ]]; then
    shift
    select_specs "$@"
    return
  fi
  cd "$root"
  if ! out=$(changed_files); then
    reason="cannot diff against $base"
  else
    files=(${(f)out})
    out=$(select_specs $files) || rc=$?
    (( rc == 3 )) && reason=$out
  fi
  if [[ -n ${reason-} ]]; then
    print -r -- "test-changed: $reason; running the full test lane"
    ${MAKE:-make} --no-print-directory test
    return
  fi
  specs=(${(f)out})
  if (( ! $#specs )); then
    print -r -- "test-changed: no spec is affected by the diff against $base; nothing to run"
    return 0
  fi
  print -r -- "test-changed: running $#specs spec(s) affected by the diff against $base:"
  print -rl -- "  "${^specs}
  tests/run-shellspec.sh $specs
}

main "$@"
