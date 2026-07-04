# backup_tm_spec.sh — tm scrub sessions (spec 2026-07-04 §5-6).
Describe 'backup-tm.zsh'
  TAB=$(printf '\t')
  LIB="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib"

  Describe 'session state + stepping'
    setup_fix() {
      FIX=$(mktemp -d)
      export TZ=UTC BKP_CONFIG="$FIX/c.toml" BKP_TM_SESSIONS="$FIX/sessions"
      export BKP_STATE_DIR="$FIX/state"
      printf '[staging]\npath = "%s/repo"\npassword_command = "echo pw"\n' "$FIX" > "$FIX/c.toml"
      printf 'roots = []\n' > "$FIX/m.toml"
      export BKP_MANIFEST="$FIX/m.toml"
      cat > "$FIX/snaps.json" <<'EOF'
[{"id":"aaaa000000000000000000000000000000000000000000000000000000000000","time":"2026-07-01T10:00:00Z"},
 {"id":"cccc000000000000000000000000000000000000000000000000000000000000","time":"2026-07-03T10:00:00Z"}]
EOF
      STUB="$FIX/stub"; mkdir -p "$STUB"
      printf '#!/bin/sh\necho "ya $*" >> "%s/ya.calls"\n' "$FIX" > "$STUB/ya"
      chmod +x "$STUB/ya"
      PATH="$STUB:$PATH"
      mkdir -p "$FIX/anchor"
    }
    cleanup_fix() { rm -rf "$FIX"; unset BKP_CONFIG BKP_TM_SESSIONS BKP_STATE_DIR BKP_MANIFEST; }
    BeforeEach 'setup_fix'
    AfterEach 'cleanup_fix'

    stub_restic() {
      bkp::restic() {
        local repo="$1"; shift
        case "$1 ${2:-}" in
          'snapshots --json') cat "$FIX/snaps.json" ;;
          *) return 0 ;;
        esac
      }
    }

    It 'creates a session with ladder, lens, anchor and rung=1'
      run_it() {
        source "$LIB/backup-tm.zsh"; stub_restic
        local s
        s=$(bkp::tm::session_new explore "$FIX/anchor") || return 1
        cat "$s/lens" "$s/rung"
        head -1 "$s/ladder"
      }
      When run run_it
      The line 1 should equal "explore"
      The line 2 should equal "1"
      The line 3 should start with "cccc"
      The line 3 should match pattern "*[0-9]	*"
    End

    It 'steps older/newer with clamping and refreshes explore via ya'
      run_it() {
        source "$LIB/backup-tm.zsh"; stub_restic
        local s
        s=$(bkp::tm::session_new explore "$FIX/anchor")
        print -r -- 42 > "$s/yazi.id"
        mkdir -p "$s/mnt/ids"
        bkp::tm::step "$s" older; local r1=$(<"$s/rung")
        bkp::tm::step "$s" older; local r2=$(<"$s/rung")   # clamp at oldest
        bkp::tm::step "$s" newer; local r3=$(<"$s/rung")
        print -r -- "$r1 $r2 $r3"
        cat "$FIX/ya.calls"
      }
      When run run_it
      The line 1 should equal "2 2 1"
      The line 2 should start with "ya emit-to 42 cd"
      The line 2 should include "/mnt/ids/aaaa0000"
    End

    It 'refresh is a silent no-op before yazi publishes its id'
      run_it() {
        source "$LIB/backup-tm.zsh"; stub_restic
        local s
        s=$(bkp::tm::session_new explore "$FIX/anchor")
        bkp::tm::step "$s" older
        print -r -- "rc=$? rung=$(<"$s/rung")"
      }
      When run run_it
      The output should equal "rc=0 rung=2"
      The stderr should equal ""
    End

    It 'regenerates current.patch for the diff lens on step'
      run_it() {
        source "$LIB/backup-tm.zsh"; stub_restic
        local s
        s=$(bkp::tm::session_new diff "$FIX/anchor")
        # fake mount rung trees for both rungs
        mkdir -p "$s/mnt/ids/cccc0000$FIX/anchor" "$s/mnt/ids/aaaa0000$FIX/anchor"
        print past > "$s/mnt/ids/aaaa0000$FIX/anchor/f.txt"
        print now  > "$FIX/anchor/f.txt"
        bkp::tm::step "$s" older
        grep -c 'diff --git' "$s/current.patch"
      }
      When run run_it
      The output should equal 1
    End
  End

  Describe 'bkp::tm::timeline_render'
    setup_fix() {
      FIX=$(mktemp -d)
      export TZ=UTC BKP_TM_SESSIONS="$FIX/sessions"
      mkdir -p "$FIX/sessions/s.test"
      S="$FIX/sessions/s.test"
      # epochs: fixed, old enough for absolute rendering + one recent
      now=$(date +%s)
      printf 'cccc000000000000000000000000000000000000000000000000000000000000\t%s\t30m\n' "$(( now - 1800 ))" > "$S/ladder"
      printf 'aaaa000000000000000000000000000000000000000000000000000000000000\t1782813780\tyear\n' >> "$S/ladder"
      printf '1\n' > "$S/rung"
    }
    cleanup_fix() { rm -rf "$FIX"; unset BKP_TM_SESSIONS; }
    BeforeEach 'setup_fix'
    AfterEach 'cleanup_fix'

    It 'renders rungs with relative and absolute stamps'
      run_it() { source "$LIB/backup-tm.zsh"; bkp::tm::timeline_render "$S" 20; }
      When run run_it
      The line 1 should include "● 30m ago"
      The output should include "┃"
      The output should include "2026"     # absolute stamp for the old rung
    End

    It 'marks the current rung with the tier label'
      run_it() { source "$LIB/backup-tm.zsh"; bkp::tm::timeline_render "$S" 20; }
      When run run_it
      The line 1 should include "30m"
    End

    It 'windows long ladders around the current rung'
      run_it() {
        source "$LIB/backup-tm.zsh"
        local i now=$(date +%s)
        : > "$S/ladder"
        for i in {1..40}; do
          printf '%04d00000000000000000000000000000000000000000000000000000000000\t%s\tday\n' "$i" "$(( now - i * 86400 ))" >> "$S/ladder"
        done
        print -r -- 20 > "$S/rung"
        bkp::tm::timeline_render "$S" 12
      }
      When run run_it
      The lines of output should equal 12
      The output should include "…"
    End
  End

  Describe 'bkp::tm::kill_lens'
    setup_fix() {
      FIX=$(mktemp -d)
      export BKP_TM_SESSIONS="$FIX/sessions"
      mkdir -p "$FIX/sessions/s.test"
      S="$FIX/sessions/s.test"
    }
    cleanup_fix() {
      # belt-and-braces: never leak the fake wrapper/child past the test
      [ -f "$S/child.pid" ] && kill "$(cat "$S/child.pid")" 2>/dev/null
      [ -f "$S/lens.pid" ] && kill "$(cat "$S/lens.pid")" 2>/dev/null
      rm -rf "$FIX"; unset BKP_TM_SESSIONS
    }
    BeforeEach 'setup_fix'
    AfterEach 'cleanup_fix'

    It 'kills the wrapper and its child UI process'
      run_it() {
        source "$LIB/backup-tm.zsh"
        cat > "$S/wrapper.zsh" <<'EOS'
sleep 100 &
print -r -- $! > "$1/child.pid"
print -r -- $$ > "$1/lens.pid"
wait
EOS
        zsh "$S/wrapper.zsh" "$S" &
        local i
        for i in {1..50}; do
          [[ -s "$S/child.pid" && -s "$S/lens.pid" ]] && break
          sleep 0.02
        done
        [[ -s "$S/child.pid" && -s "$S/lens.pid" ]] || { echo "setup failed"; return 1 }
        bkp::tm::kill_lens "$S" || { echo "kill_lens rc=$?"; return 1 }
        local child=$(<"$S/child.pid") wrapper=$(<"$S/lens.pid") cdead=no wdead=no
        for i in {1..50}; do
          kill -0 "$child" 2>/dev/null || cdead=yes
          kill -0 "$wrapper" 2>/dev/null || wdead=yes
          [[ "$cdead" == yes && "$wdead" == yes ]] && break
          sleep 0.02
        done
        print -r -- "child-dead=$cdead wrapper-dead=$wdead"
      }
      When run run_it
      The output should equal "child-dead=yes wrapper-dead=yes"
    End

    It 'is a no-op when no lens.pid exists'
      run_it() {
        source "$LIB/backup-tm.zsh"
        bkp::tm::kill_lens "$S"
        print -r -- "rc=$?"
      }
      When run run_it
      The output should equal "rc=0"
      The stderr should equal ""
    End
  End

  Describe 'yazi overlay + lens command'
    setup_fix() {
      FIX=$(mktemp -d)
      export TZ=UTC BKP_TM_SESSIONS="$FIX/sessions" YAZI_USER_CONFIG="$FIX/yazicfg"
      mkdir -p "$FIX/sessions/s.test" "$FIX/yazicfg/plugins"
      S="$FIX/sessions/s.test"
      printf 'cccc000000000000000000000000000000000000000000000000000000000000\t1751500000\t30m\n' > "$S/ladder"
      printf '1\n' > "$S/rung"
      printf '%s\n' "$FIX/anchor" > "$S/anchor"
      mkdir -p "$FIX/anchor"
      printf '[mgr]\n' > "$FIX/yazicfg/keymap.toml"
      printf '# yazi.toml\n' > "$FIX/yazicfg/yazi.toml"
      STUB="$FIX/stub"; mkdir -p "$STUB"
      printf '#!/bin/sh\nexit 0\n' > "$STUB/bx"; chmod +x "$STUB/bx"
      PATH="$STUB:$PATH"
    }
    cleanup_fix() { rm -rf "$FIX"; unset BKP_TM_SESSIONS YAZI_USER_CONFIG; }
    BeforeEach 'setup_fix'
    AfterEach 'cleanup_fix'

    It 'generates an overlay whose keymap adds the session bindings'
      run_it() {
        source "$LIB/backup-tm.zsh"
        local ovl
        ovl=$(bkp::tm::yazi_overlay "$S")
        [ -L "$ovl/yazi.toml" ] && echo linked
        grep -c 'prepend_keymap' "$ovl/keymap.toml"
        grep 'system-backup-tm' "$ovl/keymap.toml" | head -1
      }
      When run run_it
      The line 1 should equal "linked"
      The line 2 should equal 4
      The line 3 should include "system-backup-tm"
    End

    It 'builds a jailed explore command'
      run_it() {
        source "$LIB/backup-tm.zsh"
        print -r -- explore > "$S/lens"
        print -r -- 77 > "$S/yazi.id"
        bkp::tm::lens_cmd "$S"
      }
      When run run_it
      The line 1 should equal "bx"
      The output should include "--client-id"
      The output should include "/mnt/ids/cccc0000"
    End

    It 'builds the hunk --watch command for the diff lens'
      run_it() {
        source "$LIB/backup-tm.zsh"
        print -r -- diff > "$S/lens"
        bkp::tm::lens_cmd "$S"
      }
      When run run_it
      The line 1 should equal "hunk"
      The line 2 should equal "patch"
      The output should include "current.patch"
      The output should include "--watch"
    End
  End

  Describe 'route verb'
    BIN="$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_system-backup-tm"
    setup_fix() {
      FIX=$(mktemp -d)
      export TZ=UTC BKP_TM_SESSIONS="$FIX/sessions" BKP_LIB="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib"
      export BKP_CONFIG="$FIX/c.toml"
      printf '[staging]\npath = "%s/repo"\npassword_command = "echo pw"\n' "$FIX" > "$FIX/c.toml"
      S="$FIX/sessions/s.test"; mkdir -p "$S"
      printf 'cccc000000000000000000000000000000000000000000000000000000000000\t1751500000\t30m\naaaa000000000000000000000000000000000000000000000000000000000000\t1751000000\tday\n' > "$S/ladder"
      printf '1\n' > "$S/rung"
      printf 'diff\n' > "$S/lens"
      printf '%s\n' "$FIX/anchor" > "$S/anchor"
      mkdir -p "$FIX/anchor" "$S/mnt/ids/cccc0000$FIX/anchor" "$S/mnt/ids/aaaa0000$FIX/anchor"
      printf '4242\n' > "$S/lens.pid"
      STUB="$FIX/stub"; mkdir -p "$STUB"
      printf '#!/bin/sh\necho "zellij $*" >> "%s/zj.calls"\n' "$FIX" > "$STUB/zellij"
      chmod +x "$STUB/zellij"
      PATH="$STUB:$PATH"
    }
    cleanup_fix() { rm -rf "$FIX"; unset BKP_TM_SESSIONS BKP_LIB BKP_CONFIG; }
    BeforeEach 'setup_fix'
    AfterEach 'cleanup_fix'

    It 'steps the owning session older on shift+down'
      When run zsh "$BIN" route shift+down 4242
      The status should be success
      The contents of file "$FIX/sessions/s.test/rung" should equal 2
    End

    It 'writes the key through when no session owns the pid'
      When run zsh "$BIN" route shift+down 9999
      The status should be success
      The contents of file "$FIX/zj.calls" should include "action write-chars"
      The contents of file "$FIX/sessions/s.test/rung" should equal 1
    End
  End

  Describe 'apply flow'
    BIN="$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_system-backup-tm"
    setup_fix() {
      FIX=$(mktemp -d)
      export TZ=UTC BKP_TM_SESSIONS="$FIX/sessions" BKP_LIB="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib"
      export BKP_CONFIG="$FIX/c.toml" BKP_TM_ASSUME_YES=1
      printf '[staging]\npath = "%s/repo"\npassword_command = "echo pw"\n' "$FIX" > "$FIX/c.toml"
      S="$FIX/sessions/s.test"; mkdir -p "$S"
      printf 'cccc000000000000000000000000000000000000000000000000000000000000\t1751500000\t30m\n' > "$S/ladder"
      printf '1\n' > "$S/rung"
      printf 'explore\n' > "$S/lens"
      printf '%s\n' "$FIX/anchor" > "$S/anchor"
      mkdir -p "$FIX/anchor"
      STUB="$FIX/stub"; mkdir -p "$STUB"
      # recorder restic: apply must call restore --force via bkp::restore::paths
      printf '#!/bin/sh\necho "restic $*" >> "%s/restic.calls"\nexit 0\n' "$FIX" > "$STUB/restic"
      chmod +x "$STUB/restic"
      PATH="$STUB:$PATH"
      unset ZELLIJ
    }
    cleanup_fix() { rm -rf "$FIX"; unset BKP_TM_SESSIONS BKP_LIB BKP_CONFIG BKP_TM_ASSUME_YES; }
    BeforeEach 'setup_fix'
    AfterEach 'cleanup_fix'

    It 'maps mount-absolute selections to live paths and restores with --force'
      run_it() {
        print old > "$FIX/anchor/f.txt"   # live file exists -> undo snapshot fires
        zsh "$BIN" apply "$S" "$S/mnt/ids/cccc0000$FIX/anchor/f.txt" >/dev/null
        cat "$S/apply.list"
        grep -c 'backup --tag bkp-undo' "$FIX/restic.calls"
        grep -c -- '--include' "$FIX/restic.calls"
      }
      When run run_it
      The line 1 should equal "$FIX/anchor/f.txt"
      The line 2 should equal 1
      The line 3 should equal 1
    End

    It 'does nothing without a selection in the explore lens'
      When run zsh "$BIN" apply "$S"
      The status should be success
      The stderr should include "select in yazi"
      The file "$S/apply.list" should not be exist
    End

    It 'rejects a selection outside the current rung mount'
      When run zsh "$BIN" apply "$S" "/etc/passwd"
      The status should equal 1
      The stderr should include "not under the current rung"
      The file "$S/apply.list" should not be exist
    End

    It 'routes the diff-lens focus through hunk with an anchored session match'
      run_it() {
        printf 'diff\n' > "$S/lens"
        # hunk recorder: session list carries a prefix-collision decoy
        # (path: ${S}0) FIRST; only the real session id yields a focus.
        cat > "$STUB/hunk" <<EOF
#!/bin/sh
case "\$1 \$2" in
  'session list')
    printf 'deadbeef-0000-0000-0000-000000000000\n'
    printf '  path: ${S}0\n'
    printf 'cafecafe-0000-0000-0000-000000000000\n'
    printf '  path: ${S}\n'
    ;;
  'session get')
    if [ "\$3" = "cafecafe-0000-0000-0000-000000000000" ]; then
      printf '{"focus":{"file":"tmp-live/f.txt"}}\n'
    else
      printf '{}\n'
    fi
    ;;
esac
EOF
        chmod +x "$STUB/hunk"
        zsh "$BIN" apply "$S" >/dev/null
        cat "$S/apply.list"
      }
      When run run_it
      The output should equal "/tmp-live/f.txt"
    End
  End
End
