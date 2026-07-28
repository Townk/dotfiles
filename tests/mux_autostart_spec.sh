# Tests for the .zshrc MUX AUTOSTART dispatch (migration Phase 7 / D17) — the
# block that decides which multiplexer a bare terminal launches into.
#
# This is the highest-consequence code in the repo: it runs on every
# interactive shell, and a mistake locks the user out of the terminal they
# would need to fix it. It is also unusually hard to test, because the block
# ends in `exec` and hard-codes absolute binary paths.
#
# The technique: extract the block VERBATIM from the rendered .zshrc, rewrite
# only the two binary-search lists to point at a stub, and let it exec into
# that stub — which prints the argv it was launched with instead of starting a
# multiplexer. So each case asserts on the real command the real block builds.
#
# Rewriting the lists is line-scoped on purpose. A `${block//for _tmux in *; do/}`
# pattern looks right and is not: zsh's `*` matches across newlines, so it
# swallows the whole loop body and silently tests nothing.
#
# The three-way "Main" reuse dance (absent / idle / has-a-client) is asserted
# on BOTH backends. Mirroring it was the point of the phase — the knob is meant
# to change which mux starts, never how the system behaves — so the Zellij
# expectations here are a regression fence around the pre-flip behaviour.
Describe 'zshrc mux autostart'
  setup_all() {
    AS_TMP=$(mktemp -d)
    chezmoi execute-template <home/dot_config/zsh/dot_zshrc.tmpl >"$AS_TMP/zshrc" 2>/dev/null

    # Stub multiplexer. Answers the liveness/client probes from $CASE; for
    # anything else prints the argv, which is what the block execs into.
    # Matches on the WHOLE argv: `--session Main action list-clients` (a probe)
    # and `--session Main --new-session-with-layout default` (a launch) are
    # indistinguishable from $1/$2 alone.
    cat >"$AS_TMP/mux" <<'EOS'
#!/usr/bin/env zsh
case "$*" in
  "has-session -t=Main")  [[ "$CASE" == none ]] && exit 1 || exit 0 ;;
  "list-clients -t=Main") [[ "$CASE" == attached ]] && print -r -- "/dev/ttys00 ..." ; exit 0 ;;
  "list-sessions -n")     [[ "$CASE" == none ]] && print -r -- Other || print -r -- "Main [Created 1s ago]" ; exit 0 ;;
  "--session Main action list-clients")
    print -r -- HEADER
    [[ "$CASE" == attached ]] && print -r -- client1
    exit 0 ;;
  "delete-session Main"*) exit 0 ;;
esac
print -r -- "EXEC: $*"
EOS
    chmod +x "$AS_TMP/mux"
  }
  cleanup_all() { [ -n "$AS_TMP" ] && rm -rf "$AS_TMP"; }
  BeforeAll setup_all
  AfterAll cleanup_all

  # launch <baked-backend> <case> [loose-pin] — run the real block, print the
  # command it execs. Also drops the recency-seed verdict in $AS_TMP/seeded.
  launch() {
    _bk=$1 _case=$2 _pin=${3-}
    rm -rf "$AS_TMP/cfg" "$AS_TMP/cache"; mkdir -p "$AS_TMP/cfg/mux"
    [ -n "$_pin" ] && print -r -- "$_pin" >"$AS_TMP/cfg/mux/backend"
    {
      print -r -- '_zsh_should_autoattach_mux() { return 0 }'
      # A login over SSH emits a clear-screen escape ahead of the exec; unset
      # so it does not glue itself onto the captured line.
      print -r -- 'SSH_CONNECTION='
      print -r -- "XDG_CACHE_HOME=$AS_TMP/cache"
      print -r -- "XDG_CONFIG_HOME=$AS_TMP/cfg"
      awk '/^if _zsh_should_autoattach_mux; then$/,/^unset -f _zsh_should_autoattach_mux/' "$AS_TMP/zshrc" \
        | awk -v stub="$AS_TMP/mux" '
            /for _tmux in /   { print "    for _tmux in \"" stub "\"; do";   next }
            /for _zellij in / { print "    for _zellij in \"" stub "\"; do"; next }
                              { print }' \
        | sed -E "s/_mux_backend=\"(zellij|tmux)\"/_mux_backend=\"$_bk\"/"
    } >"$AS_TMP/case.zsh"
    CASE=$_case zsh "$AS_TMP/case.zsh" 2>&1 | grep '^EXEC:'
    if [ -s "$AS_TMP/cache/quick-launch/usage-workspace" ]; then
      print -r -- yes >"$AS_TMP/seeded"
    else
      print -r -- no >"$AS_TMP/seeded"
    fi
  }
  seeded() { cat "$AS_TMP/seeded"; }

  Describe 'tmux backend'
    It 'creates Main when no session exists'
      When call launch tmux none
      The output should eq 'EXEC: new-session -s Main'
    End

    It 'reattaches an idle Main rather than making a second one'
      When call launch tmux idle
      The output should eq 'EXEC: attach-session -t=Main'
    End

    # The case D17's one-liner (`tmux new -A -s Main`) would have collapsed:
    # a second window must get its OWN session, not mirror the first one.
    It 'spawns an anonymous session when Main already has a client'
      When call launch tmux attached
      The output should eq 'EXEC: new-session'
    End

    # `-t=` is an exact match. A bare `-t Main` prefix-matches, so a session
    # called "Main2" would answer for "Main".
    It 'anchors the session lookup exactly'
      When call launch tmux none
      The output should include '-s Main'
      The contents of file "$AS_TMP/case.zsh" should include 'has-session -t=Main'
    End
  End

  Describe 'zellij backend (regression fence — must not have moved)'
    It 'creates Main with the default layout when none exists'
      When call launch zellij none
      The output should eq 'EXEC: --session Main --new-session-with-layout default'
    End

    It 'reattaches an idle Main'
      When call launch zellij idle
      The output should eq 'EXEC: attach Main'
    End

    It 'spawns an anonymous session when Main already has a client'
      When call launch zellij attached
      The output should eq 'EXEC: --new-session-with-layout default'
    End
  End

  # "Main" sorts to the top of the quick-launch picker because this boot path
  # records it by hand. Only the paths that actually land IN Main should do so:
  # the anonymous-session branch is a different workspace.
  Describe 'quick-launch recency seeding'
    Parameters
      tmux   none     yes
      tmux   idle     yes
      tmux   attached no
      zellij none     yes
      zellij idle     yes
      zellij attached no
    End

    It "seeds Main only when attaching to it ($1/$2)"
      When call launch "$1" "$2"
      The result of function seeded should eq "$3"
      The output should include 'EXEC:'
    End
  End

  # Loose file beats chezmoi data, so one machine can dissent without an edit.
  Describe 'the loose ~/.config/mux/backend pin'
    It 'overrides a baked zellij default'
      When call launch zellij none tmux
      The output should eq 'EXEC: new-session -s Main'
    End

    It 'overrides a baked tmux default'
      When call launch tmux none zellij
      The output should eq 'EXEC: --session Main --new-session-with-layout default'
    End

    It 'tolerates surrounding whitespace'
      When call launch zellij none '  tmux  '
      The output should eq 'EXEC: new-session -s Main'
    End

    # A typo must not leave the login shell with no multiplexer at all.
    It 'ignores an unrecognised value instead of obeying it'
      When call launch tmux none nonsense
      The output should eq 'EXEC: new-session -s Main'
    End
  End

  # mux::default_backend answers the same question for callers that are not the
  # login shell. Nothing forces the two to agree, so pin them here: a flip that
  # changes only one of them is a split brain that shows up as "the picker
  # thinks I am on Zellij while I am sitting in tmux".
  Describe 'the shim default agrees with the chezmoi default'
    baked_zshrc() { grep -oE 'muxBackend: [a-z]+' home/.chezmoidata/mux.yaml | awk '{print $2}'; }
    baked_shim()  {
      unset ZELLIJ ZELLIJ_SESSION_NAME TMUX MUX_BACKEND
      XDG_CONFIG_HOME=$(mktemp -d) zsh -c '
        source home/dot_local/lib/mux.zsh
        mux::default_backend'
    }

    It 'has the same fallback in both places'
      When call baked_shim
      The output should eq "$(grep -oE 'muxBackend: [a-z]+' home/.chezmoidata/mux.yaml | awk '{print $2}')"
    End
  End
End
