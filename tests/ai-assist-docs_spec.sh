Describe 'ai-assist-docs'
  docs() { "$HOME/.local/share/chezmoi/home/dot_local/libexec/executable_ai-assist-docs" "$@"; }

  It 'returns the tldr page on a hit'
    # Mimic real tealdeer (1.8.x): it uses its cache by default and has NO
    # --offline flag — passing one errors out. This guards the regression where
    # ai-assist-docs called `tldr --offline …` and silently fell through to --help.
    Mock tldr
      case " $* " in (*" --offline "*) echo 'tldr: unexpected argument --offline' >&2; exit 2 ;; esac
      printf 'TLDR_PAGE_MARKER for %s\n' "${@: -1}"
    End
    When call docs faketool-xyz
    The output should include 'TLDR_PAGE_MARKER'
    The status should be success
  End

  It 'falls back to --help when tldr misses'
    Mock tldr
      exit 1
    End
    Mock somecmd
      [ "$1" = --help ] && echo 'usage: somecmd [opts]'
    End
    When call docs somecmd
    The output should include 'usage: somecmd'
    The status should be success
  End

  It 'is empty + nonzero on total miss'
    Mock tldr
      exit 1
    End
    When call docs definitely-not-a-real-cmd-xyz
    The status should be failure
    The output should equal ''
  End
End
