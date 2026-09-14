# gpg-agent-forward-provision — the oneshot behind gpg-forward-socketdir.service.
# Its sshd half (StreamLocalBindUnlink) used to go through `sudo -n` only, so a
# server administered as root WITHOUT sudo logged "sudo unavailable" and left
# sshd alone — every reconnect then collided with the socket the previous
# session left behind ("remote port forwarding failed"). Root must write the
# drop-in directly. gpgconf/sshd/systemctl/id are stubbed on PATH; the drop-in
# path comes from the GPG_FORWARD_SSHD_DROPIN seam so the test never touches
# /etc.
Describe 'gpg-agent-forward-provision'
  SCRIPT="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_gpg-agent-forward-provision"

  setup() {
    WORK="$(mktemp -d "$SHELLSPEC_TMPBASE/gpgfwd.XXXXXX")"
    mkdir -p "$WORK/bin" "$WORK/etc"
    printf '#!/bin/sh\nexit 0\n' >"$WORK/bin/gpgconf"
    printf '#!/bin/sh\nexit 0\n' >"$WORK/bin/sshd"
    printf '#!/bin/sh\necho "$*" >>"%s/systemctl.log"\n' "$WORK" >"$WORK/bin/systemctl"
    chmod +x "$WORK/bin/gpgconf" "$WORK/bin/sshd" "$WORK/bin/systemctl"
    export WORK DROPIN="$WORK/etc/99-gpg-agent-forward.conf"
  }
  BeforeEach 'setup'

  stub_uid() {   # stub_uid <uid> — `id -u` answer
    printf '#!/bin/sh\necho %s\n' "$1" >"$WORK/bin/id"
    chmod +x "$WORK/bin/id"
  }

  # No sudo anywhere on PATH: only the stub dir plus the bare system dirs.
  run_provision() {
    env -i PATH="$WORK/bin:/usr/bin:/bin" HOME="$WORK" \
      GPG_FORWARD_SSHD_DROPIN="$DROPIN" sh "$SCRIPT"
  }

  It 'as root without sudo, writes the sshd drop-in and reloads sshd'
    stub_uid 0
    When call run_provision
    The status should be success
    The output should include "installed"
    The contents of file "$DROPIN" should include "StreamLocalBindUnlink yes"
    The contents of file "$WORK/systemctl.log" should include "reload ssh"
  End

  It 'as a non-root user without sudo, leaves sshd alone and says so'
    stub_uid 1000
    When call run_provision
    The status should be success
    The stderr should include "sudo unavailable"
    The path "$DROPIN" should not be exist
  End

  It 'is idempotent: an existing drop-in is left alone and sshd is not reloaded'
    stub_uid 0
    printf 'StreamLocalBindUnlink yes\n' >"$DROPIN"
    When call run_provision
    The status should be success
    The path "$WORK/systemctl.log" should not be exist
  End
End
