# Tests for home/.chezmoi.toml.tmpl — the init template that generates
# ~/.config/chezmoi/chezmoi.toml.
#
# The subject is secretsSlot. Unlike the profile, which is re-answered by a
# prompt on every init, the slot arrives only through CHEZMOI_SECRETS_SLOT — so
# a bare `chezmoi init` used to empty it. That failure is silent by
# construction: an empty slot un-ignores nothing and breaks nothing on the spot,
# because the already-rendered fragment stays on disk at 0600 and keeps being
# sourced. chezmoi simply stops managing it, and the host drifts until a secret
# changes. Both machines were found in exactly that state on 2026-08-10, one of
# them since an init eight days earlier, so the case is covered here rather than
# left to the next person to rediscover.
#
# Hermetic: config, persistent state and cache all live under $SHELLSPEC_TMPBASE
# and the repo source tree is only ever read, so the machine's real chezmoi
# state is never opened — a test that regenerates the live config would inflict
# the very bug it is testing for.
Describe '.chezmoi.toml.tmpl (secretsSlot across re-inits)'
  SRC="$SHELLSPEC_PROJECT_ROOT/home"

  setup() {
    CZTMP="$(mktemp -d "$SHELLSPEC_TMPBASE/init-tmpl.XXXXXX")"
    CFG="$CZTMP/chezmoi.toml"
    unset CHEZMOI_SECRETS_SLOT
    unset CHEZMOI_PROFILE
  }
  BeforeEach 'setup'

  # The config a host already has, before the init that regenerates it.
  seed() {
    {
      printf '[data]\n'
      printf '    profile = "%s"\n' "$1"
      printf '    secretsSlot = "%s"\n' "$2"
    } >"$CFG"
  }

  reinit() {
    CHEZMOI_PROFILE="$1" chezmoi \
      --config "$CFG" \
      --persistent-state "$CZTMP/state.boltdb" \
      --cache "$CZTMP/cache" \
      --source "$SRC" \
      init
  }

  field() { sed -n "s/.*$1 = \"\(.*\)\".*/\1/p" "$CFG" }

  reinit_slot() { reinit "$1" >/dev/null 2>&1 && field secretsSlot }
  reinit_profile() { reinit "$1" >/dev/null 2>&1 && field profile }

  It 'carries the slot forward, since nothing else can re-answer it'
    seed dev-shell slot-abc123
    When call reinit_slot dev-shell
    The output should equal "slot-abc123"
  End

  It 'still lets an explicit slot win, which is how onboarding sets one'
    seed dev-shell slot-abc123
    export CHEZMOI_SECRETS_SLOT=slot-def456
    When call reinit_slot dev-shell
    The output should equal "slot-def456"
  End

  It 'leaves a never-onboarded host empty, because guards depend on that'
    When call reinit_slot server
    The output should equal ""
  End

  # The profile is deliberately NOT sticky — it is prompted for every time, and
  # carrying the slot forward must not quietly change that.
  It 'does not make the profile sticky along with the slot'
    seed dev-shell slot-abc123
    When call reinit_profile server
    The output should equal "server"
  End
End
