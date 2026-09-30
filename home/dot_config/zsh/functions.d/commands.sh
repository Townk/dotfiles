source "${0:A:h}/_lib.sh"

function system-update() {
  local keep_shell=0 help_requested=0 update_status arg
  local -a args

  for arg in "$@"; do
    case "$arg" in
      --keep-shell)
        keep_shell=1
        ;;
      -h | --help | help)
        help_requested=1
        args+=("$arg")
        ;;
      *)
        args+=("$arg")
        ;;
    esac
  done

  command system-update "${args[@]}"
  update_status=$?
  (( update_status == 0 )) || return "$update_status"
  (( keep_shell || help_requested )) && return 0
  [[ -t 0 && -t 1 ]] || return 0

  print -P -- "%F{yellow}↻ Run %Bexec zsh%b in your other open sessions on this machine to pick up the update.%f"
  print -P -- "%F{8}Refreshing this session now (exec zsh)…%f"
  exec zsh
}

# The welcome screen: macchina, the chezmoi drift line when there is drift, a
# heavy rule, then the cockpit — two columns, MANAGE THIS MACHINE (the
# system-* front doors, from commands.tsv) and AT THE PROMPT (the key bindings
# people forget, from keys.tsv). It is a function so it can be called
# arbitrarily; the first pane of a session (dot_zshrc.tmpl) just calls it.
function motd() {
  macchina
  # macchina ends with a blank line of its own; step back onto it so the next
  # line (drift or rule) sits directly under the block. Only on a terminal:
  # piped, there is no cursor to move.
  [[ -t 1 ]] && print -n -- $'\e[1A'

  # chezmoi drift warning — silent when there is nothing to say. `chezmoi
  # status` costs ~0.9s even with scripts excluded, far too slow for the
  # startup path, so print the *previous* run's verdict from a stamp and
  # refresh it in the background for the next new window. Scripts must be
  # excluded: plain `run_` scripts are pending on every apply by design, so
  # including them would make this fire forever.
  local stamp="${XDG_CACHE_HOME:-$HOME/.cache}/chezmoi-drift"
  [[ -s "$stamp" ]] \
    && print -P -- "%F{$C_HEX_YELLOW}↻ chezmoi drift: \$HOME differs from source — run %Bchezmoi diff --exclude=scripts%b%f"
  ( chezmoi status --exclude=scripts >| "$stamp" 2>/dev/null & )

  _cockpit
}

# The data behind the cockpit is data, not code: see ../commands.tsv.tmpl and
# ../keys.tsv.tmpl for the formats, and tests/commands-index_spec.sh for the
# geometry they have to respect. Resolved here because `$0` inside a function
# is the function's name, not this file.
#
# Overridable because the sources are chezmoi TEMPLATES, gated per profile: the
# spec has to render them and point these at the result, the way spec_helper
# does with THEME_PALETTE_FILE.
typeset -g _CMDS_INDEX="${_CMDS_INDEX:-${0:A:h:h}/commands.tsv}"
typeset -g _KEYS_INDEX="${_KEYS_INDEX:-${0:A:h:h}/keys.tsv}"

# Display cells of a string, the way the terminal draws it, returned in $REPLY.
# zsh's own (m) flag knows wide CJK and emoji but counts a Nerd Font glyph — a
# private-use codepoint — as one cell, while tmux draws it in two, so each of
# those is added back. ${#str} would be wrong twice over: it counts codepoints,
# not cells.
function _motd_width() {
  local pua="${1//[^$''-$''$'\U000F0000'-$'\U000FFFFD']/}"
  REPLY=$(( ${(m)#1} + ${#pua} ))
}

# `text` padded with spaces to `width` display cells, in $REPLY. Padding with
# ${(r:N:)} would count the glyph as one cell and leave the next column short.
function _motd_pad() {
  _motd_width "$1"
  local -i gap=$(( $2 - REPLY ))
  (( gap < 0 )) && gap=0
  REPLY="${1}${(l:$gap:: :)}"
}

# Rows of a data file, comments and blanks skipped. Tab is an IFS *whitespace*
# character, so `read -r a b c` silently collapses runs of tabs and an empty
# blurb would slide the description into it; whole lines are split with
# `(@ps)`, which preserves empty fields.
typeset -ga _cockpit_left _cockpit_right
function _cockpit_load() {
  local line
  local -a field
  _cockpit_left=() _cockpit_right=()
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == '#'* ]] && continue
    field=("${(@ps:\t:)line}")
    [[ "$field[3]" == 1 ]] && _cockpit_left+=("$field[1]"$'\t'"$field[4]")
  done < "$_CMDS_INDEX"
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == '#'* ]] && continue
    field=("${(@ps:\t:)line}")
    _cockpit_right+=("$field[1]"$'\t'"$field[2]")
  done < "$_KEYS_INDEX"
}

# The rule and the two columns, never past 78 columns. Left cell 38 wide (a
# 14-wide name, two spaces, up to 22 of blurb), right cell a 10-wide key then up
# to 26 of blurb. The last cell of a row is never padded: trailing blanks would
# push a full row to the edge and wrap a terminal exactly that wide.
function _cockpit() {
  local -i i rows lw=38
  local rule="${(l:78::━:)}" lhead rhead lul rul lname lblurb rkey rblurb lcell
  local -a left right

  _cockpit_load
  rows=$(( ${#_cockpit_left[@]} > ${#_cockpit_right[@]} ? ${#_cockpit_left[@]} : ${#_cockpit_right[@]} ))

  print -P -- "${P_GRA}${rule}${P_RES}"

  lhead=$'\U000F0493'" MANAGE THIS MACHINE" rhead=$'\U000F030C'" AT THE PROMPT"
  # Each underline is as wide as the header it sits under, in display cells,
  # except that both are a cell shorter, and the gap between them a cell narrower,
  # by choice.
  _motd_width "$lhead"; lul="${(l:$(( REPLY - 1 ))::─:)}"
  _motd_width "$rhead"; rul="${(l:$(( REPLY - 1 ))::─:)}"
  _motd_pad "$lhead" $lw; lhead="$REPLY"
  _motd_pad "$lul" $(( lw - 1 )); lul="$REPLY"
  print -P -- "  ${P_YEL}${lhead}${rhead}${P_RES}"
  print -P -- "  ${P_GRA}${lul}${rul}${P_RES}"

  for (( i = 1; i <= rows; i++ )); do
    left=("${(@ps:\t:)_cockpit_left[i]}") right=("${(@ps:\t:)_cockpit_right[i]}")
    lname="$left[1]" lblurb="$left[2]" rkey="$right[1]" rblurb="$right[2]"
    _motd_pad "$lname" 14; lname="$REPLY"
    # Blurbs are plain text, so their length is their width.
    lcell="${P_BWH}${lname}${P_RES}  ${P_GRA}${lblurb}${P_RES}${(l:$(( lw - 16 - ${#lblurb} )):: :)}"
    if [[ -n "$rkey" ]]; then
      _motd_pad "$rkey" 10; rkey="$REPLY"
      print -P -- "  ${lcell}${P_BWH}${rkey}${P_RES}${P_GRA}${rblurb}${P_RES}"
    else
      print -P -- "  ${lcell}"
    fi
  done
}

# `cmds` searches the whole index rather than the handful of rows the cockpit
# lists. The cockpit is for glancing; this is for what it is worst at — you
# remember what a tool does but not what it is called, so you search the
# descriptions.
#
# The picker itself is pick-command, in the same engine as every other picker
# here. This stays a function only because it writes the edit buffer, which a
# child process cannot do: the pick lands on the line instead of running, since
# most of these commands need arguments. The trailing space is where you would
# type the first one.
#
# ONE function, two entry points: typed as a command, and bound as the Alt+x
# widget (`zle -N command-pick cmds`, declared in widgets.sh). $WIDGET is set
# only inside ZLE and is the whole difference between them:
#
#   from the prompt   `print -z` pushes a fresh line; inline, in the flow of the
#                     terminal you typed the command in.
#   from Alt+x        inserted at the cursor, so it works mid-command
#                     (`git log | ` → Alt+x), and --float makes it a modal,
#                     which is what suits a keystroke.
#
# Delivery is the only fork; everything above it — and the whole picker — is
# shared, so a change like that trailing space happens once.
function cmds() {
  local pick
  local -a float=()
  [[ -n "${WIDGET:-}" ]] && float=(--float)
  pick=$("$HOME/.local/libexec/pick-command" "${float[@]}" "$@") || pick=""

  if [[ -n "${WIDGET:-}" ]]; then
    [[ -n "$pick" ]] && LBUFFER+="$pick "
    zle reset-prompt
  else
    [[ -n "$pick" ]] && print -z -- "$pick "
  fi
}

# Helper utility to print a big and noticeable banner in the terminal.
# This function is useful whel you're running a series of long-running commands
# and want to have a good way to visually distinguish between them.
function lolbanner {
  local font_name=""
  local user_specified_dir=false
  local figlet_args=()
  local terminal_width

  terminal_width="$(stty size | awk '{ print $2 }')"

  while [[ $# -gt 0 ]]; do
    case "$1" in
    -f)
      if [[ $# -gt 1 ]]; then
        font_name="$2"
        shift 2
      else
        shift
      fi
      ;;
    -d)
      user_specified_dir=true
      figlet_args+=("$1")
      if [[ $# -gt 1 ]]; then
        figlet_args+=("$2")
        shift 2
      else
        shift
      fi
      ;;
    *)
      figlet_args+=("$1")
      shift
      ;;
    esac
  done

  # Fonts from all repos + figlet's bundled set are flattened into a single
  # dir by run_onchange_after_21-setup-figlet-fonts; figlet -d takes only one.
  local figlet_fonts_dir="${XDG_DATA_HOME:-$HOME/.local/share}/fonts/figlet"
  if [[ -n "$font_name" ]] && [[ "$user_specified_dir" == false ]]; then
    if [[ -d "$figlet_fonts_dir" ]]; then
      figlet -d "$figlet_fonts_dir" -f "$font_name" -w "$terminal_width" "${figlet_args[@]}" | lolcat
    else
      figlet -w "$terminal_width" "${figlet_args[@]}" | lolcat
    fi
  else
    [[ -n "$font_name" ]] && figlet_args=("-f" "$font_name" "${figlet_args[@]}")
    figlet -w "$terminal_width" "${figlet_args[@]}" | lolcat
  fi
}

# The function that rule all the change-directory functions.
# It uses common-sense and Zoxide to do its job and make my life navigating
# directories easier!
function super-cd {
  local all_dots=${1//[^.]/}
  local next_dir=""
  if [[ $# -eq 0 ]]; then
    # cd with no parameter should change to $HOME dir
    \builtin cd ~ || die "${P_RED}Error${P_RES}: Failed to change current directory to '$HOME'" || return
  elif [[ "$1" == "-/" ]]; then
    # cd with a '-' parameter plus a '/' at the end skips the "super-cd
    # previous dir" mechanism
    \builtin cd - || die "${P_RED}Error${P_RES}: Failed to change current directory to the previous one" || return
  elif [[ "$1" == "-" ]]; then
    # cd with a '-' parameter allows the user to select the previous directory
    # among the dirstack plus the zoxide last accessed
    if ! command -v fzf >/dev/null 2>&1; then
      die "${P_RED}Error${P_RES}: fzf is required for this operation"
      return 1
    fi
    typeset -a prev_stack
    prev_stack+=("${dirstack[@]}")
    # shellcheck disable=SC2296
    prev_stack+=("${(@f)$(\command zoxide query --list --exclude "$PWD" 2>/dev/null | head -50)}")
    # shellcheck disable=SC2296,SC2206
    prev_stack=(${(u)prev_stack[@]})

    if [[ "${#prev_stack[@]}" -eq 0 ]]; then
      die "${P_YEL}No previous directories available${P_RES}"
      return 1
    elif [[ "${#prev_stack[@]}" -gt 1 ]]; then
      # Inherit FZF_DEFAULT_OPTS (glyph prompt, colours, binds) so this matches
      # TAB and the other widgets, with two exceptions: `--no-sort` keeps the
      # dirstack/zoxide order intact, and `--preview-window=hidden` starts the
      # preview collapsed (fzf merges repeated --preview-window flags, so the
      # inherited right:60% geometry survives; ctrl-space reveals it on demand).
      next_dir=$(print -l -- "${prev_stack[@]}" | fzf --no-sort --preview-window=hidden)
      next_dir="${(MS)next_dir##[[:graph:]]*[[:graph:]]}"
    else
      next_dir="${prev_stack[1]}"
    fi
    if [[ -n "$next_dir" ]]; then
      \builtin cd "$next_dir" || die "${P_RED}Error${P_RES}: Failed to change current directory to '$next_dir'" || return
    fi
  elif [[ "$1" == ".." ]]; then
    # cd with a '..' parameter allows the user to select anyone of the parent
    # directories to go
    if [[ "$PWD" == "/" ]]; then
      die "${P_YEL}Already at root directory${P_RES}"
      return 0
    fi
    if ! command -v fzf >/dev/null 2>&1; then
      die "${P_RED}Error${P_RES}: fzf is required for this operation"
      return 1
    fi
    typeset -a dir_stack
    local _cur_dir
    _cur_dir=${PWD%/*}
    while [[ -n "$_cur_dir" ]]; do
      dir_stack+=("$_cur_dir")
      _cur_dir="${_cur_dir%/*}"
    done
    # Inherit FZF_DEFAULT_OPTS like above; preview starts collapsed.
    next_dir=$(print -l -- "${dir_stack[@]}" | fzf --preview-window=hidden)
    next_dir="${(MS)next_dir##[[:graph:]]*[[:graph:]]}"
    if [[ -n "$next_dir" ]]; then
      \builtin cd "$next_dir" || die "${P_RED}Error${P_RES}: Failed to change current directory to '$next_dir'" || return
    fi
  elif [[ ${#all_dots} -gt 2 ]] && [[ ${#1} -eq ${#all_dots} ]]; then
    # cd with 3 or more consecutive '.' characters as parameter will traverse
    # the directory hierarchy N times, where N is the number of '.' characters
    # minus 1.
    next_dir="../"
    for ((i = 2; i < ${#1}; i++)); do
      next_dir="${next_dir}../"
    done
    \builtin cd "$next_dir" || die "${P_RED}Error${P_RES}: Failed to change current directory to '$next_dir'" || return
  elif [[ -d "$*" ]]; then
    # when the parameter given to `super-cd` is a known directory, we use the
    # builtin `cd` command to go there
    \builtin cd "$@" || die "${P_RED}Error${P_RES}: Failed to change current directory to '$*'" || return
  else
    # when the given parameter was not match by any of the previous criterias,
    # we fallback to use Zoxide to try to change directories
    next_dir="$(\command zoxide query --exclude "$PWD" -- "$@" 2>/dev/null)"
    if [[ -n "$next_dir" ]]; then
      \builtin cd "$next_dir" || die "${P_RED}Error${P_RES}: Failed to change current directory to '$next_dir'" || return
    else
      die "${P_RED}Error${P_RES}: Failed to change current directory to '$*'"
      return 1
    fi
  fi
}
compdef _directories super-cd

# Helper function to create a directory and enter on it with one command
function take() {
  [[ $# == 1 ]] && mkdir -p -- "$1" && cd -- "$1" || die "${P_RED}Error${P_RES}: Failed to change current directory to '$1'" || return
}
compdef _directories take

# The short-form of git.
# If this function is run without parameters, it runs a `git status` on the
# current project.
function g {
  if [[ $# = 0 ]]; then
    git status --short .
  else
    git "$@"
  fi
}
compdef g=git

# A Gradle wrapper that gives preference to run `gradle` from the local
# project, unless the current project did not defined one. In that case, it
# runs the `gradle` command installed in the system.
function gg {
  if [[ -x "./gradlew" ]]; then
    ./gradlew "$@"
  else
    gradle "$@"
  fi
}
compdef gg=gradle

# `preview` lives at ~/.local/bin/preview as a standalone
# script. fzf invokes previews via `$SHELL -c '<cmd>'` in a
# non-interactive subshell that doesn't source this file, so a zsh
# function here wouldn't be visible to fzf. (zsh's `typeset -fx` does
# not propagate function definitions to child zsh shells the way
# bash's `export -f` does.) The script is found via PATH and works
# everywhere.

# A Yazi wrapper that allows me to chage the current working directory to where
# I was in Yazi before I quit.
# Usually, one would press `Q` to exit Yazi without changing directories, and
# `q` to change the current working dir. However, in my Yazi configuration,
# these keybindings are inverted.
function y() {
  local tmp
  tmp="$(mktemp -t "yazi-cwd.XXXXXX")"
  yazi "$@" --cwd-file="$tmp"
  IFS= read -r -d '' cwd <"$tmp"
  rm -f -- "$tmp"
  if [ -n "$cwd" ] && [ "$cwd" != "$PWD" ]; then
    \builtin cd -- "$cwd" ||
      die "${P_RED}Error${P_RES}: Failed to change current directory to '$cwd'" ||
      return
  fi
}

# `pi-local` runs the Pi coding agent against the local 32K-context config
# home (~/.pi/agent-local) with an isolated session store, so local and cloud
# sessions never resume into the wrong config. Plain `pi` stays cloud.
function pi-local() {
  PI_CODING_AGENT_DIR="$HOME/.pi/agent-local" \
  PI_CODING_AGENT_SESSION_DIR="$HOME/.pi/agent-local/sessions" \
    pi "$@"
}
