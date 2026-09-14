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

  It 'server on Linux: the mise toolbox conf is deployed (not ignored)'
    Skip if "linux only" [ "$(uname -s)" != "Linux" ]
    When call ignored_for server
    The status should be success
    The output should not include ".config/mise/conf.d/headless-linux.toml"
  End

  It 'personal: the mise toolbox conf is ignored (Brewfile owns the tools there)'
    When call ignored_for personal
    The status should be success
    The output should include ".config/mise/conf.d/headless-linux.toml"
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

  It 'server on Linux: headless-linux.toml carries the toolbox without the dev-shell 403 workaround'
    Skip if "linux only" [ "$(uname -s)" != "Linux" ]
    When call rendered server dot_config__mise__conf.d__headless-linux.toml.tmpl
    The status should be success
    The output should include '"ripgrep"'
    The output should include '"sops"'
    The output should not include 'use_versions_host'
  End

  It 'dev-shell on Linux: keeps use_versions_host = false'
    Skip if "linux only" [ "$(uname -s)" != "Linux" ]
    When call rendered dev-shell dot_config__mise__conf.d__headless-linux.toml.tmpl
    The status should be success
    The output should include 'use_versions_host = false'
  End

  # Darwin-runnable guard on the gates themselves (the renders above are
  # linux-only): the outer gate is the headless trait; the ONLY profile-name
  # comparison left is the inner dev-shell settings block.
  # macOS-only mise tools (assets that exist only for darwin) live in their
  # own darwin-gated conf, never in the shared config.toml, so a Linux host's
  # `mise install` does not fail on them.
  It 'darwin.toml carries the macOS-only tools on this darwin host'
    Skip if "darwin only" [ "$(uname -s)" != "Darwin" ]
    When call rendered personal dot_config__mise__conf.d__darwin.toml.tmpl
    The status should be success
    The output should include 'dictutil'
  End

  It 'the shared mise config.toml names no darwin-only asset'
    When call grep -c 'darwin-64bit' "$SHELLSPEC_PROJECT_ROOT/home/dot_config/mise/config.toml"
    The status should be failure
    The output should equal 0
  End

  It 'headless-linux.toml.tmpl gates on the headless trait, with a single dev-shell inner block'
    f="$SHELLSPEC_PROJECT_ROOT/home/dot_config/mise/conf.d/headless-linux.toml.tmpl"
    When call sh -c 'grep -c "\$traits.headless" "$1"; grep -c "eq .profile \"dev-shell\"" "$1"' _ "$f"
    The status should be success
    The line 1 of output should equal 1
    The line 2 of output should equal 1
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

# Root-aware privilege: a server is administered as root with no sudo. The
# scripts render only on Linux, so guard the SOURCE here (runs on every host).
Describe 'headless run-scripts are root-aware'
  S15="$SHELLSPEC_PROJECT_ROOT/home/.chezmoiscripts/run_once_after_15-setup-dev-shell-tools.sh.tmpl"
  S35="$SHELLSPEC_PROJECT_ROOT/home/.chezmoiscripts/run_after_35-install-dev-shell-sudo-tool-links.sh.tmpl"

  It '15: routes apt through as_root and has no bare sudo call'
    When call sh -c 'grep -c "^as_root()" "$1"; grep -cE "^[[:space:]]*sudo " "$1" || true' _ "$S15"
    The line 1 of output should equal 1
    The line 2 of output should equal 0
  End

  # apt supplies the build deps (bison, readline, ncurses…) that mise-built
  # tools need; running `mise install` first guarantees a failed first pass
  # and a misleading "some tools failed" on every fresh box.
  It '15: installs apt packages BEFORE the first mise install'
    When call awk '/apt-get install -y -qq "\$\{APT_PACKAGES/{a=NR} /^  mise install -y/{m=NR} END{if(a&&m&&a<m)print "apt-first";else print "wrong-order"}' "$S15"
    The output should equal apt-first
  End

  # mise resolves most toolbox entries through the GitHub API; unauthenticated,
  # the 60/hour anonymous budget dies halfway through a fresh box (403s). The
  # secret fragment is already rendered when run_ scripts fire, so the script
  # loads it first — the same reason the macOS bootstrap sources it.
  It '15: loads the secrets fragment before the first mise install'
    When call awk '/\. "\$HOME\/.config\/zsh\/secrets.sh"/{s=NR} /^  mise install -y/{m=NR} END{if(s&&m&&s<m)print "secrets-first";else print "wrong-order"}' "$S15"
    The output should equal secrets-first
  End

  # environment.sh carries the XDG homes mise must see (MISE_CARGO_HOME,
  # MISE_RUSTUP_HOME, GOPATH/GOBIN). Installing without them put Rust at the
  # default ~/.cargo, which system-update later flagged as a stale link and
  # reinstalled (with rustup's "cannot install while Rust is installed" noise).
  It '15: loads environment.sh before the first mise install'
    When call awk '/\. "\$HOME\/.config\/zsh\/environment.sh"/{e=NR} /^  mise install -y/{m=NR} END{if(e&&m&&e<m)print "env-first";else print "wrong-order"}' "$S15"
    The output should equal env-first
  End

  It '35: links directly when uid is 0'
    When call grep -F 'if [ "$(id -u)" -eq 0 ]; then' "$S35"
    The status should be success
    The output should include 'if [ "$(id -u)" -eq 0 ]; then'
  End
End
