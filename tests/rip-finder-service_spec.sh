# tests/rip-finder-service_spec.sh — the Finder Quick Action's embedded
# shell script
# (home/dot_local/share/services/browse-audiobook-folder/Contents/document.wflow).
# services/ holds one subdirectory per bundle (browse-audiobook-folder is
# this one) so a future sibling Quick Action — for movies, audio tracks,
# eBooks — gets its own subdirectory and its own installer rather than
# colliding with this one.
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
  WFLOW="$SHELLSPEC_PROJECT_ROOT/home/dot_local/share/services/browse-audiobook-folder/Contents/document.wflow"
  INFO_PLIST="$SHELLSPEC_PROJECT_ROOT/home/dot_local/share/services/browse-audiobook-folder/Contents/Info.plist"

  # A silent-empty extraction (wrong path, a plutil that quietly failed)
  # must fail LOUDLY here, not let every example below run against an
  # empty script and pass vacuously (an empty file sources cleanly and
  # simply never calls the shadowed hs — most assertions would still
  # fail, but not for a reason anyone could diagnose from the output).
  setup() {
    SANDBOX=$(mktemp -d)
    LOGDIR="$SANDBOX/calls"
    COUNTER="$SANDBOX/counter"
    mkdir -p "$LOGDIR"
    SCRIPT_FILE="$SANDBOX/extracted-script.sh"
    if ! plutil -extract actions.0.action.ActionParameters.COMMAND_STRING raw -o - "$WFLOW" \
      > "$SCRIPT_FILE"; then
      echo "setup: plutil failed to extract COMMAND_STRING from $WFLOW" >&2
      return 1
    fi
    # `plutil -extract ... raw` always appends a trailing newline, even
    # when the extracted value is the empty string — an empty
    # COMMAND_STRING therefore produces a 1-BYTE file, and `[ -s ... ]`
    # ("nonzero size") is false for it, so a size check alone silently
    # misses exactly the case this guard exists to catch. `$(cat ...)`
    # strips trailing newlines under command substitution, so checking
    # ITS length (not the file's byte count) catches a lone "\n" too.
    if [ -z "$(cat "$SCRIPT_FILE")" ]; then
      echo "setup: extracted script from $WFLOW is EMPTY — refusing to run examples against nothing" >&2
      return 1
    fi
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

# The INSTALLER (home/.chezmoiscripts/run_onchange_after_38-…): it links the
# managed bundle into ~/Library/Services and flushes Launch Services.
#
# Rendered with `chezmoi execute-template` (never `chezmoi apply`), run
# against a SANDBOX $HOME, with /System/Library/CoreServices/pbs shadowed by
# a bash function — the same absolute-path interception technique the block
# above uses for hs, for the same reason: the script hardcodes the path, so a
# PATH stub would never be reached, and `pbs -flush` must not touch this
# machine's real Launch Services database.
Describe 'audiobook Finder Quick Action installer'
  TPL="$SHELLSPEC_PROJECT_ROOT/home/.chezmoiscripts/run_onchange_after_38-install-audiobook-finder-service.sh.tmpl"

  setup() {
    SANDBOX=$(mktemp -d)
    HOOK="$SANDBOX/install.sh"
    HOME_DIR="$SANDBOX/home"
    PBS_LOG="$SANDBOX/pbs.log"
    SRC="$HOME_DIR/.local/share/services/browse-audiobook-folder/Contents"
    DEST="$HOME_DIR/Library/Services/Browse Audiobook Folder.workflow"
    mkdir -p "$SRC"
    printf 'managed\n' > "$SRC/document.wflow"
    command chezmoi execute-template < "$TPL" > "$HOOK" 2>/dev/null
    if [ -z "$(cat "$HOOK")" ]; then
      echo "setup: chezmoi execute-template produced nothing for $TPL" >&2
      return 1
    fi
  }
  cleanup() { rm -rf "$SANDBOX"; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  run_installer() {
    HOOK="$HOOK" HOME_DIR="$HOME_DIR" PBS_LOG="$PBS_LOG" bash -c '
      function /System/Library/CoreServices/pbs {
        printf "%s\n" "$*" >> "$PBS_LOG"
      }
      HOME="$HOME_DIR"
      . "$HOOK"
    ' bash
  }

  # Everything the destination could be, one per example. Only the third is
  # the review finding; the other three are what must keep working.
  It 'creates the symlink when nothing is there yet'
    When call run_installer
    The status should equal 0
    The value "$(readlink "$DEST")" should equal "$HOME_DIR/.local/share/services/browse-audiobook-folder"
    The path "$PBS_LOG" should be exist
  End

  It 'replaces an existing symlink rather than linking beside it'
    mkdir -p "$HOME_DIR/Library/Services" "$SANDBOX/stale"
    ln -s "$SANDBOX/stale" "$DEST"
    When call run_installer
    The status should equal 0
    The value "$(readlink "$DEST")" should equal "$HOME_DIR/.local/share/services/browse-audiobook-folder"
  End

  # THE FINDING. `ln -sfn` -n only affects an existing SYMLINK: against a
  # real directory ln links INSIDE it and exits 0, so the installer would
  # report success, flush Launch Services, and leave Finder running the stale
  # copied bundle forever. That precondition is reachable through this epic's
  # own documented fallback (`cp -R` if pbs will not register a symlinked
  # .workflow), which is exactly what this fixture builds.
  It 'refreshes a real directory in place and never nests a link inside it'
    mkdir -p "$DEST/Contents"
    printf 'STALE\n' > "$DEST/Contents/document.wflow"
    When call run_installer
    The status should equal 0
    The stdout should include "copy mode"
    # no link was created inside the bundle
    The path "$DEST/browse-audiobook-folder" should not be exist
    # the destination is still a real directory (copy mode preserved) …
    The value "$(readlink "$DEST" 2>/dev/null)" should equal ""
    # … carrying the managed bundle's CURRENT content, not the stale copy
    The contents of file "$DEST/Contents/document.wflow" should equal "managed"
    # and the staging directory used for the atomic swap is gone
    The path "$DEST.new" should not be exist
  End

  It 'replaces a plain file sitting where the bundle belongs'
    mkdir -p "$HOME_DIR/Library/Services"
    printf 'junk\n' > "$DEST"
    When call run_installer
    The status should equal 0
    The value "$(readlink "$DEST")" should equal "$HOME_DIR/.local/share/services/browse-audiobook-folder"
  End
End
