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
End

Describe 'profile-traits.tmpl fail-closed'
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

  traits_for() {
    printf '{{ includeTemplate "profile-traits.tmpl" (dict "profile" "%s") }}' "$1" |
      chezmoi --config "$CZTMP/chezmoi.toml" --source "$SRC" \
        --destination "$CZTMP/dest" execute-template
  }

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

# Semantic fail-closed assertions on the ignore list per profile. Renders go
# through tests/render-matrix.sh (executed, never sourced). OS-dependent
# expectations are gated on the host OS: the suite runs on both the Macs and
# the Linux dev-shell, so both branches get exercised across machines.
Describe '.chezmoiignore profile gating'
  setup_matrix() {
    MTMP="$(mktemp -d "$SHELLSPEC_TMPBASE/render-matrix.XXXXXX")"
  }
  BeforeEach 'setup_matrix'

  ignored_for() {
    "$SHELLSPEC_PROJECT_ROOT/tests/render-matrix.sh" \
      --source "$SHELLSPEC_PROJECT_ROOT/home" --profile "$1" --out "$MTMP/$1" \
      >/dev/null || return $?
    cat "$MTMP/$1/ignored.txt"
  }

  It 'server: work tooling, TM stack, GUI configs, and the local pi home stay off'
    When call ignored_for server
    The status should be success
    The output should include ".cursor"
    The output should include ".local/bin/system-backup"
    The output should include ".config/wezterm"
    The output should include ".pi/agent-local"
  End

  It 'server on Linux: not GUI Linux, no brew, no snap, but keeps systemd worker and bash shims'
    Skip if "linux only" [ "$(uname -s)" != "Linux" ]
    When call ignored_for server
    The status should be success
    The output should include ".local/libexec/tab-edit"
    The output should include ".local/bin/system-package-brew"
    The output should include ".local/bin/system-package-snap"
    The output should not include ".local/bin/system-service-systemd"
    The output should not include ".bashrc"
  End

  It 'dev-shell: still ephemeral (snap stays, prune stays)'
    Skip if "linux only" [ "$(uname -s)" != "Linux" ]
    When call ignored_for dev-shell
    The status should be success
    The output should not include ".local/bin/system-package-snap"
  End

  It 'personal: unchanged human-Mac posture (cursor off, backup stack on)'
    When call ignored_for personal
    The status should be success
    The output should include ".cursor"
    The output should not include ".local/bin/system-backup"
  End
End

Describe 'template gates for the server profile'
  setup_matrix() {
    MTMP="$(mktemp -d "$SHELLSPEC_TMPBASE/render-matrix.XXXXXX")"
  }
  BeforeEach 'setup_matrix'

  rendered() {  # rendered <profile> <flattened-template-name>
    "$SHELLSPEC_PROJECT_ROOT/tests/render-matrix.sh" \
      --source "$SHELLSPEC_PROJECT_ROOT/home" --profile "$1" --out "$MTMP/$1" \
      >/dev/null || return $?
    cat "$MTMP/$1/rendered/$2"
  }

  It 'server: ai-playbook drives the claude harness (cursor never deploys there)'
    When call rendered server dot_config__ai-playbook__config.toml.tmpl
    The status should be success
    The output should include 'harness = "claude"'
  End

  It 'work: ai-playbook still drives cursor'
    When call rendered work dot_config__ai-playbook__config.toml.tmpl
    The status should be success
    The output should include 'harness = "cursor"'
  End

  It 'server: gpg.conf carries the forwarded-agent posture'
    When call rendered server dot_config__private_gnupg__private_gpg.conf.tmpl
    The status should be success
    The output should include "no-autostart"
  End

  It 'server: pi settings omit the GUI extension and cursor provider'
    When call rendered server dot_pi__agent__modify_settings.json.tmpl
    The status should be success
    The output should not include "glimpseui"
    The output should not include "pi-cursor-provider"
  End

  It 'Linux: Uvfile never ships mlx-vlm (Apple-Silicon-only)'
    Skip if "linux only" [ "$(uname -s)" != "Linux" ]
    When call rendered server dot_config__packages__Uvfile.tmpl
    The status should be success
    The output should not include "mlx-vlm"
  End
End

# The server's secret set, straight from the committed manifest with the same
# filter sec::manifest_names_for_profile uses.
Describe 'secrets.yaml server requiredFor'
  MANIFEST="$SHELLSPEC_PROJECT_ROOT/home/.chezmoidata/secrets.yaml"

  server_secrets() {
    profile=server yq -r \
      '.secrets[] | select(.requiredFor[] == strenv(profile)) | .name' \
      "$MANIFEST" | sort
  }

  It 'grants server exactly MISE_GITHUB_TOKEN and CONTEXT7_API_KEY'
    When call server_secrets
    The status should be success
    The output should equal "CONTEXT7_API_KEY
MISE_GITHUB_TOKEN"
  End
End
