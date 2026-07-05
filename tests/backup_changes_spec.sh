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
        # now-24h is always after the newest fixture snapshot (2026-07-03),
        # so the newest rung at/before the cutoff is deterministically cccc.
        bkp::snap::resolve_since "24h"
        print -r -- "$REPLY"
      }
      When run run_it
      The status should be success
      The output should start with "cccc"
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
          diff) [ -e "$FIX/diff-fails" ] && return 1; cat "$FIX/diff.json" ;;
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

    It 'fails (rc 1) when restic diff fails instead of reporting no changes'
      run_it() {
        source "$LIB/backup.zsh"; stub_restic
        touch "$FIX/diff-fails"
        bkp::changeset::patch aaaa bbbb "$FIX/home"
      }
      When run run_it
      The status should equal 1
    End
  End

  Describe 'bkp::changeset::patch_live'
    setup_fix() {
      FIX=$(mktemp -d)
      export BKP_CONFIG="$FIX/c.toml" BKP_MANIFEST="$FIX/m.toml"
      printf '[staging]\npath = "%s/repo"\npassword_command = "echo pw"\n' "$FIX" > "$FIX/c.toml"
      printf 'roots = []\n' > "$FIX/m.toml"
      # hermetic chezmoi: no managed files unless a test overrides the stub
      STUB="$FIX/stub"; mkdir -p "$STUB"
      printf '#!/bin/sh\nexit 0\n' > "$STUB/chezmoi"
      chmod +x "$STUB/chezmoi"
      PATH="$STUB:$PATH"
      # "mount": past state; "live": current state
      mkdir -p "$FIX/mnt/ids/aaaa$FIX/live" "$FIX/live"
      print old > "$FIX/mnt/ids/aaaa$FIX/live/f.txt"
      print new > "$FIX/live/f.txt"
      print lost > "$FIX/mnt/ids/aaaa$FIX/live/del.txt"
    }
    cleanup_fix() { rm -rf "$FIX"; unset BKP_CONFIG BKP_MANIFEST; }
    BeforeEach 'setup_fix'
    AfterEach 'cleanup_fix'

    It 'diffs mount rung vs live with live-absolute labels'
      run_it() {
        source "$LIB/backup.zsh"
        bkp::changeset::patch_live "$FIX/mnt/ids/aaaa" "$FIX/live"
      }
      When run run_it
      The output should include "diff --git a$FIX/live/f.txt b$FIX/live/f.txt"
      The output should include "--- a$FIX/live/del.txt"
      The output should include "-old"
      The output should include "+new"
      The output should not include "mnt/ids"
    End

    It 'survives special files (sockets/fifos) in the live tree via a clean view'
      run_it() {
        source "$LIB/backup.zsh"
        mkfifo "$FIX/live/pipe.fifo"
        bkp::changeset::patch_live "$FIX/mnt/ids/aaaa" "$FIX/live"
      }
      When run run_it
      The status should be success
      # labels must map the cleaned view back to the real live root
      The output should include "diff --git a$FIX/live/f.txt b$FIX/live/f.txt"
      The output should include "+new"
      The output should not include "bkp-liveview"
    End

    It 'is empty when past and live are identical'
      run_it() {
        source "$LIB/backup.zsh"
        rm "$FIX/mnt/ids/aaaa$FIX/live/del.txt"
        print new > "$FIX/mnt/ids/aaaa$FIX/live/f.txt"
        bkp::changeset::patch_live "$FIX/mnt/ids/aaaa" "$FIX/live"
      }
      When run run_it
      The status should be success
      The output should equal ""
    End

    It 'filters the live side through capture rules — no phantom additions'
      run_it() {
        source "$LIB/backup.zsh"
        # live-only files the capture deliberately skips: one chezmoi-
        # managed, one deny-listed. A raw dir diff would render both as
        # added; the filtered view must show only the real change.
        print managed > "$FIX/live/managed.txt"
        print denied > "$FIX/live/secret.key"
        printf 'roots = []\ndeny = ["**/*.key"]\n' > "$FIX/m.toml"
        printf '#!/bin/sh\necho "%s/live/managed.txt"\n' "$FIX" > "$STUB/chezmoi"
        chmod +x "$STUB/chezmoi"
        bkp::changeset::patch_live "$FIX/mnt/ids/aaaa" "$FIX/live"
      }
      When run run_it
      The status should be success
      The output should include "+new"
      The output should include "del.txt"
      The output should not include "managed.txt"
      The output should not include "secret.key"
    End

    It 'refuses a scope over the live-view file cap, loudly'
      run_it() {
        source "$LIB/backup.zsh"
        local i
        for i in 1 2 3 4 5; do print x > "$FIX/live/extra$i.txt"; done
        BKP_TM_LIVEVIEW_MAX_FILES=3 \
          bkp::changeset::patch_live "$FIX/mnt/ids/aaaa" "$FIX/live"
      }
      When run run_it
      The status should equal 1
      The stderr should include "too large for live-diff synthesis"
    End

    It 'tolerates rsync partial-transfer (rc 23/24) when building the view'
      run_it() {
        source "$LIB/backup.zsh"
        mkfifo "$FIX/live/pipe.fifo"
        # rsync stub: copies what held still, then reports "files
        # vanished" (rc 24) — routine on a churning live tree, and the
        # view must still be used, not discarded.
        STUB="$FIX/stub"; mkdir -p "$STUB"
        cat > "$STUB/rsync" <<'EOF'
#!/bin/sh
n=$#
dst=$(eval "echo \${$n}")
m=$((n - 1))
src=$(eval "echo \${$m}")
mkdir -p "$dst"
cp "$src"f.txt "$dst"/f.txt 2>/dev/null
exit 24
EOF
        chmod +x "$STUB/rsync"
        PATH="$STUB:$PATH"
        bkp::changeset::patch_live "$FIX/mnt/ids/aaaa" "$FIX/live"
      }
      When run run_it
      The status should be success
      The output should include "+new"
      The output should not include "bkp-liveview"
      The stderr should equal ""
    End
  End

  Describe 'bkp::ux::changes_cmd'
    setup_fix() {
      FIX=$(mktemp -d)
      export BKP_CONFIG="$FIX/c.toml"
      printf '[staging]\npath = "%s/repo"\npassword_command = "echo pw"\n' "$FIX" > "$FIX/c.toml"
      cat > "$FIX/snaps.json" <<'EOF'
[{"id":"aaaa000000000000000000000000000000000000000000000000000000000000","time":"2026-07-01T10:00:00Z"},
 {"id":"cccc000000000000000000000000000000000000000000000000000000000000","time":"2026-07-03T10:00:00Z"}]
EOF
      printf '' > "$FIX/diff.json"
    }
    cleanup_fix() { rm -rf "$FIX"; unset BKP_CONFIG; }
    BeforeEach 'setup_fix'
    AfterEach 'cleanup_fix'

    stub_restic() {
      bkp::restic() {
        local repo="$1"; shift
        print -r -- "$repo $*" >> "$FIX/calls"
        case "$1" in
          snapshots) cat "$FIX/snaps.json" ;;
          diff)      cat "$FIX/diff.json" ;;
          *) return 0 ;;
        esac
      }
    }

    It 'defaults to previous vs latest and reports no changes'
      run_it() {
        source "$LIB/backup.zsh"; stub_restic
        bkp::ux::changes_cmd "" "" "" ""
      }
      When run run_it
      The status should be success
      The output should include "no changes"
      The output should include "aaaa"
      The output should include "cccc"
    End

    It 'refuses --since combined with explicit snapshots'
      run_it() {
        source "$LIB/backup.zsh"; stub_restic
        bkp::ux::changes_cmd "yesterday" "aaaa0000" "" ""
      }
      When run run_it
      The status should equal 2
      The stderr should include "mutually exclusive"
    End

    It 'diffs restic-side and prints the as-of footer'
      run_it() {
        source "$LIB/backup.zsh"; stub_restic
        printf '{"message_type":"change","path":"/x","modifier":"M"}\n' > "$FIX/diff.json"
        mkdir -p "$FIX/snaps/aaaa0000" # restore stub materializes nothing -> empty sides
        bkp::ux::changes_cmd "" "aaaa0000" "cccc0000" "" 2>/dev/null
      }
      When run run_it
      The status should be success
      The output should include "as of"
    End
  End

  Describe 'system-backup dispatcher: changes + diff guard'
    DISPATCH="$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_system-backup"
    setup_fix() {
      FIX=$(mktemp -d)
      export BKP_LIB="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib" BKP_CONFIG="$FIX/c.toml"
      printf '[staging]\npath = "%s/repo"\npassword_command = "echo pw"\n' "$FIX" > "$FIX/c.toml"
    }
    cleanup_fix() { rm -rf "$FIX"; unset BKP_LIB BKP_CONFIG; }
    BeforeEach 'setup_fix'
    AfterEach 'cleanup_fix'

    It 'lists changes in usage'
      When run zsh "$DISPATCH" --help
      The output should include "changes"
    End

    It 'redirects diff on a directory to changes'
      When run zsh "$DISPATCH" diff "$FIX" aaaa0000
      The status should equal 2
      The stderr should include "changes"
    End
  End
End
