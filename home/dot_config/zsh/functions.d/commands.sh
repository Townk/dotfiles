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

# I decide to make my MOTD screen a function to allow me to call it
# arbitrarially if I wanted.
function motd() {
  macchina
}

# Quick function to print my outstanding additions to my terminal
#
# Here is the command template with no color markers to make it easy to change:
#
# 0                                                                                               98
# --------------------------------------------------------------------------------------------------
#  Available Commands%f
#
#  SYSTEM                         󰇺 PROCESSORS                      UTILITIES
#   ------                           ----------                       ---------
#   tldr      - Extra help           jq      - JSON processor         7zz       - 7-Zip cli
#   btm       - 'top' (bottom)       gron    - JSON to list assign    eva       - Calculator
#   procs     - Processes 'ps'       xq      - XML processor          fd        - 'find'
#   duf       - Disk usage           yq      - YAML processor         fend      - Unit conversion
#   y         - Files (yazi)         pandoc  - Any text processor     gh        - GitHub cli
#                                                                     git       - Version control
#  NETWORK                        󰊪 VISUALIZERS                      grex      - RegEx generator
#   -------                          -----------                      hyperfine - Benchmark
#   bandwhich - Network use          jless   - JSON tree              rg        - 'grep' (ripgrep)
#   doggo     - DNS look-up          tokei   - Code metrics           t-rec     - Terminal recorder
#   gping     - Latency graph        tv      - csv (tidy-viewer)      unrar     - Handle .rar format
# --------------------------------------------------------------------------------------------------
function terminal_commands() {
  print -P -- "$P_BLU Available Commands$P_RES

  ${P_YEL} SYSTEM${P_RES}                         ${P_YEL}󰇺 PROCESSORS${P_RES}                     ${P_YEL} UTILITIES${P_RES}
  ${P_YEL}--------${P_RES}                         ${P_YEL}------------${P_RES}                     ${P_YEL}-----------${P_RES}
  ${P_BWH}btm${P_RES}       - 'top' (bottom)       ${P_BWH}jq${P_RES}      - JSON processor         ${P_BWH}7zz${P_RES}       - 7-Zip cli
  ${P_BWH}duf${P_RES}       - Disk usage 'du'      ${P_BWH}pandoc${P_RES}  - Any text processor     ${P_BWH}eva${P_RES}       - Calculator
  ${P_BWH}y${P_RES}         - Files (yazi)         ${P_BWH}gron${P_RES}    - JSON to list assign    ${P_BWH}fd${P_RES}        - 'find'
  ${P_BWH}procs${P_RES}     - Processes 'ps'       ${P_BWH}xq${P_RES}      - XML processor          ${P_BWH}fend${P_RES}      - Unit conversion
  ${P_BWH}tldr${P_RES}      - Extra help           ${P_BWH}yq${P_RES}      - YAML processor         ${P_BWH}gh${P_RES}        - GitHub cli
                                                                    ${P_BWH}git${P_RES}       - Version control
  ${P_YEL} NETWORK                        ${P_YEL}󰊪 VISUALIZERS                    ${P_BWH}grex${P_RES}      - RegEx generator
  ${P_YEL}---------                        ${P_YEL}-------------                    ${P_BWH}hyperfine${P_RES} - Benchmark
  ${P_BWH}bandwhich${P_RES} - Network use          ${P_BWH}jless${P_RES}   - JSON tree              ${P_BWH}rg${P_RES}        - 'grep' (ripgrep)
  ${P_BWH}doggo${P_RES}     - DNS look-up          ${P_BWH}tokei${P_RES}   - Code metrics           ${P_BWH}t-rec${P_RES}     - Terminal recorder
  ${P_BWH}gping${P_RES}     - Latency graph        ${P_BWH}tv${P_RES}      - csv (tidy-viewer)      ${P_BWH}unrar${P_RES}     - Handle .rar format
  "
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
