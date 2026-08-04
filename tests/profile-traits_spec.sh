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
