# rip-audiobook — the provider contract, the libation provider, the CLI and
# the session worker. Hermetic: sandboxed staging, fake LibationCli
# (RIP_LIBATION_BIN), fake ssh (RIP_SSH_BIN), no network, no GUI.
Describe 'rip audiobooks'
  RIPLIB="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib/rip.zsh"
  PROVIDER="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_rip-provider-libation"

  setup() {
    export RIP_SANDBOX=$(mktemp -d)
    export RIP_STAGING_ROOT="$RIP_SANDBOX/Rips"
    export RIP_REMOTE_BASE="$RIP_SANDBOX/server"
    export JOB_STATE_ROOT="$RIP_SANDBOX/state"
    export JOB_FAKE_LOG="$RIP_SANDBOX/pueue.log"
    export RIP_LIB_DIR="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib"
    export RIP_LIBEXEC_DIR="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec"
    export RIP_PUSH_MIN_AGE_S=0
    mkdir -p "$RIP_STAGING_ROOT/audiobooks/Books" "$RIP_SANDBOX/server/audiobooks"
    cat > "$RIP_SANDBOX/pueue" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$JOB_FAKE_LOG"
case "$1" in add) echo "7" ;; esac
exit 0
EOF
    chmod +x "$RIP_SANDBOX/pueue"
    export JOB_PUEUE_BIN="$RIP_SANDBOX/pueue"

    # Fake LibationCli: `export -j -p <file>` writes a two-record library,
    # one Liberated and one not. Any other verb records its argv so an
    # example can assert what was (and was NOT) invoked.
    cat > "$RIP_SANDBOX/LibationCli" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$RIP_SANDBOX/libation.log"
if [ "$1" = "export" ]; then
  out=""
  while [ $# -gt 0 ]; do
    case "$1" in -p|--path) out="$2" ;; esac
    shift
  done
  cat > "$out" <<'JSON'
[
 {"AudibleProductId":"B00ECDZ08I","Title":"Steelheart","Subtitle":"The Reckoners, Book 1",
  "AuthorNames":"Brandon Sanderson","NarratorNames":"MacLeod Andrews","LengthInMinutes":762,
  "SeriesNames":"Reckoners","SeriesOrder":"1 : Reckoners","Language":"english","IsAbridged":false,
  "HasPdf":false,"PictureId":"51kzMpLGP7L","BookStatus":"NotLiberated","LastDownloaded":null},
 {"AudibleProductId":"B0DGKKZ123","Title":"Wind and Truth","Subtitle":"",
  "AuthorNames":"Brandon Sanderson","NarratorNames":"Michael Kramer","LengthInMinutes":3360,
  "SeriesNames":"The Stormlight Archive","SeriesOrder":"5 : The Stormlight Archive","Language":"english",
  "IsAbridged":false,"HasPdf":true,"PictureId":"81abcDEF","BookStatus":"Liberated",
  "LastDownloaded":"2026-08-22 08:18:03.838369"}
]
JSON
  echo "Library exported to: $out"
  exit 0
fi
exit 0
EOF
    chmod +x "$RIP_SANDBOX/LibationCli"
    export RIP_LIBATION_BIN="$RIP_SANDBOX/LibationCli"
    export RIP_LIBATION_IMAGES="$RIP_SANDBOX/Images"
    mkdir -p "$RIP_LIBATION_IMAGES"
  }
  cleanup() { rm -rf "$RIP_SANDBOX"; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  It 'provider: capabilities describes itself'
    When run zsh "$PROVIDER" capabilities
    The status should equal 0
    The output should include '"name":"libation"'
    The output should include '"can_acquire":true'
  End

  It 'provider: list emits one JSON line per title in the common schema'
    When run zsh "$PROVIDER" list
    The status should equal 0
    The line 1 should include '"id":"B00ECDZ08I"'
    The line 1 should include '"duration_s":45720'
    The line 1 should include '"acquired":false'
    The line 1 should include '"audible.asin":"B00ECDZ08I"'
    The line 2 should include '"acquired":true'
    The line 2 should include '"has_pdf":true'
  End

  It 'provider: path carries Title: Subtitle, the folder Libation actually writes'
    When run zsh "$PROVIDER" list
    The status should equal 0
    The line 1 should include '"path":"Brandon Sanderson/Steelheart: The Reckoners, Book 1"'
    The line 1 should include '"title":"Steelheart"'
    The line 2 should include '"path":"Brandon Sanderson/Wind and Truth"'
  End

  It 'provider: cover prefers the local cache, falls back to the CDN'
    touch "$RIP_LIBATION_IMAGES/51kzMpLGP7L_80x80.jpg"
    When run zsh "$PROVIDER" list
    The status should equal 0
    The line 1 should include "file://$RIP_LIBATION_IMAGES/51kzMpLGP7L_80x80.jpg"
    The line 2 should include "https://m.media-amazon.com/images/I/81abcDEF.jpg"
  End

  It 'provider: never invokes set-status'
    When run zsh "$PROVIDER" list
    The status should equal 0
    The contents of file "$RIP_SANDBOX/libation.log" should not include "set-status"
  End

  It 'provider: a missing LibationCli fails cleanly'
    export RIP_LIBATION_BIN="$RIP_SANDBOX/nope"
    When run zsh "$PROVIDER" list
    The status should equal 3
    The stderr should include "LibationCli not found"
  End
End
