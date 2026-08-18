# Tests for the bridge daemon's own dispatch, driven directly with prebuilt
# frames (spec §11.3). The transport under test is RECOB and the thing under
# test is `recobd`; the zsh dispatcher these examples used to pipe a byte
# string into no longer exists.
#
# The structure is unchanged from the opcode-era file -- same three subjects,
# same intent -- but three of the original nineteen examples describe apparatus
# the redesign deleted rather than renamed, and are called out where they stood
# instead of being quietly reshaped into something else:
#
#   O declare-origin  -> clip.set{origin_host}   (§6.2: provenance is a field)
#   S get-current-ts  -> clip.get{timestamp}     (§6.2: one exchange, four facts)
#   n notify          -> osd.notify{style,...}   (§6.6: `fn` becomes an enum)
#
# and the magic error strings became codes (§10): a refusal that used to be
# "an E frame" is now a specific `code`, which is what these examples assert.
#
# ASSERTION SHAPE, and why it is not the obvious one -- the same trap
# tests/pbcopy_spec.sh documents. shellspec expands a `The value "$(...)"`
# subject outside the example's environment, where none of the per-example
# exports exist, so the read silently falls back to stdin and "passes" against
# the wrong thing. Every example below therefore runs the exchange and prints
# what it wants to check from *inside* one function, and asserts on that
# output.

# --- frame plumbing -----------------------------------------------------
#
# A RECOB client, in the only two dozen lines of shell it takes on the trusted
# socket: §5 lets the client write its preamble, hello and first requests in one
# go without waiting for the banner, so a request is a byte string `nc -U` can
# pour in, exactly as the opcode frames were. Reading the answer is the new
# work, and it is a decoder rather than a `head -c1` because the answer is a
# body of named fields now (§4.3), not a status byte.

# A byte string as lowercase hex, and back. Hex is the currency here for the
# same reason §11.1's recorder chose it: NUL and binary payloads survive it
# exactly, and `printf %b` is the portable way back that tests/recob_helper.sh
# already relies on.
cb_hex() { printf '%s' "$1" | od -An -v -tx1 | tr -d ' \n'; }
cb_unhex() { printf '%b' "$(printf '%s' "$1" | sed 's/../\\x&/g')"; }
cb_unhex_stdin() { cb_unhex "$(cat)"; }

# §4.3's field and §4.2's frame, built in hex. Lengths are byte counts, so they
# are half the hex length -- the one arithmetic mistake worth naming, because a
# wrong length is decoded as a protocol error rather than as the field intended.
cb_be32() { printf '%08x' "$1"; }
cb_field() {
  printf '%02x%s%s%s' "${#1}" "$(cb_hex "$1")" "$(cb_be32 $(( ${#2} / 2 )))" "$2"
}
cb_frame() { printf '%s%s%s' "$(cb_hex "$1")" "$(cb_be32 $(( ${#2} / 2 )))" "$2"; }

# The response stream -> one line per frame: `<kind>\t<name>=<hex>...`, the
# same shape §11.1 fixed for the recorder's log, so the two read alike.
cb_decode() {
  od -An -v -tx1 | tr -d ' \n' | awk '
    function h2i(s,   i, n) {
      n = 0
      for (i = 1; i <= length(s); i++) n = n * 16 + index("0123456789abcdef", substr(s, i, 1)) - 1
      return n
    }
    function h2s(s,   i, r) {
      r = ""
      for (i = 1; i <= length(s); i += 2) r = r sprintf("%c", h2i(substr(s, i, 2)))
      return r
    }
    {
      # 6 preamble bytes = 12 hex characters, then frames until the stream ends.
      h = $0; p = 13
      while (p + 9 <= length(h)) {
        kind = h2s(substr(h, p, 2)); p += 2
        len = h2i(substr(h, p, 8)); p += 8
        body = substr(h, p, len * 2); p += len * 2
        line = kind; q = 1
        while (q + 1 <= length(body)) {
          nlen = h2i(substr(body, q, 2)); q += 2
          name = h2s(substr(body, q, nlen * 2)); q += nlen * 2
          vlen = h2i(substr(body, q, 8)); q += 8
          line = line "\t" name "=" substr(body, q, vlen * 2); q += vlen * 2
        }
        print line
      }
    }'
}

# cb_ask <body-hex> -- one exchange on the trusted socket. The answer is the
# last frame: the banner and the capabilities frame precede it (§5), and this
# client asks exactly one thing per connection.
cb_ask() {
  cb_unhex "$(cb_hex RECOB)01$(cb_frame H "$(cb_field proto "$(cb_hex 1)")")$(cb_frame Q "$1")" \
    > "$CB_REQ"
  nc -U "$CLIPBOARD_BRIDGE_LOCAL_SOCKET" < "$CB_REQ" > "$CB_RESP" 2>/dev/null
  cb_decode < "$CB_RESP" | tail -1 > "$CB_ANSWER"
}

# `R` on success, `E` on a refusal -- the successor to the status byte these
# examples used to read with `head -c1`.
cb_kind() { cut -f1 "$CB_ANSWER"; }
# One field of the answer, decoded. Empty output for an absent field, which is
# itself assertable.
cb_answer() {
  tr '\t' '\n' < "$CB_ANSWER" | sed -n "s/^${1}=//p" | head -1 | cb_unhex_stdin
}

# Whether this daemon was built with the macOS platform layer. §14.7 compiles
# it out of the Linux build, and one refusal below is that build's alone.
cb_is_macos() { [ "$(uname -s)" = Darwin ]; }

# Tests for what the `O` declare-origin op became. §6.2 is the largest
# collapse in the redesign: the daemon writes the pasteboard and the store row
# in one operation, so provenance travels as `clip.set{origin_host}` (P3)
# instead of being left in a file for the Hammerspoon watcher to find.
#
# Three of the original six examples went with the file. `current-origin`, its
# `SHA256(plain)` keying, its `ORIGIN_TTL` and its `suppress-echo` flag are all
# deleted outright, not renamed -- they existed only because the writer and the
# observer were different processes, and they are not. So "writes sha256(text)
# as line 2" and "does not write the suppress-echo flag (exactly 3 lines)" have
# no successor here. The property the second one protected -- that a later
# physical copy of the same text is still captured -- survives as §11.4's "one
# copy, one row", which needs a capturing daemon and belongs with that coverage
# rather than in a dispatch spec.
#
# What does survive is everything the origin file was written *for*: that the
# operation is acknowledged, that the declared origin is recorded, and SEC-2 --
# that a peer's host field is untrusted and must pass the wire identity shape.
Describe 'recobd: clip.set provenance'
  Include tests/recob_helper.sh

  setup() {
    recob_start
    CB_REQ="$SHELLSPEC_TMPBASE/cb-req"
    CB_RESP="$SHELLSPEC_TMPBASE/cb-resp"
    CB_ANSWER="$SHELLSPEC_TMPBASE/cb-answer"
    DB="$XDG_DATA_HOME/pick-clipboard/history.db"
  }
  BeforeEach 'setup'
  AfterEach 'recob_stop'

  set_frame() {
    cb_ask "$(cb_field op "$(cb_hex clip.set)")$(cb_field text "$(cb_hex "$2")")$(cb_field regtype "$(cb_hex v)")$(cb_field origin_host "$1")"
  }

  It 'acknowledges a well-formed clip.set with a response frame'
    ack() { set_frame "$(cb_hex TESTHOST)" hello; cb_kind; }
    When call ack
    The output should equal 'R'
  End

  # The successor to "writes the origin host as line 1". The declared origin
  # ends up on the store row the same operation wrote, which is the whole of
  # §6.2: nobody has to match a hash within a TTL to find out where a clip
  # came from, because the process that wrote it recorded it.
  It 'records the declared origin on the row it wrote'
    origin() {
      set_frame "$(cb_hex TESTHOST)" hello
      sqlite3 "$DB" 'SELECT source_host FROM clips;'
    }
    When call origin
    The output should equal 'TESTHOST'
  End

  # SEC-2: `clip.set` is reachable from the network-facing public endpoint, so
  # a peer's host field is untrusted and must pass the same shape rule §6.6
  # states and `clip::self_host` enforced -- alnum first character, then
  # alnum/dot/dash. A valid dotted host is still accepted.
  It 'accepts a valid dotted host (SEC-2)'
    dotted() {
      set_frame "$(cb_hex good.host.local)" hi
      printf '%s|%s' "$(cb_kind)" "$(sqlite3 "$DB" 'SELECT source_host FROM clips;')"
    }
    When call dotted
    The output should equal 'R|good.host.local'
  End

  # SEC-2 (the exploit). A host carrying an embedded newline used to forge
  # extra origin-file lines the watcher trusted. The file is gone, but the
  # host still reaches a store row and, on a peer, a mount key, so the shape
  # rule is what stops it -- and the refusal is now a `bad-field` code naming
  # the offending field (§10) rather than a bare E frame.
  #
  # "and writes no origin file" becomes the two things there are left to
  # observe: no row was written, and the pasteboard the operation would have
  # written still holds what it held before.
  It 'refuses a host with an embedded newline and performs nothing (SEC-2)'
    forged() {
      set_frame "$(cb_hex before)" before
      sqlite3 "$DB" 'DELETE FROM clips;'
      set_frame "$(printf '%s0a%s' "$(cb_hex evil)" "$(cb_hex forged)")" hi
      printf '%s|%s|%s|' "$(cb_kind)" "$(cb_answer code)" "$(cb_answer field)"
      printf '%s|' "$(sqlite3 "$DB" 'SELECT count(*) FROM clips;')"
      cb_ask "$(cb_field op "$(cb_hex clip.get)")"
      cb_answer text
    }
    When call forged
    The output should equal 'E|bad-field|origin_host|0|before'
  End
End

# Tests for what the `S` get-current-ts op became: `clip.get`'s `timestamp`
# field (§6.1). The op collapsed into `clip.get` -- one exchange now returns
# the text, the register type, the timestamp and this machine's identity, where
# the picker's live-peer row used to open three connections for them (§6.2).
# What `timestamp` *means* is carried through unchanged, which is why every
# example below survives the conversion intact.
#
# Resolution is still by TEXT CONTENT (`rtrim(text_plain, char(10))` on both
# sides), NOT by any hash -- so it matches a row the capture pipeline recorded,
# whose `type_hash` is computed over the sorted uti=blob SET and would never
# hash-match. The 'watcher-captured row' example below is the case a hash-based
# S got wrong, and it is the reason this resolution exists.
#
# No `pbpaste` stub any more, and none is possible: the daemon reads the
# pasteboard through the platform layer in-process (§14.1). The seam that
# replaces it is `RECOB_CAPTURE_PASTEBOARD` (set by recob_helper.sh to a
# per-example private pasteboard), so these examples seed the clipboard the
# daemon reads with a real `clip.set` and still never touch the human's own.
Describe 'recobd: clip.get timestamp'
  Include tests/recob_helper.sh

  setup() {
    recob_start
    CB_REQ="$SHELLSPEC_TMPBASE/ts-req"
    CB_RESP="$SHELLSPEC_TMPBASE/ts-resp"
    CB_ANSWER="$SHELLSPEC_TMPBASE/ts-answer"
    DB="$XDG_DATA_HOME/pick-clipboard/history.db"
  }
  BeforeEach 'setup'
  AfterEach 'recob_stop'

  # Put text on the private pasteboard and then clear the store: the seeding
  # write is a real clip.set, so it leaves a row of its own that would sit in
  # front of every fixture below. Clearing after is what makes the fixtures the
  # only rows, which is what the original's freshly-created table gave for free.
  seed() {
    cb_ask "$(cb_field op "$(cb_hex clip.set)")$(cb_field text "$(cb_hex "$1")")$(cb_field regtype "$(cb_hex v)")"
    sqlite3 "$DB" 'DELETE FROM clips; DELETE FROM clip_types;'
  }
  row() {
    sqlite3 "$DB" "INSERT INTO clips (type_kind, last_ts, text_plain, type_hash) VALUES ('text', $1, $2, '$3');"
  }
  timestamp() { cb_ask "$(cb_field op "$(cb_hex clip.get)")"; cb_answer timestamp; }

  # THE case a hash-based S got wrong: a row the capture pipeline recorded has
  # its text in text_plain but a type_hash computed over the sorted uti=blob
  # SET -- deliberately NOT equal to shasum(text_plain). Hashing the current
  # clipboard and looking up type_hash never matched it and fell through to
  # MAX(last_ts) (~now, inflated by an unrelated recent push), floating an old
  # clip to the top. Content match returns ITS real last_ts instead.
  It "returns a captured row's last_ts via content match (type_hash is an unrelated uti-set hash, never shasum(text))"
    matched() {
      seed 'hello world'
      # A newer, unrelated row is what MAX(last_ts) would wrongly return if the
      # content match failed -- pin it far in the future.
      row 999.9 "'something else entirely'" unrelated-recent
      row 111.5 "'hello world'" uti-set-hash-not-shasum
      timestamp
    }
    When call matched
    The output should equal '111.5'
  End

  # Trailing-newline insensitivity (rtrim char(10) on both sides): a stored
  # copy keeps the newline the pasteboard's plain-text flavor does not, so the
  # current clipboard text can differ from text_plain by exactly that and must
  # still match.
  It 'matches trailing-newline-insensitively (stored text_plain keeps a newline the clipboard does not)'
    newline_insensitive() {
      seed 'line one'
      row 123.5 "'line one' || char(10)" x
      timestamp
    }
    When call newline_insensitive
    The output should equal '123.5'
  End

  It 'returns the MOST RECENT last_ts when several rows share the current clipboard text'
    newest() {
      seed 'hello world'
      row 111.5 "'hello world'" a
      row 222.75 "'hello world'" b
      timestamp
    }
    When call newest
    The output should equal '222.75'
  End

  # Fallback tier 1: no stored row's text matches the current clipboard (a
  # just-copied text that has not reached the store yet, or -- as here --
  # simply nothing matching) -- fall back to the store's most recent last_ts.
  It "falls back to the store's most recent last_ts when nothing matches the current clipboard's text"
    fallback() {
      seed 'not in the store'
      row 50 "'row a'" deadbeef
      row 300.25 "'row b'" cafebabe
      timestamp
    }
    When call fallback
    The output should equal '300.25'
  End

  # Fallback tier 2: the store is completely empty -- nothing to fall back to
  # at all. The answer is still a response frame; `timestamp` is present and
  # empty, which §4.3 makes distinct from absent.
  It 'returns an empty timestamp when the store has no rows at all'
    empty_store() {
      seed 'anything'
      cb_ask "$(cb_field op "$(cb_hex clip.get)")"
      printf '%s|%s|%s' "$(cb_kind)" "$(cb_answer text)" "$(cb_answer timestamp)"
    }
    When call empty_store
    The output should equal 'R|anything|'
  End
End

# osd.notify -- the bridge raising an OSD on the machine it runs on, for a
# caller at the far end of the tunnel. Same shape as window.fullscreen.* (a GUI
# side effect for a caller with no GUI of its own) and, like it, ungated on the
# public endpoint: a toast is annoyance, not exfiltration.
#
# This Describe covers the DAEMON contract -- that the operation is dispatched
# at all, that a remote-origin toast is labelled with where it came from, that
# the untrusted fields are refused, and that a host with no OSD says so instead
# of silently swallowing the notification.
#
# The conversion's one substantive change is `fn` -> `style` (§6.6, P5). The op
# used to carry the name of a Lua global for the handler to interpolate into a
# generated script, so "refuses a function name outside notify/notifyAnsi" was
# a code-execution question. `style` is a closed enum mapped to a callable by a
# table inside the handler and the symbol never crosses the wire, so the same
# example is now a `bad-field` on a closed set -- a weaker thing to have to get
# right, which is the point of the change.
#
# `hs` is stubbed through RECOB_HS_BIN (§14.3 puts the delegated programs on
# the daemon's context rather than on PATH), so nothing here reaches a real
# Hammerspoon.
Describe 'recobd: osd.notify'
  Include tests/recob_helper.sh

  setup() {
    # The stub copies out the side files the generated Lua would have read --
    # values reach Hammerspoon through files, never interpolated into the
    # script, so the files ARE the payload under test.
    SEEN="$SHELLSPEC_TMPBASE/seen"
    rm -rf "$SEEN"; mkdir -p "$SEEN" "$SHELLSPEC_TMPBASE/nbin"
    cat > "$SHELLSPEC_TMPBASE/nbin/hs" <<EOF
#!/bin/sh
d=\$(dirname "\$1")
cp "\$d/text" "$SEEN/text" 2>/dev/null
cp "\$d/icon" "$SEEN/icon" 2>/dev/null
cp "\$d/sound" "$SEEN/sound" 2>/dev/null
cp "\$1" "$SEEN/script.lua" 2>/dev/null
exit 0
EOF
    chmod +x "$SHELLSPEC_TMPBASE/nbin/hs"
    export RECOB_HS_BIN="$SHELLSPEC_TMPBASE/nbin/hs"

    recob_start
    # Pins the daemon's identity so "is this toast from somewhere else" is
    # decidable. Written after the listener is up on purpose: §3.4 forbids
    # caching it, so the next request already sees this.
    mkdir -p "$XDG_STATE_HOME/clipboard"
    printf 'thismac\n' > "$XDG_STATE_HOME/clipboard/self-name"

    CB_REQ="$SHELLSPEC_TMPBASE/n-req"
    CB_RESP="$SHELLSPEC_TMPBASE/n-resp"
    CB_ANSWER="$SHELLSPEC_TMPBASE/n-answer"
  }
  BeforeEach 'setup'
  AfterEach 'recob_stop'

  # All five fields, in the order §6.1 lists them. Icon and sound are empty
  # here for the same reason the original left their positions empty: they are
  # optional decoration, and §4.3 makes an empty value a legal one.
  notify() {
    cb_ask "$(cb_field op "$(cb_hex osd.notify)")$(cb_field origin_host "$(cb_hex "$1")")$(cb_field style "$(cb_hex "$2")")$(cb_field icon '')$(cb_field sound '')$(cb_field text "$(cb_hex "$3")")"
  }

  It 'accepts a well-formed frame'
    accepted() { notify mac-mini plain 'build finished'; cb_kind; }
    When call accepted
    The output should equal 'R'
  End

  # Provenance, not decoration: the public endpoint is reachable from every
  # host the user ssh'es into, so an unlabelled toast is indistinguishable
  # from one this machine raised itself.
  It 'labels a toast that came from another host'
    labelled() { notify mac-mini plain 'build finished'; cat "$SEEN/text"; }
    When call labelled
    The output should equal 'mac-mini: build finished'
  End

  It 'leaves a toast from this same host unlabelled'
    unlabelled() { notify thismac plain 'build finished'; cat "$SEEN/text"; }
    When call unlabelled
    The output should equal 'build finished'
  End

  # P5 on the wire: `style` selects behavior, so it is a closed enum and a
  # value outside it is refused before anything is staged, let alone spawned.
  It 'refuses a style outside the closed set'
    bad_style() {
      notify mac-mini os.execute pwned
      printf '%s|%s|%s|%s' "$(cb_kind)" "$(cb_answer code)" "$(cb_answer field)" \
        "$([ -e "$SEEN/script.lua" ] && echo staged || echo nothing)"
    }
    When call bad_style
    The output should equal 'E|bad-field|style|nothing'
  End

  # Same shape rule clip.set and store.persist.* enforce: the host is rendered
  # into the toast, and one carrying a newline could forge a second line.
  It 'refuses a host that fails the wire identity shape'
    bad_host() { notify -nothost plain hi; printf '%s|%s' "$(cb_kind)" "$(cb_answer field)"; }
    When call bad_host
    The output should equal 'E|origin_host'
  End

  # §6.6 writes today's caps down rather than inventing new ones: 1024 bytes of
  # toast text, so that two clients cannot disagree about what is sendable and
  # discover it as a runtime rejection.
  It 'refuses a text field past the size cap'
    oversize() {
      big=$(awk 'BEGIN { while (i++ < 1025) printf "x" }')
      notify mac-mini plain "$big"
      printf '%s|%s|%s' "$(cb_kind)" "$(cb_answer code)" "$(cb_answer field)"
    }
    When call oversize
    The output should equal 'E|bad-field|text'
  End

  # The successor to "refuses a payload without all five fields": there is no
  # positional payload to be short any more, so the missing field is named
  # (§10) instead of being inferred from a separator count.
  It 'refuses a request missing a required field'
    incomplete() {
      cb_ask "$(cb_field op "$(cb_hex osd.notify)")$(cb_field origin_host "$(cb_hex mac-mini)")$(cb_field style "$(cb_hex plain)")$(cb_field text "$(cb_hex hi)")"
      printf '%s|%s|%s' "$(cb_kind)" "$(cb_answer code)" "$(cb_answer field)"
    }
    When call incomplete
    The output should equal 'E|missing-field|icon'
  End

  # A dev-shell answering `R` would swallow the notification instead of letting
  # the client learn its bridge points at the wrong end of the tunnel. The old
  # dispatcher took CLIPBOARD_PLATFORM from the environment, so this could be
  # forced anywhere; §14.7 compiles the platform layer out of the Linux build
  # instead, which makes the branch a property of the binary rather than of a
  # variable. The assertion is unchanged and runs where it can be true.
  It 'is refused on a host with no OSD rather than silently accepted'
    Skip if 'this daemon carries the macOS platform layer (§14.7), so it has an OSD' cb_is_macos
    headless() { notify mac-mini plain hi; printf '%s|%s' "$(cb_kind)" "$(cb_answer code)"; }
    When call headless
    The output should equal 'E|unavailable'
  End
End

# system-clip paste — 6b's newer-wins. Over SSH the client now compares TWO
# stores: the peer's, over the public tunnel, and this machine's own, over the
# trusted socket (§4.4). `choose_paste_source`'s table is unit-tested directly
# in wire/src/bin/system-clip.rs; what belongs here is proof the wiring around
# it is real — that a genuinely newer peer clip is what gets printed AND
# materialized into the local store (§11's "a used peer clip survives the
# origin going offline"), against a REAL client and REAL daemons rather than
# the fake `system-bridge` clipboard-bridge-client_spec.sh uses for the zsh
# picker half.
#
# One recording daemon cannot supply two different scripted replies to its two
# listeners: record.rs's `open_script` reloads the WHOLE script fresh on every
# CONNECTION, so a public connection and a trusted connection consuming their
# first exchange both draw the same first directive. A genuine two-store
# comparison therefore needs two daemon PROCESSES: the shared --record daemon
# `recob_start` already gives every spec in this file stands in for the peer
# (its public endpoint gets one scripted clip.get reply below), and a second,
# plain (unscripted) trusted-only daemon — started by this Describe, not by
# the shared helper — stands in for this machine's own bridge, its real
# sqlite store seeded with a controlled timestamp the same way the "recobd:
# clip.get timestamp" Describe above seeds its rows.
Describe 'system-clip paste: 6b newer-wins'
  Include tests/recob_helper.sh

  setup() {
    export SSH_CONNECTION="x 1 y 22"   # force the over-SSH branch
    recob_start
    CLIENT="$(recob_client_bin)"
    DB="$XDG_DATA_HOME/pick-clipboard/history.db"

    OWN_DIR=$(mktemp -d "${SHELLSPEC_TMPBASE:-${TMPDIR:-/tmp}}/recob-own.XXXXXX") || return 1
    OWN_SOCK="$OWN_DIR/own.sock"
    OWN_LOG="$OWN_DIR/daemon.log"
    CB_REQ="$OWN_DIR/cb-req"
    CB_RESP="$OWN_DIR/cb-resp"
    CB_ANSWER="$OWN_DIR/cb-answer"
    own_start || return 1
    # Saved before the override below: recob_stop's own cleanup loop removes
    # whatever $CLIPBOARD_BRIDGE_LOCAL_SOCKET currently names (§ "the port
    # must be refused, not silent"), so a spec that calls recob_stop after
    # pointing this at the own daemon's socket must point it back at the
    # peer's first — otherwise recob_stop deletes the OWN daemon's live
    # socket out from under it.
    PEER_SOCK="$CLIPBOARD_BRIDGE_LOCAL_SOCKET"
    # Overrides the peer daemon's own (unused) trusted socket that recob_start
    # pointed this at. Both processes still share $XDG_DATA_HOME, but nothing
    # here ever drives a real store op against the peer daemon's trusted
    # listener, so the two never contend for the sqlite file.
    export CLIPBOARD_BRIDGE_LOCAL_SOCKET="$OWN_SOCK"
  }
  BeforeEach 'setup'

  # recob_stop, scoped so its socket-cleanup loop reclaims the PEER daemon's
  # own socket rather than the OWN daemon's live one (see the PEER_SOCK
  # comment in setup above).
  peer_stop() {
    _own_sock="$CLIPBOARD_BRIDGE_LOCAL_SOCKET"
    CLIPBOARD_BRIDGE_LOCAL_SOCKET="$PEER_SOCK"
    recob_stop
    CLIPBOARD_BRIDGE_LOCAL_SOCKET="$_own_sock"
  }

  teardown() {
    own_stop
    peer_stop
  }
  AfterEach 'teardown'

  # A second, plain trusted-only daemon, following recob_start's own
  # bind-retry and readiness-wait shape (§11.1's daemon log line) since it is
  # standing in for a second, independent machine rather than reusing the
  # shared helper's single daemon.
  own_start() {
    [ -x "$(recob_bin)" ] || {
      echo "own_start: $(recob_bin) is missing -- run make -C custom-builds/recob build" >&2
      return 1
    }
    _attempt=0
    while [ "$_attempt" -lt 8 ]; do
      _attempt=$((_attempt + 1))
      rm -f "$OWN_SOCK" "$OWN_LOG"
      "$(recob_bin)" --no-public --socket "$OWN_SOCK" >"$OWN_LOG" 2>&1 &
      OWN_PID=$!
      _i=0
      while [ "$_i" -lt 200 ]; do
        grep -q '^recobd: wire ' "$OWN_LOG" 2>/dev/null && return 0
        kill -0 "$OWN_PID" 2>/dev/null || break
        sleep 0.02
        _i=$((_i + 1))
      done
      kill "$OWN_PID" 2>/dev/null
      wait "$OWN_PID" 2>/dev/null
      OWN_PID=""
    done
    echo "own_start: trusted-only daemon never came up:" >&2
    cat "$OWN_LOG" >&2
    return 1
  }

  own_stop() {
    case "${OWN_PID:-}" in
      '' | *[!0-9]*) OWN_PID=""; return 0 ;;
    esac
    kill "$OWN_PID" 2>/dev/null
    wait "$OWN_PID" 2>/dev/null
    OWN_PID=""
  }

  # One row at a controlled last_ts, the same content-match resolution the
  # "recobd: clip.get timestamp" Describe exercises — except this time the
  # real daemon behind it is standing in for a second, independent machine.
  own_seed() {  # $1=ts $2=text
    cb_ask "$(cb_field op "$(cb_hex clip.set)")$(cb_field text "$(cb_hex "$2")")$(cb_field regtype "$(cb_hex v)")"
    sqlite3 "$DB" "DELETE FROM clips; DELETE FROM clip_types;
      INSERT INTO clips (type_kind, last_ts, text_plain, type_hash, source_host)
      VALUES ('text', $1, '$2', 'own-seed', 'ownhost');"
  }

  # The peer's one clip.get exchange, scripted on the shared --record daemon's
  # public endpoint.
  peer_script() {  # $1=ts $2=text
    recob_script "ok text=$(cb_hex "$2") regtype=$(cb_hex v) timestamp=$(cb_hex "$1") host=$(cb_hex peerhost)"
  }

  It 'prints a strictly-newer peer clip and persists it into the own store'
    newer_peer() {
      own_seed 100 'own text'
      peer_script 300 'peer text'
      out=$("$CLIENT" paste 2>/dev/null)
      printf '%s|%s|%s' "$out" \
        "$(sqlite3 "$DB" "SELECT count(*) FROM clips WHERE source_host='peerhost';")" \
        "$(sqlite3 "$DB" "SELECT text_plain FROM clips WHERE source_host='peerhost';")"
    }
    When call newer_peer
    # The printed text is the peer's, and the local store now also carries it
    # under the peer's declared host — §11's "a used peer clip survives the
    # origin going offline", exercised end to end rather than asserted on the
    # pure resolver alone.
    The output should equal 'peer text|1|peer text'
  End

  # The own-newer/tied arm of choose_paste_source, asserted end to end rather
  # than only on the pure resolver: own wins AND the peer clip is never
  # materialized locally (persist_peer_text must not run when own's write
  # already answered the paste).
  It 'prints the own clip when it is newer, and never persists a peer row'
    own_wins() {
      own_seed 300 'own text'
      peer_script 100 'peer text'
      out=$("$CLIENT" paste 2>/dev/null)
      printf '%s|%s' "$out" \
        "$(sqlite3 "$DB" "SELECT count(*) FROM clips WHERE source_host='peerhost';")"
    }
    When call own_wins
    The output should equal 'own text|0'
  End

  # §5.2's licensed downgrade, the task's namesake behavior: a REFUSED public
  # port (nothing bound there at all, unlike a stalled or refusing one) falls
  # back to this machine's own clip with exactly one stderr warning line,
  # never a hard failure. `peer_stop` tears down the shared --record daemon
  # standing in for the peer (its own trusted listener is unused here, since
  # $CLIPBOARD_BRIDGE_LOCAL_SOCKET already points at the separate own daemon)
  # — scoped so recob_stop's own socket-cleanup loop cannot touch the OWN
  # daemon's still-live socket (see PEER_SOCK in setup above).
  It 'falls back to the own clip with exactly one warning when the public tunnel refuses'
    refused() {
      own_seed 999 'own text'
      peer_stop
      out=$("$CLIENT" paste 2>"$OWN_DIR/stderr")
      printf '%s|%s|%s' "$?" "$out" "$(wc -l < "$OWN_DIR/stderr" | tr -d ' ')"
    }
    When call refused
    The output should equal '0|own text|1'
    The contents of file "$OWN_DIR/stderr" should include 'bridge not reachable on 127.0.0.1'
    The contents of file "$OWN_DIR/stderr" should include 'using this machine'
  End

  # §4.4's own-side degrade: the peer tunnel is healthy, but THIS machine's
  # own trusted bridge is down (`own_stop` kills the process; the stale
  # socket path connects-and-refuses exactly like self_bind.rs's "stale
  # socket from a dead daemon" case). A paste must still succeed, answered by
  # the peer, with exactly one warning naming the own store as the reason —
  # never a hard failure just because this machine's own daemon happened to
  # be down.
  It 'falls back to the peer clip with exactly one warning when the own trusted socket is down'
    own_down() {
      peer_script 555 'peer text'
      own_stop
      out=$("$CLIENT" paste 2>"$OWN_DIR/stderr")
      printf '%s|%s|%s' "$?" "$out" "$(wc -l < "$OWN_DIR/stderr" | tr -d ' ')"
    }
    When call own_down
    The output should equal '0|peer text|1'
    The contents of file "$OWN_DIR/stderr" should include 'own clipboard store is unreachable'
  End
End

# system-clip paste --files --from-peer — 6b's forced peer endpoint. The
# picker's live-row restore runs where the ENVIRONMENT cannot answer (a GUI
# job under pueue, a VNC-local TUI: no SSH vars), so the flag must (a) reach
# the PUBLIC endpoint anyway and (b) treat a refused tunnel as a hard error —
# never the trusted fallback, whose current clip is a DIFFERENT clip.
Describe 'system-clip paste --files --from-peer'
  Include tests/recob_helper.sh

  setup() {
    unset SSH_CONNECTION SSH_CLIENT SSH_TTY
    RECOB_SELF_NAME=mac-mini
    recob_start
    CLIENT="$(recob_client_bin)"
    DEST="$SHELLSPEC_TMPBASE/from-peer-dest"; rm -rf "$DEST"; mkdir -p "$DEST"
    SRC="$SHELLSPEC_TMPBASE/from-peer-src"; rm -rf "$SRC"; mkdir -p "$SRC"
    printf 'bridge bytes' > "$SRC/pulled.txt"
  }
  BeforeEach 'setup'
  teardown() { recob_stop; }
  AfterEach 'teardown'

  It 'reaches the public endpoint with no SSH environment at all'
    # The scripted files.list reply exists only on the recorder's PUBLIC
    # listener, so bytes landing at all proves the endpoint choice. The
    # manifest names THIS machine's own host, which routes the engine down
    # its same-host local-copy tier — real bytes, no grant/fetch stream to
    # script — keeping the example about the flag, not the stream codec.
    pull() {
      recob_script "ok kind=$(cb_hex files) host=$(cb_hex mac-mini) timestamp=$(cb_hex 111) paths=$(cb_hex "$SRC/pulled.txt")"
      "$CLIENT" paste --files --from-peer --quiet "$DEST" || return 1
      cat "$DEST/pulled.txt"
    }
    When call pull
    The output should equal 'bridge bytes'
  End

  It 'a refused tunnel is a hard error — never the trusted-store fallback'
    refused() {
      recob_stop
      out=$("$CLIENT" paste --files --from-peer --quiet "$DEST" 2>&1)
      printf '%s|%s' "$?" "$out"
    }
    When call refused
    The output should start with '1|'
    The output should include 'bridge not reachable'
  End
End
