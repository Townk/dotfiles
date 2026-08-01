# Tests for home/dot_local/bin/executable_system-images.
#
# Focus: the attach-state seam. Mount state MUST be derived from the IMAGE
# (its image-path, via `hdiutil info -plist`), not from whether the declared
# <mountpoint>/<name> directory happens to be a mount root. The old path-only
# heuristic (compare a dir's device id to its parent's) is blind to any image
# the user attached by other means — Finder double-click, `open x.sparseimage`,
# or a bare `hdiutil attach` — all of which mount at /Volumes/<volname>. That
# blindness is MED-9 (list/status wrongly say "unmounted"; unmount refuses;
# mount re-attaches an attached image) and it also arms MED-3 (`remove`'s
# path-gated detach short-circuits, so `rm -f` unlinks a LIVE device's backing
# store).
#
# hdiutil is stubbed on PATH; yq/jq/plutil are the real tools, so these specs
# exercise the real plist parsing. The stub serves `info -plist` from a state
# file we control and records every `attach`/`detach` invocation; a non-stubborn
# `detach` flips the state file to the empty (unattached) plist, modelling a
# real successful detach.

Describe 'system-images'
  IMAGES="$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_system-images"

  # An empty (no images attached) `hdiutil info -plist`, the real shape.
  _empty_plist() {
    cat <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>framework</key><string>683.100.3</string>
	<key>images</key>
	<array/>
	<key>revision</key><string>683.100.3</string>
	<key>vendor</key><string>Apple</string>
</dict>
</plist>
EOF
  }

  # `hdiutil info -plist` for `work` attached, mounted at $2 (a mount point).
  # Whole-disk dev node is /dev/disk4; the mounted volume is /dev/disk5s1.
  # $1 = image-path, $2 = mount-point.
  _mounted_plist() {
    cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>framework</key><string>683.100.3</string>
	<key>images</key>
	<array>
		<dict>
			<key>image-path</key><string>$1</string>
			<key>system-entities</key>
			<array>
				<dict><key>content-hint</key><string>GUID_partition_scheme</string><key>dev-entry</key><string>/dev/disk4</string></dict>
				<dict><key>content-hint</key><string>Apple_APFS</string><key>dev-entry</key><string>/dev/disk5</string></dict>
				<dict><key>content-hint</key><string>41504653-0000-11AA-AA11-00306543ECAC</string><key>dev-entry</key><string>/dev/disk5s1</string><key>mount-point</key><string>$2</string></dict>
			</array>
		</dict>
	</array>
	<key>revision</key><string>683.100.3</string>
	<key>vendor</key><string>Apple</string>
</dict>
</plist>
EOF
  }

  # `work` attached but with NO mounted volume (e.g. ejected in Finder while
  # the /dev/disk4 device lingers). $1 = image-path.
  _attached_no_volume_plist() {
    cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>framework</key><string>683.100.3</string>
	<key>images</key>
	<array>
		<dict>
			<key>image-path</key><string>$1</string>
			<key>system-entities</key>
			<array>
				<dict><key>content-hint</key><string>GUID_partition_scheme</string><key>dev-entry</key><string>/dev/disk4</string></dict>
			</array>
		</dict>
	</array>
	<key>revision</key><string>683.100.3</string>
	<key>vendor</key><string>Apple</string>
</dict>
</plist>
EOF
  }

  setup() {
    STAGE="$(mktemp -d)"
    # $HOME sandbox so the tool's `source $HOME/.local/lib/...` resolves the
    # real lib (palette/common.zsh come via THEME_PALETTE_FILE from the helper).
    mkdir -p "$STAGE/.local/bin"
    ln -s "$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib" "$STAGE/.local/lib"
    cp "$IMAGES" "$STAGE/.local/bin/system-images"
    chmod +x "$STAGE/.local/bin/system-images"
    OLD_HOME="${HOME:-}"; export HOME="$STAGE"

    # Manifest + image dir.
    export IMGFILE="$STAGE/images.toml"
    export IMG_DIR="$STAGE/images"
    export MOUNT_PARENT="$STAGE/mnt"
    mkdir -p "$IMG_DIR" "$MOUNT_PARENT"
    cat >"$IMGFILE" <<EOF
[work]
mountpoint = "$MOUNT_PARENT"
automount = true
size = "1g"
EOF
    IMG="$IMG_DIR/work.sparseimage"
    printf 'sparse-bytes' >"$IMG"        # a plausible backing file

    # hdiutil stub: `info -plist` serves $HDIUTIL_STATE; attach/detach are
    # logged; a non-stubborn detach flips the state to the empty plist.
    STUB_DIR="$STAGE/stub"; mkdir -p "$STUB_DIR"
    export HDIUTIL_LOG="$STAGE/hdiutil.log"; : >"$HDIUTIL_LOG"
    export HDIUTIL_STATE="$STAGE/hdiutil.plist"
    export HDIUTIL_EMPTY="$STAGE/empty.plist"
    _empty_plist >"$HDIUTIL_EMPTY"
    _empty_plist >"$HDIUTIL_STATE"       # default: nothing attached
    cat >"$STUB_DIR/hdiutil" <<'STUB'
#!/bin/sh
case "$1" in
  info)   cat "$HDIUTIL_STATE" ;;
  attach) shift; printf 'attach %s\n' "$*" >>"$HDIUTIL_LOG" ;;
  detach) shift; printf 'detach %s\n' "$*" >>"$HDIUTIL_LOG"
          [ "${HDIUTIL_STUBBORN:-0}" = 1 ] || cp "$HDIUTIL_EMPTY" "$HDIUTIL_STATE" ;;
  *)      : ;;
esac
exit 0
STUB
    chmod +x "$STUB_DIR/hdiutil"
    export PATH="$STUB_DIR:$PATH"
  }
  cleanup() {
    export HOME="$OLD_HOME"
    rm -rf "$STAGE"
    unset IMGFILE IMG_DIR MOUNT_PARENT HDIUTIL_LOG HDIUTIL_STATE HDIUTIL_EMPTY HDIUTIL_STUBBORN
  }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  # Attach `work` at the given mount point by swapping the state file.
  attach_at() { _mounted_plist "$IMG" "$1" >"$HDIUTIL_STATE"; }

  Describe 'MED-9: mount state derived from the image, not the declared path'
    Context 'image attached at /Volumes/work (NOT the declared dir)'
      before() { attach_at "/Volumes/work"; }
      BeforeEach 'before'

      It 'img::is_mounted reports it mounted'
        probe() { source "$HOME/.local/bin/system-images"; img::is_mounted work; }
        When run probe
        The status should be success
      End

      It 'status reports mounted at the actual mount point'
        When run zsh "$STAGE/.local/bin/system-images" status work
        The output should include "yes (at /Volumes/work)"
        The status should be success
      End

      It 'list reports mounted and names the actual mount point'
        When run zsh "$STAGE/.local/bin/system-images" list
        The output should include "mounted"
        The output should include "/Volumes/work"
        The status should be success
      End

      It 'unmount proceeds and detaches the device (not the declared dir)'
        When run zsh "$STAGE/.local/bin/system-images" unmount work
        The output should include "unmounted work"
        The status should be success
        The contents of file "$HDIUTIL_LOG" should include "detach /dev/disk4"
      End

      It 'mount does NOT re-attach an already-attached image'
        When run zsh "$STAGE/.local/bin/system-images" mount work
        The output should include "already mounted at /Volumes/work"
        The status should be success
        The contents of file "$HDIUTIL_LOG" should not include "attach"
      End
    End

    Context 'image attached at the declared dir (no regression)'
      before() { attach_at "$MOUNT_PARENT/work"; }
      BeforeEach 'before'

      It 'still reports mounted'
        probe() { source "$HOME/.local/bin/system-images"; img::is_mounted work; }
        When run probe
        The status should be success
      End

      It 'status shows mounted at the declared dir'
        When run zsh "$STAGE/.local/bin/system-images" status work
        The output should include "yes (at $MOUNT_PARENT/work)"
      End
    End

    Context 'image not attached at all'
      It 'img::is_mounted reports it unmounted'
        probe() { source "$HOME/.local/bin/system-images"; img::is_mounted work; }
        When run probe
        The status should be failure
      End

      It 'list reports unmounted'
        When run zsh "$STAGE/.local/bin/system-images" list
        The output should include "unmounted"
        The status should be success
      End

      It 'unmount is a no-op that does not detach'
        When run zsh "$STAGE/.local/bin/system-images" unmount work
        The output should include "not mounted"
        The contents of file "$HDIUTIL_LOG" should not include "detach"
      End
    End
  End
End
