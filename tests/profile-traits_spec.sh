# Tests for home/.chezmoitemplates/profile-traits.tmpl — the single source of
# truth mapping a chezmoi profile to its traits (headless, ephemeral), and the
# fail-closed guarantee that an unknown profile aborts the render.
#
# Hermetic: a throwaway chezmoi config in $SHELLSPEC_TMPBASE; the repo source
# tree is only ever read. CHEZMOI_PROFILE is unset so the ambient shell can
# never leak a profile into the render.
Describe 'profile-traits.tmpl'
  SRC="$SHELLSPEC_PROJECT_ROOT/home"

  setup() {
    CZTMP="$(mktemp -d "$SHELLSPEC_TMPBASE/profile-traits.XXXXXX")"
    mkdir -p "$CZTMP/dest"
    {
      printf '[data]\n'
      printf '    profile = "personal"\n'
      printf '    secretsSlot = ""\n'
      printf '    [data.pi]\n'
      printf '        [data.pi.devExtensions]\n'
      printf '            pi-cockpit = ""\n'
      printf '            pi-plannotator-bridge = ""\n'
    } > "$CZTMP/chezmoi.toml"
    unset CHEZMOI_PROFILE
  }
  BeforeEach 'setup'

  # Renders the helper for one profile; stdout is the raw JSON (or the
  # template error on stderr for the unknown-profile case).
  traits_for() {
    printf '{{ includeTemplate "profile-traits.tmpl" (dict "profile" "%s") }}' "$1" |
      chezmoi --config "$CZTMP/chezmoi.toml" --source "$SRC" \
        --destination "$CZTMP/dest" execute-template
  }

  Parameters
    personal  false false
    work      false false
    dev-shell true  true
    server    true  false
  End

  It "maps profile $1 to headless=$2 ephemeral=$3"
    When call traits_for "$1"
    The status should be success
    The output should include "\"headless\": $2"
    The output should include "\"ephemeral\": $3"
  End

  It 'fails the render on an unknown profile (fail-closed)'
    When call traits_for laptop
    The status should be failure
    The stderr should include "profile-traits: unknown profile"
  End
End

# The init template must emit the SOPS_AGE_KEY_FILE [env] block for every
# headless profile (dev-shell AND server), and for no human profile.
Describe '.chezmoi.toml.tmpl headless SOPS gate'
  SRC="$SHELLSPEC_PROJECT_ROOT/home"

  render_init() {
    # --init gives the template promptString; CHEZMOI_PROFILE must not leak.
    unset CHEZMOI_PROFILE
    chezmoi execute-template --init --promptString profile="$1" \
      < "$SRC/.chezmoi.toml.tmpl"
  }

  It 'emits SOPS_AGE_KEY_FILE for server'
    When call render_init server
    The status should be success
    The output should include "SOPS_AGE_KEY_FILE"
    The output should include 'profile = "server"'
  End

  It 'emits SOPS_AGE_KEY_FILE for dev-shell'
    When call render_init dev-shell
    The status should be success
    The output should include "SOPS_AGE_KEY_FILE"
  End

  It 'does not emit SOPS_AGE_KEY_FILE for personal'
    When call render_init personal
    The status should be success
    The output should not include "SOPS_AGE_KEY_FILE"
  End
End
