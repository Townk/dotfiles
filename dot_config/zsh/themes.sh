# Theme env vars for CLI tools that can't be themed via a config
# file. Sourced by ~/.zshenv so subshells (including fzf preview
# subshells, which run non-interactively) inherit these values too.
#
# Keep this file POSIX sh-compatible — ~/.zshenv `.` is also reachable
# from /bin/sh contexts via the launchd agent that loads
# environment.sh.

# JQ_COLORS — Catppuccin Mocha palette via 24-bit SGR codes.
#
# Format: null:false:true:numbers:strings:arrays:objects[:object_keys]
# Each field is a comma-separated SGR sequence. `38;2;R;G;B` selects a
# true-color foreground; the leading `0;`/`1;` sets attributes
# (normal/bold). Requires jq 1.7+ for the 8th `object_keys` field and
# a truecolor terminal for the RGB codes to render.
#
# Colors:
#   null    overlay0  #6c7086  (dim gray, bold)
#   false   red       #f38ba8
#   true    green     #a6e3a1
#   numbers peach     #fab387
#   strings yellow    #f9e2af
#   arrays  blue      #89b4fa  (bold)
#   objects lavender  #b4befe  (bold)
#   objkey  sapphire  #74c7ec
#
# `yq -C` and `xq -C` inherit the same palette via this env var.
export JQ_COLORS='1;38;2;108;112;134:0;38;2;243;139;168:0;38;2;166;227;161:0;38;2;250;179;135:0;38;2;249;226;175:1;38;2;137;180;250:1;38;2;180;190;254:0;38;2;116;199;236'
