# tests/rip-finder-service_spec.sh — the Finder Quick Action's embedded
# shell script (home/dot_local/share/services/Contents/document.wflow).
#
# The Automator bundle itself (plists wiring a Finder service to a "Run
# Shell Script" action) cannot be meaningfully unit-tested — that needs a
# human right-clicking a folder in Finder. But the script INSIDE the
# bundle has real logic (a loop, an escaping scheme) and is fully
# testable, so this file extracts it VERBATIM with
# `plutil -extract ... raw` and runs THAT — never a copy pasted in here,
# which could silently drift from what Finder actually invokes and make
# this suite unable to fail.
#
# RULING 8b is the whole point of this file: the brief's rejected
# `[[$d]]` (Lua long-bracket) approach breaks on a folder literally named
# `x]]..os.execute("...")..[[`. Instead the script base64-encodes the
# path and decodes it on the Lua side (hs.base64.decode) — an alphabet of
# [A-Za-z0-9+/=] is provably safe inside both the outer shell double
# quotes and the Lua single-quoted string, no escaping analysis required.
# Every test below that passes an awkward folder name decodes the
# captured base64 payload with the system `base64 -d` and asserts
# byte-identical recovery.
#
# RULING 8a: the script must `require('ripper')`, matching init.lua:18 —
# NOT `require('modules.ripper')`, which resolves to a SECOND, distinct
# package.loaded entry (modules/system/bootstrap.lua puts both
# `modules/?.lua` and `modules/?/init.lua` on package.path) and would
# construct a second ripper instance with its own webview, untouched by
# the live one.
#
# Interception technique: /opt/homebrew/bin/hs is the REAL, live
# Hammerspoon symlink on this machine and must never be invoked — but the
# script hardcodes that absolute path (correct: Finder's environment has
# no useful PATH), so a PATH-prepended stub named "hs" would never be
# reached. Bash's `function name { ... }` form (unlike the POSIX
# `name() { ... }` form, which rejects a slash-bearing name outright)
# defines a function keyed by that literal string, and function lookup —
# unlike PATH search — still fires for a command word containing a slash,
# taking priority even over a real file that exists at that path. This
# was hand-verified against /bin/echo before relying on it here: the
# function intercepted the call, and /bin/echo itself was provably
# unmodified and callable normally immediately after. The shadow lives
# only inside the one `bash -c` subprocess spawned below — nothing on
# disk is touched, and the real Hammerspoon instance (a different
# process entirely) is never contacted.
Describe 'audiobook Finder Quick Action'
  WFLOW="$SHELLSPEC_PROJECT_ROOT/home/dot_local/share/services/Contents/document.wflow"
  INFO_PLIST="$SHELLSPEC_PROJECT_ROOT/home/dot_local/share/services/Contents/Info.plist"

  setup() {
    SANDBOX=$(mktemp -d)
    LOGDIR="$SANDBOX/calls"
    COUNTER="$SANDBOX/counter"
    mkdir -p "$LOGDIR"
    SCRIPT_FILE="$SANDBOX/extracted-script.sh"
    plutil -extract actions.0.action.ActionParameters.COMMAND_STRING raw -o - "$WFLOW" \
      > "$SCRIPT_FILE"
  }
  cleanup() { rm -rf "$SANDBOX"; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  # Runs the ACTUAL extracted script against the given folder names. Each
  # call the script makes to /opt/homebrew/bin/hs is recorded as its own
  # "$LOGDIR/call-N.args" file, one argv element per line, in call order.
  run_service() {
    SCRIPT_FILE="$SCRIPT_FILE" LOGDIR="$LOGDIR" COUNTER="$COUNTER" bash -c '
      function /opt/homebrew/bin/hs {
        n=$(( $(cat "$COUNTER" 2>/dev/null || echo 0) + 1 ))
        echo "$n" > "$COUNTER"
        : > "$LOGDIR/call-$n.args"
        for a in "$@"; do printf "%s\n" "$a" >> "$LOGDIR/call-$n.args"; done
      }
      . "$SCRIPT_FILE"
    ' bash "$@"
  }

  call_count() { cat "$COUNTER" 2>/dev/null || echo 0; }
  call_line() { sed -n "${2}p" "$LOGDIR/call-$1.args"; }
  # The Lua string is always argv[3] (`-q`, `-c`, then the command),
  # shaped `require('ripper').browse(require('hs.base64').decode('B64'))`.
  decoded_path() {
    b64=$(call_line "$1" 3 | sed -E "s/.*decode\('([^']*)'\)\).*/\1/")
    printf '%s' "$b64" | base64 -d
  }

  It 'both bundle plists lint clean'
    The value "$(plutil -lint "$INFO_PLIST" 2>&1)" should include "OK"
    The value "$(plutil -lint "$WFLOW" 2>&1)" should include "OK"
  End

  It 'requires the live ripper module, never a second modules.ripper instance (RULING 8a)'
    The value "$(cat "$SCRIPT_FILE")" should include "require('ripper')"
    The value "$(cat "$SCRIPT_FILE")" should not include "modules.ripper"
  End

  It 'always passes -q ahead of -c (the recursive-IPC GUI wedge guard)'
    run_service "/tmp/plain-folder"
    The value "$(call_line 1 1)" should equal "-q"
    The value "$(call_line 1 2)" should equal "-c"
  End

  It 'passes a plain folder path through byte-identical'
    folder="/Users/thiago/Audiobooks/Some Book"
    run_service "$folder"
    The value "$(call_count)" should equal "1"
    The value "$(decoded_path 1)" should equal "$folder"
  End

  It 'survives ]], a double quote, a single quote, literal $HOME text, and a backslash intact (RULING 8b)'
    folder='/Users/thiago/Rips/It'"'"'s $HOME "quoted" ]] back\slash'
    run_service "$folder"
    The value "$(decoded_path 1)" should equal "$folder"
  End

  It 'a folder literally shaped like the rejected [[$d]] escape attack decodes as inert data, not code'
    folder='x]]..os.execute("touch /tmp/rip-finder-service-pwned")..[['
    run_service "$folder"
    The value "$(decoded_path 1)" should equal "$folder"
    The value "$(call_line 1 3)" should not include 'os.execute'
    The value "$(call_line 1 3)" should not include ']]..'
  End

  It 'invokes hs once per folder, in call order, for a multi-folder Finder selection'
    run_service "/tmp/Folder One" "/tmp/Folder Two" "/tmp/Folder Three"
    The value "$(call_count)" should equal "3"
    The value "$(decoded_path 1)" should equal "/tmp/Folder One"
    The value "$(decoded_path 2)" should equal "/tmp/Folder Two"
    The value "$(decoded_path 3)" should equal "/tmp/Folder Three"
  End
End
