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
End
