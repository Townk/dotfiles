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
    rm -f "$SHELLSPEC_TMPBASE/cm-calls" "$SHELLSPEC_TMPBASE/ssh-calls" "$SHELLSPEC_TMPBASE/ssh-stdin"
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
    printf '#!/bin/sh\ncat > "%s/ssh-stdin"\necho "$*" >> "%s/ssh-calls"\n' \
      "$SHELLSPEC_TMPBASE" "$SHELLSPEC_TMPBASE" > "$STUBS/ssh"
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
End
