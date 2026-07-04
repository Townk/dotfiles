# backup_changes_spec.sh — changeset review engine + changes verb (spec 2026-07-04).
Describe 'backup.zsh changes'
  TAB=$(printf '\t')
  setup() { export TZ=UTC; }
  BeforeEach 'setup'
  LIB="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib"

  Describe 'bkp::config::change_size_threshold'
    setup_fix() {
      FIX=$(mktemp -d)
      export BKP_CONFIG="$FIX/c.toml"
      printf '[staging]\npath = "%s/repo"\npassword_command = "echo pw"\n' "$FIX" > "$FIX/c.toml"
    }
    cleanup_fix() { rm -rf "$FIX"; unset BKP_CONFIG; }
    BeforeEach 'setup_fix'
    AfterEach 'cleanup_fix'

    It 'defaults to 5 MB when the key is absent'
      run_it() { source "$LIB/backup.zsh"; bkp::config::change_size_threshold; }
      When run run_it
      The output should equal 5242880
    End

    It 'reads [changes].size_threshold with units'
      run_it() {
        printf '\n[changes]\nsize_threshold = "2m"\n' >> "$FIX/c.toml"
        source "$LIB/backup.zsh"
        bkp::config::change_size_threshold
      }
      When run run_it
      The output should equal 2097152
    End
  End

  Describe 'bkp::snap ladder + resolver'
    setup_fix() {
      FIX=$(mktemp -d)
      export BKP_CONFIG="$FIX/c.toml"
      printf '[staging]\npath = "%s/repo"\npassword_command = "echo pw"\n' "$FIX" > "$FIX/c.toml"
      # Three capture snapshots + one bkp-undo (must be excluded).
      cat > "$FIX/snaps.json" <<'EOF'
[{"id":"aaaa000000000000000000000000000000000000000000000000000000000000","time":"2026-07-01T10:00:00Z"},
 {"id":"bbbb000000000000000000000000000000000000000000000000000000000000","time":"2026-07-02T10:00:00Z"},
 {"id":"undo000000000000000000000000000000000000000000000000000000000000","time":"2026-07-02T11:00:00Z","tags":["bkp-undo"]},
 {"id":"cccc000000000000000000000000000000000000000000000000000000000000","time":"2026-07-03T10:00:00Z"}]
EOF
    }
    cleanup_fix() { rm -rf "$FIX"; unset BKP_CONFIG; }
    BeforeEach 'setup_fix'
    AfterEach 'cleanup_fix'

    stub_restic() {
      bkp::restic() {
        local repo="$1"; shift
        print -r -- "$repo $*" >> "$FIX/calls"
        case "$1 ${2:-}" in
          'snapshots --json') cat "$FIX/snaps.json" ;;
          *) return 0 ;;
        esac
      }
    }

    It 'lists the ladder newest-first without bkp-undo'
      run_it() { source "$LIB/backup.zsh"; stub_restic; bkp::snap::ladder; }
      When run run_it
      The lines of output should equal 3
      The line 1 should start with "cccc"
      The line 3 should start with "aaaa"
      The output should not include "undo"
    End

    It 'resolves an ISO date to the newest snapshot at or before it'
      run_it() {
        source "$LIB/backup.zsh"; stub_restic
        bkp::snap::resolve_since "2026-07-02" && print -r -- "$REPLY"
      }
      When run run_it
      # midnight 2026-07-02 → only the 07-01 snapshot qualifies
      The output should start with "aaaa"
    End

    It 'resolves a relative duration'
      run_it() {
        source "$LIB/backup.zsh"; stub_restic
        # freeze "now" so 24h lands between the 07-02 and 07-03 snapshots
        bkp::snap::resolve_since "24h"
        print -r -- "$REPLY"
      }
      When run run_it
      The status should be success
    End

    It 'resolves a snapshot id prefix'
      run_it() {
        source "$LIB/backup.zsh"; stub_restic
        bkp::snap::resolve_since "bbbb0000" && print -r -- "$REPLY"
      }
      When run run_it
      The output should start with "bbbb"
      The output should match pattern "*000000"
    End

    It 'errors naming the oldest rung when nothing is old enough'
      run_it() {
        source "$LIB/backup.zsh"; stub_restic
        bkp::snap::resolve_since "2020-01-01"
      }
      When run run_it
      The status should equal 2
      The stderr should include "aaaa"
    End
  End
End
