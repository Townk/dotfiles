source "${0:A:h}/_lib.sh"

# This is the main function to update my system.
# It is idempotent and it cleans up after itself.
# I usually run this function every day before starting my work.
function system-update {
  print -P -- "\n${C_BLU}System Update\n-------------${C_RES}"
  print -P -- "\n  Updating Homebrew sources...\n"
  brew update || die "\n${C_RED}Error${C_RES}: Failed to update Homebrew!" || return
  print -P -- "\n🍻 Upgrade Homebrew Bundle...\n"
  cat ~/.config/brewfile/Brewfile | brew bundle install -q --cleanup --upgrade --file=- || die "\n${C_RED}Error${C_RES}: Failed to upgrade Homebrew Bundle!" || return
  print -P -- "\n🍺 Upgrade Homebrew formulas...\n"
  brew upgrade || die "\n${C_RED}Error${C_RES}: Failed to upgrade Homebrew formulas!" || return
  print -P -- "\n🍺 Upgrade Homebrew casks...\n"
  brew upgrade --cask --greedy-latest || die "\n${C_RED}Error${C_RES}: Failed to upgrade Homebrew casks!" || return
  print -P -- "\n🧹 Cleanning up Homebrew artifacts...\n"
  brew cleanup -q --prune=all || die "\n${C_RED}Error${C_RES}: Failed to clean up Homebrew files!" || return
  print -P -- "\n🦆 Upgrade Yazi plugins...\n"
  ya pkg upgrade || die "\n${C_RED}Error${C_RES}: Failed to upgrade Yazi plugins!" || return
  print -P -- "\n🔧 Upgrade Mise tools...\n"
  mise upgrade
  mise prune -y
  print -P -- "\n👍 System updated ${C_BWH}successfully${C_RES}!\n"

  #if command -v system-update-work >/dev/null; then
  #  system-update-work
  #fi

  print -P -- "\n🐚 Updating zsh4humans...\n"
  z4h update || die "\n${C_RED}Error${C_RES}: Failed to upgrade zsh4humans!" || return
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
#  Available Commands%f
#
#  SYSTEM                         󰇺 PROCESSORS                      UTILITIES
#   ------                           ----------                       ---------
#   tldr      - Extra help           jq      - JSON processor         7zz       - 7-Zip cli
#   btm       - 'top' (bottom)       gron    - JSON to list assign    eva       - Calculator
#   procs     - Processes 'ps'       xq      - XML processor          fd        - 'find'
#   duf       - Disk usage           yq      - YAML processor         fend      - Unit conversion
#   y         - Files (yazi)         pandoc  - Any text processor     gh        - GitHub cli
#                                                                     git       - Version control
#  NETWORK                        󰊪 VISUALIZERS                      grex      - RegEx generator
#   -------                          -----------                      hyperfine - Benchmark
#   bandwhich - Network use          jless   - JSON tree              rg        - 'grep' (ripgrep)
#   doggo     - DNS look-up          tokei   - Code metrics           t-rec     - Terminal recorder
#   gping     - Latency graph        tv      - csv (tidy-viewer)      unrar     - Handle .rar format
# --------------------------------------------------------------------------------------------------
function terminal_commands() {
  print -P -- "$C_BLU Available Commands$C_RES

  ${C_YEL} SYSTEM${C_RES}                         ${C_YEL}󰇺 PROCESSORS${C_RES}                     ${C_YEL} UTILITIES${C_RES}
  ${C_YEL}------${C_RES}                           ${C_YEL}----------${C_RES}                       ${C_YEL}---------${C_RES}
  ${C_BWH}btm${C_RES}       - 'top' (bottom)       ${C_BWH}jq${C_RES}      - JSON processor         ${C_BWH}7zz${C_RES}       - 7-Zip cli
  ${C_BWH}duf${C_RES}       - Disk usage 'du'      ${C_BWH}pandoc${C_RES}  - Any text processor     ${C_BWH}eva${C_RES}       - Calculator
  ${C_BWH}y${C_RES}         - Files (yazi)         ${C_BWH}gron${C_RES}    - JSON to list assign    ${C_BWH}fd${C_RES}        - 'find'
  ${C_BWH}procs${C_RES}     - Processes 'ps'       ${C_BWH}xq${C_RES}      - XML processor          ${C_BWH}fend${C_RES}      - Unit conversion
  ${C_BWH}tldr${C_RES}      - Extra help           ${C_BWH}yq${C_RES}      - YAML processor         ${C_BWH}gh${C_RES}        - GitHub cli
                                                                    ${C_BWH}git${C_RES}       - Version control
  ${C_YEL} NETWORK                        ${C_YEL}󰊪 VISUALIZERS                    ${C_BWH}grex${C_RES}      - RegEx generator
  ${C_YEL}-------                          ${C_YEL}-----------                      ${C_BWH}hyperfine${C_RES} - Benchmark
  ${C_BWH}bandwhich${C_RES} - Network use          ${C_BWH}jless${C_RES}   - JSON tree              ${C_BWH}rg${C_RES}        - 'grep' (ripgrep)
  ${C_BWH}doggo${C_RES}     - DNS look-up          ${C_BWH}tokei${C_RES}   - Code metrics           ${C_BWH}t-rec${C_RES}     - Terminal recorder
  ${C_BWH}gping${C_RES}     - Latency graph        ${C_BWH}tv${C_RES}      - csv (tidy-viewer)      ${C_BWH}unrar${C_RES}     - Handle .rar format
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

  if [[ -n "$font_name" ]] && [[ "$user_specified_dir" == false ]]; then
    local figlet_font_dir
    local font_file
    figlet_font_dir="$(figlet -I 2)"
    font_file=$(fd -1 -e flf -e flf.gz -e tlf -e tlf.gz -a "$font_name" "$XDG_DATA_HOME/fonts" "$figlet_font_dir" 2>/dev/null)
    if [[ -n "$font_file" ]]; then
      figlet -d "${font_file%/*}" -f "$font_name" -w "$terminal_width" "${figlet_args[@]}" | lolcat
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
    \builtin cd ~ || die "${C_RED}Error${C_RES}: Failed to change current directory to '$HOME'" || return
  elif [[ "$1" == "-/" ]]; then
    # cd with a '-' parameter plus a '/' at the end skips the "super-cd
    # previous dir" mechanism
    \builtin cd - || die "${C_RED}Error${C_RES}: Failed to change current directory to the previous one" || return
  elif [[ "$1" == "-" ]]; then
    # cd with a '-' parameter allows the user to select the previous directory
    # among the dirstack plus the zoxide last accessed
    typeset -a prev_stack
    [[ -n "$dirstack" ]] || declare -a dirstack
    prev_stack+=("${dirstack[@]}")
    # shellcheck disable=SC2296
    prev_stack+=("${(@f)$(\command zoxide query --list --exclude "$PWD" 2> /dev/null)}")
    if [[ "${#prev_stack[@]}" -gt 1 ]]; then
      next_dir=$(print -l -- "${prev_stack[@]}" | fzf --no-sort)
      next_dir="${next_dir#$'\n'}"
    elif [[ "${#prev_stack[@]}" -eq 1 ]]; then
      next_dir="${prev_stack[0]}"
    fi
    if [[ -n "$next_dir" ]]; then
      \builtin cd "$next_dir" || die "${C_RED}Error${C_RES}: Failed to change current directory to '$next_dir'" || return
    fi
  elif [[ "$1" == ".." ]]; then
    # cd with a '..' parameter allows the user to select anyone of the parent
    # directories to go
    typeset -a dir_stack
    local _cur_dir
    _cur_dir=${PWD%/*}
    while [[ -n "$_cur_dir" ]]; do
      dir_stack+=("$_cur_dir")
      _cur_dir="${_cur_dir%/*}"
    done
    next_dir=$(print -l -- "${dir_stack[@]}" | fzf)
    next_dir="${(MS)next_dir##[[:graph:]]*[[:graph:]]}"
    if [[ -n "$next_dir" ]]; then
      \builtin cd "$next_dir" || die "${C_RED}Error${C_RES}: Failed to change current directory to '$next_dir'" || return
    fi
  elif [[ ${#all_dots} -gt 2 ]] && [[ ${#1} -eq ${#all_dots} ]]; then
    # cd with 3 or more consecutive '.' characters as parameter will traverse
    # the directory hierarchy N times, where N is the number of '.' characters
    # minus 1.
    next_dir="../"
    for ((i = 2; i < ${#1}; i++)); do
      next_dir="${next_dir}../"
    done
    # next_dir=$(\builtin printf '../%.0s' {2..${#1}})
    \builtin cd "$next_dir" || die "${C_RED}Error${C_RES}: Failed to change current directory to '$next_dir'" || return
  elif [[ -d "$*" ]]; then
    # when the parameter given to `super-cd` is a known directory, we use the
    # builtin `cd` command to go there
    \builtin cd "$@" || die "${C_RED}Error${C_RES}: Failed to change current directory to '$*'" || return
  else
    # when the given parameter was not match by any of the previous criterias,
    # we fallback to use Zoxide to try to change directories
    next_dir="$(\command zoxide query --exclude "$PWD" -- "$@" 2>/dev/null)"
    if [[ -n "$next_dir" ]]; then
      \builtin cd "$next_dir" || die "${C_RED}Error${C_RES}: Failed to change current directory to '$next_dir'" || return
    else
      die "${C_RED}Error${C_RES}: Failed to change current directory to '$*'"
      return 1
    fi
  fi
}
compdef _directories super-cd

# Helper function to create a directory and enter on it with one command
function take() {
  [[ $# == 1 ]] && mkdir -p -- "$1" && cd -- "$1" || die "${C_RED}Error${C_RES}: Failed to change current directory to '$1'" || return
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

# A helper function to be used as an `fzf` previewer.
function fzf-preview {
  if [[ -d "$1" ]]; then
    eza -F -h --group-directories-first --icons --hyperlink --tree --color=always "$1" | head -200
  elif [[ ! -f "$1" ]]; then
    echo "Nothing to preview"
  else
    (bat --theme=OneHalfDark --style=numbers,changes --color=always "$1" ||
      highlight -O ansi -l "$1" ||
      \cat "$1") 2>/dev/null | head -200
  fi
}

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
      die "${C_RED}Error${C_RES}: Failed to change current directory to '$cwd'" ||
      return
  fi
}
