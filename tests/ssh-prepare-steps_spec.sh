# ssh-prepare-connection's `prepare:` list. system-onboard accepts a comma OR
# space list for --prepare and used to write it verbatim, but the hook split
# on whitespace only, so `prepare: gpg,theme` failed as an unknown step on
# EVERY connect — silently, since the Match exec hook discards its output: the
# gpg forward never healed past its first-connect placeholder and the theme
# never pushed. Steps are validated as they are reached, so an unknown FIRST
# token proves the split without any step (or ssh) ever running.
Describe 'ssh-prepare-connection: prepare list parsing'
  SPC="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_ssh-prepare-connection"

  setup() { CONF="$SHELLSPEC_TMPBASE/steps.conf"; }
  BeforeEach 'setup'

  write_conf() {  # write_conf <prepare value>
    {
      echo "# ---"
      echo "# alias: box"
      echo "# prepare: $1"
      echo "# ---"
      echo "Host box"
      echo "    HostName 192.0.2.10"
    } >"$CONF"
  }

  It 'splits a comma-separated list: the unknown token is reported alone'
    write_conf "bogus,theme"
    When run zsh -f "$SPC" "$CONF"
    The status should be failure
    The stderr should include "unknown step 'bogus'"
    The stderr should not include "bogus,theme"
  End

  It 'still splits on whitespace'
    write_conf "bogus theme"
    When run zsh -f "$SPC" "$CONF"
    The status should be failure
    The stderr should include "unknown step 'bogus'"
  End
End
