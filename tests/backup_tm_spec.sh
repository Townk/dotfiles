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
        bkp::tm::ladder_fill "$s" || return 1
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
        bkp::tm::ladder_fill "$s"
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
        bkp::tm::ladder_fill "$s"
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
        bkp::tm::ladder_fill "$s"
        # fake mount rung trees for both rungs (snapshot side gets PAST
        # mtimes — the prescreen compares size+mtime)
        mkdir -p "$s/mnt/ids/cccc0000$FIX/anchor" "$s/mnt/ids/aaaa0000$FIX/anchor"
        print past > "$s/mnt/ids/aaaa0000$FIX/anchor/f.txt"
        touch -t 202601010000 "$s/mnt/ids/aaaa0000$FIX/anchor/f.txt"
        print now  > "$FIX/anchor/f.txt"
        bkp::tm::step "$s" older
        grep -c 'diff --git' "$s/current.patch"
      }
      When run run_it
      The output should equal 1
    End

    It 'kills the viewer into the spinner on builds; cache hits reload in place'
      wait_dead() {
        local pid="$1" i
        for i in {1..50}; do
          kill -0 "$pid" 2>/dev/null || { print yes; return 0 }
          sleep 0.02
        done
        kill "$pid" 2>/dev/null
        print no
      }
      run_it() {
        source "$LIB/backup-tm.zsh"; stub_restic
        local s
        s=$(bkp::tm::session_new diff "$FIX/anchor")
        bkp::tm::ladder_fill "$s"
        mkdir -p "$s/mnt/ids/cccc0000$FIX/anchor" "$s/mnt/ids/aaaa0000$FIX/anchor"
        print -r -- 4242 > "$s/lens.pid"
        # fake viewer whose cmdline matches the session's patch path
        printf '#!/bin/sh\nsleep 30\n' > "$FIX/stub/diffnav"
        chmod +x "$FIX/stub/diffnav"
        # UNCACHED rung: the viewer dies at build start (spinner phase
        # takes over) and the building flag clears once the patch lands.
        "$FIX/stub/diffnav" --watch --watch-cmd "cat $s/current.patch" & local a=$!
        sleep 0.2
        bkp::tm::step "$s" older || { echo "step rc=$?"; return 1 }
        print -r -- "build-kill=$(wait_dead "$a")"
        [[ -e "$s/building" ]] && print building-left || print building-cleared
        bkp::tm::step "$s" newer   # rung 1 built too (for the cache below)
        # CACHED rung: no spinner, no kill — diffnav's own watch re-reads
        # the patch in place.
        "$FIX/stub/diffnav" --watch --watch-cmd "cat $s/current.patch" & local c=$!
        sleep 0.2
        bkp::tm::step "$s" older || { echo "step rc=$?"; return 1 }
        sleep 0.3
        if kill -0 "$c" 2>/dev/null; then print viewer-alive; else print viewer-killed; fi
        kill "$c" 2>/dev/null
        [[ -e "$s/respawn" ]] && print respawn-flagged || print no-respawn
      }
      When run run_it
      The line 1 should equal "build-kill=yes"
      The line 2 should equal "building-cleared"
      The line 3 should equal "viewer-alive"
      The line 4 should equal "no-respawn"
    End

    It 'serves a revisited rung from the patch cache (one synthesis per rung)'
      run_it() {
        source "$LIB/backup-tm.zsh"; stub_restic
        local s calls="$FIX/synth.calls"
        s=$(bkp::tm::session_new diff "$FIX/anchor")
        bkp::tm::ladder_fill "$s"
        mkdir -p "$s/mnt/ids/cccc0000$FIX/anchor" "$s/mnt/ids/aaaa0000$FIX/anchor"
        bkp::changeset::patch_live() {
          print -r -- synth >> "$FIX/synth.calls"
          print -r -- "diff --git a/x b/x for rung ${1:t}"
        }
        bkp::tm::step "$s" older    # rung 2: synthesis #1
        bkp::tm::step "$s" newer    # rung 1: synthesis #2
        bkp::tm::step "$s" older    # rung 2 again: cache hit
        grep -c '' "$calls"
        grep -c 'aaaa0000' "$s/current.patch"
      }
      When run run_it
      The line 1 should equal 2
      The line 2 should equal 1
    End

    It 'flags the build spinner during synthesis and clears it after'
      run_it() {
        source "$LIB/backup-tm.zsh"; stub_restic
        local s
        s=$(bkp::tm::session_new diff "$FIX/anchor")
        bkp::tm::ladder_fill "$s"
        mkdir -p "$s/mnt/ids/cccc0000$FIX/anchor" "$s/mnt/ids/aaaa0000$FIX/anchor"
        # observe the flag mid-build via a synthesis stub
        bkp::changeset::patch_live() {
          [[ -e "$S_UNDER_TEST/building" ]] && print -r -- flag-during-build >&2
          print -r -- "diff --git a/x b/x"
        }
        S_UNDER_TEST="$s"
        bkp::tm::refresh "$s" || return 1
        [[ -e "$s/building" ]] && print flag-left || print flag-cleared
        grep -c 'diff --git' "$s/current.patch"
      }
      When run run_it
      The line 1 should equal "flag-cleared"
      The line 2 should equal 1
      The stderr should include "flag-during-build"
    End

    It 'supersedes a running synthesis and reaps its pid file'
      run_it() {
        source "$LIB/backup-tm.zsh"; stub_restic
        local s
        s=$(bkp::tm::session_new diff "$FIX/anchor")
        bkp::tm::ladder_fill "$s"
        mkdir -p "$s/mnt/ids/cccc0000$FIX/anchor" "$s/mnt/ids/aaaa0000$FIX/anchor"
        # fake in-flight synthesis from a previous scrub step
        sleep 30 & local prev=$!
        print -r -- "$prev" > "$s/refresh.pid"
        bkp::tm::step "$s" older || { echo "step rc=$?"; return 1 }
        local i dead=no
        for i in {1..50}; do
          kill -0 "$prev" 2>/dev/null || { dead=yes; break }
          sleep 0.02
        done
        kill "$prev" 2>/dev/null
        print -r -- "prev-dead=$dead"
        [[ -f "$s/refresh.pid" ]] && print pid-file-left || print pid-file-reaped
      }
      When run run_it
      The line 1 should equal "prev-dead=yes"
      The line 2 should equal "pid-file-reaped"
    End

    It 'refreshes a FUSE-less diff session from a per-rung restore cache'
      run_it() {
        source "$LIB/backup-tm.zsh"
        local calls="$FIX/restore.calls"
        bkp::restic() {
          local repo="$1"; shift
          case "$1" in
            snapshots) cat "$FIX/snaps.json" ;;
            restore)
              shift
              print -r -- restore >> "$calls"
              local target="" anchor=""
              while (( $# )); do
                case "$1" in
                  --target) target="$2"; shift 2 ;;
                  --include) anchor="$2"; shift 2 ;;
                  *) shift ;;
                esac
              done
              mkdir -p "$target$anchor"
              print past > "$target$anchor/f.txt"
              ;;
            *) return 0 ;;
          esac
        }
        local s
        s=$(bkp::tm::session_new diff "$FIX/anchor")
        bkp::tm::ladder_fill "$s"
        print now > "$FIX/anchor/f.txt"
        # no $s/mnt dir at all — rung_root must fall back to the cache
        bkp::tm::refresh "$s" || { echo "refresh1 rc=$?"; return 1 }
        grep -c 'diff --git' "$s/current.patch"
        [[ -f "$s/rungs/cccc0000/.done" ]] && echo done-exists || echo missing
        # second refresh must be a cache hit — no second restore invocation
        bkp::tm::refresh "$s" || { echo "refresh2 rc=$?"; return 1 }
        grep -c '' "$calls"
      }
      When run run_it
      The line 1 should equal 1
      The line 2 should equal "done-exists"
      The line 3 should equal 1
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

    It 'renders every rung as a two-line date/time stamp with a leading space'
      run_it() { source "$LIB/backup-tm.zsh"; bkp::tm::timeline_render "$S" 20; }
      When run run_it
      # 2 rungs -> 2 stamp rows each + 1 connector = 5 rows
      The lines of output should equal 5
      The line 1 should start with " ● "
      The line 1 should include "2026"
      The line 2 should start with " ┃ "
      The line 2 should match pattern "*[ap]m*"
      The line 4 should include "2026"
    End

    It 'renders the highlighted current rung under set -u with styling on'
      run_it() {
        # tty styling makes the highlight/pad branch run; set -u is what
        # the real worker runs under — this combination once crashed with
        # ": parameter not set" (zsh (l::) pad on an empty param name).
        zsh -c '
          set -u -o pipefail
          source "'"$LIB"'/backup-tm.zsh"
          C_RES=$(printf "\e[0m")
          bkp::tm::timeline_render "'"$S"'" 20 24 1 > /dev/null
        '
        print -r -- "rc=$?"
      }
      When run run_it
      The output should equal "rc=0"
      The stderr should equal ""
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
      The output should include "⋮"
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
      PATH="$STUB:$PATH"
    }
    cleanup_fix() { rm -rf "$FIX"; unset BKP_TM_SESSIONS YAZI_USER_CONFIG; }
    BeforeEach 'setup_fix'
    AfterEach 'cleanup_fix'

    It 'generates a parseable overlay keymap (append form, no user array)'
      run_it() {
        source "$LIB/backup-tm.zsh"
        local ovl
        ovl=$(bkp::tm::yazi_overlay "$S")
        [ -f "$ovl/yazi.toml" ] && grep -q 'ratio = \[ 2, 4, 4 \]' "$ovl/yazi.toml" && echo three-col
        yq -p toml -o json '.' "$ovl/keymap.toml" | jq -r '.mgr.prepend_keymap | length'
        grep -c 'system-backup-tm' "$ovl/keymap.toml" > /dev/null && echo has-bindings
        # yazi 26.5 silently drops `--args=` plugin args — positional only
        grep -q -- '--args=' "$ovl/keymap.toml" || echo positional-args
      }
      When run run_it
      The line 1 should equal "three-col"
      The line 2 should equal 19
      The line 3 should equal "has-bindings"
      The line 4 should equal "positional-args"
    End

    It 'injects into an existing [mgr] prepend_keymap array (parseable, ours first)'
      run_it() {
        source "$LIB/backup-tm.zsh"
        cat > "$FIX/yazicfg/keymap.toml" <<'EOF'
[mgr]
prepend_keymap = [
  { on = "X", run = "noop", desc = "user row" },
]

[input]
prepend_keymap = [{ on = "<Esc>", run = "close", desc = "Cancel input" }]
EOF
        local ovl
        ovl=$(bkp::tm::yazi_overlay "$S")
        local json
        json=$(yq -p toml -o json '.' "$ovl/keymap.toml") || { echo UNPARSEABLE; return 1 }
        jq -r '.mgr.prepend_keymap | length' <<<"$json"
        jq -r '.mgr.prepend_keymap[0].on' <<<"$json"
        jq -r '.mgr.prepend_keymap[-1].on' <<<"$json"
        jq -r '.input.prepend_keymap | length' <<<"$json"
      }
      When run run_it
      The line 1 should equal 20
      The line 2 should equal "K"
      The line 3 should equal "X"
      The line 4 should equal 1
    End

    It 'binds Shift-Up/Down to the same newer/older steps as K/J'
      run_it() {
        source "$LIB/backup-tm.zsh"
        local ovl
        ovl=$(bkp::tm::yazi_overlay "$S")
        grep -A1 'on = "<S-Up>"' "$ovl/keymap.toml" | grep -c 'ctl .* newer'
        grep -A1 'on = "<S-Down>"' "$ovl/keymap.toml" | grep -c 'ctl .* older'
      }
      When run run_it
      The line 1 should equal 1
      The line 2 should equal 1
    End

    It 'builds a plain gated explore command (env-driven tm-gate, no sandbox)'
      run_it() {
        source "$LIB/backup-tm.zsh"
        print -r -- explore > "$S/lens"
        print -r -- 77 > "$S/yazi.id"
        bkp::tm::lens_cmd "$S"
      }
      When run run_it
      The line 1 should equal "env"
      The output should include "BKP_TM_MNT=$S/mnt"
      The output should include "BKP_TM_ANCHOR=$FIX/anchor"
      The output should include "BKP_TM_SESSION=$S"
      The output should include "--client-id"
      The output should include "/mnt/ids/cccc0000"
      The output should not include "sandbox-exec"
    End

    It 'composes plugins/init.lua: user config + generated tm-gate'
      run_it() {
        source "$LIB/backup-tm.zsh"
        mkdir -p "$FIX/yazicfg/plugins/userp.yazi"
        printf 'return {}\n' > "$FIX/yazicfg/plugins/userp.yazi/main.lua"
        printf '-- user init\n' > "$FIX/yazicfg/init.lua"
        printf '# theme\n' > "$FIX/yazicfg/theme.toml"
        local ovl
        ovl=$(bkp::tm::yazi_overlay "$S")
        # user theme passes through untouched (the dead [dark.mgr] hover
        # block is gone — cursor styling lives in the flavor [indicator])
        grep -q '# theme' "$ovl/theme.toml" && ! grep -q 'dark.mgr' "$ovl/theme.toml" && echo theme-linked
        [ -L "$ovl/plugins/userp.yazi" ] && echo userplugin-linked
        # one cd subscription: the navigation bounce
        grep -c 'ps.sub("cd"' "$ovl/plugins/tm-gate.yazi/main.lua"
        # two BKP_TM_MNT reads: the setup gate + the h-at-root handler
        grep -c 'BKP_TM_MNT' "$ovl/plugins/tm-gate.yazi/main.lua"
        # the timeline renders inside yazi's parent column, and the dead
        # tm-focus/cursor-bounce machinery stays gone
        grep -q 'Parent:redraw' "$ovl/plugins/tm-gate.yazi/main.lua" && echo timeline-in-parent
        grep -q 'tm-focus' "$ovl/plugins/tm-gate.yazi/main.lua" || echo no-tm-focus
        grep -c 'require("tm-gate")' "$ovl/init.lua"
        grep -c 'dofile' "$ovl/init.lua"
      }
      When run run_it
      The line 1 should equal "theme-linked"
      The line 2 should equal "userplugin-linked"
      The line 3 should equal 1
      The line 4 should equal 2
      The line 5 should equal "timeline-in-parent"
      The line 6 should equal "no-tm-focus"
      The line 7 should equal 1
      The line 8 should equal 1
    End

    It 'builds the diffnav watch command for the diff lens (no pty-frame)'
      run_it() {
        source "$LIB/backup-tm.zsh"
        print -r -- diff > "$S/lens"
        export BKP_TM_PTYFRAME_BIN=/nonexistent
        bkp::tm::lens_cmd "$S"
        # the watch-cmd must be ONE argv element (space inside, no quoting)
        bkp::tm::lens_cmd "$S" | sed -n '8p'
      }
      When run run_it
      The line 1 should equal "env"
      The line 2 should start with "DELTA_FEATURES="
      The line 2 should not include "side-by-side"
      The line 3 should start with "COLORTERM="
      The line 4 should equal "diffnav"
      The line 5 should equal "--unified"
      The line 6 should equal "--watch"
      The output should include "--watch-interval"
      The line 11 should equal "cat $S/current.patch"
    End

    It 'wraps the lens in pty-frame with title/focus channels when present'
      run_it() {
        source "$LIB/backup-tm.zsh"
        print -r -- diff > "$S/lens"
        printf '#!/bin/sh\n' > "$FIX/ptyframe"
        chmod +x "$FIX/ptyframe"
        BKP_TM_PTYFRAME_BIN="$FIX/ptyframe" bkp::tm::lens_cmd "$S" > "$FIX/argv"
        grep -c -- '--bare' "$FIX/argv"
        grep -c -- '--tui' "$FIX/argv"
        grep -c "^$S/lens-title$" "$FIX/argv"
        grep -c "^$S/focus$" "$FIX/argv"
        grep -c '^diffnav$' "$FIX/argv"
        grep -cx -- '--focus-remap' "$FIX/argv"
        # the header file is seeded at lens spawn, explore-style
        head -c 4 "$S/lens-title"; echo
        grep -c "$FIX/anchor" "$S/lens-title"
      }
      When run run_it
      The line 1 should equal 1
      The line 2 should equal 1
      The line 3 should equal 1
      The line 4 should equal 1
      The line 5 should equal 1
      The line 6 should equal 1
      The line 7 should equal "● "
      The line 8 should equal 1
    End
  End

  Describe 'route verb'
    BIN="$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_system-backup-tm"
    setup_fix() {
      FIX=$(mktemp -d)
      export TZ=UTC BKP_TM_SESSIONS="$FIX/sessions" BKP_LIB="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib"
      export BKP_CONFIG="$FIX/c.toml" BKP_MANIFEST="$FIX/m.toml"
      printf '[staging]\npath = "%s/repo"\npassword_command = "echo pw"\n' "$FIX" > "$FIX/c.toml"
      printf 'roots = []\n' > "$FIX/m.toml"
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
    cleanup_fix() { rm -rf "$FIX"; unset BKP_TM_SESSIONS BKP_LIB BKP_CONFIG BKP_MANIFEST; }
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

    It 'fzf multi-pick preserves spaces in paths and skips /dev/null'
      run_it() {
        printf 'diff\n' > "$S/lens"
        # No ZELLIJ in this fixture -> tm_apply takes the inline fzf
        # multi-pick over current.patch's +++ b/--- a header lines. Real
        # git diff appends a trailing tab on --- /+++ lines whose path
        # has a space — this fixture reproduces that so the tab-strip is
        # exercised too.
        {
          print -r -- 'diff --git a/live/dir/deleted one.txt b/live/dir/deleted one.txt'
          print -r -- 'deleted file mode 100644'
          print -r -- 'index 111..000'
          print -r -- $'--- a/live/dir/deleted one.txt\t'
          print -r -- '+++ /dev/null'
          print -r -- '@@ -1 +0,0 @@'
          print -r -- '-gone'
          print -r -- 'diff --git a/live/dir/file one.txt b/live/dir/file one.txt'
          print -r -- 'index 222..333 100644'
          print -r -- $'--- a/live/dir/file one.txt\t'
          print -r -- $'+++ b/live/dir/file one.txt\t'
          print -r -- '@@ -1 +1 @@'
          print -r -- '-old'
          print -r -- '+new'
        } > "$S/current.patch"
        # stub fzf: select everything piped to it (stands in for the user
        # multi-picking every changed file)
        printf '#!/bin/sh\ncat\n' > "$STUB/fzf"
        chmod +x "$STUB/fzf"
        zsh "$BIN" apply "$S" >/dev/null
        cat "$S/apply.list"
      }
      When run run_it
      The line 1 should equal "/live/dir/deleted one.txt"
      The line 2 should equal "/live/dir/file one.txt"
      The lines of output should equal 2
    End
  End

  Describe 'session launcher'
    setup_fix() {
      FIX=$(mktemp -d)
      export TZ=UTC BKP_CONFIG="$FIX/c.toml" BKP_TM_SESSIONS="$FIX/sessions"
      export BKP_MANIFEST="$FIX/m.toml" BKP_HAS_FUSE=1
      printf '[staging]\npath = "%s/repo"\npassword_command = "echo pw"\n' "$FIX" > "$FIX/c.toml"
      printf 'roots = []\n' > "$FIX/m.toml"
      cat > "$FIX/snaps.json" <<'EOF'
[{"id":"cccc000000000000000000000000000000000000000000000000000000000000","time":"2026-07-03T10:00:00Z"}]
EOF
      STUB="$FIX/stub"; mkdir -p "$STUB"
      printf '#!/bin/sh\necho "zellij $*" >> "%s/zj.calls"\n' "$FIX" > "$STUB/zellij"
      chmod +x "$STUB/zellij"
      printf '#!/bin/sh\necho "tm $*" >> "%s/tm.calls"\n' "$FIX" > "$STUB/system-backup-tm"
      chmod +x "$STUB/system-backup-tm"
      export BKP_TM_BIN="$STUB/system-backup-tm"
      PATH="$STUB:$PATH"
      mkdir -p "$FIX/anchor"
      export ZELLIJ=1 ZELLIJ_PANE_ID=1
    }
    cleanup_fix() { rm -rf "$FIX"; unset BKP_CONFIG BKP_TM_SESSIONS BKP_MANIFEST BKP_HAS_FUSE ZELLIJ ZELLIJ_PANE_ID BKP_TM_BIN; }
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

    It 'runs explore as ONE pane: the lens takes the invoking pane, no split'
      run_it() {
        source "$LIB/backup-tm.zsh"; stub_restic
        bkp::mount() { mkdir -p "$2/snapshots"; REPLY=$$; }
        bkp::tm::launch explore "$FIX/anchor"
        cat "$FIX/tm.calls"
        [ -f "$FIX/zj.calls" ] && cat "$FIX/zj.calls" || echo no-zellij-calls
      }
      When run run_it
      The status should be success
      The output should include "tm lens"
      The output should include "no-zellij-calls"
      The output should not include "tm timeline"
    End

    It 'splits the diff tab: hunk lens right, timeline in the invoking pane'
      run_it() {
        source "$LIB/backup-tm.zsh"; stub_restic
        bkp::mount() { mkdir -p "$2/snapshots"; REPLY=$$; }
        bkp::tm::launch diff "$FIX/anchor"
        cat "$FIX/zj.calls"
        cat "$FIX/tm.calls"
      }
      When run run_it
      The status should be success
      The output should include "run --close-on-exit --direction right"
      The output should include "action resize increase left"
      The output should include "tm timeline"
      The output should not include "new-tab"
      # focus deliberately STAYS on the lens pane — no move-focus back
      The output should not include "move-focus"
    End

    It 'fallback survives a failing lens under set -e and still tears down'
      run_it() {
        printf '#!/bin/sh\nexit 3\n' > "$STUB/yazi"
        chmod +x "$STUB/yazi"
        cat > "$FIX/driver.zsh" <<EOS
set -eu -o pipefail
source "$LIB/backup-tm.zsh"
bkp::restic() {
  local repo="\$1"; shift
  case "\$1 \${2:-}" in
    'snapshots --json') cat "$FIX/snaps.json" ;;
    *) return 0 ;;
  esac
}
bkp::mount() { mkdir -p "\$2/snapshots"; REPLY=\$\$; }
bkp::umount() { print umount >> "$FIX/calls"; }
unset ZELLIJ
s=\$(bkp::tm::session_new explore "$FIX/anchor")
bkp::tm::fallback "\$s"
[[ -d "\$s" ]] && print leaked || print cleaned
EOS
        zsh "$FIX/driver.zsh" <<< q
        cat "$FIX/calls"
      }
      When run run_it
      The status should be success
      The output should include "cleaned"
      The output should include "umount"
      # read -k has no tty here; it degrades to the q path with a complaint
      The stderr should be defined
    End
  End

  Describe 'tm-tab: sessions in a fresh zellij tab'
    BIN="$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_tm-tab"
    setup_fix() {
      FIX=$(mktemp -d)
      mkdir -p "$FIX/stub"
      # zellij stub records its argv and snapshots the layout file before
      # tm-tab's delayed reaper can touch it
      cat > "$FIX/stub/zellij" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$FIX/zellij.calls"
for a in "\$@"; do prev_was_layout=\${layout:+x}; done
EOF
      cat > "$FIX/stub/zellij" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$FIX/zellij.calls"
while [ \$# -gt 0 ]; do
  [ "\$1" = "--layout" ] && cp "\$2" "$FIX/layout.kdl"
  shift
done
EOF
      cat > "$FIX/stub/system-backup" <<EOF
#!/bin/sh
printf 'browse-direct %s\n' "\$*" >> "$FIX/sb.calls"
EOF
      chmod +x "$FIX/stub/zellij" "$FIX/stub/system-backup"
    }
    cleanup_fix() { rm -rf "$FIX"; }
    BeforeEach 'setup_fix'
    AfterEach 'cleanup_fix'

    It 'renders a one-pane layout and names the tab after the anchor'
      run_it() {
        PATH="$FIX/stub:$PATH" ZELLIJ=1 zsh "$BIN" "$FIX/some dir"
        cat "$FIX/zellij.calls"
        cat "$FIX/layout.kdl"
      }
      When run run_it
      The status should be success
      The output should include "action new-tab --name tm: some dir --layout"
      The output should include 'command="system-backup"'
      The output should include "args \"browse\" \"$FIX/some dir\""
      The output should include "close_on_exit true"
    End

    It 'escapes KDL-hostile characters in the anchor path'
      run_it() {
        PATH="$FIX/stub:$PATH" ZELLIJ=1 zsh "$BIN" "$FIX/we\"ird"
        grep -F 'we\"ird' "$FIX/layout.kdl" | head -1
      }
      When run run_it
      The status should be success
      The output should include 'we\"ird'
    End

    It 'drops empty positionals and anchors at PWD'
      run_it() {
        cd "$FIX"
        PATH="$FIX/stub:$PATH" ZELLIJ=1 zsh "$BIN" ""
        cat "$FIX/layout.kdl" | grep args
      }
      When run run_it
      The status should be success
      The output should include "\"browse\" \"$FIX\""
    End

    It 'degrades to an inline session outside zellij'
      run_it() {
        cd "$FIX"
        PATH="$FIX/stub:$PATH" ZELLIJ= zsh "$BIN" --diff "$FIX"
        cat "$FIX/sb.calls"
        [[ -f "$FIX/zellij.calls" ]] && print zellij-was-called || print no-zellij
      }
      When run run_it
      The status should be success
      The output should include "browse-direct browse --diff $FIX"
      The output should include "no-zellij"
    End
  End
End
