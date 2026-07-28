# WezTerm's picker chords — the three that reach the mux, and the one of them
# that has to know about nested sessions.
#
# Nothing tested these until 2026-07-28, which is how they drifted twice in one
# day: the rebinding moved the SESSION picker from ⌘⇧P to ⌘⇧S, and the
# nested-session split stayed behind on ⌘⇧P — a chord that now means "pane".
# Inside a nested session it went on summoning the local WORKSPACE picker.
#
# These assertions are structural (the config is Lua we do not execute here),
# but they pin the three facts that actually broke: which chord carries the
# nested split, which chord forwards to the remote, and that the pane chord
# carries neither.
Describe 'wezterm picker chords'
  LUA="$SHELLSPEC_PROJECT_ROOT/home/dot_config/wezterm/wezterm.lua"

  # The binding for one chord: from `key = "<k>",` + the matching mods line,
  # up to the end of that table entry.
  # index(), not a regex: the mods string contains `|`, which a dynamic awk
  # regex reads as ALTERNATION — "CMD|SHIFT" happily matched a plain
  # `mods = "CMD",` line and tested the wrong binding.
  chord() {
    awk -v k="key = \"$1\"," -v m="mods = \"$2\"," '
      index($0, k) { buf = $0; grab = 1; next }
      grab && index($0, m) { buf = buf "\n" $0; want = 1; next }
      grab && want { buf = buf "\n" $0; if ($0 ~ /^\t\},$/) { print buf; exit } ; next }
      grab { grab = 0 }
    ' "$LUA"
  }

  It 'sends the session picker on cmd+shift+s'
    When call chord s "CMD|SHIFT"
    The output should include 'send_meh("s")'
  End

  # A nested session clears its local binds, so every key passes through to the
  # remote and the LOCAL picker becomes unreachable. Ctrl+Alt+Space is the one
  # binding a nested layout keeps — sent as raw CSI-u because WezTerm
  # mis-encodes that combination (Ctrl+Space collapses to NUL).
  It 'summons the local picker from a nested session, on that same chord'
    When call chord s "CMD|SHIFT"
    The output should include "pane_session_is_nested"
    The output should include '\x1b[32;7u'
  End

  It 'sends the tab picker on cmd+shift+t'
    When call chord t "CMD|SHIFT"
    The output should include 'send_meh("t")'
  End

  # The pane chord is plain on purpose: in a nested session it passes through
  # and picks a pane on the REMOTE, which is the session being worked in.
  # It carried the nested split until the rebinding, where it would have
  # summoned the workspace picker from a key that means "pane".
  It 'sends the pane picker on cmd+shift+p, with no nested special case'
    When call chord p "CMD|SHIFT"
    The output should include 'send_meh("p")'
    The output should not include "pane_session_is_nested"
    The output should not include '32;7u'
  End

  # Reaching the REMOTE's own picker is a deliberate, separate chord. It types
  # LITERAL KEYS, so it means whatever the remote's keymap says — which is why
  # it had to follow Session mode from `o` to `s`.
  Describe 'cmd+shift+alt+s reaches the remote picker'
    It 'forwards the leader chord for the remote session picker'
      When call chord s "CMD|SHIFT|ALT"
      The output should include "pane_session_is_nested"
      The output should include 'key = "w", mods = "ALT"'
      The output should include 'key = "s"'
      The output should include 'key = "S"'
    End

    # `o` was Session mode until 2026-07-28. A stale chord here keeps typing a
    # letter the remote no longer binds — silently, with nothing to connect
    # the silence back to the rebinding.
    It 'no longer types the retired session-mode letter'
      When call chord s "CMD|SHIFT|ALT"
      The output should not include 'key = "o"'
    End
  End
End
