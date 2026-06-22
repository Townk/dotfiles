Describe 'ai-assist-docs'
  docs() { "$HOME/.local/share/chezmoi/home/dot_local/libexec/executable_ai-assist-docs" "$@"; }

  It 'returns the tldr page on a hit'
    Mock tldr
      printf '# convert\n  resize: convert in.png -resize 200x out.png\n'
    End
    When call docs convert
    The output should include 'resize'
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
