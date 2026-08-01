# Tests for system-update's publish_yazi_bump (MED-2: don't publish unrelated
# local commits alongside the yazi package.toml bump).
#
# After `ya pkg upgrade` bumps ~/.config/yazi/package.toml, system-update copies
# the file back into the chezmoi source and commits JUST that path — correct. It
# then pushes. A BARE `git push` (push.default=simple) publishes the whole
# branch, so any unrelated local commits this repo "commonly carries before they
# are pushed" get published too. The fix gates the push on ahead-count: publish
# only when the yazi bump is the sole unpushed commit; otherwise keep everything
# local and say so.
#
# system-update is a zsh script that runs its update body top-to-bottom.
# SYSTEM_UPDATE_NO_RUN is a test-only escape hatch (same convention as
# SYSTEM_ONBOARD_NO_RUN) that returns after the helper definitions so a test can
# source the file and call publish_yazi_bump directly against a throwaway repo —
# no brew, mise, chezmoi apply, or push of the real repo.
Describe 'system-update: publish_yazi_bump push gating (MED-2)'
  SCRIPT="$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_system-update"

  # A throwaway "chezmoi source" repo (REPO) that tracks a bare upstream
  # (ORIGIN), plus the live yazi package.toml (TARGET) whose contents differ
  # from what is committed — i.e. a pending bump ready to publish.
  setup() {
    STAGE="$(mktemp -d "$SHELLSPEC_TMPBASE/system-update.XXXXXX")"
    # common.zsh resolves via $HOME/.local/lib; symlink the real lib in and
    # sandbox HOME so sourcing the script never touches the real machine.
    mkdir -p "$STAGE/home/.local"
    ln -s "$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib" "$STAGE/home/.local/lib"

    ORIGIN="$STAGE/origin.git"
    REPO="$STAGE/repo"
    SREL="dot_config/yazi/package.toml"
    TARGET="$STAGE/live-package.toml"

    git -c init.defaultBranch=master init --bare -q "$ORIGIN" 2>/dev/null
    git -c init.defaultBranch=master clone -q "$ORIGIN" "$REPO" 2>/dev/null
    (
      cd "$REPO"
      git config user.email test@example.com
      git config user.name 'Test'
      git config commit.gpgsign false
      mkdir -p "dot_config/yazi"
      printf 'rev = "aaaa"\n' >"$SREL"
      git add "$SREL"
      git commit -qm 'seed yazi package.toml'
      git push -q origin master
    ) >/dev/null 2>&1

    # The live file carries a fresh rev — the bump system-update would capture.
    printf 'rev = "bbbb"\n' >"$TARGET"
    export SCRIPT_PATH="$SCRIPT"
  }
  cleanup() { rm -rf "$STAGE"; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  # Source the script under NO_RUN in a fresh `zsh -f` (no rc files) and call
  # publish_yazi_bump directly. `set --` clears positional params so the
  # script's own arg parser sees no args; values pass through the environment.
  run_publish() {
    REPO="$REPO" SREL="$SREL" TARGET="$TARGET" HOME="$STAGE/home" \
      zsh -f -c '
        set --
        export SYSTEM_UPDATE_NO_RUN=1
        source "$SCRIPT_PATH"
        publish_yazi_bump "$REPO" "$SREL" "$TARGET"
      '
  }

  # What actually reached the upstream — the security-relevant question.
  origin_log() { git -C "$ORIGIN" log --oneline --all 2>/dev/null; }

  It 'publishes when the yazi bump is the only unpushed commit'
    When call run_publish
    The status should be success
    The stdout should include "Publishing yazi package state"
    The result of function origin_log should include "update dependencies"
  End

  It 'keeps commits local when unrelated unpushed commits already exist'
    # Simulate the repo carrying local work that has not been pushed yet.
    git -C "$REPO" -c user.email=t@e.x -c user.name=T -c commit.gpgsign=false \
      commit -q --allow-empty -m 'unrelated local work' >/dev/null 2>&1

    When call run_publish
    The status should be success
    The stdout should include "Publishing yazi package state"
    The stderr should include "not auto-pushing"
    # Neither the bump nor the unrelated commit may reach the upstream.
    The result of function origin_log should not include "update dependencies"
    The result of function origin_log should not include "unrelated local work"
  End
End
