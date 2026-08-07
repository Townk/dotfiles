#!/usr/bin/env zsh
# D7: how the daemon raises the OSD.
#
# The notification UI stays in Hammerspoon (spec §14.3), so the daemon has to
# reach it. Two options:
#   1. spawn `hs` per notification, as today;
#   2. a persistent subscription — Hammerspoon holds a connection to the trusted
#      socket and the daemon streams notifications as `D` frames.
#
# Option 2's saving is exactly option 1's cost, so measuring option 1 is what
# decides it. What is measured here is the *delivery* mechanism only: the script
# each arm runs is `return 1`, not a toast, because drawing the toast happens
# inside Hammerspoon either way and is common to both options.
#
# Both arms run in one session and in both orders, per the audit brief's warning
# that arms measured minutes apart drift by around 20 ms.
#
#   ./d7-osd-delivery.zsh          # needs hyperfine and a running Hammerspoon

setopt err_return
command -v hyperfine >/dev/null || { print -u2 "needs hyperfine"; exit 1 }
command -v hs >/dev/null || { print -u2 "needs the hs CLI"; exit 1 }
pgrep -qf 'Hammerspoon.app/Contents/MacOS/Hammerspoon' || {
  print -u2 "Hammerspoon is not running; every arm would measure a failure"
  exit 1
}

tmp=$(mktemp -d /tmp/recob-d7.XXXXXX)
trap 'rm -rf -- "$tmp"' EXIT
print -r -- 'return 1' > "$tmp/noop.lua"

print -r -- "== the delivery mechanism the current code uses"
print -r -- "   clip::hs_run runs a script FILE: 'hs -c' is recorded as unreliable"
print -r -- "   (observed to hang even on trivial code) in clipboard-platform-macos.zsh:27."
hyperfine --warmup 3 --runs 20 --style basic \
  -n "hs <file>  (round trip)" "hs $tmp/noop.lua" \
  -n "/usr/bin/true (spawn floor)" "/usr/bin/true"

print -r -- ""
print -r -- "== reversed order, to cancel drift"
hyperfine --warmup 3 --runs 20 --style basic \
  -n "/usr/bin/true (spawn floor)" "/usr/bin/true" \
  -n "hs <file>  (round trip)" "hs $tmp/noop.lua"

print -r -- ""
print -r -- "== for the record: hs -c, the form the shell library refuses to use"
print -r -- "   Timed out at 5s per run if it hangs, which is the behavior that"
print -r -- "   disqualified it."
hyperfine --warmup 1 --runs 10 --style basic --ignore-failure \
  -n "hs -c" "timeout 5 hs -c 'return 1'" || true

print -r -- ""
print -r -- "== what the DAEMON pays, as opposed to what the toast costs"
print -r -- "   §3.4 gives each connection its own task, so a spawn blocks only the"
print -r -- "   connection that asked for a toast. And the caller already backgrounds"
print -r -- "   the notify (mux/scripts/executable_copy-pwd:155), so this latency is"
print -r -- "   not on the path the human waits for either way."
