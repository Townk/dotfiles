#!/usr/bin/env zsh
# no-real-waits.sh — count the real waits left in the test files.
#
# Policy (tests/README-scaffolding.md): a test never waits on the real clock.
# No `sleep`, no `timeout`/`gtimeout`, no `zselect`, no timed `read`, and no
# assertion on elapsed real time. Time is driven through the virtual clock
# (spec_clock_*), processes are joined with `wait`, and fakes act at a counted
# poll.
#
# Prints "<file> <waits> <clock-reads>" for every tests/*_spec.sh and
# tests/*_helper.sh that has any, sorted. A use is counted in COMMAND position
# only: the words in a comment, in an It/Describe title, in a `--timeout`
# flag being asserted, or as a job's own argument (`job::start -- sleep 5`)
# are not waits.
#
# tests/no_real_waits_spec.sh compares this with tests/no-real-waits.baseline:
# a file may not have MORE than its recorded count (a new wait), and may not
# have FEWER without the baseline being lowered (progress is locked in). When
# the baseline is empty it is deleted and the rule is simply "none".
#
# Exempt: spec_helper.sh and spec_helper_spec.sh implement and test the fake
# `sleep`; this file's own spec quotes the words as data.
emulate -L zsh
setopt extended_glob
cd "${1:-${0:A:h}}" || exit 2

local f
for f in *_spec.sh(N) *_helper.sh(N); do
  case "$f" in
    spec_helper.sh | spec_helper_spec.sh | no_real_waits_spec.sh) continue ;;
  esac
  perl -ne '
    next if /^\s*#/;                                   # comment line
    next if /^\s*(It|Describe|Context|Specify|Example|The|Skip|Pending|Todo)\b/;
    s/(?<![\$\w])#\s.*$//;                             # trailing comment
    my $l = $_;
    # command position: line start, after ; & | ( { `, after $( , or after
    # then/do/else/time/exec/command, optionally with a path in front.
    my $pos = qr/(?:^|[;&|(\{`]|\$\(|\b(?:then|do|else|exec|command|env)\s)\s*(?:\S*\/)?/;
    $w++ while $l =~ /$pos(?:sleep|timeout|gtimeout|zselect)\b(?!\s*\(\))/g;
    $w++ while $l =~ /\bread\b[^|;&]*\s-[A-Za-z]*t\b/g;  # read -t / -sk1 -t …
    $c++ while $l =~ /\b(?:EPOCHREALTIME|EPOCHSECONDS)\b|\$\{?SECONDS\b/g;
    END { printf "%s %d %d\n", $ARGV, $w // 0, $c // 0 if ($w // 0) + ($c // 0) }
  ' "$f"
done | sort
