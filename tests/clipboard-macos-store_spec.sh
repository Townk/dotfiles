# Tests for the macOS pasteboard backend (home/dot_local/lib/
# clipboard-platform-macos.zsh), driven through the dispatcher with
# CLIPBOARD_PLATFORM=macos forced and `pbpaste` stubbed on PATH -- so no test
# touches the real system pasteboard. Mirrors the stub-pbpaste convention of
# the S get-current-ts Describe in tests/clipboard-bridge_spec.sh.
Describe 'clipboard-bridge-dispatch: macOS pasteboard backend'
  DISPATCH="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_clipboard-bridge-dispatch"

  setup() {
    export XDG_STATE_HOME="$SHELLSPEC_TMPBASE/state"
    export XDG_DATA_HOME="$SHELLSPEC_TMPBASE/data"
    mkdir -p "$XDG_STATE_HOME/pick-clipboard" "$XDG_DATA_HOME/pick-clipboard"
    REGTYPE_FILE="$XDG_STATE_HOME/pick-clipboard/current-regtype"

    # Stub pbpaste -> a controlled fixture file (never the real pasteboard).
    export PATH="$SHELLSPEC_TMPBASE/bin:$PATH"
    mkdir -p "$SHELLSPEC_TMPBASE/bin"
    PBPASTE_FIXTURE="$SHELLSPEC_TMPBASE/pbpaste-fixture"
    : > "$PBPASTE_FIXTURE"
    cat > "$SHELLSPEC_TMPBASE/bin/pbpaste" <<EOF
#!/bin/sh
cat "$PBPASTE_FIXTURE"
EOF
    chmod +x "$SHELLSPEC_TMPBASE/bin/pbpaste"

    REQ="$SHELLSPEC_TMPBASE/req"
    RESP="$SHELLSPEC_TMPBASE/resp"
  }
  BeforeEach 'setup'

  run_dispatch() {  # request on stdin, forced macOS platform, reply -> $RESP
    sh -c 'CLIPBOARD_PLATFORM=macos zsh -f "$1" < "$2" > "$3"' \
      _ "$DISPATCH" "$REQ" "$RESP"
  }

  # MED-11: op_get read the pasteboard via `text="$(pbpaste)"`, and command
  # substitution strips ALL trailing newlines -- so a clip of "hello\n" came
  # back as 5 bytes, not 6. The linux backend already avoids this with
  # writefile+clip::read_file for byte-exactness; the macOS backend must match.
  It 'G preserves a single trailing newline (MED-11)'
    printf 'hello\n' > "$PBPASTE_FIXTURE"   # 6 bytes
    printf 'G\000\000\000\000' > "$REQ"
    When call run_dispatch
    The status should be success
    The contents of file "$RESP" should start with "O"
    # reply = 'O' + BE32(6) + "hello\n" = 5-byte header + 6-byte payload
    size=$(wc -c < "$RESP" | tr -d ' ')
    The variable size should equal 11
    hdr=$(od -An -tx1 "$RESP" | tr -s ' \n' ' ')
    The variable hdr should include "4f 00 00 00 06 68 65 6c 6c 6f 0a"
  End

  It 'G preserves multiple trailing newlines (MED-11)'
    printf 'foo\n\n\n' > "$PBPASTE_FIXTURE"   # 6 bytes
    printf 'G\000\000\000\000' > "$REQ"
    When call run_dispatch
    The status should be success
    The contents of file "$RESP" should start with "O"
    size=$(wc -c < "$RESP" | tr -d ' ')
    The variable size should equal 11
    hdr=$(od -An -tx1 "$RESP" | tr -s ' \n' ' ')
    The variable hdr should include "4f 00 00 00 06 66 6f 6f 0a 0a 0a"
  End

  # LOW-1: the trailing-newline l/v heuristic lived INSIDE the
  # `[[ -f "$REGTYPE_FILE" ]]` branch, so a missing state file (fresh Mac, or
  # state cleared) short-circuited to the 'v' initializer instead of falling
  # back to the sentinel heuristic. With no state file and a pasteboard ending
  # in "\n", R must answer 'l', not 'v'.
  It 'R falls back to the newline heuristic when no state file exists (LOW-1)'
    rm -f "$REGTYPE_FILE"
    printf 'a line\n' > "$PBPASTE_FIXTURE"
    printf 'R\000\000\000\000' > "$REQ"
    When call run_dispatch
    The status should be success
    The contents of file "$RESP" should start with "O"
    # payload is the single regtype byte after the 5-byte frame header
    rt=$(tail -c +6 "$RESP")
    The variable rt should equal "l"
  End

  # LOW-1 companion: no state file and a pasteboard NOT ending in "\n" -> 'v'.
  It 'R falls back to v with no state file and no trailing newline (LOW-1)'
    rm -f "$REGTYPE_FILE"
    printf 'a line' > "$PBPASTE_FIXTURE"
    printf 'R\000\000\000\000' > "$REQ"
    When call run_dispatch
    The status should be success
    rt=$(tail -c +6 "$RESP")
    The variable rt should equal "v"
  End
End
