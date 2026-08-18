# Tests for home/dot_config/atuin/config.toml.tmpl and the zshrc atuin sync
# gate (spec: docs/superpowers/specs/2026-08-17-atuin-homelab-sync-design.md).
#
# The load-bearing fact: atuin's config FILE beats ATUIN_* env vars, so
# headless must set auto_sync=false in the file, and human profiles must NOT
# set it at all (the zshrc probe gates it via env).
#
# Hermetic: throwaway chezmoi config in $SHELLSPEC_TMPBASE; the repo source
# tree is only ever read. CHEZMOI_PROFILE unset so the ambient shell can
# never leak a profile into the render.
Describe 'atuin config.toml.tmpl'
  SRC="$SHELLSPEC_PROJECT_ROOT/home"

  setup() {
    CZTMP="$(mktemp -d "$SHELLSPEC_TMPBASE/atuin-config.XXXXXX")"
    mkdir -p "$CZTMP/dest"
    unset CHEZMOI_PROFILE
  }
  BeforeEach 'setup'

  # Render one template file for one profile; mirrors render-matrix.sh's
  # throwaway-config shape (keep the [data] stanza in sync with it).
  render_for() {
    {
      printf '[data]\n'
      printf '    profile = "%s"\n' "$1"
      printf '    secretsSlot = ""\n'
      printf '    [data.pi]\n'
      printf '        [data.pi.devExtensions]\n'
      printf '            pi-cockpit = ""\n'
      printf '            pi-plannotator-bridge = ""\n'
    } > "$CZTMP/chezmoi.toml"
    chezmoi --config "$CZTMP/chezmoi.toml" --source "$SRC" \
      --destination "$CZTMP/dest" execute-template < "$SRC/$2"
  }

  # Active (uncommented) sync keys in the rendered config; the upstream
  # sample file carries '# sync_address = ...' comments, so a plain
  # substring check would false-positive.
  active_sync_keys() {
    render_for "$1" dot_config/atuin/config.toml.tmpl | grep -E '^(auto_sync|sync_address)'
  }

  Parameters
    dev-shell
    server
  End
  It "hard-disables sync for headless profile $1"
    When call active_sync_keys "$1"
    The status should be success
    The output should equal "auto_sync = false"
  End
End

Describe 'atuin config.toml.tmpl (human profiles)'
  SRC="$SHELLSPEC_PROJECT_ROOT/home"

  setup() {
    CZTMP="$(mktemp -d "$SHELLSPEC_TMPBASE/atuin-config.XXXXXX")"
    mkdir -p "$CZTMP/dest"
    unset CHEZMOI_PROFILE
  }
  BeforeEach 'setup'

  render_for() {
    {
      printf '[data]\n'
      printf '    profile = "%s"\n' "$1"
      printf '    secretsSlot = ""\n'
      printf '    [data.pi]\n'
      printf '        [data.pi.devExtensions]\n'
      printf '            pi-cockpit = ""\n'
      printf '            pi-plannotator-bridge = ""\n'
    } > "$CZTMP/chezmoi.toml"
    chezmoi --config "$CZTMP/chezmoi.toml" --source "$SRC" \
      --destination "$CZTMP/dest" execute-template < "$SRC/$2"
  }

  active_sync_keys() {
    render_for "$1" dot_config/atuin/config.toml.tmpl | grep -E '^(auto_sync|sync_address)'
  }
  sync_v2_kept() {
    render_for "$1" dot_config/atuin/config.toml.tmpl | grep -E '^records = true'
  }

  Parameters
    personal
    work
  End
  It "omits auto_sync and sync_address for $1 (env-gated at runtime)"
    When call active_sync_keys "$1"
    The status should be failure
    The output should equal ""
  End
  It "keeps sync v2 records=true for $1"
    When call sync_v2_kept "$1"
    The status should be success
  End
End
