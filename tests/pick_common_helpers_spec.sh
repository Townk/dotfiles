# pick-common shared helpers: the sqlite -escape capability probe and the
# clipboard-copy chain (M6/M7 consolidation).
#
# pick::sqlite_raw replaces two verbatim file-scope probes (pick-symbols,
# pick-clipboard). It must stay a CALLED function — pick-common is sourced by
# ~15 consumers that never touch sqlite (mux dialogs, fzf-tab preview), and a
# file-scope probe would fork sqlite3 in every one of them.
Describe 'pick::sqlite_raw'
  probe_with_stub() {
    zsh -c '
      stub="$(mktemp -d)" || exit 90
      printf "%s\n" "#!/bin/sh" "$1" > "$stub/sqlite3"
      chmod +x "$stub/sqlite3"
      PATH="$stub:$PATH"
      source home/dot_local/lib/pick-common.zsh
      pick::sqlite_raw
      print -r -- "${#PICK_SQLITE_RAW[@]}:${PICK_SQLITE_RAW[*]}"
      rm -rf -- "$stub"
    ' _ "$1"
  }

  It 'passes -escape off when the sqlite CLI supports it'
    When call probe_with_stub 'exit 0'
    The output should equal '2:-escape off'
    The status should be success
  End

  It 'stays empty when the CLI rejects the flag (pre-3.46)'
    When call probe_with_stub 'exit 1'
    The output should equal '0:'
    The status should be success
  End
End

# pick::clipboard had zero coverage; these pin its contract (exact bytes, no
# trailing newline — a paste at a prompt must not auto-execute — and a clear
# die when no helper exists) across the M7 rewrite onto pick::detect_clip.
Describe 'pick::clipboard'
  It 'copies exactly the string with no trailing newline via the first helper'
    When run zsh -c '
      stub="$(mktemp -d)" || exit 90
      cap="$stub/captured"
      printf "%s\n" "#!/bin/sh" "/bin/cat > \"$cap\"" > "$stub/pbcopy"
      chmod +x "$stub/pbcopy"
      source home/dot_local/lib/pick-common.zsh
      PATH="$stub"
      pick::clipboard "hello world"
      PATH="/usr/bin:/bin"
      printf "bytes=%s content=[%s]\n" "$(wc -c < "$cap" | tr -d " ")" "$(cat "$cap")"
      rm -rf -- "$stub"
    '
    The output should equal 'bytes=11 content=[hello world]'
    The status should be success
  End

  It 'dies with a clear error when no helper exists'
    When run zsh -c '
      source home/dot_local/lib/pick-common.zsh
      PATH="/nonexistent"
      pick::clipboard "x"
    '
    The status should be failure
    The stderr should include 'no clipboard helper'
  End
End
