#!/usr/bin/env zsh
# platform.sh — load the OS-specific `platform::` implementation.
#
# SOURCED, never executed. A thin runtime dispatcher: it sources the base (for
# die/log_*) and then the matching platform-<os>.sh, which defines the
# `platform::` interface (launch a GUI app, raise a window). Plain shell (not a
# chezmoi template) so it is directly sourceable in tests and portable; the OS
# can be forced with $PLATFORM_OS to exercise either branch.
#
# Dual-shell (bash + zsh) like common.sh — its only consumer, tab-edit,
# stays bash because the zellij-session.sh it sources relies on bash word
# splitting. Keep this file and the platform-<os>.sh impls free of zsh-only
# runtime syntax.
#
# Interface implemented by every platform-<os>.sh:
#   platform::launch_gui <macos-app> <linux-bin> -- <argv...>
#       Launch a GUI app, detached, running <argv...>. macOS routes through
#       `open -a <macos-app>`; Linux execs <linux-bin> directly.
#   platform::raise_app  <macos-app> [<linux-wm-class>]
#       Best-effort: bring the app's window to the foreground. Never fatal.

if [ -n "${BASH_SOURCE:-}" ]; then
  _platform_self="${BASH_SOURCE[0]}"
else
  _platform_self="${(%):-%x}"
fi
_platform_dir="$(dirname "$_platform_self")"
unset _platform_self

source "$_platform_dir/common.sh"

# $PLATFORM_OS defaults to the running kernel; tests override it to load a
# specific implementation regardless of the host.
: "${PLATFORM_OS:=$(uname -s)}"
case "$PLATFORM_OS" in
  Darwin) source "$_platform_dir/platform-macos.sh" ;;
  Linux)  source "$_platform_dir/platform-linux.sh" ;;
  *)      unset _platform_dir; die "platform.sh: unsupported OS: $PLATFORM_OS" ;;
esac
unset _platform_dir
