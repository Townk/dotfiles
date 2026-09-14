# system-package-cargo — cargo-binstall resolves releases through the GitHub
# API; without a token a fresh box's first sync burns the anonymous 60/hour
# budget, times out every fetcher and falls back to source builds. The worker
# hands binstall the token mise already carries (MISE_GITHUB_TOKEN) unless an
# explicit GITHUB_TOKEN is set. cargo is a stub that prints what it received.
Describe 'system-package-cargo: binstall GitHub token'
  setup() { export WORKER="$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_system-package-cargo"; }
  BeforeEach 'setup'

  provision() {   # provision <GITHUB_TOKEN> <MISE_GITHUB_TOKEN>
    zsh -f -c '
      export SYSTEM_PACKAGE_CARGO_NO_RUN=1
      unset GITHUB_TOKEN MISE_GITHUB_TOKEN   # the ambient shell may carry either
      source "$WORKER"
      HAVE_BINSTALL=1
      cargo() { [[ "$1" == binstall ]] && print -r -- "token=${GITHUB_TOKEN:-unset}" }
      [[ -n "$1" ]] && export GITHUB_TOKEN="$1"
      [[ -n "$2" ]] && export MISE_GITHUB_TOKEN="$2"
      cargo_provision kdl-lsp
    ' _ "$@"
  }

  It 'hands binstall the mise token when no GITHUB_TOKEN is set'
    When call provision "" mise-tok
    The output should equal "token=mise-tok"
  End

  It 'lets an explicit GITHUB_TOKEN win'
    When call provision explicit-tok mise-tok
    The output should equal "token=explicit-tok"
  End

  It 'passes nothing when neither token exists'
    When call provision "" ""
    The output should equal "token=unset"
  End
End
