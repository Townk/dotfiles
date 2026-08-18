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
    The output should include "records = true"
  End
End

Describe 'zshrc atuin sync gate'
  SRC="$SHELLSPEC_PROJECT_ROOT/home"

  setup() {
    CZTMP="$(mktemp -d "$SHELLSPEC_TMPBASE/atuin-zshrc.XXXXXX")"
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

  # The gate must exist AND run before `atuin init` in the zsh-defer FIFO —
  # print the line numbers of both and compare.
  gate_ordering() {
    rendered="$(render_for "$1" dot_config/zsh/dot_zshrc.tmpl)"
    gate_line="$(printf '%s\n' "$rendered" | grep -n 'ATUIN_AUTO_SYNC=false' | head -1 | cut -d: -f1)"
    init_line="$(printf '%s\n' "$rendered" | grep -n 'atuin init zsh' | head -1 | cut -d: -f1)"
    [ -n "$gate_line" ] && [ -n "$init_line" ] && [ "$gate_line" -lt "$init_line" ] && echo ordered
  }

  # A stale ATUIN_AUTO_SYNC=false inherited from a mux server started off-LAN
  # must not pin sync off forever: probe success must UNSET the var (not just
  # skip the export), so the config-file default (true) applies per-shell.
  gate_unsets_on_success() {
    render_for "$1" dot_config/zsh/dot_zshrc.tmpl | grep -c 'else unset ATUIN_AUTO_SYNC'
  }
  Parameters
    personal
    work
  End
  It "gates before atuin init for $1"
    When call gate_ordering "$1"
    The output should equal "ordered"
  End
  It "unsets ATUIN_AUTO_SYNC on probe success for $1"
    When call gate_unsets_on_success "$1"
    The output should equal "1"
  End
End

Describe 'zshrc atuin sync gate (headless profiles get none)'
  SRC="$SHELLSPEC_PROJECT_ROOT/home"

  setup() {
    CZTMP="$(mktemp -d "$SHELLSPEC_TMPBASE/atuin-zshrc.XXXXXX")"
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

  # Anchored to the assignment (`ATUIN_AUTO_SYNC=`), not a bare substring:
  # the always-rendered FIFO order comment above the gate names
  # ATUIN_AUTO_SYNC in prose ("...exports ATUIN_AUTO_SYNC first") on every
  # profile including headless ones, which would false-positive a plain
  # 'ATUIN_AUTO_SYNC' grep here.
  no_gate() {
    render_for "$1" dot_config/zsh/dot_zshrc.tmpl | grep 'ATUIN_AUTO_SYNC='
  }

  Parameters
    dev-shell
    server
  End
  It "renders no gate for headless profile $1 (config file is the off switch)"
    When call no_gate "$1"
    The status should be failure
    The output should equal ""
  End
End
