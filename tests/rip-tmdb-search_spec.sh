# rip-tmdb-search — TMDB typeahead backend for the ripper chooser.
Describe 'rip-tmdb-search'
  BIN="$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_rip-tmdb-search"

  setup() {
    TS_SANDBOX=$(mktemp -d)
    cat > "$TS_SANDBOX/curl" <<'EOF'
#!/bin/sh
cat <<'JSON'
{"results":[{"title":"Heat","release_date":"1995-12-15","poster_path":"/a.jpg"},
{"title":"Heat","release_date":"2013-06-01","poster_path":null}]}
JSON
EOF
    chmod +x "$TS_SANDBOX/curl"
    export RIP_CURL_BIN="$TS_SANDBOX/curl"
    export TMDB_API_KEY="test-key"
  }
  cleanup() { rm -rf "$TS_SANDBOX"; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  It 'emits one JSON line per result with Title (Year)'
    When run zsh "$BIN" heat
    The status should equal 0
    The line 1 of output should include '"title":"Heat (1995)"'
    The line 1 of output should include 'image.tmdb.org/t/p/w92/a.jpg'
    The line 2 of output should include '"title":"Heat (2013)"'
    The line 2 of output should not include 'image.tmdb.org'
  End

  It 'exits 3 without a key'
    # zsh -f: skip ~/.zshenv, which re-injects the real TMDB_API_KEY from
    # system-secrets now that the operator has registered one (2026-08-20)
    # — a bare unset stopped being hermetic the day the key existed.
    unset TMDB_API_KEY
    When run zsh -f "$BIN" heat
    The status should equal 3
    The stderr should include "TMDB_API_KEY"
  End

  It 'exits 2 without a query'
    When run zsh "$BIN"
    The status should equal 2
    The stderr should include "usage"
  End
End
