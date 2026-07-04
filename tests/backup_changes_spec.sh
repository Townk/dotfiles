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

  Describe 'bkp::changeset::patch (snapshot pair)'
    setup_fix() {
      FIX=$(mktemp -d)
      export BKP_CONFIG="$FIX/c.toml"
      printf '[staging]\npath = "%s/repo"\npassword_command = "echo pw"\n' "$FIX" > "$FIX/c.toml"
      # Fixture snapshot trees: snaps/<id><abs-path>
      mkdir -p "$FIX/snaps/aaaa/$FIX/home/sub" "$FIX/snaps/bbbb/$FIX/home/sub"
      print v1   > "$FIX/snaps/aaaa/$FIX/home/f.txt"
      print v2   > "$FIX/snaps/bbbb/$FIX/home/f.txt"
      print gone > "$FIX/snaps/aaaa/$FIX/home/sub/del.txt"
      print new  > "$FIX/snaps/bbbb/$FIX/home/sub/add.txt"
      # restic diff --json fixture (one line per change, NDJSON)
      cat > "$FIX/diff.json" <<EOF
{"message_type":"change","path":"$FIX/home/f.txt","modifier":"M"}
{"message_type":"change","path":"$FIX/home/sub/del.txt","modifier":"-"}
{"message_type":"change","path":"$FIX/home/sub/add.txt","modifier":"+"}
{"message_type":"change","path":"$FIX/home/meta.txt","modifier":"U"}
{"message_type":"change","path":"$FIX/elsewhere/x.txt","modifier":"M"}
{"message_type":"statistics","source_snapshot":"aaaa"}
EOF
    }
    cleanup_fix() { rm -rf "$FIX"; unset BKP_CONFIG; }
    BeforeEach 'setup_fix'
    AfterEach 'cleanup_fix'

    stub_restic() {
      bkp::restic() {
        local repo="$1"; shift
        print -r -- "$repo $*" >> "$FIX/calls"
        case "$1" in
          diff) cat "$FIX/diff.json" ;;
          restore)
            local snap="$2" target="" incfile="" p src
            while (( $# )); do
              case "$1" in
                --target) target="$2"; shift 2 ;;
                --include-file) incfile="$2"; shift 2 ;;
                *) shift ;;
              esac
            done
            while IFS= read -r p; do
              src="$FIX/snaps/$snap$p"
              [ -e "$src" ] || continue
              mkdir -p "$target${p:h}"
              cp "$src" "$target$p"
            done < "$incfile"
            ;;
          *) return 0 ;;
        esac
      }
    }

    It 'synthesizes a patch with live-relative a/b labels'
      run_it() {
        source "$LIB/backup.zsh"; stub_restic
        bkp::changeset::patch aaaa bbbb "$FIX/home"
      }
      When run run_it
      The output should include "diff --git a$FIX/home/f.txt b$FIX/home/f.txt"
      The output should include "+++ b$FIX/home/sub/add.txt"
      The output should include "--- a$FIX/home/sub/del.txt"
      The output should not include "meta.txt"
      The output should not include "elsewhere"
    End

    It 'emits nothing when the scope has no changes'
      run_it() {
        source "$LIB/backup.zsh"; stub_restic
        bkp::changeset::patch aaaa bbbb "$FIX/nowhere"
      }
      When run run_it
      The status should be success
      The output should equal ""
    End

    It 'stubs oversized files and logs the skip'
      run_it() {
        source "$LIB/backup.zsh"; stub_restic
        printf '\n[changes]\nsize_threshold = "1k"\n' >> "$FIX/c.toml"
        head -c 2048 /dev/urandom > "$FIX/snaps/bbbb/$FIX/home/f.txt"
        bkp::changeset::patch aaaa bbbb "$FIX/home"
      }
      When run run_it
      The output should include "content skipped"
      The stderr should include "size threshold"
    End
  End
End
