# Tests for clipbridge::peer_snapshot
# (home/dot_local/lib/clipboard-bridge-client.zsh) — the two-exchange peer
# clipboard read a remote pull needs. (The companion persist_files wrapper is
# gone: an accepted live FILES candidate is recorded by the picker's own
# pointer-row insert, not by a trusted store.persist.files the daemon refuses
# for a foreign host — see the lib's own note where it used to live, and
# tests/pick-clipboard-files_spec.sh's real-store examples.)
# The fake `system-bridge` is the seam (SYSTEM_BRIDGE_BIN,
# the CLIPBOARD_MOUNT_BIN precedent the lib's own header comment names):
# these examples never touch a real recobd, only the reply shape
# clipbridge::call decodes (one `name=<hex>` line per field).
Describe 'clipbridge::peer_snapshot'
  setup() {
    export WORK="$SHELLSPEC_TMPBASE/snap.$$"; mkdir -p "$WORK"
    export SYSTEM_BRIDGE_BIN="$WORK/fake-bridge"
    export TEXT_OUT="$WORK/live-text"
  }
  BeforeEach 'setup'

  # hex of: "hello\n" = 68656c6c6f0a ; "v"=76 ; "1755551234.5"=... ; "laptop"=6c6170746f70
  write_fake() {  # $1 = clip.get behavior, $2 = files.list behavior
    cat > "$SYSTEM_BRIDGE_BIN" <<FAKE
#!/bin/sh
# argv: call --peer <op>
op=""
for a in "\$@"; do case "\$a" in clip.get|files.list) op="\$a";; esac; done
case "\$op" in
  clip.get)  $1 ;;
  files.list) $2 ;;
esac
FAKE
    chmod +x "$SYSTEM_BRIDGE_BIN"
  }
  hex() { printf '%s' "$1" | xxd -p | tr -d '\n'; }

  run_snapshot() {
    zsh -c 'source "$1"; clipbridge::peer_snapshot "$2"' zsh \
      "$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib/clipboard-bridge-client.zsh" \
      "$TEXT_OUT"
  }

  It 'emits both candidates and writes the text bytes'
    write_fake \
      "printf 'text=%s\nregtype=%s\ntimestamp=%s\nhost=%s\n' '$(hex $'hi\n')' '$(hex v)' '$(hex 1755551234.5)' '$(hex laptop)'" \
      "printf 'kind=%s\nhost=%s\ntimestamp=%s\npaths=%s\n' '$(hex files)' '$(hex laptop)' '$(hex 1755551300.1)' '$(printf '/a/b\0/c' | xxd -p | tr -d '\n')'"
    When call run_snapshot
    The status should eq 0
    The line 1 of output should include '"kind":"text"'
    The line 1 of output should include '"timestamp":"1755551234.5"'
    The line 2 of output should include '"kind":"files"'
    The line 2 of output should include '"paths":["/a/b","/c"]'
    The contents of file "$TEXT_OUT" should eq 'hi'
  End

  It 'treats files.list not-found as "no files candidate", not an error'
    write_fake \
      "printf 'text=%s\nregtype=%s\ntimestamp=%s\nhost=%s\n' '$(hex x)' '$(hex v)' '$(hex 1)' '$(hex laptop)'" \
      "echo 'system-bridge: the current clip is not a files clip (not-found)' >&2; exit 1"
    When call run_snapshot
    The status should eq 0
    The lines of output should eq 1
    The line 1 of output should include '"kind":"text"'
  End

  It 'yields nothing when the bridge is unreachable'
    write_fake "exit 1" "exit 1"
    When call run_snapshot
    The status should eq 0
    The output should eq ''
  End

  It 'suppresses a whitespace-only text clip'
    write_fake \
      "printf 'text=%s\nregtype=%s\ntimestamp=%s\nhost=%s\n' '$(hex $'  \n')' '$(hex v)' '$(hex 1)' '$(hex laptop)'" \
      "exit 1"
    When call run_snapshot
    The status should eq 0
    The output should eq ''
  End
End
