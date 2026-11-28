# Tests for the apply-hook fragments under home/.chezmoitemplates/ that are
# shared by inclusion:
#
#   signature-marker.sh.tmpl   the "static inputs changed?" tail of the two
#                              symbols detection hooks (60, 70);
#   build-runner.sh.tmpl       the "hand over to the builder" tail of the
#                              custom-build hooks (50, 55).
#
# Each fragment is rendered on its own and run against a scratch $HOME or a
# stub builder, and each including hook is rendered and compared with the
# fragment's text: the hooks are run_onchange, so what they render to is what
# decides whether chezmoi runs them again.
Describe 'apply-hook fragments'
  HOOKS="$SHELLSPEC_PROJECT_ROOT/home/.chezmoiscripts"

  setup() {
    spec_sandbox hf; HF_TMP=$SANDBOX
    HF_HOME="$HF_TMP/home"
    mkdir -p "$HF_HOME"
  }
  BeforeEach 'setup'

  # render <template text> — through chezmoi, with this repo's fragments.
  render() { print -r -- "$1" | chezmoi -S "$SHELLSPEC_PROJECT_ROOT" execute-template; }
  render_hook() { chezmoi -S "$SHELLSPEC_PROJECT_ROOT" execute-template <"$HOOKS/$1" >"$HF_TMP/hook.sh"; }
  # hook_has <text> — the rendered hook contains exactly these lines.
  hook_has() { [[ "$(<"$HF_TMP/hook.sh")" == *"$1"* ]]; }

  Describe 'signature-marker.sh.tmpl'
    SIG_CALL='{{ includeTemplate "signature-marker.sh.tmpl" (dict "reason" "inputs changed" "changed" "[t] change detected." "unchanged" "[t] unchanged.") }}'
    STATE_DIR() { print -r -- "$HF_HOME/.local/state/chezmoi"; }
    # The three sig examples run the same rendering of the same call, five
    # times in all: rendered once for the group.
    sig_once() { SIG_RENDERED=$(render "$SIG_CALL"); }
    BeforeAll 'sig_once'

    # sig <signature> — run the fragment as a hook would, with that fingerprint.
    sig() {
      {
        print -r -- 'set -eu'
        print -r -- 'MARKER="${HOME}/.local/state/chezmoi/t-pending"'
        print -r -- 'STATE="${HOME}/.local/state/chezmoi/t.sig"'
        print -r -- "STATIC_SIG=\"$1\""
        print -r -- "$SIG_RENDERED"
      } >"$HF_TMP/sig.sh"
      env HOME="$HF_HOME" bash "$HF_TMP/sig.sh"
      print -r -- "rc=$? marker=$([[ -f "$(STATE_DIR)/t-pending" ]] && cat "$(STATE_DIR)/t-pending")"
    }

    It 'records the first fingerprint without writing the marker'
      When call sig aaa
      The output should equal "[t] unchanged.
rc=0 marker="
      The contents of file "$HF_HOME/.local/state/chezmoi/t.sig" should equal "aaa"
    End

    It 'stays quiet when the fingerprint is the same'
      run() { sig aaa >/dev/null; sig aaa; }
      When call run
      The output should equal "[t] unchanged.
rc=0 marker="
    End

    It 'writes the marker when an earlier fingerprint differs'
      run() { sig aaa >/dev/null; sig bbb; }
      When call run
      The output should equal "[t] change detected.
rc=0 marker=inputs changed"
      The contents of file "$HF_HOME/.local/state/chezmoi/t.sig" should equal "bbb"
    End

    It 'is the tail of the symbols DB hook'
      Skip if 'complete-only: renders a whole apply hook and its fragment through chezmoi (two execute-template runs), then bash -n' spec_complete_only
      run() {
        render_hook run_onchange_after_60-symbols-db.sh.tmpl || return 1
        hook_has "$(render '{{ includeTemplate "signature-marker.sh.tmpl" (dict "reason" "static DB inputs changed" "changed" "[symbols-db] static input change detected; DB re-probe pending (marker written)." "unchanged" "[symbols-db] static fingerprint initialized/unchanged.") }}')" &&
          bash -n "$HF_TMP/hook.sh" && grep -c 'includeTemplate "signature-marker.sh.tmpl"' "$HOOKS/run_onchange_after_60-symbols-db.sh.tmpl"
      }
      When call run
      The output should equal 1
    End

    It 'is the tail of the symbols font hook'
      Skip if 'complete-only: renders a whole apply hook and its fragment through chezmoi (two execute-template runs), then bash -n' spec_complete_only
      run() {
        render_hook run_onchange_after_70-symbols-nerd-font.sh.tmpl || return 1
        hook_has "$(render '{{ includeTemplate "signature-marker.sh.tmpl" (dict "reason" "static font inputs changed" "changed" "[symbols-nerd-font] static font input change detected; build pending (marker written)." "unchanged" "[symbols-nerd-font] static font fingerprint initialized/unchanged.") }}')" &&
          bash -n "$HF_TMP/hook.sh" && grep -c 'includeTemplate "signature-marker.sh.tmpl"' "$HOOKS/run_onchange_after_70-symbols-nerd-font.sh.tmpl"
      }
      When call run
      The output should equal 1
    End
  End

  Describe 'build-runner.sh.tmpl'
    # runner <builder path> — the fragment alone, as a hook would end.
    runner() {
      { print -r -- 'set -eu'; render "{{ includeTemplate \"build-runner.sh.tmpl\" (dict \"tag\" \"t-build\" \"build\" \"$1\") }}"; } >"$HF_TMP/run.sh"
      bash "$HF_TMP/run.sh"
      print -r -- "rc=$?"
    }

    It 'skips, successfully, when the builder is missing'
      When call runner "$HF_TMP/absent.sh"
      The output should equal "rc=0"
      The error should equal "[t-build] builder missing at $HF_TMP/absent.sh — skipping."
    End

    It 'hands over to the builder and keeps its exit status'
      print -r -- 'echo built; exit 7' >"$HF_TMP/build.sh"
      When call runner "$HF_TMP/build.sh"
      The output should equal "built
rc=7"
    End

    # The hook is out of scope on some hosts and then renders to a bare
    # `exit 0`; the fragment's text is still its tail.
    tail_of() { # <hook> <tag> <builder, relative to the working tree>
      render_hook "$1" || return 1
      hook_has "$(render "{{ includeTemplate \"build-runner.sh.tmpl\" (dict \"tag\" \"$2\" \"build\" (joinPath .chezmoi.workingTree \"$3\")) }}")" &&
        bash -n "$HF_TMP/hook.sh" && grep -c 'includeTemplate "build-runner.sh.tmpl"' "$HOOKS/$1"
    }

    It 'is the tail of the zsh build hook'
      Skip if 'complete-only: renders a whole apply hook and its fragment through chezmoi (two execute-template runs), then bash -n' spec_complete_only
      When call tail_of run_onchange_after_50-custom-build-zsh.sh.tmpl zsh-build custom-builds/zsh/build-zsh.sh
      The output should equal 1
    End

    It 'is the tail of the colorscripts build hook'
      Skip if 'complete-only: renders a whole apply hook and its fragment through chezmoi (two execute-template runs), then bash -n' spec_complete_only
      When call tail_of run_onchange_after_55-custom-build-colorscripts.sh.tmpl colorscripts-build custom-builds/colorscripts/build-colorscripts.sh
      The output should equal 1
    End

    It 'keeps the per-hook hashes in the hooks'
      run() { grep -c 'sha256 : {{ if \$buildSHA }}' "$HOOKS"/run_onchange_after_5[05]-custom-build-*.sh.tmpl | sed 's/.*://' | paste -sd' ' -; }
      When call run
      The output should equal "1 1"
    End
  End
End
