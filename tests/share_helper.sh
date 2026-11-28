# share_helper.sh — fixtures for the share*_spec.sh files, and only for them
# (`Include tests/share_helper.sh`). They exist to keep an example's own
# setup out of its 0.1 s: a fork costs 1.2-2.2 ms, and every share spec
# rebuilt its sandbox, its manifest and its stubs with eight to twelve of
# them before each example.
zmodload -F zsh/files b:zf_mkdir b:zf_rm 2>/dev/null

# share_fresh <dir> [subdir...] — <dir> empty and present again, with the
# subdirectories named: `rm -rf "$dir"; mkdir -p "$dir/a" "$dir/b"` without
# the two processes.
share_fresh() {
  local dir=$1
  shift
  zf_rm -rf -- "$dir" 2>/dev/null
  zf_mkdir -p -- "$dir" "${(@)^@/#/$dir/}"
}

# share_write <file> / share_append <file> — stdin to the file, as
# `cat >file` and `cat >>file`, read by the shell itself: for the manifest
# and the fixtures a setup writes from a heredoc for every example.
share_write() {
  local REPLY
  IFS= read -r -d '' || :
  print -rn -- "$REPLY" > "$1"
}
share_append() {
  local REPLY
  IFS= read -r -d '' || :
  print -rn -- "$REPLY" >> "$1"
}

# share_fixture_script <path> — write stdin to <path> as an executable
# script, for a BeforeAll: a stub every example uses unchanged is written
# ONCE per file, in a directory the examples share (put it on PATH behind the
# example's own bin directory, or name it in the *_BIN seam).
#
# Such a stub keeps nothing beside itself: what it records goes where an
# exported variable says (the example's sandbox). An example that needs a
# different stub of the same name writes its own in ITS bin directory, which
# is first on PATH, and re-points the seam; it never rewrites the shared one.
#
# macOS vets a script the first time its inode is exec'd (about 50 ms, see
# THE EXEC POOL in spec_helper.sh). The charge follows the inode, so the file
# is run once as an empty script here, then filled in place: no example pays.
share_fixture_script() {
  zf_mkdir -p -- "${1:h}"
  print -r -- '#!/bin/sh' > "$1" && command chmod +x "$1" && "$1" < /dev/null && cat > "$1"
}
