# ssh-prepare-connection `mount` step (clipboard-mount spec §3.2): mounts the
# peer at connect, gated on peer-hostname + the clipboard RemoteForward,
# backgrounded so the connection never waits. The step disowns its work, so
# examples poll for the stub's record file.
Describe 'ssh-prepare-connection: mount step'
  SPC="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_ssh-prepare-connection"

  write_conf() {  # write_conf <peer-hostname-line-or-empty> <remoteforward 0|1>
    {
      echo "# ---"
      echo "# alias: mini"
      echo "# prepare: mount"
      [ -n "$1" ] && echo "# peer-hostname: $1"
      echo "# ---"
      echo "Host mini thiago-mac-mini"
      echo "    HostName 192.0.2.10"
      if [ "$2" = 1 ]; then
        echo "    RemoteForward 127.0.0.1:2490 127.0.0.1:2489"
      fi
    } > "$CONF"
  }

  run_and_wait() {
    zsh -f "$SPC" "$CONF"
    i=0; while [ ! -e "$SHELLSPEC_TMPBASE/cm-calls" ] && [ $i -lt 30 ]; do sleep 0.1; i=$((i+1)); done
    return 0
  }

  setup() {
    CONF="$SHELLSPEC_TMPBASE/mini.conf"
    rm -f "$SHELLSPEC_TMPBASE/cm-calls" "$SHELLSPEC_TMPBASE/ssh-calls" \
      "$SHELLSPEC_TMPBASE/ssh-stdin" "$SHELLSPEC_TMPBASE/ssh-token-stdin" \
      "$SHELLSPEC_TMPBASE/ssh-peerterm-stdin" "$SHELLSPEC_TMPBASE/ssh-mount-token-stdin"
    # The credential push (RECOB §9.2) fires only when this machine HAS a
    # token, so every example gets its own empty state dir: without this the
    # step's behavior here would depend on whether recobd had ever run on the
    # machine running the suite.
    export XDG_STATE_HOME="$SHELLSPEC_TMPBASE/state"
    rm -rf "$XDG_STATE_HOME"
    mkdir -p "$XDG_STATE_HOME/clipboard"
    STUBS="$SHELLSPEC_TMPBASE/bin"
    export PATH="$STUBS:$PATH"
    mkdir -p "$STUBS"
    export CLIPBOARD_MOUNT_BIN="$STUBS/clipboard-mount"
    printf '#!/bin/sh\necho "$*" >> "%s"\n' "$SHELLSPEC_TMPBASE/cm-calls" > "$STUBS/clipboard-mount"
    # the other prepare steps' externals. `ssh` records every invocation's
    # argv (to ssh-calls) and stdin (to ssh-stdin) -- prepare: mount runs
    # only step_mount, whose sole ssh caller is the new identity push below,
    # so recording is unambiguous for those examples; the prepare: all
    # example below never inspects these files, so step_gpg's own inert ssh
    # call there is harmless noise.
    # step_mount makes three ssh calls now (identity, peer-term, credential),
    # so the stub keeps their stdin apart -- each push is recognizable by its
    # remote command, and every example's assertions stay unambiguous.
    printf '#!/bin/sh\ncase "$*" in *mount-tokens*) cat > "%s/ssh-mount-token-stdin" ;; *tunnel-tokens*) cat > "%s/ssh-token-stdin" ;; *accepted-token*) printf %%s bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb ;; *rm\\ -f*peer-term*) : ;; *peer-term*) cat > "%s/ssh-peerterm-stdin" ;; *) cat > "%s/ssh-stdin" ;; esac\necho "$*" >> "%s/ssh-calls"\n' \
      "$SHELLSPEC_TMPBASE" "$SHELLSPEC_TMPBASE" "$SHELLSPEC_TMPBASE" "$SHELLSPEC_TMPBASE" "$SHELLSPEC_TMPBASE" > "$STUBS/ssh"
    # The peer-term push reads the REAL terminal's fingerprints; the suite
    # may itself run inside one, so every example starts undetectable and
    # the ones that test detection set exactly what they mean.
    unset TERM_PROGRAM WEZTERM_PANE WEZTERM_EXECUTABLE GHOSTTY_RESOURCES_DIR
    printf '#!/bin/sh\nexit 0\n' > "$STUBS/rsync"
    chmod +x "$STUBS/clipboard-mount" "$STUBS/ssh" "$STUBS/rsync"
  }
  BeforeEach 'setup'

  wait_for_ssh_calls() {
    zsh -f "$SPC" "$CONF"
    i=0; while [ ! -e "$SHELLSPEC_TMPBASE/ssh-calls" ] && [ $i -lt 30 ]; do sleep 0.1; i=$((i+1)); done
    return 0
  }

  It 'ensures the peer mount, keyed by peer-hostname, ssh via the alias'
    write_conf thiago-mac-mini 1
    When call run_and_wait
    The contents of file "$SHELLSPEC_TMPBASE/cm-calls" should equal "ensure thiago-mac-mini mini"
  End

  It 'skips silently when the fragment has no peer-hostname'
    write_conf "" 1
    When call run_and_wait
    The path "$SHELLSPEC_TMPBASE/cm-calls" should not be exist
  End

  It 'skips when the fragment has no clipboard RemoteForward'
    write_conf thiago-mac-mini 0
    When call run_and_wait
    The path "$SHELLSPEC_TMPBASE/cm-calls" should not be exist
  End

  It 'skips when peer-hostname is not a safe ssh/host name'
    write_conf "../evil" 1
    When call run_and_wait
    The path "$SHELLSPEC_TMPBASE/cm-calls" should not be exist
  End

  # 6c: the credential FETCH — the mirror of the token push. Pointer pushes
  # from this machine dial the 2491 LocalForward, whose far end challenges
  # with the REMOTE's token, so step_mount pulls the remote's accepted-token
  # back into our tunnel-tokens keyed by its identity, mode 600.
  It 'fetches the visited-direction credential back, keyed by peer hostname'
    write_conf thiago-mac-mini 1
    fetched="$XDG_STATE_HOME/clipboard/tunnel-tokens/thiago-mac-mini"
    run_and_wait_token() {
      run_and_wait
      i=0; while [ ! -e "$fetched" ] && [ $i -lt 30 ]; do sleep 0.1; i=$((i+1)); done
      cat "$fetched" 2>/dev/null
      printf '|%s' "$(stat -f %Lp "$fetched" 2>/dev/null || stat -c %a "$fetched" 2>/dev/null)"
    }
    When call run_and_wait_token
    The output should include 'bbbbbbbb'
    The output should end with '|600'
  End

  no_fetch_call() {
    grep -c 'accepted-token' "$SHELLSPEC_TMPBASE/ssh-calls" 2>/dev/null || echo 0
  }

  # 6c part 2: the mount-serve token push -- the visited machine's reverse
  # mount answers OUR serve's challenge with this token, so step_mount ships
  # it per-connect, keyed by our identity, mode-600 discipline remote-side.
  It 'pushes the mount-serve token to the visited machine when the serve has minted one'
    write_conf thiago-mac-mini 1
    printf '%s' "$(printf 'c%.0s' $(seq 64))" > "$XDG_STATE_HOME/clipboard/mount-serve-token"
    wait_mount_token() {
      run_and_wait
      i=0; while [ ! -e "$SHELLSPEC_TMPBASE/ssh-mount-token-stdin" ] && [ $i -lt 30 ]; do sleep 0.1; i=$((i+1)); done
      cat "$SHELLSPEC_TMPBASE/ssh-mount-token-stdin" 2>/dev/null
    }
    When call wait_mount_token
    The output should include 'cccccccc'
    The contents of file "$SHELLSPEC_TMPBASE/ssh-calls" should include 'mount-tokens'
  End

  It 'skips the mount-serve push silently when no serve token exists'
    write_conf thiago-mac-mini 1
    When call run_and_wait
    The path "$SHELLSPEC_TMPBASE/ssh-mount-token-stdin" should not be exist
  End

  It 'the credential fetch also respects the unsafe-hostname gate'
    write_conf "../evil" 1
    When call run_and_wait
    The result of function no_fetch_call should eq 0
  End

  It 'prepare: all includes the mount step'
    write_conf thiago-mac-mini 1
    sed -i '' 's/# prepare: mount/# prepare: all/' "$CONF"
    When call run_and_wait
    The contents of file "$SHELLSPEC_TMPBASE/cm-calls" should equal "ensure thiago-mac-mini mini"
  End

  # R-batch Task A: front-matter `alias:` is now a space-separated list of
  # full entry points; parse_header's target must be the FIRST token only —
  # a later token (e.g. a second human-facing name) must never leak into the
  # ssh target this step connects with.
  It 'uses the first alias token as the ssh target when the front matter lists several'
    {
      echo "# ---"
      echo "# alias: mini backup-mini"
      echo "# prepare: mount"
      echo "# peer-hostname: thiago-mac-mini"
      echo "# ---"
      echo "Host mini backup-mini thiago-mac-mini thiago-mac-mini.local"
      echo "    HostName 192.0.2.10"
      echo "    RemoteForward 127.0.0.1:2490 127.0.0.1:2489"
    } > "$CONF"
    When call run_and_wait
    The contents of file "$SHELLSPEC_TMPBASE/cm-calls" should equal "ensure thiago-mac-mini mini"
  End

  # R-batch Task B amendment: the driven machine may not know its own stable
  # clipboard identity (ephemeral cloud hostnames); peer-hostname IS that
  # identity, and the sit-at machine (running this script, right now) is the
  # one that knows it -- so it pushes a fail-soft, backgrounded self-name
  # file to the target before the mount ensure call.
  It 'pushes a stable self-name identity to the peer, keyed by peer-hostname, via ssh to the alias target'
    write_conf thiago-mac-mini 1
    When call wait_for_ssh_calls
    The contents of file "$SHELLSPEC_TMPBASE/ssh-calls" should include "mini"
    The contents of file "$SHELLSPEC_TMPBASE/ssh-stdin" should equal "thiago-mac-mini"
  End

  # Nested-mux reality (found live at cutover validation): the remote's
  # fullscreen-toggle cannot detect the physical terminal through an inner
  # mux, and the sit-at machine -- running this script, right now -- is the
  # one that knows what it runs in. TERM_PROGRAM survives mux layers where
  # TERM does not.
  wait_for_peerterm() {
    zsh -f "$SPC" "$CONF"
    i=0; while [ ! -e "$SHELLSPEC_TMPBASE/ssh-peerterm-stdin" ] && [ $i -lt 30 ]; do sleep 0.1; i=$((i+1)); done
    return 0
  }

  It 'pushes the physical terminal for the fullscreen toggle when detectable'
    write_conf thiago-mac-mini 1
    export TERM_PROGRAM=ghostty
    When call wait_for_peerterm
    The contents of file "$SHELLSPEC_TMPBASE/ssh-peerterm-stdin" should equal "ghostty"
  End

  # An undetectable terminal REMOVES the remote state instead of leaving a
  # stale name from a previous connect to misdirect the toggle; absent state
  # falls back to the old detection chain on the remote.
  wait_for_peerterm_rm() {
    zsh -f "$SPC" "$CONF"
    i=0; while ! grep -q "rm -f" "$SHELLSPEC_TMPBASE/ssh-calls" 2>/dev/null && [ $i -lt 30 ]; do sleep 0.1; i=$((i+1)); done
    return 0
  }

  It 'removes the pushed terminal state when the local terminal is undetectable'
    write_conf thiago-mac-mini 1
    When call wait_for_peerterm_rm
    The contents of file "$SHELLSPEC_TMPBASE/ssh-calls" should include "peer-term"
    The contents of file "$SHELLSPEC_TMPBASE/ssh-calls" should include "rm -f"
    The path "$SHELLSPEC_TMPBASE/ssh-peerterm-stdin" should not be exist
  End

  # RECOB spec §9.2: a remote answering this machine's reverse-tunneled bridge
  # needs this machine's token. The push is keyed by owner, and its MODE is the
  # point -- `umask` before the write and `chmod` after, so the secret never
  # exists readable to anyone else, unlike the self-name push above.
  wait_for_token_push() {
    zsh -f "$SPC" "$CONF"
    i=0
    while [ ! -e "$SHELLSPEC_TMPBASE/ssh-token-stdin" ] && [ $i -lt 30 ]; do
      sleep 0.1; i=$((i+1))
    done
    return 0
  }

  It 'pushes the credential of this machine, keyed by owner, with the mode set before and after the write'
    write_conf thiago-mac-mini 1
    printf '%s\n' "$(printf 'a%.0s' $(seq 64))" > "$XDG_STATE_HOME/clipboard/accepted-token"
    When call wait_for_token_push
    The contents of file "$SHELLSPEC_TMPBASE/ssh-token-stdin" should include "aaaa"
    The contents of file "$SHELLSPEC_TMPBASE/ssh-calls" should include "umask 077"
    The contents of file "$SHELLSPEC_TMPBASE/ssh-calls" should include "tunnel-tokens"
    The contents of file "$SHELLSPEC_TMPBASE/ssh-calls" should include "chmod 700"
    The contents of file "$SHELLSPEC_TMPBASE/ssh-calls" should include "chmod 600"
  End

  It 'pushes no credential when this machine has none yet'
    write_conf thiago-mac-mini 1
    When call wait_for_ssh_calls
    The path "$SHELLSPEC_TMPBASE/ssh-token-stdin" should not be exist
    The contents of file "$SHELLSPEC_TMPBASE/ssh-calls" should not include "tunnel-tokens"
  End
End
