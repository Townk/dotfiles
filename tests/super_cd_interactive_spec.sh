# super-cd in a real interactive zsh, with the library chain the deferred
# completion.sh pulls in (fzf-tab-rich.zsh -> theme-common.zsh -> common.zsh).
# common.zsh defines `die() { …; exit 1 }`; if that ever replaces the
# interactive helper, a failing `cd` kills the user's shell.
Describe 'super-cd in zsh -i after the deferred library chain'
  setup_home() {
    T="$(cd "$(mktemp -d)" && pwd -P)"
    mkdir -p "$T/zsh/functions.d" "$T/lib"
    local src="$SHELLSPEC_PROJECT_ROOT/home"
    cp "$src"/dot_config/zsh/functions.sh "$T/zsh/"
    cp "$src"/dot_config/zsh/functions.d/*.sh "$T/zsh/functions.d/"
    cp "$src"/dot_local/lib/{fzf-tab-rich,theme-common,common}.zsh "$T/lib/"
    cat >"$T/.zshrc" <<RC
setopt extendedglob
compdef() { :; }
alias cd=super-cd
source "$T/zsh/functions.sh"
source "$T/lib/fzf-tab-rich.zsh"
RC
  }
  cleanup_home() { rm -rf "$T"; }
  BeforeAll setup_home
  AfterAll cleanup_home

  run_interactive() {
    mkdir -p "$T/start"
    (cd "$T/start" && printf '%s\n' "$1" 'print -r -- "SENTINEL rc=$? pwd=$PWD"' |
      env HOME="$T" ZDOTDIR="$T" THEME_PALETTE_FILE="$THEME_PALETTE_FILE" zsh -i 2>&1)
  }

  It 'survives cd into a missing absolute path'
    When call run_interactive 'cd /no/such/dir'
    The output should include 'SENTINEL rc=1'
    The output should include "pwd=$T/start"
  End

  It 'survives cd to a name with no match'
    When call run_interactive 'cd nosuchname'
    The output should include 'SENTINEL rc=1'
    The output should include "pwd=$T/start"
  End
End
