# ~/.ssh/config.d/personal.config — the managed `Host *` defaults. Resolved
# through `ssh -G` against the real file so the assertions are on what ssh
# actually applies, not on text. Without IdentitiesOnly, ssh also offers every
# key the agent holds: 1Password serves a whole vault, so an unrelated key is
# tried first on every connection and refused ("agent refused operation"),
# and a pending approval dialog can stall a non-interactive run outright.
Describe 'ssh defaults (personal.config)'
  CFG="$SHELLSPEC_PROJECT_ROOT/home/private_dot_ssh/config.d/private_personal.config"

  resolved() { ssh -F "$CFG" -G example.invalid 2>/dev/null | grep -E "^$1 "; }

  It 'pins the configured identity as the only one offered'
    When call resolved identitiesonly
    The output should equal "identitiesonly yes"
  End

  It 'still names the ed25519 key as that identity'
    When call resolved identityfile
    The output should include "id_ed25519"
  End
End
