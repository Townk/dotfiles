# clipboard-platform-macos.zsh — the pasteboard/Hammerspoon pb::* backend
# (Phase 7 spec §2). Byte-identical behavior to the pre-split dispatcher:
# every function below MOVED here verbatim; only the pb::* wrappers are new.
REGTYPE_FILE="$STATE_DIR/current-regtype"

pb::init() { :; }

# pb::get_text -- current clipboard text into $REPLY, byte-exact (pbpaste to a
# temp file + clip::read_file -- NEVER a $(...) capture, which strips ALL
# trailing newlines and truncates at the first embedded NUL). Mirrors the
# linux backend's pb::get_text, which reaches for the same seam precisely for
# byte-exactness. Empty $REPLY on failure / empty clipboard.
pb::get_text() {
  REPLY=""
  local tmpf; tmpf=$(mktemp "${TMPDIR:-/tmp}/clipboard-bridge-get.XXXXXX") || return 0
  pbpaste > "$tmpf" 2>/dev/null
  [[ -s "$tmpf" ]] && clip::read_file "$tmpf"
  rm -f "$tmpf"
}

# pb::legacy_dump -- the pre-Phase-5 bare-connect contract: dump pbpaste,
# unframed, and exit. See the dispatcher's LEGACY_GRACE_S header comment.
pb::legacy_dump() {
  exec pbpaste
}

# Runs a Lua script file through Hammerspoon. `hs -c` is unreliable here
# (observed to hang even on trivial code); `hs <file>` is the confirmed-
# reliable form (see the header comment).
clip::hs_run() {
  local script=$1
  timeout 10 hs "$script" >/dev/null 2>&1
}

clip::op_get() {
  pb::get_text
  send_ok "$REPLY"
}

# See the header comment on op T: a hash of the clipboard text at set-time
# is stored alongside the regtype, so a later get-regtype only trusts it if
# nothing else has copied since (self-invalidating, no dependency on
# Hammerspoon's own change-tracking).
clip::op_get_regtype() {
  local regtype='v'
  if [[ -f "$REGTYPE_FILE" ]]; then
    local stored_rt stored_hash current_hash
    { read -r stored_rt; read -r stored_hash; } < "$REGTYPE_FILE"
    current_hash="$(pbpaste 2>/dev/null | clip::sha256)"
    if [[ -n "$stored_rt" && "$stored_hash" == "$current_hash" ]]; then
      regtype=$stored_rt
    else
      # Command substitution strips trailing newlines, so a bare
      # "$(pbpaste)" can never end in \n even when the real clipboard does
      # -- append a sentinel after it so the real trailing byte (if any)
      # isn't the last character being stripped.
      local sentinel; sentinel="$(pbpaste 2>/dev/null; print -n x)"
      [[ "$sentinel" == *$'\n''x' ]] && regtype='l' || regtype='v'
    fi
  fi
  send_ok "$regtype"
}

# clip::set_pasteboard_core <regtype> <text> -- the actual pasteboard write +
# regtype-file bookkeeping op T performs, split out so a caller needing that
# write without a reply frame of its own could invoke it directly (see
# op_set below -- now a thin wrapper: parse the wire payload, call the core,
# send ONE reply). Was also used by the now-retired `N` push-manifest op
# (files-yazi design §5, Fix A) -- see the header opcode table's note on why
# N was removed; no current caller other than op_set invokes this directly,
# but it's left split out in case a future op needs the same seam.
clip::set_pasteboard_core() {
  local regtype=$1 text=$2
  print -rn -- "$text" | pbcopy
  local h; h="$(print -rn -- "$text" | clip::sha256)"
  print -r -- "$regtype" > "$REGTYPE_FILE"
  print -r -- "$h" >> "$REGTYPE_FILE"
}

clip::op_set() {
  local payload=$1
  (( $#payload >= 1 )) || { send_err "empty payload"; return }
  local regtype=${payload[1,1]}
  local text=${payload[2,-1]}
  clip::set_pasteboard_core "$regtype" "$text"
  send_ok ""
}

clip::op_copy() {
  local payload=$1
  clip::parse_rich_payload "$payload" || { send_err "$REPLY"; return }
  local uti=$REPLY_UTI blob=$REPLY_BLOB
  local tmpdir; tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/clipboard-bridge-copy.XXXXXX")
  local blobfile="$tmpdir/blob"
  local fd
  exec {fd}> "$blobfile"
  syswrite -o $fd -- "$blob"
  exec {fd}>&-
  local utifile="$tmpdir/uti"
  print -rn -- "$uti" > "$utifile"
  local script="$tmpdir/copy.lua"
  {
    print -r -- "local function readfile(p) local f=io.open(p,'rb'); if not f then return nil end; local c=f:read('*a'); f:close(); return c end"
    print -r -- "local u, b = readfile([[$utifile]]), readfile([[$blobfile]])"
    print -r -- "if u and b then hs.pasteboard.writeAllData({[u] = b}) end"
  } > "$script"
  if clip::hs_run "$script"; then
    send_ok ""
  else
    send_err "hs run failed"
  fi
  rm -rf -- "$tmpdir"
}

# clip::set_file_urls_core <NUL-joined-abs-paths> [untrusted=0] [expected-change-count]
# -- the form-A pasteboard
# write extracted from op_set_file_urls so the M handler's mount enrichment
# (clip::mount_enrich below) can reuse it verbatim: generates the
# writeAllData Lua (NSFilenamesPboardType = all paths as an XML plist,
# public.file-url = the first path, urlencoded) and runs it through hs.
# No framing/validation/reply -- callers own those. rc 0 on success.
clip::set_file_urls_core() {
  local payload=$1 untrusted=${2:-0} expected_cc=${3:-}
  local tmpdir; tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/clipboard-bridge-fileurls.XXXXXX") || return 1
  local script="$tmpdir/set-file-urls.lua"
  # Paths go via a NUL-joined side file, not string-interpolated into Lua
  # (paths may contain quotes/brackets that would break a Lua literal).
  local pathfile="$tmpdir/paths"
  print -rn -- "$payload" > "$pathfile"
  {
    print -r -- "local f = io.open([[$pathfile]], 'rb'); local raw = f:read('*a'); f:close()"
    print -r -- "local paths = {}"
    print -r -- "for p in raw:gmatch('[^\\0]+') do paths[#paths+1] = p end"
    print -r -- "local xml = {'<?xml version=\"1.0\" encoding=\"UTF-8\"?>',"
    print -r -- "  '<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">',"
    print -r -- "  '<plist version=\"1.0\"><array>'}"
    print -r -- "local function esc(s) return (s:gsub('&','&amp;'):gsub('<','&lt;'):gsub('>','&gt;')) end"
    print -r -- "for _, p in ipairs(paths) do xml[#xml+1] = '<string>' .. esc(p) .. '</string>' end"
    print -r -- "xml[#xml+1] = '</array></plist>'"
    print -r -- "local function urlenc(s) return (s:gsub('[^%w%-%._~/]', function(c) return string.format('%%%02X', c:byte()) end)) end"
    print -r -- "local data = {"
    print -r -- "  ['NSFilenamesPboardType'] = table.concat(xml, '\\n'),"
    print -r -- "  ['public.file-url'] = 'file://' .. urlenc(paths[1]),"
    if (( untrusted )); then
      # Change-bound provenance: unlike the old TTL file, this marker travels
      # in the exact pasteboard change the watcher observes and cannot be
      # overwritten by a concurrent public O request.
      print -r -- "  ['org.chezmoi.clipboard.UntrustedFileURLs'] = '1',"
    fi
    print -r -- "}"
    if [[ -n "$expected_cc" ]]; then
      print -r -- "if hs.pasteboard.changeCount() ~= $expected_cc then return end"
    fi
    print -r -- "if not hs.pasteboard.writeAllData(data) then error('writeAllData failed') end"
  } > "$script"
  local rc=0
  clip::hs_run "$script" || rc=1
  rm -rf -- "$tmpdir"
  return $rc
}

# U  set-file-urls: put a real file clip on THIS Mac's pasteboard (see the
# header comment). Payload form A: NUL-joined absolute paths, written as
# NSFilenamesPboardType (all paths) + public.file-url (first path). Form B:
# "id:<rowid>", routed to the HS clipboard-history module's restore_by_id for
# a full-fidelity local restore of a stored files row.
clip::op_set_file_urls() {
  local payload=$1
  if [[ "$payload" == id:<-> ]]; then
    local id=${payload#id:}
    local tmpdir; tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/clipboard-bridge-fileurls.XXXXXX") || { send_err "mktemp failed"; return }
    local script="$tmpdir/set-file-urls.lua"
    print -r -- "require('modules.apps.clipboard-history').restore_by_id($id)" > "$script"
    if clip::hs_run "$script"; then send_ok ""; else send_err "hs run failed"; fi
    rm -rf -- "$tmpdir"
    return
  fi
  local -a paths=( "${(@ps:\0:)payload}" )
  local p
  for p in "${paths[@]}"; do
    [[ "$p" == /* ]] || { send_err "not absolute: $p"; return }
  done
  if clip::set_file_urls_core "$payload"; then send_ok ""; else send_err "hs run failed"; fi
}

# pb::parse_ns_filenames <blobfile> <tmpdir> -> sets $REPLY to the NUL-
# joined paths decoded from an NSFilenamesPboardType blob (binary OR XML
# property list -- plutil auto-detects either form). Primary path: convert
# to JSON and pick the string array apart in zsh (brief's prescribed
# algorithm -- good enough for paths, which don't contain raw '","' runs).
# Fallback (plutil choking on some binary-plist edge case): a throwaway
# hs.plist.read() Lua script via clip::hs_run, same generated-side-file
# pattern as op_copy/op_set_file_urls.
pb::parse_ns_filenames() {
  local blobfile=$1 tmpdir=$2
  REPLY=""
  local json; json="$(plutil -convert json -o - "$blobfile" 2>/dev/null)"
  local -a paths
  if [[ -n "$json" && "$json" == \[*\] ]]; then
    local inner=${json#\[}
    inner=${inner%\]}
    if [[ -n "$inner" ]]; then
      # Strip the array's outermost string quotes FIRST, while they are
      # unambiguous (a JSON string always terminates on an UNescaped quote,
      # so inner's first/last chars are never the tail of an escaped `\"`).
      # Doing this per-element instead was a real bug: the boundary split
      # already consumes each non-terminal element's closing quote, so a
      # per-element `${r%\"}` had nothing legitimate left to strip and ate
      # the `"` of an escaped `\"` whenever a path literally ends in a
      # quote -- `/tmp/a"` came out as `/tmp/a\`.
      inner=${inner#\"}
      inner=${inner%\"}
      # Split on the literal 3-char quote-comma-quote element boundary.
      # Content can never false-match it: an in-content quote is always
      # escaped as `\"`, so a bare quote right after a comma only occurs
      # where a real element starts. Two steps -- boundary -> real newline,
      # then (@f) -- because a $'...' pattern holds literal `"`s with none
      # of the escaping headaches a "..." one has here.
      inner=${inner//$'","'/$'\n'}
      local -a raw; raw=("${(@f)inner}")
      local r
      for r in "${raw[@]}"; do
        # JSON unescapes. Order matters: `\/` and `\"` before `\\`, or the
        # backslash freed by `\\ -> \` would pair with a following `/`/`"`
        # and be double-unescaped.
        r=${r//\\\//\/}
        r=${r//\\\"/\"}
        r=${r//\\\\/\\}
        paths+=("$r")
      done
    fi
  fi
  if (( ${#paths[@]} == 0 )); then
    local outfile="$tmpdir/ns-filenames-fallback"
    local script="$tmpdir/ns-filenames-fallback.lua"
    {
      print -r -- "local t = hs.plist.read([[$blobfile]])"
      print -r -- "if t and #t > 0 then"
      print -r -- "  local f = io.open([[$outfile]], 'wb')"
      print -r -- "  f:write(table.concat(t, '\\0'))"
      print -r -- "  f:close()"
      print -r -- "end"
    } > "$script"
    if clip::hs_run "$script" && [[ -s "$outfile" ]]; then
      clip::read_file "$outfile"
    fi
    return
  fi
  REPLY="${(pj:\0:)paths}"
}

# clip::pb_changecount -- prints hs.pasteboard.changeCount() (the guard token
# for retroactive enrichment; see clip::mount_enrich). Same generated-side-
# file pattern as every other hs call; unlike clip::hs_run this CAPTURES
# stdout, since the whole point is reading a value back. rc 1 (nothing
# printed) when hs is unavailable or prints a non-number.
clip::pb_changecount() {
  local tmpd; tmpd=$(mktemp -d "${TMPDIR:-/tmp}/clipboard-bridge-cc.XXXXXX") || return 1
  print -r -- 'print(hs.pasteboard.changeCount())' > "$tmpd/cc.lua"
  local out
  out=$(timeout 10 hs "$tmpd/cc.lua" 2>/dev/null)
  rm -rf -- "$tmpd"
  out="${out//[[:space:]]/}"
  [[ "$out" == <-> ]] || return 1
  print -r -- "$out"
}

# clip::mount_enrich <host> <NUL-joined-abs-paths> -- the mount-aware half of
# op M (clipboard-mount spec §3.4): when THIS Mac holds a healthy rclone
# mount of <host>, additionally set the pasteboard with mount-relative
# file-urls so Cmd+V in Finder is a native Finder copy. The durable store row
# stays the lazy manifest the caller already persisted -- Ctrl-Y rsync
# materialization is untouched and remains the fallback.
#
# Runs ENTIRELY in a disowned, fd-detached background subshell, called AFTER
# send_ok: the reply latency pbcopy sees is identical to the pre-mount
# behavior in every case, and a wedged FUSE stat in here can never hang the
# dispatcher. Chain:
#   changeCount snapshot -> check (instant negative when unmounted) ->
#   [self-heal: ensure + re-check -- a remount takes ~3-7s, far past pbcopy's
#    2s best-effort window, and sessions ride a long-lived ControlMaster mux
#    so after a mid-session teardown the Match-hook may not re-fire for days;
#    without this every copy would silently stay lazy until a fresh
#    connection] -> map paths (inline prefix concat; clipboard-mount map's
#    line output can't carry NUL-joined path lists) -> first-path existence ->
#    one Hammerspoon script atomically checks changeCount and writes standard
#    file URLs plus the private UntrustedFileURLs marker. The marker belongs
#    to that exact pasteboard change, so the watcher cannot turn a public M
#    pointer into file authority and a concurrent O request cannot erase it.
# Every failure anywhere just exits: the lazy row is already the fallback.
# CLIPBOARD_MOUNT_BIN overrides the helper path (tests stub it; unset+missing
# file = enrichment compiled out, byte-identical legacy behavior).
clip::mount_enrich() {
  local host=$1 paths=$2
  (
    local cm="${CLIPBOARD_MOUNT_BIN:-$HOME/.local/libexec/clipboard-mount}"
    [[ -x "$cm" ]] || exit 0
    # M runs for BOTH the origin's trusted local-socket send and the public
    # peer push (seen by that peer through port 2490) -- the SAME payload,
    # same <host>. When <host> IS this machine (the trusted leg), enriching
    # would try to mount OURSELVES over
    # SFTP: needless per-copy ssh churn, log growth, and if self-ssh ever
    # authenticates, a persistent self-mount + a pasteboard write that
    # violates M's whole contract (record-only, no pasteboard side effect --
    # see the header opcode table). Bail before touching the mount helper at
    # all whenever the manifest's source_host resolves to us.
    #
    # Identity resolution here MUST mirror pbcopy's self_host() precedence
    # (executable_pbcopy, near abspath()) -- that function is what stamps an
    # outgoing M row's host field in the first place, preferring the pushed
    # $XDG_STATE_HOME/clipboard/self-name over scutil/hostname (a stable
    # self-name can drift from live scutil output: a hand-edited fragment,
    # or macOS auto-renaming LocalHostName on collision, e.g.
    # thiago-mac-mini -> thiago-mac-mini-2). If this guard only checked
    # scutil/hostname, a self-name-stamped row would stop matching THIS
    # machine's own idea of itself the moment the two diverge, and the
    # per-copy self-mount churn (or worse, a persistent self-mount) this
    # guard exists to prevent would come right back.
    local self_host="" sh_file sh_name
    sh_file="${XDG_STATE_HOME:-$HOME/.local/state}/clipboard/self-name"
    if [[ -r "$sh_file" ]]; then
      # First line only (zsh flavor of pbcopy's single-line read) -- the
      # file is written by a single `print -rn` (no trailing newline; see
      # ssh-prepare-connection's step_mount), so this is normally the whole
      # file anyway. Intentional divergence from pbcopy's self_host(),
      # which rejects a multi-line file OUTRIGHT: here the validated first
      # line is used even if garbage follows -- moot for the writer above,
      # only observable on a hand-edited multi-line file.
      local -a sh_lines; sh_lines=( "${(f)"$(<"$sh_file")"}" )
      sh_name=$sh_lines[1]
      # Same shape rule as pbcopy's self_host()/clipboard-mount's
      # cm::valid_host/ssh-prepare-connection's peer_hostname check: alnum
      # first char, then alnum/dot/dash. `#` (zero-or-more) needs
      # extended_glob -- scoped to this disowned subshell, never the parent
      # shell.
      setopt extended_glob
      [[ "$sh_name" == [A-Za-z0-9][A-Za-z0-9.-]# ]] && self_host=$sh_name
    fi
    [[ -n "$self_host" ]] || self_host=$(scutil --get LocalHostName 2>/dev/null) || self_host=$(hostname -s 2>/dev/null)
    [[ -n "$self_host" && "$host" == "$self_host" ]] && exit 0
    local cc; cc=$(clip::pb_changecount) || exit 0
    local mp
    if ! mp=$("$cm" check "$host" 2>/dev/null); then
      "$cm" ensure "$host" >/dev/null 2>&1 || exit 0
      mp=$("$cm" check "$host" 2>/dev/null) || exit 0
    fi
    [[ -n "$mp" ]] || exit 0
    local -a f=( "${(@ps:\0:)paths}" ) mapped=()
    local p
    for p in "${f[@]}"; do mapped+=( "${mp}${p}" ); done
    [[ -e "${mapped[1]}" ]] || exit 0
    # The final changeCount comparison and write happen in ONE Hammerspoon
    # script. A shell-side recheck followed by a second hs invocation left a
    # multi-second gap in which a newer user copy could be overwritten.
    clip::set_file_urls_core "${(pj:\0:)mapped}" 1 "$cc"
  ) </dev/null >/dev/null 2>&1 &!
}

# pb::enrich_manifest -- the M handler's post-reply hook (spec §2): on macOS
# this is the mount-aware pasteboard enrichment; linux-headless makes it a
# no-op. Runs AFTER send_ok, backgrounded+disowned inside mount_enrich.
pb::enrich_manifest() {
  clip::mount_enrich "$1" "$2"
}
