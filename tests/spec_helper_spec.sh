# Tests for the shared scaffolding in tests/spec_helper.sh: the sandbox, the
# stub writer, the PATH prepend, the canned fake rex, the template renderer,
# and the after-all hook that removes the per-file tmpbase. The contracts are
# in the comments there; the conversion rules in tests/README-scaffolding.md.
Describe 'spec_helper scaffolding'
  Describe 'spec_sandbox'
    It 'sets $SANDBOX to a new, empty directory under the tmpbase'
      made() {
        spec_sandbox || return 1
        [ -d "$SANDBOX" ] && print -r -- "dir entries=$(ls -A "$SANDBOX" | wc -l | tr -d ' ')"
        [[ "$SANDBOX" == "$SHELLSPEC_TMPBASE"/sb.* ]] && print under-tmpbase
      }
      When call made
      The output should equal "dir entries=0
under-tmpbase"
    End

    It 'gives every call its own directory, named after the argument'
      two() {
        spec_sandbox home; local a=$SANDBOX
        spec_sandbox home; local b=$SANDBOX
        [[ "$a" != "$b" && -d "$a" && -d "$b" ]] && print distinct
        print -r -- "${a:t:r} ${b:t:r}"
      }
      When call two
      The output should equal "distinct
home home"
    End

    It 'prints nothing, so it can run in a hook'
      When call spec_sandbox
      The output should equal ""
      The status should be success
    End
  End

  Describe 'spec_stub'
    BeforeEach 'spec_sandbox'

    It 'writes an executable that logs its argv and exits 0'
      run() { spec_stub "$SANDBOX" croc; "$SANDBOX/croc" send --code x; print -r -- "rc=$?"; "$SANDBOX/croc"; spec_stub_calls "$SANDBOX" croc | sed 's/^/argv=/'; }
      When call run
      The output should equal "rc=0
argv=send --code x
argv="
    End

    It 'keeps an argument with newlines on one log line'
      run() { spec_stub "$SANDBOX" ssh; "$SANDBOX/ssh" host "line one
line two" 'back\nslash'; spec_stub_calls "$SANDBOX" ssh | wc -l | tr -d ' '; spec_stub_calls "$SANDBOX" ssh; }
      When call run
      The output should equal '1
host line one line two back\nslash'
    End

    It 'runs the body after logging, with its own directory as $STUB_DIR'
      run() {
        spec_stub "$SANDBOX" tool \
          'echo "log has $(wc -l <"$STUB_LOG" | tr -d " ") line"' \
          'case "$1" in fail) exit 3 ;; esac' \
          'cat >"$STUB_DIR/stdin"'
        print -r -- piped | "$SANDBOX/tool" go; print -r -- "rc=$? stdin=$(cat "$SANDBOX/stdin")"
        "$SANDBOX/tool" fail >/dev/null; print -r -- "rc=$?"
      }
      When call run
      The output should equal "log has 1 line
rc=0 stdin=piped
rc=3"
    End

    It 'expands nothing in the body when the stub is written'
      run() { spec_stub "$SANDBOX" tool 'echo "$HOME|$1"'; HOME=/at/run/time "$SANDBOX/tool" x; }
      When call run
      The output should equal "/at/run/time|x"
    End

    It 'creates the directory, and survives a quote in its name'
      run() { spec_stub "$SANDBOX/it's/bin" tool 'echo "$STUB_DIR"'; "$SANDBOX/it's/bin/tool" a; spec_stub_calls "$SANDBOX/it's/bin" tool; }
      When call run
      The output should equal "$SANDBOX/it's/bin
a"
    End

    It 'reports no calls for a stub that never ran'
      When call spec_stub_calls "$SANDBOX" never
      The output should equal ""
      The status should be success
    End

    It 'refuses to be called without a name'
      When call spec_stub "$SANDBOX"
      The status should equal 2
      The error should include "usage: spec_stub"
    End
  End

  # No restore is needed after an example: each one runs in its own subshell,
  # hooks included. The second example of each pair runs after the first and
  # sees none of what it exported.
  Describe 'spec_path_prepend'
    It 'puts the directories first on PATH, in the order given, exported'
      run() { spec_sandbox; spec_stub "$SANDBOX/a" uname 'echo stubbed'; spec_path_prepend "$SANDBOX/a" "$SANDBOX/b"; sh -c uname; [[ "$PATH" == "$SANDBOX/a:$SANDBOX/b:"* ]] && print ordered; }
      When call run
      The output should equal "stubbed
ordered"
    End

    It 'is undone by the end of the example'
      When call sh -c uname
      The output should not equal "stubbed"
      The value "$PATH" should not include "/sb."
    End

    Describe 'from a BeforeEach'
      prepend() { spec_sandbox; spec_stub "$SANDBOX" uname 'echo stubbed'; spec_path_prepend "$SANDBOX"; export SPEC_SCOPE_PROBE=set; }
      BeforeEach 'prepend'
      It 'reaches the example'
        When call sh -c 'uname; echo "$SPEC_SCOPE_PROBE"'
        The output should equal "stubbed
set"
      End
    End

    It 'and what a BeforeEach exported is gone as well'
      When call sh -c 'echo "${SPEC_SCOPE_PROBE-unset}"'
      The output should equal "unset"
      The value "$PATH" should not include "/sb."
    End
  End

  # Time does not pass in a spec; the clock is the test's to move.
  Describe 'the virtual clock'
    BeforeEach 'spec_clock_set 1000'

    It 'starts where it is set and moves only when told'
      run() { spec_clock_now; spec_clock_advance 90; spec_clock_now; spec_clock_advance 0.25; spec_clock_now ms; spec_clock_set 5; spec_clock_now; }
      When call run
      The output should equal "1000
1090
1090250
5"
    End

    It 'runs a loop of 25 sleeps of 0.2 s at once, and the clock is exactly 5 s later'
      run() {
        local i; for i in {1..25}; do sleep 0.2; done
        spec_clock_now ms
        spec_clock_slept | sort | uniq -c | tr -s ' '
      }
      When call run
      The output should equal "1005000
 25 0.2"
    End

    It 'flips a deadline exactly when the clock passes it'
      expired() { (( $(date +%s) >= 1030 )) && print expired || print pending; }
      run() { expired; spec_clock_advance 29.999; expired; spec_clock_advance 0.001; expired; }
      When call run
      The output should equal "pending
pending
expired"
    End

    It 'ends a poll loop at its deadline, in as many polls as the arithmetic says'
      # Code under test in miniature: poll every 0.5 s until 3 s have passed.
      poll() { local -i n=0 until=$(( $(date +%s) + 3 )); while (( $(date +%s) < until )); do (( n += 1 )); sleep 0.5; done; print -r -- "polls=$n"; }
      When call poll
      The output should equal "polls=6"
    End

    It 'is the same clock in a child process, in sh and in zsh'
      run() {
        sh -c 'sleep 2; date +%s'
        zsh -fc 'sleep 1m; print -r -- "$(date +%s)"'
        ( sleep 1.5 ) &
        wait
        spec_clock_now ms
      }
      When call run
      The output should equal "1002
1062
1063500"
    End

    It 'is one clock for the fake sleep, common::sleep and a stub that takes time'
      # COMMON_CLOCK_FILE is the name production code (common.zsh) knows the
      # journal by: always the same file.
      run() {
        print -r -- "${COMMON_CLOCK_FILE#"$SPEC_CLOCK_FILE"}|$(sh -c 'echo "${COMMON_CLOCK_FILE:+exported}"')"
        spec_stub "$SHELLSPEC_TMPBASE/slow" slow-tool 'spec-clock-advance 7'
        zsh -fc 'source "$1"; common::sleep 0.05; sleep 0.2; "$2"; common::sleep 3; common::now -m; print -r -- "$REPLY"' \
          zsh "$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib/common.zsh" "$SHELLSPEC_TMPBASE/slow/slow-tool"
        spec_clock_now ms
        spec_clock_slept | tr '\n' ' '
      }
      When call run
      The output should equal "|exported
1010250
1010250
0.05 0.2 3 "
    End

    It 'lets a test wait for what the code beside it believes has passed, not for time'
      # A loop in the background naps on the virtual clock at full speed. The
      # test joins it at 0.5 s of ITS time; the guard ends it at 1000 s of it
      # (ten thousand naps: half a second, yet far past the look).
      run() {
        zsh -fc 'source "$1"; while :; do common::sleep 0.1; done' zsh "$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib/common.zsh" &
        local pid=$!
        spec_clock_guard "$pid" 1000
        spec_clock_await 0.5
        (( $(spec_clock_now ms) >= 1000500 )) && kill -0 "$pid" 2>/dev/null && print "running at 0.5"
        wait "$pid" 2>/dev/null
        print -r -- "killed by the guard: rc=$? past the bound: $(( $(spec_clock_now ms) >= 2000000 ))"
        spec_clock_guard_off
      }
      When call run
      The output should equal "running at 0.5
killed by the guard: rc=137 past the bound: 1"
    End

    It 'stands a guard down without touching a process that ended by itself'
      run() {
        zsh -fc 'source "$1"; common::sleep 0.1' zsh "$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib/common.zsh" &
        local pid=$!
        spec_clock_guard "$pid"
        wait "$pid"; print -r -- "rc=$?"
        spec_clock_guard_off
        print -r -- "guard=${SPEC_CLOCK_GUARD:-off} left=$(ls "$SHELLSPEC_TMPBASE" | grep -c '^guard\.')"
      }
      When call run
      The output should equal "rc=0
guard=off left=0"
    End

    It 'loses no update when processes advance it at the same time'
      run() {
        local p
        for p in 1 2 3 4; do ( local i; for i in {1..25}; do sleep 0.1; done ) & done
        wait
        spec_clock_now ms
        spec_clock_slept | wc -l | tr -d ' '
      }
      When call run
      The output should equal "1010000
100"
    End

    It 'answers date in any format for the virtual now, and passes an explicit time through'
      run() { spec_clock_set 86400; date -u +%F; date -u '+%H:%M:%S'; date -u -r 0 +%Y 2>/dev/null || date -u -d @0 +%Y; }
      When call run
      The output should equal "1970-01-02
00:00:00
1970"
    End

    # The free-running clock cannot hold code still. Stepped, every nap stops
    # at a gate until the test lets it through: nothing here waits or polls,
    # each "it is at its nap now" is a blocking open of the gate's FIFO.
    Describe 'stepped'
      COMMON="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib/common.zsh"
      BeforeEach 'spec_clock_stepped'
      # napper <out> <seconds>… — in the background: nap each, then leave a
      # line in <out>. $! is the napper.
      napper() {
        zsh -fc 'source "$1"; out=$2; shift 2
          for s; do common::sleep "$s"; done; print -r -- "done $*" >> "$out"' \
          zsh "$COMMON" "$@" &
      }

      It 'holds a sleeper at its nap until the test lets it through'
        run() {
          local out="$SHELLSPEC_TMPBASE/held.$$" pid
          rm -f "$out"
          napper "$out" 0.2; pid=$!
          spec_clock_held
          print -r -- "held: ${SPEC_CLOCK_HELD#* } own-pid=$(( ${SPEC_CLOCK_HELD%% *} == pid ))"
          print -r -- "meanwhile: now=$(spec_clock_now ms) slept=$(spec_clock_slept | wc -l | tr -d ' ') done=$(cat "$out" 2>/dev/null)"
          spec_clock_step
          wait "$pid"; print -r -- "rc=$? now=$(spec_clock_now ms) $(cat "$out")"
        }
        When call run
        The output should equal "held: 200 0.2 own-pid=1
meanwhile: now=1000000 slept=0 done=
rc=0 now=1000200 done 0.2"
      End

      It 'lets exactly as many naps through as it is told, and the clock moves by their sum'
        run() {
          local out="$SHELLSPEC_TMPBASE/two.$$" pid
          rm -f "$out"
          napper "$out" 0.1 0.25 3; pid=$!
          spec_clock_step 2
          # The third nap is asked for, and not granted.
          spec_clock_held
          print -r -- "after two: now=$(spec_clock_now ms) slept=$(spec_clock_slept | tr '\n' ' ')held=${SPEC_CLOCK_HELD#* } done=$(cat "$out" 2>/dev/null)"
          spec_clock_release
          wait "$pid"; print -r -- "rc=$? now=$(spec_clock_now ms) slept=$(spec_clock_slept | tr '\n' ' ')"
        }
        When call run
        The output should equal "after two: now=1000350 slept=0.1 0.25 held=3000 3 done=
rc=0 now=1003350 slept=0.1 0.25 3 "
      End

      # One sleeper is at the gate at a time; the others queue behind it,
      # unseen, in no promised order. A step lets ONE through.
      It 'lets two concurrent sleepers through one at a time'
        run() {
          local out="$SHELLSPEC_TMPBASE/conc.$$" a b first second
          rm -f "$out"
          napper "$out" 0.1; a=$!
          napper "$out" 0.2; b=$!
          spec_clock_held; first=${SPEC_CLOCK_HELD%% *}
          spec_clock_step
          spec_clock_held; second=${SPEC_CLOCK_HELD%% *}
          [[ "$first" != "$second" && " $a $b " == *" $first "* && " $a $b " == *" $second "* ]] \
            && print "each in turn"
          # The second is at the gate: only the first can have finished.
          wait "$first"
          print -r -- "one through: slept=$(spec_clock_slept | wc -l | tr -d ' ') done=$(wc -l < "$out" | tr -d ' ')"
          spec_clock_step
          wait "$second"
          print -r -- "both: now=$(spec_clock_now ms) slept=$(spec_clock_slept | sort | tr '\n' ' ')done=$(wc -l < "$out" | tr -d ' ')"
        }
        When call run
        The output should equal "each in turn
one through: slept=1 done=1
both: now=1000300 slept=0.1 0.2 done=2"
      End

      It 'holds a sleeper in a subshell, in a child process, and one that calls the sleep command'
        run() {
          zsh -fc 'source "$1"
            ( common::sleep 0.5 )
            zsh -fc "source \"\$1\"; common::sleep 1" zsh "$1"
            sh -c "sleep 2 1m"
            common::now -m; print -r -- "child sees $REPLY"' zsh "$COMMON" &
          local pid=$! held=
          local i; for i in 1 2 3; do spec_clock_held; held+="${SPEC_CLOCK_HELD#* }|"; spec_clock_step; done
          wait "$pid"
          print -r -- "held=$held now=$(spec_clock_now ms) slept=$(spec_clock_slept | tr '\n' ',')"
        }
        When call run
        The output should equal "child sees 1063500
held=500 0.5|1000 1|62000 2 1m| now=1063500 slept=0.5,1,2 1m,"
      End

      It 'does not block when it releases with no sleeper waiting, and the clock then runs free'
        run() {
          spec_clock_release
          spec_clock_release
          sleep 1
          zsh -fc 'source "$1"; common::sleep 0.5' zsh "$COMMON"
          print -r -- "now=$(spec_clock_now ms) slept=$(spec_clock_slept | tr '\n' ' ')"
        }
        When call run
        The output should equal "now=1001500 slept=1 0.5 "
      End

      It 'can be stepped again after a release'
        run() {
          local out="$SHELLSPEC_TMPBASE/again.$$" pid
          rm -f "$out"
          spec_clock_release
          spec_clock_stepped
          napper "$out" 4; pid=$!
          spec_clock_held; print -r -- "held=${SPEC_CLOCK_HELD#* }"
          spec_clock_step; wait "$pid"; print -r -- "now=$(spec_clock_now ms)"
        }
        When call run
        The output should equal "held=4000 4
now=1004000"
      End

      # The gate lives beside the journal, in the tmpbase. A sleeper that
      # arrives when it is gone does not stop.
      It 'does not stop a sleeper whose gate has disappeared'
        run() {
          rm -rf "$SPEC_CLOCK_FILE.gate"
          zsh -fc 'source "$1"; common::sleep 0.3' zsh "$COMMON"
          sleep 2
          print -r -- "rc=$? slept=$(spec_clock_slept | tr '\n' ' ')"
        }
        When call run
        The output should equal "rc=0 slept=0.3 2 "
      End

      It 'is not upset by a sleeper that dies at the gate'
        run() {
          local out="$SHELLSPEC_TMPBASE/dies.$$" a b
          rm -f "$out"
          napper "$out" 7; a=$!
          spec_clock_held
          kill -9 "$a"; wait "$a" 2>/dev/null
          napper "$out" 0.4; b=$!
          spec_clock_step
          wait "$b"; print -r -- "rc=$? now=$(spec_clock_now ms) $(cat "$out")"
        }
        When call run
        The output should equal "rc=0 now=1000400 done 0.4"
      End

      # A wait the clock cannot see (a blocking lock): the code says it is
      # about to block. It stops at the gate like a nap; it moves no clock.
      It 'holds code that announces a wait in the kernel, and moves no clock for it'
        run() {
          zsh -fc 'source "$1"; common::blocking some.lock; print announced' zsh "$COMMON" &
          local pid=$!
          spec_clock_held; print -r -- "held=${SPEC_CLOCK_HELD#* }"
          spec_clock_step; wait "$pid"
          print -r -- "now=$(spec_clock_now ms) slept=$(spec_clock_slept | wc -l | tr -d ' ')"
          spec_clock_release
          zsh -fc 'source "$1"; common::blocking some.lock; print free' zsh "$COMMON"
          env -u COMMON_CLOCK_FILE zsh -fc 'source "$1"; common::blocking some.lock; print real' zsh "$COMMON"
          print -r -- "journal lines=$(wc -l < "$SPEC_CLOCK_FILE" | tr -d ' ')"
        }
        When call run
        The output should equal "held=- some.lock
announced
now=1000000 slept=0
free
real
journal lines=1"
      End

      # Deadlock safety. An example that ends with a sleeper still held does
      # not leave it there: the suite-wide AfterEach releases the gate …
      It 'frees a held sleeper from the suite-wide after-each hook'
        run() {
          local out="$SHELLSPEC_TMPBASE/hook.$$" pid
          rm -f "$out"
          napper "$out" 9; pid=$!
          spec_clock_held
          spec_clock_after_each
          wait "$pid"; print -r -- "rc=$? $(cat "$out") slept=$(spec_clock_slept)"
        }
        When call run
        The output should equal "rc=0 done 9 slept=9"
      End

      # … and so does the hook that removes the tmpbase, for a gate whose
      # example never got that far.
      It 'frees a held sleeper before the tmpbase is removed'
        run() {
          spec_sandbox || return 1
          local dir=$SANDBOX pid
          (
            SHELLSPEC_TMPBASE=$dir; unset SPEC_CLOCK_FILE
            spec_clock_set 5; spec_clock_stepped
            zsh -fc 'source "$1"; common::sleep 9' zsh "$COMMON" &
            pid=$!
            spec_clock_held
            SPEC_HELPER_TMPBASE=$dir spec_helper_drop_tmpbase
            wait "$pid"; print -r -- "rc=$?"
          )
          [[ -e "$dir" ]] && print "still there" || print removed
        }
        When call run
        The output should equal "rc=0
removed"
        The error should equal ""
      End
    End
  End

  It 'leaves no clock, and no fake sleep, behind for the next example'
    When call sh -c 'echo "${SPEC_CLOCK_FILE-unset}"; command -v sleep'
    The line 1 of output should equal "unset"
    The line 2 of output should not include "/clock."
  End

  Describe 'spec_fake_rex'
    BeforeEach 'spec_sandbox' 'unset STUB_SERVER STUB_NEW STUB_LAYER STUB_INSPECT_RC'
    rex() { "$SANDBOX/rex" --autostart=false "$@"; }

    It 'logs every call on one line'
      run() { spec_fake_rex "$SANDBOX"; rex whoami; rex send -- "a
b"; spec_stub_calls "$SANDBOX" rex; }
      When call run
      The output should equal "--autostart=false whoami
--autostart=false send -- a b"
    End

    It 'answers the common questions with defaults'
      run() {
        spec_fake_rex "$SANDBOX"
        rex client ls --json | jq -r '.clients[] | "\(.client_id) \(.connection_state) \(.session_ids[0])"'
        rex ls --json | jq -r '.sessions[] | "\(.session_id) \(.label)"'
        rex api call -s session:main session.view | jq -c .
        rex window new -s session:main --json notes | jq -r .window_id
        print -r -- '{"bounds":[0,0,1,1]}' | rex api call session.new_layer --stdin | jq -r '.block_ids[0]'
        jq -c . "$SANDBOX/req.json"
        [[ "$(rex block call -b block:x process | jq -r .foreground.cwd)" == "$SANDBOX" ]] && print cwd-ok
        rex anything else; print -r -- "other=$?"
      }
      When call run
      The output should equal 'client:mac connected session:main
session:main Main
{"session_id":"session:main","windows":[]}
window:new
block:layer
{"bounds":[0,0,1,1]}
cwd-ok
other=0'
    End

    It 'answers from the fixture files a spec writes'
      run() {
        spec_fake_rex "$SANDBOX"
        print -r -- '{"clients":[]}' >"$SANDBOX/clients.json"
        print -r -- '{"sessions":[{"session_id":"session:j","label":"Jobs"}]}' >"$SANDBOX/sessions.json"
        print -r -- '{"session_id":"session:j","windows":[{"window_id":"window:1"}]}' >"$SANDBOX/view.json"
        print -r -- '{"session_id":"session:j"}' >"$SANDBOX/whoami.json"
        rex client ls --json; rex ls --json; rex api call session.view; rex whoami
      }
      When call run
      The output should equal '{"clients":[]}
{"sessions":[{"session_id":"session:j","label":"Jobs"}]}
{"session_id":"session:j","windows":[{"window_id":"window:1"}]}
{"session_id":"session:j"}'
    End

    It 'exits 4 on every call when STUB_SERVER=down, still logging it'
      export STUB_SERVER=down
      run() {
        spec_fake_rex "$SANDBOX" '*" mine "*) echo mine ;;'
        local call
        for call in whoami "ls --json" "client ls --json" "window new" mine other; do rex ${=call}; print -r -- "$call=$?"; done
        spec_stub_calls "$SANDBOX" rex | wc -l | tr -d ' '
      }
      When call run
      The output should equal "whoami=4
ls --json=4
client ls --json=4
window new=4
mine=4
other=4
6"
    End

    It 'honours the failure knobs'
      run() {
        spec_fake_rex "$SANDBOX"
        STUB_NEW=fail rex window new x; print -r -- "new=$?"
        STUB_LAYER=fail rex session.new_layer </dev/null; print -r -- "layer=$?"
        STUB_INSPECT_RC=3 rex block inspect b; print -r -- "inspect=$?"
      }
      When call run
      The output should equal "new=1
layer=1
inspect=3"
    End

    # Time does not pass in a spec: a layer lives for a number of polls.
    Describe 'the life of a layer'
      layer() { rex api call session.new_layer --stdin </dev/null >/dev/null; }
      inspect() { rex block inspect -s block:layer block:layer; print -r -- "inspect=$?"; }

      It 'is over at once by default: the first inspect finds the block gone'
        run() { spec_fake_rex "$SANDBOX"; inspect; layer; inspect; }
        When call run
        The output should equal "inspect=3
inspect=3"
      End

      It 'lasts STUB_LAYER_LIFE inspects, then the block is gone'
        export STUB_LAYER_LIFE=2
        run() { spec_fake_rex "$SANDBOX"; layer; inspect; inspect; inspect; inspect; spec_stub_calls "$SANDBOX" rex | grep -c ' block inspect '; }
        When call run
        The output should equal "inspect=0
inspect=0
inspect=3
inspect=3
4"
      End

      It 'stays open until it is closed, or until the example ends it'
        export STUB_LAYER_LIFE=open
        run() {
          spec_fake_rex "$SANDBOX"; layer; inspect; inspect
          rex block close block:layer; inspect
          layer; inspect; print 0 >"$SANDBOX/layer.life"; inspect
        }
        When call run
        The output should equal "inspect=0
inspect=0
inspect=3
inspect=0
inspect=3"
      End
    End

    It 'lets the spec add arms, which win over the canned ones'
      run() {
        spec_fake_rex "$SANDBOX" \
          '*" window focus "*) [ "${STUB_FOCUS:-ok}" = ok ] || exit 1 ;;' \
          '*" session.view "*) echo "mine, from $STUB_DIR" ;;'
        rex api call session.view
        rex window focus w; print -r -- "focus=$?"
        STUB_FOCUS=fail rex window focus w; print -r -- "focus=$?"
        rex ls --json | jq -r '.sessions[0].label'
      }
      When call run
      The output should equal "mine, from $SANDBOX
focus=0
focus=1
Main"
    End

    It 'answers an --offline arm with no server, and the rest still exits 4'
      export STUB_SERVER=down
      run() {
        spec_fake_rex "$SANDBOX" '*" online "*) echo online ;;' --offline '*" config check "*) echo checked ;;'
        rex config check; print -r -- "check=$?"
        rex online; print -r -- "online=$?"
      }
      When call run
      The output should equal "checked
check=0
online=4"
    End
  End

  Describe 'spec_render_template'
    BeforeEach 'spec_sandbox'

    It 'renders a template of this source tree into the sandbox'
      run() {
        spec_render_template home/.chezmoiscripts/run_after_60-rex-main-session.sh.tmpl || return 1
        print -r -- "${SPEC_RENDERED#$SANDBOX/}"
        sed -n 1p "$SPEC_RENDERED"
        grep -c '{{' "$SPEC_RENDERED" || true
      }
      When call run
      The output should equal "run_after_60-rex-main-session.sh
#!/bin/sh
0"
    End

    It 'takes an absolute template and a destination'
      run() {
        print -r -- 'os={{ .chezmoi.os }} {{ "shout" | upper }}' >"$SANDBOX/t.tmpl"
        spec_render_template "$SANDBOX/t.tmpl" "$SANDBOX/out.txt" && cat "$SANDBOX/out.txt"
        [[ "$SPEC_RENDERED" == "$SANDBOX/out.txt" ]] && print set
      }
      When call run
      The output should equal "os=$(uname -s | tr A-Z a-z) SHOUT
set"
    End

    It 'fails with the render error, leaving no file, on a broken template'
      print -r -- '{{ nope' >"$SANDBOX/bad.sh.tmpl"
      run() { spec_render_template "$SANDBOX/bad.sh.tmpl"; print -r -- "rc=$? rendered=[$SPEC_RENDERED]"; [[ -e "$SANDBOX/bad.sh" ]] || print "no file"; }
      When call run
      The output should equal "rc=1 rendered=[]
no file"
      The error should include 'function "nope" not defined'
      The error should include "spec_render_template: $SANDBOX/bad.sh.tmpl did not render"
    End

    It 'fails on a template that does not exist'
      When call spec_render_template home/no-such-template.tmpl
      The status should be failure
      The error should include "no such template"
    End
  End

  # No spec reaches the real desktop: notifications, sounds, dialogs and apps
  # go to recording stubs, for every spec file, without the spec asking.
  Describe 'the desktop guard'
    BeforeEach 'spec_desktop_reset'
    say_it() { ( source "$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib/common.zsh" && notify "$@" ); }

    It 'records a notification from the production notify, and calls no real hs'
      run() { say_it --icon glyph:nf-md-bell "build done"; print -r -- "rc=$?"; spec_notifications; }
      When call run
      The output should equal 'rc=0
hs -q -t 4 -c notify("glyph:nf-md-bell", "build done", nil)'
    End

    It 'keeps a notification on this machine when the suite runs over SSH'
      # notify takes the clipboard-bridge route (a toast on the ORIGIN machine)
      # whenever the shell is remote. spec_helper unsets what says so.
      run() {
        print -r -- "ssh=${SSH_TTY-}${SSH_CONNECTION-}${SSH_CLIENT-} via=${NOTIFY_VIA_BRIDGE-}"
        ( source "$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib/common.zsh"
          _notify_bridge_target && print bridge || print local
          SSH_CONNECTION="192.0.2.1 1 192.0.2.2 22" _notify_bridge_target && print bridge || print local )
      }
      When call run
      The output should equal "ssh= via=
local
bridge"
    End

    It 'writes the history and the unacked ledger of a toast into the tmpbase, and pokes no tmux'
      run() {
        say_it --ack "needs a look"
        print -r -- "${NOTIFY_HISTORY_FILE#"$SHELLSPEC_TMPBASE"}:$(jq -r .text "$NOTIFY_HISTORY_FILE" | tail -n 1)"
        print -r -- "${NOTIFY_UNACKED_FILE#"$SHELLSPEC_TMPBASE"}:$(wc -l <"$NOTIFY_UNACKED_FILE" | tr -d ' ')"
        spec_desktop_calls notify-tmux
      }
      When call run
      The output should equal "/.notify/history.jsonl:needs a look
/.notify/unacked:1
refresh-client -S"
    End

    It 'refuses a rex nobody stubbed, and answers pueue as a client with no daemon'
      run() {
        print -r -- "mux=$MUX_REX_BIN job=$JOB_REX_BIN"
        ( source "$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib/mux-bootstrap.zsh"
          "$(_mux_rx_bin)" --autostart=false ls --json; print -r -- "rex=$?" )
        pueue status --json; print -r -- "pueue=$?"
        spec_desktop_calls pueue
      }
      When call run
      The output should equal "mux=/usr/bin/false job=/usr/bin/false
rex=1
pueue=1
status --json"
    End

    It 'records a sound instead of playing it'
      run() { say_it --sound Frog "copied"; afplay /System/Library/Sounds/Glass.aiff; say hello; spec_sounds; }
      When call run
      The output should equal "Frog
afplay /System/Library/Sounds/Glass.aiff
say hello"
    End

    It 'swallows dialogs, apps and other notifiers the same way'
      run() {
        osascript -e 'display notification "x"'; print -r -- "osascript=$?"
        open -a Preview /tmp/x.pdf; terminal-notifier -message hi
        spec_desktop_calls open; spec_desktop_calls | wc -l | tr -d ' '
      }
      When call run
      The output should equal "osascript=0
-a Preview /tmp/x.pdf
3"
    End

    It 'holds when a spec moves HOME or prepends to PATH'
      run() {
        spec_sandbox
        HOME="$SANDBOX" XDG_STATE_HOME="$SANDBOX/state" PATH="$SANDBOX:$PATH" say_it "moved"
        spec_notifications | wc -l | tr -d ' '
      }
      When call run
      The output should equal "1"
    End

    # PATH replaced wholesale: the absolute-path seam (HS) still names the
    # stub, so notify is held. What comes back is /usr/bin/osascript, afplay,
    # say and open, for code that calls them by NAME; such a spec keeps
    # $SPEC_DESKTOP_GUARD first on the PATH it builds.
    It 'still holds notify when PATH is replaced, through the pinned HS'
      run() {
        PATH=/usr/bin:/bin say_it --sound Glass "bare path"; spec_sounds
        PATH="$SPEC_DESKTOP_GUARD:/usr/bin:/bin" sh -c 'command -v osascript afplay say open' | sed "s|$SPEC_DESKTOP_GUARD|GUARD|"
      }
      When call run
      The output should equal "Glass
GUARD/osascript
GUARD/afplay
GUARD/say
GUARD/open"
    End

    It 'lets a stub of the spec own win over the guard'
      run() { spec_sandbox; spec_stub "$SANDBOX" hs 'echo mine'; HS="$SANDBOX/hs" say_it "to my stub"; spec_notifications | wc -l | tr -d ' '; }
      When call run
      The output should equal "mine
0"
    End

    It 'refuses to come off without the opt-in of the owner'
      run() { ( unset SPEC_REAL_DESKTOP; spec_desktop_unguard; print -r -- "rc=$?"; [[ "$HS" == "$SPEC_DESKTOP_GUARD/hs" ]] && print guarded ); }
      When call run
      The output should equal "rc=1
guarded"
      The error should include "needs SPEC_REAL_DESKTOP=1"
    End
  End

  # The one notification a run may cause, from the wrapper, after shellspec
  # has exited. The wrapper is run on a throwaway one-example project, with
  # this file's hs stub standing in for the desktop.
  Describe 'the end-of-run toast of run-shellspec.sh'
    setup() {
      spec_desktop_reset
      spec_sandbox; PROJ=$SANDBOX
      mkdir "$PROJ/spec"
      print -r -- '--shell zsh' >"$PROJ/.shellspec"
      print -rl -- "Describe 'p'" "  It 'passes'" '    When call true' '    The status should be success' '  End' 'End' >"$PROJ/spec/a_spec.sh"
    }
    BeforeEach 'setup'
    wrapped() { (cd "$PROJ" && env -i PATH="$PATH" HOME="$HOME" HS="$HS" "$@" "$SHELLSPEC_PROJECT_ROOT/tests/run-shellspec.sh" spec/a_spec.sh >/dev/null 2>&1); print -r -- "rc=$?"; }
    toast() { spec_notifications | sed -E 's/in [0-9]+m [0-9]+s/in TIME/'; }

    It 'is one notification with the suite, the counts and the duration'
      run() { wrapped SPEC_RUN_TOAST=1 SPEC_SUITE=fast; toast; }
      When call run
      The output should equal 'rc=0
hs -q -t 4 -c notify("glyph:nf-md-check_circle", "Tests (fast): 1 examples, 0 failures, 0 skips in TIME", "Glass")'
    End

    It 'is off with SPEC_RUN_TOAST=0, which every spec inherits'
      run() { wrapped SPEC_RUN_TOAST=0; toast; print -r -- "inherited=$SPEC_RUN_TOAST"; }
      When call run
      The output should equal "rc=0
inherited=0"
    End

    It 'is off by default when nobody is at a terminal'
      run() { wrapped; toast; }
      When call run
      The output should equal "rc=0"
    End
  End

  # The after-all hook. An example can leave a process behind that is still
  # writing into the tmpbase (ssh-prepare-connection disowns its pushes); one
  # `rm -rf` then ends with "Directory not empty", and anything an after-all
  # hook prints to stderr is reported as an error of the run.
  Describe 'spec_helper_drop_tmpbase'
    It 'removes a directory something is still writing into, in silence'
      run() {
        spec_sandbox || return 1
        local dir=$SANDBOX
        # A straggler: it writes a bounded number of files, with no pause, and
        # is still at it when the hook starts removing the directory.
        ( local i=0; while (( i < 3000 )); do : >"$dir/f.$((i++))"; done ) 2>/dev/null &
        ( SPEC_HELPER_TMPBASE=$dir; spec_helper_drop_tmpbase ); print -r -- "rc=$?"
        [[ -e "$dir" ]] && print "still there" || print removed
      }
      When call run
      The output should equal "rc=0
removed"
      The error should equal ""
    End

    It 'does nothing without a tmpbase of its own'
      run() { ( unset SPEC_HELPER_TMPBASE; spec_helper_drop_tmpbase ); }
      When call run
      The status should be success
      The output should equal ""
    End
  End
End
