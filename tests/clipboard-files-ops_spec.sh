# Tests for the bridge daemon's FILE operations, driven directly with prebuilt
# frames (spec §11.3). The transport is RECOB and the thing under test is
# `recobd`; the zsh dispatcher these examples used to pipe an opcode byte into
# no longer exists.
#
# The structure is the opcode-era file's -- same five subjects, same intent --
# with the opcodes renamed to §6.1 operations:
#
#   U set-file-urls        -> clip.set.files{paths | clip_id}
#   L list-files           -> files.list
#   K issue-capability     -> files.grant
#   f fetch + a archive    -> files.fetch{token,index}   (§6.2's collapse)
#   M manifest-persist     -> store.persist.files{host,paths}
#   P persist              -> store.persist.text{...}
#
# Three things the conversion deletes rather than renames, called out where
# they stood instead of being quietly reshaped into something else:
#
#   * `is-directory` and the second connection it triggered. `f` answered the
#     magic string for a directory and the client reconnected as `a`; the
#     server always knew which it was, so `files.fetch` declares `kind` and
#     streams either one (§6.2). The retry, the string, and the example that
#     asserted the string are gone; what replaces them is the directory
#     example below, which is one exchange.
#   * `current-origin`. Provenance is a field on the operation that carries it
#     (§6.2), so "does not declare an origin file" now guards a deletion
#     rather than a behavior.
#   * the US-delimited payload. Named fields (§4.3) make a missing separator
#     unrepresentable, so that example becomes `missing-field`.
#
# And the magic error strings became codes (§10): `not-files` and
# `empty-store` are `not-found` with a `reason`, `capability-required` and
# `trusted-endpoint-required` are `unauthorized`, and `unreadable-entries`
# carries a COUNT and deliberately no path -- a peer must not be handed a
# filesystem probe one refusal at a time. The examples assert `code`, never
# `message`: §10 makes the code the contract and says the message explicitly
# is not one.
#
# ASSERTION SHAPE. Every example runs its exchanges and prints what it wants
# to check from inside one function, then asserts on that function's output.
# That keeps the daemon's exit path, the wire reply and the store row in one
# failure message instead of three, which matters here because most of these
# behaviors are only visible as a reply AND a row together.

# --- the driver ---------------------------------------------------------
#
# A RECOB client that can be *paced*. The sibling spec drives one-shot
# exchanges with `nc -U`, which is enough when the answer is a single frame;
# it is not enough here, because §6.4's stream is the subject: these examples
# have to read the `R` head and then keep reading, act between the head and
# the next `D` (shrink the file, kill the listener), stop after the head
# without draining four gigabytes, and send a second request down the same
# connection to prove a mid-stream `E` did not end it. That is a client with
# state, so it is written as one -- in python3, which three other specs in
# this suite already require.
#
# It speaks the whole of §4: preamble, hello, the §9.2 challenge when the
# banner carries a nonce (which is exactly how the public endpoint announces
# itself), then one `Q` per step on ONE connection.
#
# Output, one line per fact, prefixed by the 1-based exchange number:
#
#   <n> R | E                       the reply frame's kind
#   <n> <field>=<value>             every field, in the order received
#   <n> stream chunks=<c> bytes=<b> end=<empty-d|error|eof>
#   <n> error.<field>=<value>       a mid-stream E's body
#
# `end` is the §6.4 assertion the old wire could not support: `empty-d` is the
# explicit terminator, `eof` is a truncation, and they are distinguishable.
# Values render NUL as `\0` and other non-printables as `\xNN`, so a
# NUL-joined `paths` reads as one assertable line and no byte is lost.
recob_drive_bin() {
  _drv="$SHELLSPEC_TMPBASE/recob-drive.py"
  [ -s "$_drv" ] || cat > "$_drv" <<'PYTHON'
import hashlib, os, socket, subprocess, sys, time

MAGIC = b"RECOB\x01"


def die(msg):
    sys.stdout.write("fatal %s\n" % msg)
    sys.exit(1)


def encode_body(fields):
    out = bytearray()
    for name, value in fields:
        out.append(len(name))
        out += name.encode()
        out += len(value).to_bytes(4, "big")
        out += value
    return bytes(out)


def frame(kind, body):
    return kind + len(body).to_bytes(4, "big") + body


def parse_body(body):
    fields, i = [], 0
    while i < len(body):
        n = body[i]
        i += 1
        name = body[i:i + n].decode()
        i += n
        vlen = int.from_bytes(body[i:i + 4], "big")
        i += 4
        fields.append((name, body[i:i + vlen]))
        i += vlen
    return fields


class Conn:
    def __init__(self, sock):
        self.sock, self.buf = sock, b""

    def read(self, n):
        while len(self.buf) < n:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise EOFError()
            self.buf += chunk
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def frame(self):
        head = self.read(5)
        return head[0:1], self.read(int.from_bytes(head[1:5], "big"))


def render(value):
    out = []
    for b in value:
        if b == 0:
            out.append("\\0")
        elif b == 0x5C:
            out.append("\\\\")
        elif b == 0x0A:
            out.append("\\n")
        elif 0x20 <= b < 0x7F:
            out.append(chr(b))
        else:
            out.append("\\x%02x" % b)
    return "".join(out)


def unescape(text):
    out, i = bytearray(), 0
    while i < len(text):
        if text[i] == "\\" and i + 1 < len(text):
            nxt = text[i + 1]
            if nxt in "0n\\":
                out.append({"0": 0, "n": 0x0A, "\\": 0x5C}[nxt])
                i += 2
                continue
        out += text[i].encode()
        i += 1
    return bytes(out)


def credential(state):
    """§11.1's fixture: the daemon installs it under tunnel-tokens/<owner>."""
    deadline = time.time() + 5
    tunnel = os.path.join(state, "clipboard", "tunnel-tokens")
    while time.time() < deadline:
        try:
            names = sorted(os.listdir(tunnel))
        except OSError:
            names = []
        for name in names:
            with open(os.path.join(tunnel, name)) as f:
                return f.read().strip()
        time.sleep(0.02)
    die("no credential fixture under %s" % tunnel)


def main(argv):
    plan, sockpath, port = [], None, None
    state = os.environ.get("XDG_STATE_HOME", "")
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg == "--socket":
            sockpath, i = argv[i + 1], i + 2
        elif arg == "--tcp":
            port, i = int(argv[i + 1]), i + 2
        elif arg == "--out":
            plan[-1]["out"], i = argv[i + 1], i + 2
        elif arg == "--after-head":
            plan[-1]["after_head"], i = argv[i + 1], i + 2
        elif arg == "--head-only":
            plan[-1]["head_only"], i = True, i + 1
        elif arg.startswith("op:"):
            plan.append({"op": arg[3:], "fields": []})
            i += 1
        elif "=" in arg:
            name, value = arg.split("=", 1)
            plan[-1]["fields"].append((name, unescape(value)))
            i += 1
        else:
            die("unparsed argument %r" % arg)

    if port is not None:
        sock = socket.create_connection(("127.0.0.1", port), 20)
    else:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.connect(sockpath)
    sock.settimeout(20)
    conn = Conn(sock)

    if conn.read(6) != MAGIC:
        die("not a RECOB banner")
    kind, body = conn.frame()
    if kind != b"H":
        die("banner is %r" % kind)
    banner = dict(parse_body(body))

    hello = [("proto", b"1"), ("impl", b"spec")]
    if "nonce" in banner:
        token = credential(state)
        hello.append(
            ("auth", hashlib.sha256(
                token.encode() + b":c:" + banner["nonce"]).hexdigest().encode()))
        hello.append(("cnonce", os.urandom(32)))
    sock.sendall(MAGIC + frame(b"H", encode_body(hello)))

    kind, body = conn.frame()
    if kind == b"E":
        for name, value in parse_body(body):
            print("0 %s=%s" % (name, render(value)))
        return
    if kind != b"C":
        die("expected the capabilities frame, got %r" % kind)

    for n, step in enumerate(plan, 1):
        sock.sendall(frame(b"Q", encode_body(
            [("op", step["op"].encode())] + step["fields"])))
        kind, body = conn.frame()
        print("%d %s" % (n, kind.decode()))
        for name, value in parse_body(body):
            print("%d %s=%s" % (n, name, render(value)))
        # §6.4: files.fetch is the only streaming operation.
        if kind != b"R" or step["op"] != "files.fetch":
            continue
        if step.get("head_only"):
            print("%d stream skipped" % n)
            break
        if step.get("after_head"):
            subprocess.run(["/bin/sh", "-c", step["after_head"]], check=False)
        chunks, total, payload, end, err = 0, 0, bytearray(), None, []
        while end is None:
            try:
                kind, body = conn.frame()
            except (EOFError, OSError):
                end = "eof"
                break
            if kind == b"D":
                if not body:
                    end = "empty-d"
                    break
                chunks, total = chunks + 1, total + len(body)
                payload += body
            elif kind == b"E":
                end, err = "error", parse_body(body)
            else:
                die("unexpected %r mid-stream" % kind)
        print("%d stream chunks=%d bytes=%d end=%s" % (n, chunks, total, end))
        for name, value in err:
            print("%d error.%s=%s" % (n, name, render(value)))
        if step.get("out"):
            with open(step["out"], "wb") as f:
                f.write(payload)


main(sys.argv[1:])
PYTHON
  printf '%s' "$_drv"
}

# ask <step>... — one connection on the TRUSTED Unix socket, which the daemon
# labels `local` (§9.1: its uid boundary is its credential).
ask() { python3 "$(recob_drive_bin)" --socket "$CLIPBOARD_BRIDGE_LOCAL_SOCKET" "$@"; }

# ask_public <step>... — the same over the loopback port. The helper starts the
# daemon with no forced label, so this connection really is the public endpoint:
# it pays §9.2's challenge and holds only the `authed` tier.
ask_public() { python3 "$(recob_drive_bin)" --tcp "$CLIPBOARD_BRIDGE_PORT" "$@"; }

# reply / reply_public — the same with the `message` line dropped. §10 makes
# `code` the contract and the message explicitly not one, so no assertion may
# depend on its wording. The examples that DO read the message are the ones
# asserting a path never reaches it, and they call `ask` directly.
reply() { ask "$@" | grep -v '^[0-9]* message='; }
reply_public() { ask_public "$@" | grep -v '^[0-9]* message='; }

# The daemon's own store, created by the daemon with the daemon's schema. A
# spec that re-declared the schema would be seeding rows into a table that no
# longer has to match the one under test.
store() { printf '%s' "$XDG_DATA_HOME/pick-clipboard/history.db"; }
sql() { sqlite3 "$(store)" "$@"; }

# One store-touching exchange, purely so the schema exists before an example
# seeds rows into it. `files.list` on an empty store opens the store and then
# answers not-found, which is exactly the cheap half of what is wanted.
store_ready() { ask op:files.list >/dev/null 2>&1; }

# §14.7: the Linux build has no pasteboard and no plist parser, so the
# examples that are about pasteboard flavors are the macOS build's alone.
recob_no_pasteboard() { [ "$(uname -s)" != Darwin ]; }

Describe 'recobd: clip.set.files (was U)'
  Include tests/recob_helper.sh
  BeforeEach 'recob_start'
  AfterEach 'recob_stop'

  # The `U` payload's two forms are now two fields, and the discriminator is
  # the field name rather than an `id:` prefix on a positional payload (§6.1).
  It 'writes the file flavors a paste needs and mints authority for the local capture'
    Skip if 'the pasteboard flavors are the macOS build (§14.7)' recob_no_pasteboard
    copy_files() {
      a="$RECOB_DIR/a.txt"; : > "$a"
      b="$RECOB_DIR/b.txt"; : > "$b"
      ask op:clip.set.files "paths=$a\\0$b"
      printf 'utis %s\n' "$(sql 'SELECT uti FROM clip_types;' | tr '\n' ' ')"
      printf 'authority %s\n' "$(sql 'SELECT count(*) FROM file_authorities;')"
    }
    When call copy_files
    The output should include '1 R'
    The output should include 'NSFilenamesPboardType'
    The output should include 'public.file-url'
    # The mount-enrichment marker belongs to a manifest this machine did NOT
    # capture; a local file copy must never carry it, because the row it
    # produces is the one allowed to mint authority.
    The output should not include 'UntrustedFileURLs'
    The output should include 'authority 2'
  End

  It 'rejects a relative path'
    When call reply op:clip.set.files paths=not/abs
    The output should equal "$(printf '1 E\n1 code=bad-field\n1 field=paths')"
  End

  It 'rejects a path carrying a parent-traversal component'
    When call reply op:clip.set.files 'paths=/tmp/../../../../etc/passwd'
    The output should equal "$(printf '1 E\n1 code=bad-field\n1 field=paths')"
  End

  # The `id:<n>` form's successor: a bare rowid in its own field. The
  # assertion is that the row was really restored -- it was the OLDER of two
  # rows, and afterwards it is the one `files.list` resolves.
  It 'restores a stored clip by bare rowid'
    restore_row() {
      store_ready
      id=$(sql "INSERT INTO clips (type_kind,source_host,last_ts)
                VALUES ('files','laptop',100.0); SELECT last_insert_rowid();")
      sql "INSERT INTO clip_types (clip_id,uti,blob)
           VALUES ($id,'x-file-manifest',CAST('/tmp/restored.txt' AS BLOB));
           INSERT INTO clips (type_kind,source_host,last_ts,text_plain)
           VALUES ('text','laptop',900.0,'newer');"
      reply "op:clip.set.files" "clip_id=$id" op:files.list
    }
    When call restore_row
    The output should include '1 R'
    The output should include '2 paths=/tmp/restored.txt'
  End

  # The `id:` prefix existed only to disambiguate a positional payload; a
  # named field carries the discriminator, so the prefix is now a bad value
  # and both-or-neither is a bad request.
  It 'refuses the id: prefix and refuses both discriminators at once'
    When call reply op:clip.set.files clip_id=id:7 op:clip.set.files paths=/tmp/a clip_id=7
    The output should equal "$(printf '1 E\n1 code=bad-field\n1 field=clip_id\n2 E\n2 code=bad-request')"
  End

  It 'answers not-found for a rowid that names no clip'
    When call reply op:clip.set.files clip_id=99999
    The output should equal "$(printf '1 E\n1 code=not-found\n1 reason=no-row')"
  End

  # `trusted-endpoint-required` became a tier in the policy table (§9.3):
  # clip.set.files is `local`, and only the Unix socket confers it.
  It 'refuses clip.set.files on the public endpoint'
    When call reply_public op:clip.set.files paths=/tmp/public.txt
    The output should equal "$(printf '1 E\n1 code=unauthorized\n1 reason=tier')"
  End

  It 'refuses a file-reference rich UTI on the public endpoint'
    When call reply_public op:clip.set.rich uti=public.file-url blob=/etc
    The output should equal "$(printf '1 E\n1 code=refused')"
  End

  It 'keeps the supported public.png rich copy on the public endpoint'
    When call reply_public op:clip.set.rich uti=public.png blob=DATA
    The output should equal '1 R'
  End
End

# files.list resolves the manifest of the current clipboard entry through the
# store's newest row, and files.grant adds the capability. Both are driven
# over the PUBLIC endpoint, as the opcode-era examples were: the peer asking
# for the manifest is who these two operations exist for, and `files.grant`
# handing a token to a remote is the security-relevant half.
Describe 'recobd: files.list and files.grant (was L and K)'
  Include tests/recob_helper.sh
  BeforeEach 'setup'
  AfterEach 'recob_stop'

  setup() {
    recob_start
    store_ready
  }

  # A resolved-path blob, the way the watcher writes one. CAST(... AS BLOB) and
  # not a bare string: the daemon reads `path`/`blob` columns as bytes, and a
  # TEXT value is rejected by the column type -- the same reason the opcode-era
  # examples used readfile().
  seed_clip() {
    _kind=$1 _host=$2 _ts=$3 _uti=$4 _blob=$5
    _id=$(sql "INSERT INTO clips (type_kind,source_host,last_ts)
               VALUES ('$_kind','$_host',$_ts); SELECT last_insert_rowid();")
    sql "INSERT INTO clip_types (clip_id,uti,blob)
         VALUES ($_id,'$_uti',CAST('$_blob' AS BLOB));"
    printf '%s' "$_id"
  }

  seed_plist() {
    _kind=$1 _host=$2 _ts=$3; shift 3
    _id=$(sql "INSERT INTO clips (type_kind,source_host,last_ts)
               VALUES ('$_kind','$_host',$_ts); SELECT last_insert_rowid();")
    {
      printf '<?xml version="1.0" encoding="UTF-8"?>\n'
      printf '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
      printf '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
      printf '<plist version="1.0"><array>\n'
      for _p in "$@"; do printf '<string>%s</string>\n' "$_p"; done
      printf '</array></plist>\n'
    } > "$RECOB_DIR/filenames.plist"
    sql "INSERT INTO clip_types (clip_id,uti,blob)
         VALUES ($_id,'NSFilenamesPboardType',readfile('$RECOB_DIR/filenames.plist'));"
    printf '%s' "$_id"
  }

  # The whole reply, asserted by equality. The opcode-era file needed a second
  # example to pin the field ORDER, because the reply was positional and
  # `pbpaste --manifest` parsed it by offset; §4.3 makes the names carry that,
  # and one equality assertion covers both the values and the shape.
  It 'resolves a single file via x-resolved-path (type_kind=file)'
    single() {
      seed_clip file laptop 100.5 x-resolved-path /tmp/single-file.txt >/dev/null
      reply_public op:files.list
    }
    When call single
    The output should equal "$(printf '1 R\n1 kind=file\n1 host=laptop\n1 timestamp=100.5\n1 paths=/tmp/single-file.txt')"
  End

  It 'resolves two files via a real NSFilenamesPboardType XML plist (type_kind=files)'
    Skip if 'NSFilenamesPboardType is parsed by the macOS build (§14.7)' recob_no_pasteboard
    two() {
      seed_plist files laptop 200.25 /tmp/pboard-a.txt /tmp/pboard-b.txt >/dev/null
      reply_public op:files.list
    }
    When call two
    The output should equal "$(printf '1 R\n1 kind=files\n1 host=laptop\n1 timestamp=200.25\n1 paths=/tmp/pboard-a.txt\\0/tmp/pboard-b.txt')"
  End

  # Regression from the zsh parser: a path ending in `"` in NON-terminal array
  # position. That parser split the plist text on the `",` boundary and ate the
  # element's own closing quote; the native parser cannot, and this example
  # keeps the property under the new one. Exact equality, because silently
  # wrong path bytes are the failure mode a substring check would miss.
  It 'preserves a path ending in a literal quote (non-terminal plist element)'
    Skip if 'NSFilenamesPboardType is parsed by the macOS build (§14.7)' recob_no_pasteboard
    quoted() {
      seed_plist files laptop 250.5 '/tmp/quoted"' /tmp/plain.txt >/dev/null
      reply_public op:files.list
    }
    When call quoted
    The output should equal "$(printf '1 R\n1 kind=files\n1 host=laptop\n1 timestamp=250.5\n1 paths=/tmp/quoted"\\0/tmp/plain.txt')"
  End

  It 'emits an x-file-manifest blob as-is, NUL-joined (type_kind=files, remote source_host)'
    manifest() {
      _id=$(sql "INSERT INTO clips (type_kind,source_host,last_ts)
                 VALUES ('files','devbox',300.75); SELECT last_insert_rowid();")
      printf '%s\000%s' /tmp/dev-a.txt /tmp/dev-b.txt > "$RECOB_DIR/manifest.bin"
      sql "INSERT INTO clip_types (clip_id,uti,blob)
           VALUES ($_id,'x-file-manifest',readfile('$RECOB_DIR/manifest.bin'));"
      reply_public op:files.list
    }
    When call manifest
    The output should equal "$(printf '1 R\n1 kind=files\n1 host=devbox\n1 timestamp=300.75\n1 paths=/tmp/dev-a.txt\\0/tmp/dev-b.txt')"
  End

  # Regression: a genuine multi-file local capture gets an x-resolved-path
  # blob holding just the FIRST of the N paths (the watcher only ever
  # inspected pasteboard item 1), while the SAME capture's
  # NSFilenamesPboardType blob already carries all of them. Both blobs are
  # seeded exactly as a real multi-file capture produces them: the resolution
  # order must reach every path, not truncate to the single-entry blob.
  It 'resolves ALL paths of a multi-file local clip (NSFilenamesPboardType over a single-path x-resolved-path)'
    Skip if 'NSFilenamesPboardType is parsed by the macOS build (§14.7)' recob_no_pasteboard
    multi() {
      _id=$(seed_plist file laptop 260.0 /tmp/multi-a.txt /tmp/multi-b.txt /tmp/multi-c.txt)
      sql "INSERT INTO clip_types (clip_id,uti,blob)
           VALUES ($_id,'x-resolved-path',CAST('/tmp/multi-a.txt' AS BLOB));"
      reply_public op:files.list
    }
    When call multi
    The output should equal "$(printf '1 R\n1 kind=file\n1 host=laptop\n1 timestamp=260\n1 paths=/tmp/multi-a.txt\\0/tmp/multi-b.txt\\0/tmp/multi-c.txt')"
  End

  # `not-files` and `empty-store` stopped being strings a client matches on and
  # became one code with a reason (§10). Both operations answer alike, which is
  # what makes the pair worth asserting together.
  It 'answers not-found reason=not-files when the newest row is a plain text clip'
    not_files() {
      sql "INSERT INTO clips (type_kind,source_host,last_ts,text_plain)
           VALUES ('text','laptop',400.0,'hello');"
      reply_public op:files.list op:files.grant
    }
    When call not_files
    The output should equal "$(printf '1 E\n1 code=not-found\n1 reason=not-files\n2 E\n2 code=not-found\n2 reason=not-files')"
  End

  It 'answers not-found reason=empty-store when the clips table has no rows'
    When call reply_public op:files.list op:files.grant
    The output should equal "$(printf '1 E\n1 code=not-found\n1 reason=empty-store\n2 E\n2 code=not-found\n2 reason=empty-store')"
  End

  It 'files.grant issues a 256-bit token for a trusted authority snapshot'
    granted() {
      authorized="$RECOB_DIR/authorized.txt"
      printf 'authorized\n' > "$authorized"
      _id=$(seed_clip file laptop 500.0 x-resolved-path "$authorized")
      sql "INSERT INTO file_authorities (clip_id,item_index,path)
           VALUES ($_id,1,CAST('$authorized' AS BLOB));"
      _token=$(ask_public op:files.grant | sed -n 's/^1 token=//p')
      printf 'len %s rows %s\n' "${#_token}" \
        "$(sql "SELECT count(*) FROM file_grants WHERE token='$_token';")"
    }
    When call granted
    The output should equal 'len 64 rows 1'
  End

  # The security property the whole capability scheme rests on: a row this
  # machine did not capture locally holds no authority, so a peer asking for a
  # capability over it gets `-` and cross-machine streaming fails closed.
  It 'files.grant returns no token for a pointer-only manifest'
    pointer() {
      seed_clip files peerbox 600.0 x-file-manifest /tmp/pointer.txt >/dev/null
      reply_public op:files.grant
    }
    When call pointer
    The output should include '1 token=-'
  End

  # An issued token is a snapshot: the authority rows are COPIED into the
  # grant, so a clipboard change and the retention sweep that follows it
  # cannot change what an already-issued capability means.
  It 'keeps an issued snapshot usable after the clipboard changes and the row is swept'
    snapshot() {
      source="$RECOB_DIR/granted-before-change.txt"
      printf 'snapshot bytes' > "$source"
      _id=$(seed_clip file laptop 700.0 x-resolved-path "$source")
      sql "INSERT INTO file_authorities (clip_id,item_index,path)
           VALUES ($_id,1,CAST('$source' AS BLOB));"
      _token=$(ask_public op:files.grant | sed -n 's/^1 token=//p')
      sql "DELETE FROM file_authorities WHERE clip_id=$_id;
           DELETE FROM clip_types WHERE clip_id=$_id;
           DELETE FROM clips WHERE id=$_id;
           INSERT INTO clips (type_kind,source_host,last_ts,text_plain)
           VALUES ('text','laptop',800.0,'new clipboard');"
      ask_public "op:files.fetch" "token=$_token" index=1 --out "$RECOB_DIR/fetched"
      printf 'body %s\n' "$(cat "$RECOB_DIR/fetched")"
    }
    When call snapshot
    The output should include '1 kind=file'
    The output should include 'end=empty-d'
    The output should include 'body snapshot bytes'
  End
End

# store.persist.files is record-only: it exists so a copy made over SSH lands
# a files row DIRECTLY in the store, bypassing any watcher, because the origin
# machine is typically locked when reached over SSH. It writes no pasteboard
# and declares no origin.
#
# §9.3's `mints_authority: local` is the rule under test here, and it is
# evaluated against the ENDPOINT, never against the caller-supplied `host`: a
# trusted call may authorize self-host paths, a public one produces a pointer
# row that can never mint file authority. Both endpoints are live on the one
# daemon, so the two halves are exercised against the same store.
Describe 'recobd: store.persist.files (was M)'
  Include tests/recob_helper.sh
  BeforeEach 'setup'
  AfterEach 'recob_stop'

  setup() {
    recob_start
    # `clipboard-mount` drives the Finder-native mount enrichment after the row
    # stands. Pointed at a path that cannot exist so the helper's own first
    # guard fires regardless of what is installed on the machine running the
    # tests -- on a box where the real helper IS installed, a `check` miss for
    # a fake host would fall through to `ensure`, which shells out to
    # rclone/ssh against a host that does not exist.
    export CLIPBOARD_MOUNT_BIN="$RECOB_DIR/no-clipboard-mount-here"
  }

  It 'inserts a files row and its manifest blob without touching the pasteboard'
    Skip if 'the pasteboard read is the macOS build (§14.7)' recob_no_pasteboard
    persist() {
      ask op:clip.set text=sentinel regtype=v >/dev/null
      before=$(ask op:clip.get | sed -n 's/^1 text=//p')
      reply_public op:store.persist.files host=peerbox \
        'paths=/tmp/local-a.txt\0/tmp/local-b.txt'
      printf 'kind %s\n' "$(sql "SELECT type_kind FROM clips WHERE source_host='peerbox';")"
      printf 'preview %s\n' \
        "$(sql "SELECT replace(text_preview,char(10),'|') FROM clips WHERE source_host='peerbox';")"
      sql "SELECT writefile('$RECOB_DIR/out.bin', blob) FROM clip_types
           WHERE uti='x-file-manifest';" >/dev/null
      printf 'manifest %s\n' "$(tr '\000' '|' < "$RECOB_DIR/out.bin")"
      # The negative assertion the whole operation exists for: the pasteboard
      # is exactly what it was before the row was written.
      printf 'clipboard %s -> %s\n' "$before" "$(ask op:clip.get | sed -n 's/^1 text=//p')"
    }
    When call persist
    The output should include '1 R'
    The output should include 'kind files'
    The output should include 'preview /tmp/local-a.txt|/tmp/local-b.txt'
    The output should include 'manifest /tmp/local-a.txt|/tmp/local-b.txt'
    The output should include 'clipboard sentinel -> sentinel'
  End

  It 'keeps a public persist pointer-only, with no file authority'
    pointer() {
      reply_public op:store.persist.files host=peerbox paths=/tmp/public-pointer.txt
      printf 'authority %s\n' "$(sql 'SELECT count(*) FROM file_authorities;')"
    }
    When call pointer
    The output should equal "$(printf '1 R\nauthority 0')"
  End

  It 'authorizes a self-host persist only on the trusted endpoint'
    authorize() {
      a="$RECOB_DIR/trusted-a.txt"; printf 'a\n' > "$a"
      b="$RECOB_DIR/trusted-b.txt"; printf 'b\n' > "$b"
      reply op:store.persist.files "host=$RECOB_SELF_NAME" "paths=$a\\0$b"
      printf 'authority %s\n' "$(sql 'SELECT count(*) FROM file_authorities;')"
    }
    When call authorize
    The output should equal "$(printf '1 R\nauthority 2')"
  End

  # The same manifest, arriving from off-machine, must not reactivate the
  # authority the trusted call minted -- it is refused before it reaches the
  # store, and the trusted row stands alone.
  It 'refuses a public persist claiming this machine rather than reactivating its authority'
    no_reactivate() {
      p="$RECOB_DIR/no-reactivate.txt"; printf 'safe\n' > "$p"
      reply op:store.persist.files "host=$RECOB_SELF_NAME" "paths=$p" >/dev/null
      reply_public op:store.persist.files "host=$RECOB_SELF_NAME" "paths=$p"
      printf 'rows %s authority %s\n' \
        "$(sql "SELECT count(*) FROM clips WHERE source_host='$RECOB_SELF_NAME' AND type_kind='files';")" \
        "$(sql 'SELECT count(*) FROM file_authorities;')"
    }
    When call no_reactivate
    The output should equal "$(printf '1 E\n1 code=refused\nrows 1 authority 1')"
  End

  # `current-origin` and its TTL, its SHA256 keying and its suppress-echo flag
  # are deleted outright (§6.2): one process writes the pasteboard and observes
  # it, so there is no note to leave for a stranger. This guards the deletion.
  It 'declares no origin file'
    no_origin() {
      reply_public op:store.persist.files host=peerbox paths=/tmp/local-c.txt
      [ -e "$XDG_STATE_HOME/pick-clipboard/current-origin" ] && printf 'origin file exists\n'
      return 0
    }
    When call no_origin
    The output should equal '1 R'
  End

  # Was "malformed payload (missing US separator)". §4.3's named fields make a
  # missing separator unrepresentable -- the failure that remains is an absent
  # field, and it names itself.
  It 'requires both fields, and names the one that is missing'
    When call reply_public op:store.persist.files host=peerbox op:store.persist.files paths=/tmp/x
    The output should equal "$(printf '1 E\n1 code=missing-field\n1 field=paths\n2 E\n2 code=missing-field\n2 field=host')"
  End

  It 'rejects an empty host'
    When call reply_public op:store.persist.files host= paths=/tmp/local-d.txt
    The output should equal "$(printf '1 E\n1 code=bad-field\n1 field=host')"
  End

  It 'rejects a relative path'
    When call reply_public op:store.persist.files host=peerbox paths=relative/path.txt
    The output should equal "$(printf '1 E\n1 code=bad-field\n1 field=paths')"
  End

  It 'rejects an absolute path containing parent traversal'
    When call reply_public op:store.persist.files host=peerbox 'paths=/tmp/../../../../etc/passwd'
    The output should equal "$(printf '1 E\n1 code=bad-field\n1 field=paths')"
  End

  # DATA-2: a row-write SQLite refuses used to report success -- the reply was
  # an ack while the row, the manifest blob and the authority never landed. The
  # store is made read-only after the daemon has created it, so the write is
  # refused while reads still succeed.
  It 'errors when the store write is refused (DATA-2)'
    refused_write() {
      store_ready
      chmod a-w "$(store)"
      reply_public op:store.persist.files host=peerbox paths=/tmp/ro-manifest.txt
      printf 'rows %s\n' "$(sql 'SELECT count(*) FROM clips;')"
    }
    When call refused_write
    The output should equal "$(printf '1 E\n1 code=internal\nrows 0')"
  End

  # Kind-scoped dedup: a repeated persist of the same host+paths must not
  # create a second files row.
  It 'dedups a repeated persist of the same host and paths to a single files row'
    dedup() {
      reply_public op:store.persist.files host=dupsend 'paths=/tmp/mdup-a.txt\0/tmp/mdup-b.txt' \
        op:store.persist.files host=dupsend 'paths=/tmp/mdup-a.txt\0/tmp/mdup-b.txt'
      printf 'rows %s\n' \
        "$(sql "SELECT count(*) FROM clips WHERE source_host='dupsend' AND type_kind='files';")"
    }
    When call dedup
    The output should equal "$(printf '1 R\n2 R\nrows 1')"
  End

  # Kind-scoped dedup, the collision direction: the joined paths hash exactly
  # like a text clip of the same bytes, so an unscoped dedup would bump the
  # unrelated TEXT row's last_ts instead of inserting a files row.
  It 'inserts a NEW files row (not bumping a same-hash TEXT row) when the joined paths collide with an old text clip'
    collide() {
      store_ready
      joined=$(printf '/tmp/mcollide-a.txt\n/tmp/mcollide-b.txt')
      hash=$(printf '%s' "$joined" | shasum -a 256 | awk '{print $1}')
      text_id=$(sql "INSERT INTO clips (type_kind,source_host,type_hash,last_ts,text_plain)
                     VALUES ('text','mcollidehost','$hash',50.0,'$joined');
                     SELECT last_insert_rowid();")
      reply_public op:store.persist.files host=mcollidehost \
        'paths=/tmp/mcollide-a.txt\0/tmp/mcollide-b.txt'
      printf 'files %s text %s ts %s\n' \
        "$(sql "SELECT count(*) FROM clips WHERE source_host='mcollidehost' AND type_kind='files';")" \
        "$(sql "SELECT type_kind FROM clips WHERE id=$text_id;")" \
        "$(sql "SELECT last_ts FROM clips WHERE id=$text_id;")"
    }
    When call collide
    The output should equal "$(printf '1 R\nfiles 1 text text ts 50.0')"
  End
End

# store.persist.text is the symmetric hazard: a text payload whose hash happens
# to match an existing FILES row must insert its own row rather than bump that
# one, and it may not persist a file kind at all.
Describe 'recobd: store.persist.text (was P)'
  Include tests/recob_helper.sh
  BeforeEach 'setup'
  AfterEach 'recob_stop'

  setup() {
    recob_start
    store_ready
  }

  It 'inserts a NEW text row (not bumping a same-hash FILES row) when the text collides with an existing manifest hash'
    collide() {
      text='hello from a persisted paste'
      hash=$(printf '%s' "$text" | shasum -a 256 | awk '{print $1}')
      files_id=$(sql "INSERT INTO clips (type_kind,source_host,type_hash,last_ts)
                      VALUES ('files','pdup','$hash',77.0); SELECT last_insert_rowid();")
      reply_public op:store.persist.text host=pdup kind=text app=someapp regtype=v "text=$text"
      printf 'texts %s plain %s files_kind %s files_ts %s total %s\n' \
        "$(sql "SELECT count(*) FROM clips WHERE source_host='pdup' AND type_kind='text';")" \
        "$(sql "SELECT text_plain FROM clips WHERE source_host='pdup' AND type_kind='text';")" \
        "$(sql "SELECT type_kind FROM clips WHERE id=$files_id;")" \
        "$(sql "SELECT last_ts FROM clips WHERE id=$files_id;")" \
        "$(sql "SELECT count(*) FROM clips WHERE source_host='pdup';")"
    }
    When call collide
    The output should equal "$(printf '1 R\ntexts 1 plain hello from a persisted paste files_kind files files_ts 77.0 total 2')"
  End

  It 'refuses a file-kind persist before it can reactivate an authoritative row'
    file_kind() {
      text=/tmp/authorized-again.txt
      hash=$(printf '%s' "$text" | shasum -a 256 | awk '{print $1}')
      files_id=$(sql "INSERT INTO clips (type_kind,source_host,type_hash,last_ts)
                      VALUES ('files','pdup','$hash',77.0); SELECT last_insert_rowid();")
      sql "INSERT INTO file_authorities (clip_id,item_index,path)
           VALUES ($files_id,1,CAST('$text' AS BLOB));"
      reply_public op:store.persist.text host=pdup kind=files app=someapp regtype=v "text=$text"
      printf 'ts %s\n' "$(sql "SELECT last_ts FROM clips WHERE id=$files_id;")"
    }
    When call file_kind
    The output should equal "$(printf '1 E\n1 code=refused\nts 77.0')"
  End
End

# files.fetch replaces `f` AND `a`: one capability-bound operation that
# declares whether the granted item is a file or a directory and streams
# either. §6.4's stream shape -- an explicit empty `D` terminator and a
# mid-stream `E` that ends the exchange rather than the connection -- is what
# the last two examples are about, and neither was expressible before.
Describe 'recobd: files.fetch (was f and a)'
  Include tests/recob_helper.sh
  BeforeEach 'setup'
  AfterEach 'recob_stop'

  TOKEN=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

  setup() {
    recob_start
    store_ready
    DIR="$RECOB_DIR/archive-src"
    mkdir -p "$DIR/sub"
    printf 'hello' > "$DIR/a.txt"
    printf 'world, this is a longer nested file body' > "$DIR/sub/b.txt"
  }

  # A grant seeded directly, as the opcode-era examples seeded capabilities:
  # what is under test is what spending one does, not how files.grant mints it
  # (the block above covers that).
  grant() {
    _now=$(date +%s)
    _stmt='DELETE FROM file_grants;'
    _i=0
    for _p in "$@"; do
      _i=$((_i + 1))
      _stmt="$_stmt INSERT INTO file_grants
        (token,item_index,path,created_ts,last_used_ts,hard_expires_ts)
        VALUES ('$TOKEN',$_i,CAST('$_p' AS BLOB),$_now,$_now,9999999999);"
    done
    sql "$_stmt"
  }

  fetch() { reply "op:files.fetch" "token=$TOKEN" "index=${1:-1}"; }

  # `F` and `A` took a raw path and are retired without replacement (§6.1).
  # They are not merely refused: this build cannot dispatch them at all, and
  # the answer carries what a skewed client needs to say why (§7.1).
  It 'does not dispatch the retired raw-path opcodes'
    retired() {
      # `impl` is the build identity (§5.1) and changes with the build, so it
      # is normalized rather than pinned; that it is THERE is what §7.1's skew
      # diagnostic needs from it.
      reply op:F path=/etc op:A path=/etc | sed 's/^\([0-9]*\) impl=.*/\1 impl=<build>/'
    }
    When call retired
    The output should equal "$(printf '1 E\n1 code=unknown-op\n1 op=F\n1 proto=1\n1 impl=<build>\n2 E\n2 code=unknown-op\n2 op=A\n2 proto=1\n2 impl=<build>')"
  End

  # The collapse itself. `f` used to answer the magic string `is-directory` and
  # the client reconnected as `a`; here the reply declares `kind=directory` and
  # the archive follows on the SAME exchange, terminated by the explicit empty
  # `D`. `size` is a `du`-based ESTIMATE with no directional guarantee (tar's
  # blocking-factor padding dominates on a fixture this small), so the honest
  # assertion is a band against the archive actually received -- asserting
  # against a second `du` call would compare du to itself and never fail.
  It 'streams a granted directory as one exchange declaring kind=directory'
    stream_dir() {
      grant "$DIR"
      ask "op:files.fetch" "token=$TOKEN" index=1 --out "$RECOB_DIR/archive.tar" \
        > "$RECOB_DIR/reply"
      sed -n 's/^1 kind=/kind /p;s/.*end=/end /p' "$RECOB_DIR/reply"
      _reported=$(sed -n 's/^1 size=//p' "$RECOB_DIR/reply")
      _real=$(wc -c < "$RECOB_DIR/archive.tar" | tr -d ' ')
      printf 'band %s\n' "$(awk -v r="$_reported" -v a="$_real" \
        'BEGIN { print (r > 0 && a > 0 && r <= 2*a && a <= 2*r + 10240) ? "yes" : "no" }')"
      tar -tf "$RECOB_DIR/archive.tar" | sed 's/^/entry /' | sort
    }
    When call stream_dir
    The output should include 'kind directory'
    The output should include 'end empty-d'
    The output should include 'band yes'
    The output should include 'entry archive-src/a.txt'
    The output should include 'entry archive-src/sub/b.txt'
  End

  # The other half of the same collapse: a granted FILE is not an error any
  # more (`a` answered "not a directory"), it is `kind=file` and its bytes.
  It 'streams a granted file as kind=file'
    stream_file() {
      printf 'just a file' > "$RECOB_DIR/plain.txt"
      grant "$RECOB_DIR/plain.txt"
      ask "op:files.fetch" "token=$TOKEN" index=1 --out "$RECOB_DIR/got"
      printf 'body %s\n' "$(cat "$RECOB_DIR/got")"
    }
    When call stream_file
    The output should include '1 kind=file'
    The output should include '1 size=11'
    The output should include 'end=empty-d'
    The output should include 'body just a file'
  End

  # `capability-required; update pbpaste` and `invalid or expired capability`
  # are one code now (§10). The payload is a token and is never read as a path,
  # which is the property the raw-path opcodes were retired for.
  It 'refuses a well-formed token no grant matches'
    When call fetch
    The output should equal "$(printf '1 E\n1 code=unauthorized\n1 reason=no-grant')"
  End

  It 'rejects a valid token with an item index outside its grant'
    outside() { grant "$DIR/a.txt"; fetch 2; }
    When call outside
    The output should equal "$(printf '1 E\n1 code=bad-field\n1 field=index')"
  End

  It 'rejects an idle-expired token'
    idle() {
      grant "$DIR/a.txt"
      sql 'UPDATE file_grants SET last_used_ts=0;'
      fetch
    }
    When call idle
    The output should equal "$(printf '1 E\n1 code=unauthorized\n1 reason=no-grant')"
  End

  It 'rejects a hard-expired token even when recently used'
    hard() {
      grant "$DIR/a.txt"
      sql 'UPDATE file_grants SET hard_expires_ts=0;'
      fetch
    }
    When call hard
    The output should equal "$(printf '1 E\n1 code=unauthorized\n1 reason=no-grant')"
  End

  # A symlink in a granted position is a swap: the authority snapshot never
  # held one, so one appearing since is refused rather than followed. Both
  # directions, because the opcode-era pair (`f` on a file link, `a` on a
  # directory link) is one operation now.
  It 'does not follow a granted top-level file symlink'
    file_link() {
      printf 'safe target\n' > "$RECOB_DIR/symlink-target.txt"
      ln -s "$RECOB_DIR/symlink-target.txt" "$RECOB_DIR/file-link"
      grant "$RECOB_DIR/file-link"
      fetch
    }
    When call file_link
    The output should equal "$(printf '1 E\n1 code=refused')"
  End

  It 'does not archive a granted top-level directory symlink'
    dir_link() {
      ln -s "$DIR" "$RECOB_DIR/dir-link"
      grant "$RECOB_DIR/dir-link"
      fetch
    }
    When call dir_link
    The output should equal "$(printf '1 E\n1 code=refused')"
  End

  It 'errors on a granted path that does not exist'
    missing() { grant "$RECOB_DIR/does-not-exist-at-all"; fetch; }
    When call missing
    The output should equal "$(printf '1 E\n1 code=internal')"
  End

  It 'errors on a granted relative path'
    relative() { grant relative/dir; fetch; }
    When call relative
    The output should equal "$(printf '1 E\n1 code=internal')"
  End

  # Pre-flight readability: an entry tar cannot read would otherwise surface
  # only as a mid-stream failure, and §10 narrows what may be said about it to
  # a COUNT. The path goes to the local log; putting it on the wire hands a
  # peer a filesystem probe, names outside anything it was granted, one
  # refusal at a time. Both assertions matter: the count is right, and the
  # message carries no path.
  It 'errors unreadable-entries with a count and no path when a nested file is unreadable'
    unreadable_file() {
      chmod 000 "$DIR/sub/b.txt"
      grant "$DIR"
      ask "op:files.fetch" "token=$TOKEN" index=1
    }
    When call unreadable_file
    The output should include '1 code=unreadable-entries'
    The output should include '1 count=1'
    The output should not include "$DIR"
    # Before any stream byte: an E instead of the head means there is no
    # stream line at all, which is what the client needs to abort cleanly.
    The output should not include 'stream'
  End

  It 'errors unreadable-entries when a nested DIRECTORY is untraversable'
    unreadable_dir() {
      chmod 000 "$DIR/sub"
      grant "$DIR"
      ask "op:files.fetch" "token=$TOKEN" index=1
      # Restored before the assertions so the temp dir can be removed.
      chmod 755 "$DIR/sub"
    }
    When call unreadable_dir
    The output should include '1 code=unreadable-entries'
    The output should include '1 count=1'
    The output should not include "$DIR"
  End

  It 'declares a 4 GiB size exactly rather than wrapping it to zero'
    # The old framing carried the length as a BE32 and a 4 GiB file wrapped to
    # zero, so the op refused the file outright. `size` is decimal now and the
    # stream is chunked, so the honest assertion is that the size is exact.
    # The head is read and the connection dropped: four gigabytes of `D`
    # frames would prove nothing this does not.
    big_file() {
      dd if=/dev/null of="$RECOB_DIR/exactly-4g.bin" bs=1 seek=4294967296 2>/dev/null
      grant "$RECOB_DIR/exactly-4g.bin"
      ask "op:files.fetch" "token=$TOKEN" index=1 --head-only
    }
    When call big_file
    The output should include '1 kind=file'
    The output should include '1 size=4294967296'
  End

  # §6.4's mid-stream error, and the rule that makes the connection worth
  # keeping: an error discovered after the head is an `E` in place of the next
  # `D`, it ends the EXCHANGE, and the next request is answered on the same
  # connection. The file is truncated after the head is out and while the
  # daemon is blocked on a full socket buffer, so the short read is the
  # daemon's own -- the same shape a real I/O failure has.
  It 'sends a mid-stream E and keeps the connection usable'
    mid_stream() {
      dd if=/dev/zero of="$RECOB_DIR/shrink.bin" bs=1048576 count=8 2>/dev/null
      grant "$RECOB_DIR/shrink.bin"
      ask "op:files.fetch" "token=$TOKEN" index=1 \
        --after-head ": > $RECOB_DIR/shrink.bin" op:files.list |
        grep -v '^[0-9]* message='
    }
    When call mid_stream
    The output should include '1 kind=file'
    The output should include 'end=error'
    The output should include '1 error.code=internal'
    # The connection survived the failed exchange: the next request is
    # answered rather than dropped, which is what keeps a multi-item
    # pbpaste --files from turning one bad item into a dead connection.
    The output should include '2 E'
    The output should include '2 reason=empty-store'
  End

  # The truncation the old design could not report at all: `a` wrote a raw tar
  # stream until EOF, so a stream cut short by a dying far end was
  # indistinguishable from a clean end and was caught only because tar noticed
  # its archive was malformed. Absence of the terminating empty `D` IS the
  # signal now, and this asserts a client can see it.
  It 'ends a stream without the empty D when the listener dies mid-stream'
    truncated() {
      dd if=/dev/zero of="$RECOB_DIR/dies.bin" bs=1048576 count=8 2>/dev/null
      grant "$RECOB_DIR/dies.bin"
      ask "op:files.fetch" "token=$TOKEN" index=1 --after-head "kill -9 $RECOB_PID"
    }
    When call truncated
    The output should include '1 kind=file'
    The output should include '1 size=8388608'
    The output should include 'end=eof'
  End
End
