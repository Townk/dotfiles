# vnc-companion-resolve — Screen Sharing window title -> onboarded ssh alias.
# The fragments' `Host` lines are the truth source; the FIRST token (the
# canonical alias the Match hook keys on) is the answer; a title naming no
# onboarded machine is rc 1, silently.
Describe 'vnc-companion-resolve'
  RESOLVE="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_vnc-companion-resolve"

  setup() {
    export VNC_COMPANION_CONF_DIR="$SHELLSPEC_TMPBASE/confd"
    rm -rf "$VNC_COMPANION_CONF_DIR"; mkdir -p "$VNC_COMPANION_CONF_DIR"
    cat > "$VNC_COMPANION_CONF_DIR/mac-mini.conf" <<CONF
# ---
# alias: mac-mini
# ---
Host mac-mini thiago-mac-mini thiago-mac-mini.local
    HostName mini
CONF
    cat > "$VNC_COMPANION_CONF_DIR/devbox.conf" <<CONF
Host devbox dev-box.local
    HostName devbox.example
CONF
  }
  BeforeEach 'setup'

  It 'maps a peer-hostname title to the canonical alias'
    When run script "$RESOLVE" "thiago-mac-mini — Screen Sharing"
    The status should eq 0
    The output should equal 'mac-mini'
  End

  It 'matches case-insensitively and via the .local form'
    When run script "$RESOLVE" "Sharing THIAGO-MAC-MINI.LOCAL"
    The status should eq 0
    The output should equal 'mac-mini'
  End

  It 'resolves the second fragment too'
    When run script "$RESOLVE" "dev-box.local"
    The status should eq 0
    The output should equal 'devbox'
  End

  It 'is rc 1 and silent for a title naming no onboarded machine'
    When run script "$RESOLVE" "some-random-host"
    The status should eq 1
    The output should equal ''
  End

  It 'is rc 1 on an empty title'
    When run script "$RESOLVE" ""
    The status should eq 1
  End
End
